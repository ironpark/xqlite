//! `xqt wire-diff pg [--live|--record] [CASES-FILE...]`: the
//! differential test of the PostgreSQL wire server (`xqlite serve --pg`)
//! against a real PostgreSQL, with psql as the client on both sides.
//!
//! Where `xqt dialect-diff pg` compares the rows of `xqlite sql`, this one
//! compares what a user of psql sees: the same psql (18, from the
//! postgres:18-alpine image) runs the same script against the server and
//! against `xqlite serve --pg` on a new, empty database, and its whole
//! output (aligned tables, command tags, NOTICEs, ERROR lines with
//! LINE/DETAIL/HINT, the meta-commands \d, \dt, \gdesc, \bind ...) must
//! be the same. Each case gets its own xqlite server (port 0, the port
//! read from its "listening on" line) and database file.
//!
//! PostgreSQL's side comes from one of:
//!
//! - a recording (the default): what psql printed against PostgreSQL for
//!   each case, tools/dialect/pg-expected/NAME.out for a cases file
//!   NAME.txt (dialect_diff.Recording, with a hash of the case's text and
//!   of its file's setup: a case changed since is reported, as is one not
//!   recorded). No server runs, only psql against xqlite: a psql 18 of
//!   the host if there is one, else one in a short-lived container
//!   (`podman run --rm -i postgres:18-alpine`, which reaches the host at
//!   host.containers.internal).
//! - `--live`: the server, now, with psql inside its container (xq-pg).
//! - `--record`: as --live, and what psql printed against PostgreSQL
//!   becomes the recording, with the server's and psql's versions.
//!
//! On the server (--live, --record) each worker has a database of its own
//! (xqt_wire_PID_N, with the process id, so that two runs on one server
//! do not meet), which each case empties first, as dialect-diff does.
//! Both sides connect with `-U postgres -d DB`, so the names psql prints
//! (owner, database) are the same; in the outputs the database's name
//! becomes xqt_wire_recording (as long, so that tables keep their
//! widths), the name xqlite gets when the recording is replayed.
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
//! Two outputs agree when they are the same but for what the servers may
//! answer differently and both be right (sameAnswers()): the layout of an
//! aligned table (its widths), a cell of the server's version() string,
//! and the order of the rows of a query without ORDER BY.
//!
//! psql runs through $PG_WIRE_EXEC when it is set (with --live and
//! --record, by default "podman exec -i xq-pg"), which must run `sh -c`
//! next to a psql: the standard output and error are merged there so that
//! their order is psql's. psql reaches xqlite at $PG_WIRE_HOST (default
//! host.containers.internal, the host under macOS podman; 127.0.0.1 for
//! the host's psql), and xqlite listens on $PG_WIRE_LISTEN (default
//! 0.0.0.0; 127.0.0.1 for the host's psql).
//!
//! `--regress` runs PostgreSQL's regression tests instead: against the
//! expected outputs PostgreSQL ships with them, so only psql is needed.
//!
//! Not part of `zig build check`: psql comes from podman unless the host
//! has a psql 18.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const Check = xqt.Check;
const dialect_diff = @import("dialect_diff.zig");
const Recording = dialect_diff.Recording;
const Mode = dialect_diff.Mode;

pub const usage =
    \\usage: xqt wire-diff pg [--live|--record] [--out DIR] [CASES-FILE...]
    \\       xqt wire-diff pg --regress [--live] [--out DIR] [TEST...]
    \\
    \\  Runs each case with psql against `xqlite serve --pg` (a server and
    \\  database per case) and compares psql's output with what it printed
    \\  against PostgreSQL. Default cases: tools/dialect/pg-wire-cases.txt and
    \\  tools/dialect/pg-client-cases.txt.
    \\
    \\  (default)   against the recording (tools/dialect/pg-expected/NAME.out
    \\              for NAME.txt): no server, psql 18 of the host or of
    \\              `podman run --rm -i postgres:18-alpine`
    \\  --live      against PostgreSQL, now (psql in its container)
    \\  --record    against PostgreSQL, now, and write the recording
    \\  --regress   instead run PostgreSQL's regression tests in
    \\              tools/dialect/pg-regress ($PG_REGRESS_DIR): sql/TEST.sql
    \\              against xqlite, scored per statement against
    \\              expected/TEST.out (all tests, or those named)
    \\  --out DIR   write each case's outputs to DIR/NAME.pg and DIR/NAME.xq
    \\              (with --regress: xqlite's output to DIR/TEST.out)
    \\
    \\  $PG_WIRE_EXEC    runs `sh -c ...` next to psql (with --live and --record,
    \\                   default "podman exec -i xq-pg")
    \\  $PG_WIRE_HOST    the host where psql reaches xqlite (default
    \\                   host.containers.internal; 127.0.0.1 for the host's psql)
    \\  $PG_WIRE_LISTEN  the address xqlite listens on (default 0.0.0.0;
    \\                   127.0.0.1 for the host's psql)
    \\
    \\For --live and --record, start the server first:
    \\  podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18-alpine
    \\
;

const default_files = [_][]const u8{ "tools/dialect/pg-wire-cases.txt", "tools/dialect/pg-client-cases.txt" };
const container = "podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18-alpine";
const live_exec = "podman exec -i xq-pg";
/// psql for a replay, when the host has no psql 18.
const client_exec = "podman run --rm -i postgres:18-alpine";
const client_major = "18";
const expected_dir = "tools/dialect/pg-expected";

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
    /// Its cases file, in the list of them.
    file_index: usize = 0,
    setup: []const u8,
    sql: []const u8,
    mask_oids: bool,
    /// What psql printed against PostgreSQL (recorded, or now), with the
    /// database named canonical_db and normalize()d (no "psql:<stdin>:N:",
    /// the OIDs masked in a mask-oids case).
    raw: []const u8 = "",
    server: []const u8 = "",
    xq: []const u8 = "",
    recording: dialect_diff.RecordingState = .ok,
    ran: bool = false,

    fn hash(cs: *const Case) dialect_diff.Hash {
        return dialect_diff.caseHash(&.{ cs.setup, cs.sql, if (cs.mask_oids) "mask-oids" else "" });
    }
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
    mode: Mode,
    /// Runs `sh -c CMD` next to psql (empty: on the host).
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
    var mode: Mode = .replay;
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
        } else if (std.mem.eql(u8, args[i], "--live")) {
            mode = .live;
        } else if (std.mem.eql(u8, args[i], "--record")) {
            mode = .record;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            try out.writeAll(usage);
            return 2;
        } else try files.append(arena, args[i]);
    }
    if (regress and mode == .record) {
        try out.writeAll("xqt wire-diff: --regress compares with PostgreSQL's own expected outputs: there is nothing to record\n");
        return 2;
    }
    if (files.items.len == 0 and !regress) for (default_files) |f| try files.append(arena, try std.fs.path.join(arena, &.{ cfg.root, f }));

    var cases: std.ArrayList(Case) = .empty;
    if (!regress) for (files.items, 0..) |path, fi| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
            try out.print("xqt wire-diff: cannot read {s}: {t}\n", .{ path, err });
            return 2;
        };
        const first = cases.items.len;
        try parseCases(arena, std.fs.path.basename(path), text, &cases);
        for (cases.items[first..]) |*cs| cs.file_index = fi;
    };

    var ctx: Ctx = .{ .mode = mode, .exec = &.{}, .host = "", .listen = "", .slots = undefined };
    const client = pickClient(arena, io, cfg, &ctx) catch |err| {
        try out.print("xqt wire-diff: cannot run psql ({t})\n", .{err});
        return 1;
    };
    if (client.version == null) {
        try out.print(
            \\xqt wire-diff: cannot run psql with "{s} sh -c psql":
            \\{s}
            \\
        , .{ client.exec_text, client.failure });
        if (mode != .replay) try out.print("Start the server with\n  {s}\n", .{container});
        try out.flush();
        return 1;
    }
    if (regress) {
        const dir = cfg.environ.get("PG_REGRESS_DIR") orelse try std.fs.path.join(arena, &.{ cfg.root, "tools/dialect/pg-regress" });
        return runRegress(gpa, io, cfg, out, &ctx, dir, files.items, out_dir);
    }

    var recs: []Recording = &.{};
    var server_version: []const u8 = "?";
    if (mode == .replay) {
        recs = try arena.alloc(Recording, files.items.len);
        for (files.items, recs) |path, *rec| {
            const rec_path = try dialect_diff.recordingPath(arena, cfg.root, expected_dir, path);
            const text = Io.Dir.cwd().readFileAlloc(io, rec_path, arena, .unlimited) catch |err| {
                try out.print("xqt wire-diff: cannot read the recording {s} ({t}): make it with `xqt wire-diff pg --record` (the server is needed)\n", .{ rec_path, err });
                rec.* = .{ .notes = &.{}, .entries = &.{} };
                continue;
            };
            rec.* = try Recording.parse(arena, text);
            server_version = rec.note("server");
            const recorded_client = rec.note("client");
            if (!std.mem.eql(u8, recorded_client, client.version.?))
                try out.print("note: {s} was recorded with {s}, psql here is {s}\n", .{ std.fs.path.basename(rec_path), recorded_client, client.version.? });
        }
        for (cases.items) |*cs| switch (recs[cs.file_index].lookup(cs.name, cs.hash())) {
            .found => |raw| cs.raw = raw,
            .missing => cs.recording = .missing,
            .stale => cs.recording = .stale,
        };
    }

    const n_slots = if (mode == .replay) 0 else @max(1, @min(cfg.jobs, cases.items.len, max_databases));
    var slots: Slots = .{ .free = try .initCapacity(arena, n_slots) };
    for (0..n_slots) |s| slots.free.appendAssumeCapacity(n_slots - 1 - s);
    ctx.slots = &slots;
    const admin = try psqlArgv(arena, &ctx, null, "postgres", "");
    var drop: Io.Writer.Allocating = .init(arena);
    if (mode != .replay) {
        const v = try dialect_diff.runMerged(arena, io, try psqlArgv(arena, &ctx, null, "postgres", "-At"), "SELECT version();\n");
        if (!v.ok) {
            try out.print(
                \\xqt wire-diff: cannot reach PostgreSQL with "{s} sh -c psql" ($PG_WIRE_EXEC):
                \\{s}
                \\Start it with
                \\  {s}
                \\
            , .{ client.exec_text, std.mem.trimEnd(u8, v.out, "\n"), container });
            try out.flush();
            return 1;
        }
        server_version = try arena.dupe(u8, dialect_diff.versionLine(v.out));
        var make: Io.Writer.Allocating = .init(arena);
        for (0..n_slots) |s| {
            const db = try dbName(arena, s);
            try make.writer.print("DROP DATABASE IF EXISTS {s};\nCREATE DATABASE {s};\n", .{ db, db });
            try drop.writer.print("DROP DATABASE IF EXISTS {s};\n", .{db});
        }
        const r = try dialect_diff.runMerged(arena, io, admin, make.written());
        if (!r.ok) {
            try out.print("xqt wire-diff: cannot make the databases of the workers:\n{s}", .{r.out});
            return 1;
        }
    }
    defer if (mode != .replay) {
        _ = dialect_diff.runMerged(arena, io, admin, drop.written()) catch {};
    };

    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "wire-diff", .show = .failures });
    defer suite.deinit();
    for (cases.items) |*cs| try suite.add(cs.name, runCase, .{ &ctx, cs });
    suite.run();

    if (out_dir) |dir| {
        try Io.Dir.cwd().createDirPath(io, dir);
        for (cases.items) |cs| {
            if (cs.recording != .ok) continue;
            const base = try std.fs.path.join(arena, &.{ dir, cs.name });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.mem.concat(arena, u8, &.{ base, ".pg" }), .data = cs.server });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.mem.concat(arena, u8, &.{ base, ".xq" }), .data = cs.xq });
        }
    }

    var counts: [3]usize = .{ 0, 0, 0 };
    var errors: usize = 0;
    var unrecorded: [2]usize = .{ 0, 0 };
    var dw: Io.Writer.Allocating = .init(gpa);
    defer dw.deinit();
    for (cases.items, 0..) |cs, n| {
        if (cs.recording != .ok) {
            unrecorded[@intFromBool(cs.recording == .stale)] += 1;
            try out.print("{s} {s} ({s})\n", .{ cs.recording.label(), cs.name, cs.file });
            continue;
        }
        if (suite.outcome(n).status == .failed) {
            errors += 1;
            continue;
        }
        if (std.mem.eql(u8, cs.server, cs.xq)) continue;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        if (try sameAnswers(scratch.allocator(), cs.server, cs.xq)) continue;
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
    const bad = fail + errors + unrecorded[0] + unrecorded[1];
    try out.print("pg-wire-diff: {d}/{d} cases agree with {s}{s}", .{ cases.items.len - bad, cases.items.len, if (mode == .replay) "the recording of " else "", server_version });
    if (fail > 0) try out.print(" (differ: {d} result, {d} error, {d} format)", .{ counts[0], counts[1], counts[2] });
    if (errors > 0) try out.print(" ({d} could not run)", .{errors});
    try dialect_diff.writeUnrecorded(out, unrecorded);
    try out.writeAll("\n");
    try out.flush();
    if (mode == .record) {
        for (files.items, 0..) |path, fi| {
            var entries: std.ArrayList(Recording.Entry) = .empty;
            for (cases.items) |cs| {
                if (cs.file_index != fi) continue;
                if (!cs.ran) {
                    try out.print("xqt wire-diff: {s} could not run: {s} is not recorded\n", .{ cs.name, path });
                    try out.flush();
                    return 1;
                }
                try entries.append(arena, .{ .name = cs.name, .hash = cs.hash(), .out = cs.raw });
            }
            const rec_path = try dialect_diff.recordingPath(arena, cfg.root, expected_dir, path);
            const notes = [_][]const u8{
                try std.fmt.allocPrint(arena, "xqt wire-diff pg --record: what psql printed against PostgreSQL for each case of {s}", .{std.fs.path.basename(path)}),
                try std.fmt.allocPrint(arena, "server: {s}", .{server_version}),
                try std.fmt.allocPrint(arena, "client: {s}", .{client.version.?}),
            };
            Recording.write(arena, io, rec_path, &notes, entries.items) catch |err| {
                try out.print("xqt wire-diff: cannot write {s}: {t}\n", .{ rec_path, err });
                try out.flush();
                return 1;
            };
            try out.print("recorded {d} cases in {s}\n", .{ entries.items.len, rec_path });
        }
        try out.flush();
    }
    return @intFromBool(bad > 0);
}

const Client = struct {
    exec_text: []const u8,
    /// `psql --version`; null if psql could not run.
    version: ?[]const u8,
    failure: []const u8 = "",
};

/// Where psql runs (ctx.exec, .host, .listen): $PG_WIRE_EXEC; else with
/// --live and --record in the server's container; else the host's psql
/// if it is psql 18, else a container of its own.
fn pickClient(arena: Allocator, io: Io, cfg: *const xqt.Config, ctx: *Ctx) !Client {
    const env = cfg.environ;
    var exec_text: []const u8 = env.get("PG_WIRE_EXEC") orelse if (ctx.mode == .replay) "" else live_exec;
    var host: []const u8 = "host.containers.internal";
    var listen: []const u8 = "0.0.0.0";
    if (exec_text.len == 0) {
        const v = dialect_diff.runMerged(arena, io, &.{ "sh", "-c", "psql --version" }, "") catch null;
        if (v != null and v.?.ok and isMajor(v.?.out, client_major)) {
            host = "127.0.0.1";
            listen = "127.0.0.1";
        } else exec_text = client_exec;
    }
    var exec: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, exec_text, " \t\n");
    while (words.next()) |w| try exec.append(arena, w);
    ctx.exec = exec.items;
    ctx.host = env.get("PG_WIRE_HOST") orelse host;
    ctx.listen = env.get("PG_WIRE_LISTEN") orelse listen;
    const argv = try std.mem.concat(arena, []const u8, &.{ ctx.exec, &.{ "sh", "-c", "psql --version 2>&1" } });
    const v = dialect_diff.runMerged(arena, io, argv, "") catch |err|
        dialect_diff.Merged{ .ok = false, .out = try std.fmt.allocPrint(arena, "cannot run {s}: {t}", .{ argv[0], err }) };
    const text = std.mem.trim(u8, v.out, " \n");
    return .{ .exec_text = if (exec_text.len == 0) "(the host)" else exec_text, .version = if (v.ok) text else null, .failure = text };
}

/// "psql (PostgreSQL) 18.6": whether the major version is `major`.
fn isMajor(version: []const u8, major: []const u8) bool {
    const at = std.mem.indexOf(u8, version, ") ") orelse return false;
    const rest = version[at + 2 ..];
    return std.mem.startsWith(u8, rest, major) and rest.len > major.len and rest[major.len] == '.';
}

/// The database of worker `slot` on the server: xqt_wire_PPPPPPP_S, with
/// the process id, so that runs at the same time on one server do not
/// meet. Its length is that of canonical_db, which it becomes in the
/// outputs (aligned tables keep their widths).
fn dbName(arena: Allocator, slot: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "xqt_wire_{d:0>7}_{d}", .{ @as(u32, @intCast(std.c.getpid())), slot });
}

const canonical_db = "xqt_wire_recording";

/// `text` with every `db` named canonical_db.
fn canonical(gpa: Allocator, text: []const u8, db: []const u8) ![]u8 {
    std.debug.assert(db.len == canonical_db.len);
    const copy = try dialect_diff.withNewline(gpa, text);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, copy, at, db)) |k| : (at = k + db.len) @memcpy(copy[k..][0..db.len], canonical_db);
    return copy;
}

/// `EXEC... sh -c "psql ... 2>&1"` to PostgreSQL itself.
fn psqlArgv(arena: Allocator, ctx: *const Ctx, env: ?[]const u8, db: []const u8, flags: []const u8) ![]const []const u8 {
    const cmd = try std.fmt.allocPrint(arena, "{s} 2>&1", .{try psqlCommand(arena, env, db, flags)});
    return std.mem.concat(arena, []const u8, &.{ ctx.exec, &.{ "sh", "-c", cmd } });
}

/// "[ENV] psql -X -U postgres -d DB [FLAGS]", the command line for sh.
fn psqlCommand(arena: Allocator, env: ?[]const u8, db: []const u8, flags: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}psql -X -U postgres -d {s} {s}", .{ env orelse "", if (env != null) " " else "", db, flags });
}

fn runCase(c: *Check, ctx: *Ctx, cs: *Case) !void {
    if (cs.recording != .ok) return;
    // The setup runs quietly; the case echoes its input, so that each
    // output says what it answers.
    const quiet_setup = try std.mem.concat(c.arena, u8, &.{ "\\set QUIET on\n", cs.setup, "\\set QUIET off\n\\set ECHO all\n" });
    const xq_in = try std.mem.concat(c.arena, u8, &.{ quiet_setup, cs.sql });
    if (ctx.mode == .replay) {
        const xq_raw = try runXq(c, ctx, try psqlCommand(c.arena, null, canonical_db, ""), xq_in);
        cs.server = try normalize(c.keep, cs.raw, cs.mask_oids);
        cs.xq = try normalize(c.keep, try dialect_diff.withNewline(c.arena, xq_raw), cs.mask_oids);
        cs.ran = true;
        return;
    }
    // Both sides name the worker's database, so that psql prints the
    // same name; xqlite takes any.
    const slot = ctx.slots.acquire(c.io);
    const db = try dbName(c.arena, slot);
    const server_in = try std.mem.concat(c.arena, u8, &.{ pg_reset, quiet_setup, cs.sql });
    const server_raw = dialect_diff.runMerged(c.arena, c.io, try psqlArgv(c.arena, ctx, null, db, ""), server_in);
    ctx.slots.release(c.io, slot);

    const xq_raw = try runXq(c, ctx, try psqlCommand(c.arena, null, db, ""), xq_in);

    // Recorded without what changes from run to run: the line numbers of
    // "psql:<stdin>:N:" (after pg_reset), the OIDs of a mask-oids case.
    cs.raw = try normalize(c.keep, try canonical(c.arena, (try server_raw).out, db), cs.mask_oids);
    cs.server = try normalize(c.keep, cs.raw, cs.mask_oids);
    cs.xq = try normalize(c.keep, try canonical(c.arena, xq_raw, db), cs.mask_oids);
    cs.ran = true;
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
        // version(): "PostgreSQL 18.6 on aarch64-..." against "PostgreSQL
        // 18.6 (xqlite 3.54.1)", the server saying what it is.
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

/// Whether outputs `a` and `b` say the same (the top of the file): each
/// aligned table becomes its cells, a version() cell "version()", and the
/// rows of a table sorted when the text since the table before it (the
/// statement psql echoed) has no ORDER BY.
pub fn sameAnswers(arena: Allocator, a: []const u8, b: []const u8) !bool {
    return std.mem.eql(u8, try answers(arena, a), try answers(arena, b));
}

fn answers(arena: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    const ls = lines.items;
    // Where the text since the last table starts.
    var since: usize = 0;
    var i: usize = 0;
    while (i < ls.len) {
        // A header, then its rule, rows, and "(N rows)".
        if (i + 1 < ls.len and isRule(ls[i + 1])) if (tableEnd(ls, i + 2)) |end| {
            const ordered = for (ls[since..i]) |l| {
                if (hasOrderBy(l)) break true;
            } else false;
            // psql right-aligns the columns of number types.
            var right: [64]bool = @splat(false);
            var rows: std.ArrayList([]u8) = .empty;
            for (ls[i + 2 .. end]) |row| {
                var cells: std.ArrayList(u8) = .empty;
                try appendCells(arena, &cells, row, &right);
                try rows.append(arena, cells.items);
            }
            try appendCells(arena, &out, ls[i], null);
            for (right[0..@min(right.len, std.mem.count(u8, ls[i], "|") + 1)]) |r| try out.append(arena, if (r) 'r' else 'l');
            try out.append(arena, '\n');
            if (!ordered) std.mem.sort([]u8, rows.items, {}, struct {
                fn lt(_: void, x: []u8, y: []u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (rows.items) |r| try out.appendSlice(arena, r);
            try out.appendSlice(arena, ls[end]);
            try out.append(arena, '\n');
            i = end + 1;
            since = i;
            continue;
        };
        try out.appendSlice(arena, ls[i]);
        try out.append(arena, '\n');
        i += 1;
    }
    return out.items;
}

fn hasOrderBy(line: []const u8) bool {
    var k: usize = 0;
    while (k + 8 <= line.len) : (k += 1) if (std.ascii.startsWithIgnoreCase(line[k..], "order by")) return true;
    return false;
}

/// The line of a table's "(N rows)" at or after `from`, if every line
/// before it is a row (no blank line between).
fn tableEnd(ls: []const []const u8, from: usize) ?usize {
    var j = from;
    while (j < ls.len) : (j += 1) {
        const l = ls[j];
        if (std.mem.startsWith(u8, l, "(") and std.mem.endsWith(u8, l, ")") and (std.mem.endsWith(u8, l, " rows)") or std.mem.endsWith(u8, l, " row)"))) return j;
        if (l.len == 0) return null;
    }
    return null;
}

/// /^-+(\+-+)*$/: the rule under a table's header.
fn isRule(line: []const u8) bool {
    if (line.len == 0 or line[0] != '-') return false;
    for (line) |ch| if (ch != '-' and ch != '+') return false;
    return true;
}

/// The cells of a table's line, trimmed, each ending in '|'; a cell of
/// the server's version() string is "version()". A cell padded on the
/// left (more than the one blank before a cell) marks its column in
/// `right`.
fn appendCells(arena: Allocator, out: *std.ArrayList(u8), line: []const u8, right: ?*[64]bool) !void {
    var cells = std.mem.splitScalar(u8, line, '|');
    var n: usize = 0;
    while (cells.next()) |cell| : (n += 1) {
        const t = std.mem.trim(u8, cell, " ");
        if (right) |r| if (n < r.len and t.len > 0 and std.mem.startsWith(u8, cell, "  ")) {
            r[n] = true;
        };
        const version = std.mem.startsWith(u8, t, "PostgreSQL ") and t.len > 11 and std.ascii.isDigit(t[11]);
        try out.appendSlice(arena, if (version) "version()" else t);
        try out.append(arena, '|');
    }
    try out.append(arena, '\n');
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

test sameAnswers {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Widths, a version() cell, rows without ORDER BY.
    try std.testing.expect(try sameAnswers(a, "SELECT x, version();\n x |   version   \n---+-------------\n 1 | PostgreSQL 18.6 on x\n 2 | PostgreSQL 18.6 on x\n(2 rows)\n", "SELECT x, version();\n x | version \n---+---------\n 2 | PostgreSQL 18.6 (xqlite)\n 1 | PostgreSQL 18.6 (xqlite)\n(2 rows)\n"));
    try std.testing.expect(!try sameAnswers(a, "SELECT x ORDER BY x;\n x \n---\n 1\n 2\n(2 rows)\n", "SELECT x ORDER BY x;\n x \n---\n 2\n 1\n(2 rows)\n"));
    try std.testing.expect(!try sameAnswers(a, " x \n---\n 1\n(1 row)\n", " x \n---\n 2\n(1 row)\n"));
    // An integer psql aligns as text: a column of another type.
    try std.testing.expect(!try sameAnswers(a, " k | key_seq \n---+---------\n a |       1\n(1 row)\n", " k | key_seq \n---+---------\n a | 1      \n(1 row)\n"));
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
    try std.testing.expectEqual(Class.format, try classify(a, "", " PostgreSQL 18.6 on x, 64-bit\n", " PostgreSQL 18.6 (xqlite 3.54.1)\n"));
    // Per input line: an error in one answer, a wrong row in another.
    const input = "SELECT a;\nSELECT b;\n";
    try std.testing.expectEqual(Class.result, try classify(a, input, "SELECT a;\n 1\nSELECT b;\n 2\n", "SELECT a;\nERROR:  x\nSELECT b;\n 3\n"));
    try std.testing.expectEqual(Class.@"error", try classify(a, input, "SELECT a;\n 1\nSELECT b;\n 2\n", "SELECT a;\nERROR:  x\nSELECT b;\n 2\n"));
}
