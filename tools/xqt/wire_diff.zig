//! `xqt wire-diff pg [CASES-FILE...]`: the differential test of the
//! PostgreSQL wire server (`xqlite serve --pg`) against a real
//! PostgreSQL, with psql as the client on both sides.
//!
//! Where `xqt dialect-diff pg` compares the rows of `xqlite sql`, this one
//! compares what a user of psql sees: the same psql (16, from the
//! postgres:16-alpine container) runs the same script against the
//! server and against `xqlite serve --pg` on a new, empty database, and
//! its whole output (aligned tables, command tags, NOTICEs, ERROR lines
//! with LINE/DETAIL/HINT, the meta-commands \d, \dt, \gdesc, \bind ...)
//! must be the same. Each case gets its own xqlite server (port 0, the
//! port read from its "listening on" line) and database file; on the
//! PostgreSQL side each worker has a database of its own
//! (xqt_wire_N), which each case empties first, as dialect-diff does.
//! Both sides connect with `-U postgres -d xqt_wire_N`, so the names
//! psql prints (owner, database) are the same.
//!
//! A cases file is a list of cases: a line "-- case: NAME" starts one,
//! and the lines up to the next are its psql input. The lines before the
//! first case are a setup that runs (quietly) before every case of that
//! file. A line "-- xqt: mask-oids" in a case replaces every run of five
//! or more digits in its output by "<oid>" (on both sides): the OIDs of
//! the objects a case makes are not the same.
//!
//! A case that differs is put in one of three classes:
//!
//! - result: xqlite answers, but not with what PostgreSQL answers (or
//!   answers where PostgreSQL raises an error);
//! - error: xqlite raises an error where PostgreSQL does not (more ERROR
//!   lines than PostgreSQL's);
//! - format: the same output once case, blanks, the table rules (- + |),
//!   the text of error messages and the lines around them (LINE and its
//!   caret, DETAIL, HINT, CONTEXT, NOTICE, WARNING) and the server's
//!   version() string are ignored.
//!
//! The client is reached with $PG_WIRE_EXEC (default "podman exec -i
//! xq-pg"), which must run `sh -c` next to a psql: the standard output
//! and error are merged inside the container so that their order is
//! psql's. The container reaches xqlite at $PG_WIRE_HOST (default
//! host.containers.internal, the host under macOS podman), and xqlite
//! listens on $PG_WIRE_LISTEN (default 0.0.0.0).
//!
//! Not part of `zig build check`: it needs a server.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const Check = xqt.Check;
const dialect_diff = @import("dialect_diff.zig");

pub const usage =
    \\usage: xqt wire-diff pg [--out DIR] [CASES-FILE...]
    \\       xqt wire-diff pg --regress [--out DIR] [TEST...]
    \\
    \\  Runs each case with psql against PostgreSQL and against `xqlite serve
    \\  --pg` (a server and database per case) and compares psql's output.
    \\  Default cases: tools/dialect/pg-wire-cases.txt and
    \\  tools/dialect/pg-client-cases.txt.
    \\
    \\  --regress   instead run PostgreSQL's regression tests in
    \\              tools/dialect/pg-regress ($PG_REGRESS_DIR): sql/TEST.sql
    \\              against xqlite, scored per statement against
    \\              expected/TEST.out (all tests, or those named)
    \\  --out DIR   write each case's outputs to DIR/NAME.pg and DIR/NAME.xq
    \\              (with --regress: xqlite's output to DIR/TEST.out)
    \\
    \\  $PG_WIRE_EXEC    runs `sh -c ...` next to psql (default "podman exec -i xq-pg")
    \\  $PG_WIRE_HOST    the host where psql reaches xqlite (default host.containers.internal)
    \\  $PG_WIRE_LISTEN  the address xqlite listens on (default 0.0.0.0)
    \\
    \\Start the server first:
    \\  podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
    \\
;

const default_files = [_][]const u8{ "tools/dialect/pg-wire-cases.txt", "tools/dialect/pg-client-cases.txt" };
const container = "podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine";

/// Empties the worker's database, as dialect-diff's prelude, quietly.
const pg_reset = "\\set QUIET on\n" ++
    "SET client_min_messages = warning; DROP SCHEMA public CASCADE; CREATE SCHEMA public;" ++
    " DO $$DECLARE r record; BEGIN FOR r IN SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg\\_%' AND nspname NOT IN ('public', 'information_schema')" ++
    " LOOP EXECUTE 'DROP SCHEMA ' || quote_ident(r.nspname) || ' CASCADE'; END LOOP; END$$;\n" ++
    "RESET client_min_messages;\n";

const max_databases = 8;

pub const Class = enum { result, @"error", format };

const Case = struct {
    name: []const u8,
    file: []const u8,
    setup: []const u8,
    sql: []const u8,
    mask_oids: bool,
    server: []const u8 = "",
    xq: []const u8 = "",
};

const Slots = struct {
    mutex: Io.Mutex = .init,
    freed: Io.Condition = .init,
    free: std.ArrayList(usize),

    fn acquire(s: *Slots, io: Io) usize {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        while (true) {
            if (s.free.pop()) |i| return i;
            s.freed.waitUncancelable(io, &s.mutex);
        }
    }

    fn release(s: *Slots, io: Io, i: usize) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.free.appendAssumeCapacity(i);
        s.freed.signal(io);
    }
};

const Ctx = struct {
    exec: []const []const u8,
    host: []const u8,
    listen: []const u8,
    slots: *Slots,
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (args.len < 1 or !(std.mem.eql(u8, args[0], "pg") or std.mem.eql(u8, args[0], "postgres"))) {
        try out.writeAll(usage);
        return 2;
    }
    var out_dir: ?[]const u8 = null;
    var regress = false;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            i += 1;
            if (i == args.len) {
                try out.writeAll(usage);
                return 2;
            }
            out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--regress")) {
            regress = true;
        } else try files.append(arena, args[i]);
    }
    if (files.items.len == 0 and !regress) for (default_files) |f| try files.append(arena, try std.fs.path.join(arena, &.{ cfg.root, f }));

    var cases: std.ArrayList(Case) = .empty;
    if (!regress) for (files.items) |path| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
            try out.print("xqt wire-diff: cannot read {s}: {t}\n", .{ path, err });
            return 2;
        };
        try parseCases(arena, std.fs.path.basename(path), text, &cases);
    };

    const exec_text = cfg.environ.get("PG_WIRE_EXEC") orelse "podman exec -i xq-pg";
    var exec: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, exec_text, " \t\n");
    while (words.next()) |w| try exec.append(arena, w);
    var ctx: Ctx = .{
        .exec = exec.items,
        .host = cfg.environ.get("PG_WIRE_HOST") orelse "host.containers.internal",
        .listen = cfg.environ.get("PG_WIRE_LISTEN") orelse "0.0.0.0",
        .slots = undefined,
    };

    const probe = dialect_diff.runMerged(arena, io, try psqlArgv(arena, &ctx, null, "postgres"), "SELECT 1;\n") catch |err|
        dialect_diff.Merged{ .ok = false, .out = try std.fmt.allocPrint(arena, "cannot run {s}: {t}", .{ exec.items[0], err }) };
    if (!probe.ok) {
        try out.print(
            \\xqt wire-diff: cannot reach PostgreSQL with "{s} sh -c psql" ($PG_WIRE_EXEC):
            \\{s}
            \\Start it with
            \\  {s}
            \\
        , .{ exec_text, std.mem.trimEnd(u8, probe.out, "\n"), container });
        try out.flush();
        return 1;
    }
    if (regress) {
        const dir = cfg.environ.get("PG_REGRESS_DIR") orelse try std.fs.path.join(arena, &.{ cfg.root, "tools/dialect/pg-regress" });
        return runRegress(gpa, io, cfg, out, &ctx, dir, files.items, out_dir);
    }

    const n_slots = @max(1, @min(cfg.jobs, cases.items.len, max_databases));
    var slots: Slots = .{ .free = try .initCapacity(arena, n_slots) };
    for (0..n_slots) |s| slots.free.appendAssumeCapacity(n_slots - 1 - s);
    ctx.slots = &slots;
    var make: Io.Writer.Allocating = .init(arena);
    var drop: Io.Writer.Allocating = .init(arena);
    for (0..n_slots) |s| {
        try make.writer.print("DROP DATABASE IF EXISTS xqt_wire_{d};\nCREATE DATABASE xqt_wire_{d};\n", .{ s, s });
        try drop.writer.print("DROP DATABASE IF EXISTS xqt_wire_{d};\n", .{s});
    }
    const admin = try psqlArgv(arena, &ctx, null, "postgres");
    const r = try dialect_diff.runMerged(arena, io, admin, make.written());
    if (!r.ok) {
        try out.print("xqt wire-diff: cannot make the databases of the workers:\n{s}", .{r.out});
        return 1;
    }
    defer _ = dialect_diff.runMerged(arena, io, admin, drop.written()) catch {};

    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "wire-diff", .show = .failures });
    defer suite.deinit();
    for (cases.items) |*cs| try suite.add(cs.name, runCase, .{ &ctx, cs });
    suite.run();

    if (out_dir) |dir| {
        try Io.Dir.cwd().createDirPath(io, dir);
        for (cases.items) |cs| {
            const base = try std.fs.path.join(arena, &.{ dir, cs.name });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.mem.concat(arena, u8, &.{ base, ".pg" }), .data = cs.server });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.mem.concat(arena, u8, &.{ base, ".xq" }), .data = cs.xq });
        }
    }

    var counts: [3]usize = .{ 0, 0, 0 };
    var errors: usize = 0;
    var dw: Io.Writer.Allocating = .init(gpa);
    defer dw.deinit();
    for (cases.items, 0..) |cs, n| {
        if (suite.outcome(n).status == .failed) {
            errors += 1;
            continue;
        }
        if (std.mem.eql(u8, cs.server, cs.xq)) continue;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const class = try classify(scratch.allocator(), cs.sql, cs.server, cs.xq);
        counts[@backingInt(class)] += 1;
        try out.print("DIFF [{t}] {s} ({s})\n", .{ class, cs.name, cs.file });
        dw.clearRetainingCapacity();
        try xqt.diff.write(&dw.writer, scratch.allocator(), "PostgreSQL", "xqlite", cs.server, cs.xq, .{});
        var diff_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, dw.written(), "\n"), '\n');
        var k: usize = 0;
        while (diff_lines.next()) |line| : (k += 1) {
            if (k == 40) break;
            try out.print("  {s}\n", .{line});
        }
    }
    const fail = counts[0] + counts[1] + counts[2];
    try out.print("pg-wire-diff: {d}/{d} cases agree", .{ cases.items.len - fail - errors, cases.items.len });
    if (fail > 0) try out.print(" (differ: {d} result, {d} error, {d} format)", .{ counts[0], counts[1], counts[2] });
    if (errors > 0) try out.print(" ({d} could not run)", .{errors});
    try out.writeAll("\n");
    try out.flush();
    return @intFromBool(fail + errors > 0);
}

/// `EXEC... sh -c "psql ... 2>&1"` to PostgreSQL itself.
fn psqlArgv(arena: Allocator, ctx: *const Ctx, env: ?[]const u8, db: []const u8) ![]const []const u8 {
    const cmd = try std.fmt.allocPrint(arena, "{s} 2>&1", .{try psqlCommand(arena, env, db, "")});
    return std.mem.concat(arena, []const u8, &.{ ctx.exec, &.{ "sh", "-c", cmd } });
}

/// "[ENV] psql -X -U postgres -d DB [FLAGS]", the command line for sh.
fn psqlCommand(arena: Allocator, env: ?[]const u8, db: []const u8, flags: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}psql -X -U postgres -d {s} {s}", .{ env orelse "", if (env != null) " " else "", db, flags });
}

fn runCase(c: *Check, ctx: *Ctx, cs: *Case) !void {
    // The setup runs quietly; the case echoes its input, so that each
    // output says what it answers.
    const quiet_setup = try std.mem.concat(c.arena, u8, &.{ "\\set QUIET on\n", cs.setup, "\\set QUIET off\n\\set ECHO all\n" });
    // Both sides name the worker's database, so that psql prints the
    // same name; xqlite takes any.
    const slot = ctx.slots.acquire(c.io);
    const db = try std.fmt.allocPrint(c.arena, "xqt_wire_{d}", .{slot});
    const server_in = try std.mem.concat(c.arena, u8, &.{ pg_reset, quiet_setup, cs.sql });
    const server_raw = dialect_diff.runMerged(c.arena, c.io, try psqlArgv(c.arena, ctx, null, db), server_in);
    ctx.slots.release(c.io, slot);

    const xq_in = try std.mem.concat(c.arena, u8, &.{ quiet_setup, cs.sql });
    const xq_raw = try runXq(c, ctx, try psqlCommand(c.arena, null, db, ""), xq_in);

    cs.server = try normalize(c.keep, (try server_raw).out, cs.mask_oids);
    cs.xq = try normalize(c.keep, xq_raw, cs.mask_oids);
}

/// Starts `xqlite serve --pg 0` on a new database in the check's
/// directory and runs `psql` (a psqlCommand without the host and port,
/// which this adds) with `input` against it.
fn runXq(c: *Check, ctx: *const Ctx, psql: []const u8, input: []const u8) ![]u8 {
    const log = "serve.log";
    var server = try c.spawn(&.{ c.cfg.xq, "serve", try c.path("wire.db"), "--pg", "0", "--host", ctx.listen }, .{ .output = log });
    defer server.kill();
    const port = try waitListening(c, log);
    const cmd = try std.fmt.allocPrint(c.arena, "{s} -h {s} -p {d} 2>&1", .{ psql, ctx.host, port });
    const argv = try std.mem.concat(c.arena, []const u8, &.{ ctx.exec, &.{ "sh", "-c", cmd } });
    return (try dialect_diff.runMerged(c.arena, c.io, argv, input)).out;
}

// ---------------------------------------------------------------- --regress

/// A test of PostgreSQL's regression suite: sql/NAME.sql run with psql
/// as pg_regress runs it, against expected/NAME.out.
const Test = struct {
    name: []const u8,
    sql: []const u8,
    expected: []const u8,
    setup: []const u8,
    got: []const u8 = "",
    /// Statements with output in expected/NAME.out, and of them those
    /// whose output xqlite gives.
    total: usize = 0,
    same: usize = 0,
    classes: [3]usize = .{ 0, 0, 0 },
};

fn runRegress(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, ctx: *Ctx, dir: []const u8, names: []const []const u8, out_dir: ?[]const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const setup = Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, "setup.sql" }), arena, .unlimited) catch "";

    var list: std.ArrayList([]const u8) = .empty;
    if (names.len > 0) try list.appendSlice(arena, names) else {
        var d = Io.Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ dir, "sql" }), .{ .iterate = true }) catch |err| {
            try out.print("xqt wire-diff: cannot open {s}/sql: {t}\n", .{ dir, err });
            return 2;
        };
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".sql"))
            try list.append(arena, try arena.dupe(u8, e.name[0 .. e.name.len - 4]));
        std.mem.sort([]const u8, list.items, {}, struct {
            fn f(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.f);
    }
    const tests = try arena.alloc(Test, list.items.len);
    for (list.items, tests) |name, *t| {
        const sql_path = try std.fmt.allocPrint(arena, "{s}/sql/{s}.sql", .{ dir, name });
        const out_path = try std.fmt.allocPrint(arena, "{s}/expected/{s}.out", .{ dir, name });
        t.* = .{
            .name = name,
            .setup = setup,
            .sql = Io.Dir.cwd().readFileAlloc(io, sql_path, arena, .unlimited) catch |err| {
                try out.print("xqt wire-diff: cannot read {s}: {t}\n", .{ sql_path, err });
                return 2;
            },
            .expected = Io.Dir.cwd().readFileAlloc(io, out_path, arena, .unlimited) catch |err| {
                try out.print("xqt wire-diff: cannot read {s}: {t}\n", .{ out_path, err });
                return 2;
            },
        };
    }

    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "wire-diff-regress", .show = .failures });
    defer suite.deinit();
    for (tests) |*t| try suite.add(t.name, runTest, .{ ctx, t });
    suite.run();

    var total: usize = 0;
    var same: usize = 0;
    var classes: [3]usize = .{ 0, 0, 0 };
    for (tests, 0..) |t, n| {
        if (out_dir) |od| {
            try Io.Dir.cwd().createDirPath(io, od);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}.out", .{ od, t.name }), .data = t.got });
        }
        if (suite.outcome(n).status == .failed) {
            try out.print("{s}: could not run\n", .{t.name});
            continue;
        }
        try out.print("{s}: {d}/{d} statements give the expected output (differ: {d} result, {d} error, {d} format)\n", .{ t.name, t.same, t.total, t.classes[0], t.classes[1], t.classes[2] });
        total += t.total;
        same += t.same;
        for (&classes, t.classes) |*a, b| a.* += b;
    }
    try out.print("pg-regress: {d}/{d} statements ({d}.{d}%) give the expected output (differ: {d} result, {d} error, {d} format)\n", .{
        same,       total,      same * 100 / @max(total, 1), (same * 1000 / @max(total, 1)) % 10,
        classes[0], classes[1], classes[2],
    });
    try out.flush();
    return @intFromBool(same != total or suite.failed() > 0);
}

fn runTest(c: *Check, ctx: *Ctx, t: *Test) !void {
    // As pg_regress runs a test: psql -X -a -q with its variables and the
    // time zone and date style the expected files were made with. The
    // setup runs first, not echoed.
    const psql = try psqlCommand(c.arena, "PGTZ=PST8PDT PGDATESTYLE='Postgres, MDY'", "regression", "-q -v HIDE_TABLEAM=on -v HIDE_TOAST_COMPRESSION=on");
    const input = try std.mem.concat(c.arena, u8, &.{ t.setup, "\\set ECHO all\n", t.sql });
    const raw = try runXq(c, ctx, psql, input);
    t.got = try normalize(c.keep, raw, false);

    const want = try segments(c.arena, t.sql, t.expected);
    const got = try segments(c.arena, t.sql, t.got);
    if (want.len != got.len) return c.abort("the output does not echo the input as expected/{s}.out does", .{t.name});
    // Segment 0 is what comes before the first echoed line (the setup's
    // errors): no statement of the test.
    for (want[1..], got[1..]) |w, g| {
        if (!hasOutput(w)) continue;
        t.total += 1;
        if (std.mem.eql(u8, w, g)) {
            t.same += 1;
            continue;
        }
        t.classes[@backingInt(try classifyOne(c.arena, w, g))] += 1;
    }
}

/// Whether a segment has more than its echoed input line.
fn hasOutput(seg: []const u8) bool {
    const nl = std.mem.indexOfScalar(u8, seg, '\n') orelse return false;
    return std.mem.trim(u8, seg[nl + 1 ..], " \n").len > 0;
}

/// The port of "xqlite serve: listening on ADDR:PORT (postgres, ..."
/// in the server's log, waited for up to 10 s.
fn waitListening(c: *Check, log: []const u8) !u16 {
    var waited: i64 = 0;
    while (waited < 10_000) : (waited += 20) {
        const text = c.readFile(log) catch "";
        if (std.mem.indexOf(u8, text, "listening on ")) |at| {
            const rest = text[at + "listening on ".len ..];
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const colon = std.mem.lastIndexOfScalar(u8, rest[0..sp], ':') orelse continue;
            return std.fmt.parseUnsigned(u16, rest[colon + 1 .. sp], 10) catch continue;
        }
        if (std.mem.indexOf(u8, text, "xqlite serve:") != null and std.mem.indexOf(u8, text, "listening") == null)
            return c.abort("xqlite serve failed:\n{s}", .{text});
        c.sleep(20);
    }
    return c.abort("xqlite serve did not start in 10 s:\n{s}", .{c.readFile(log) catch ""});
}

/// The cases of a file: "-- case: NAME" starts one; the lines before the
/// first are the file's setup.
fn parseCases(arena: Allocator, file: []const u8, text: []const u8, cases: *std.ArrayList(Case)) !void {
    var setup: std.ArrayList(u8) = .empty;
    var sql: std.ArrayList(u8) = .empty;
    const first = cases.items.len;
    var it = std.mem.splitScalar(u8, if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "-- case:")) {
            if (cases.items.len > first) cases.items[cases.items.len - 1].sql = try sql.toOwnedSlice(arena);
            const name = std.mem.trim(u8, line["-- case:".len..], " ");
            try cases.append(arena, .{ .name = name, .file = file, .setup = "", .sql = "", .mask_oids = false });
        } else if (cases.items.len > first) {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line, " "), "-- xqt: mask-oids")) {
                cases.items[cases.items.len - 1].mask_oids = true;
                continue;
            }
            try sql.appendSlice(arena, line);
            try sql.append(arena, '\n');
        } else {
            try setup.appendSlice(arena, line);
            try setup.append(arena, '\n');
        }
    }
    if (cases.items.len > first) cases.items[cases.items.len - 1].sql = try sql.toOwnedSlice(arena);
    const s = try setup.toOwnedSlice(arena);
    for (cases.items[first..]) |*cs| cs.setup = s;
}

// ---------------------------------------------------------------- normalizing

/// What differs between two servers and is not the answer: psql's "psql:"
/// line prefixes (line numbers differ by the reset sent to PostgreSQL)
/// and, with mask_oids, runs of five or more digits.
fn normalize(gpa: Allocator, text: []const u8, mask_oids: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        var line = raw;
        if (std.mem.startsWith(u8, line, "psql:<stdin>:")) {
            var j: usize = "psql:<stdin>:".len;
            while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
            if (std.mem.startsWith(u8, line[j..], ": ")) line = line[j + 2 ..];
        }
        if (!mask_oids) {
            try out.appendSlice(gpa, line);
            continue;
        }
        var k: usize = 0;
        while (k < line.len) {
            if (std.ascii.isDigit(line[k])) {
                var e = k;
                while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
                const word = (k == 0 or !std.ascii.isAlphanumeric(line[k - 1])) and (e == line.len or !std.ascii.isAlphanumeric(line[e]));
                try out.appendSlice(gpa, if (e - k >= 5 and word) "<oid>" else line[k..e]);
                k = e;
            } else {
                try out.append(gpa, line[k]);
                k += 1;
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The class of a case whose outputs differ (see the top of the file).
/// psql echoes the input, so the outputs split into the answers of each
/// input line; each pair of answers that differ gets a class, and the
/// case gets the worst one (result, then error, then format).
pub fn classify(arena: Allocator, input: []const u8, server: []const u8, xq: []const u8) !Class {
    const a = try segments(arena, input, server);
    const b = try segments(arena, input, xq);
    if (a.len != b.len) return classifyOne(arena, server, xq);
    var worst: ?Class = null;
    for (a, b) |sa, sb| {
        if (std.mem.eql(u8, sa, sb)) continue;
        const class = try classifyOne(arena, sa, sb);
        if (worst == null or @backingInt(class) < @backingInt(worst.?)) worst = class;
    }
    return worst orelse classifyOne(arena, server, xq);
}

fn classifyOne(arena: Allocator, server: []const u8, xq: []const u8) !Class {
    if (countErrors(xq) > countErrors(server)) return .@"error";
    if (std.mem.eql(u8, try loose(arena, server), try loose(arena, xq))) return .format;
    return .result;
}

/// The output cut before each echoed line of the input, in order.
fn segments(arena: Allocator, input: []const u8, output: []const u8) ![]const []const u8 {
    var want = std.mem.splitScalar(u8, input, '\n');
    var next = want.next();
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var pos: usize = 0;
    while (pos <= output.len) {
        const end = std.mem.indexOfScalarPos(u8, output, pos, '\n') orelse output.len;
        const line = output[pos..end];
        if (next) |w| if (line.len > 0 and std.mem.eql(u8, line, w)) {
            try list.append(arena, output[start..pos]);
            start = pos;
            next = want.next();
            while (next) |n| : (next = want.next()) if (n.len > 0) break;
        };
        pos = end + 1;
    }
    try list.append(arena, output[start..]);
    return list.items;
}

fn countErrors(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| n += @intFromBool(std.mem.startsWith(u8, line, "ERROR:") or std.mem.startsWith(u8, line, "FATAL:") or
        std.mem.startsWith(u8, line, "psql: error:"));
    return n;
}

/// The text lowercased, without blanks and the rules of aligned tables,
/// with each error reduced to "error" and without the lines that only
/// say more about a message (LINE and its caret, DETAIL, HINT, CONTEXT,
/// NOTICE, WARNING).
fn loose(arena: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (startsWithLineN(line) or isCaret(line) or startsWithAny(line, &.{ "DETAIL:", "HINT:", "CONTEXT:", "NOTICE:", "WARNING:" })) continue;
        if (startsWithAny(line, &.{ "ERROR:", "FATAL:", "psql: error:" })) {
            try out.appendSlice(arena, "error");
            continue;
        }
        // version(): "PostgreSQL 16.4 on aarch64-..." against "PostgreSQL
        // 17.0 (xqlite 3.54.1)", the server saying what it is.
        const t = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, t, "PostgreSQL ") and t.len > 11 and std.ascii.isDigit(t[11])) {
            try out.appendSlice(arena, "version()");
            continue;
        }
        for (line) |ch| switch (ch) {
            ' ', '\t', '-', '+', '|' => {},
            else => try out.append(arena, std.ascii.toLower(ch)),
        };
    }
    return out.items;
}

/// /^LINE [0-9]+:/
fn startsWithLineN(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "LINE ")) return false;
    var i: usize = 5;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    return i > 5 and i < line.len and line[i] == ':';
}

/// /^ *\^$/: the caret under a LINE.
fn isCaret(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " ");
    return std.mem.eql(u8, t, "^");
}

fn startsWithAny(line: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, line, p)) return true;
    return false;
}

test normalize {
    const a = std.testing.allocator;
    const got = try normalize(a, "psql:<stdin>:12: ERROR:  x\n 16385 | int4 | 23\nt16385", true);
    defer a.free(got);
    try std.testing.expectEqualStrings("ERROR:  x\n <oid> | int4 | 23\nt16385", got);
}

test classify {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Class.@"error", try classify(a, "", " x \n---\n 1\n", "ERROR:  no\n"));
    try std.testing.expectEqual(Class.format, try classify(a, "", " x \n---\n 1\n", " X\n--\n1\n"));
    try std.testing.expectEqual(Class.result, try classify(a, "", " x \n---\n 1\n", " x \n---\n 2\n"));
    try std.testing.expectEqual(Class.result, try classify(a, "", "ERROR:  no\n", "INSERT 0 1\n"));
    try std.testing.expectEqual(Class.format, try classify(a, "", "ERROR:  dup\nDETAIL:  Key (a)=(1)\nNOTICE:  x\n", "ERROR:  UNIQUE failed\n"));
    try std.testing.expectEqual(Class.format, try classify(a, "", "ERROR:  no\nLINE 1: SELECT x;\n               ^\n", "ERROR:  no\n"));
    try std.testing.expectEqual(Class.format, try classify(a, "", " PostgreSQL 16.4 on x, 64-bit\n", " PostgreSQL 17.0 (xqlite 3.54.1)\n"));
    // Per input line: an error in one answer, a wrong row in another.
    const input = "SELECT a;\nSELECT b;\n";
    try std.testing.expectEqual(Class.result, try classify(a, input, "SELECT a;\n 1\nSELECT b;\n 2\n", "SELECT a;\nERROR:  x\nSELECT b;\n 3\n"));
    try std.testing.expectEqual(Class.@"error", try classify(a, input, "SELECT a;\n 1\nSELECT b;\n 2\n", "SELECT a;\nERROR:  x\nSELECT b;\n 2\n"));
}
