//! `xqt dialect-diff pg|mariadb [CASES]`: the differential test of a
//! dialect against its real server. Each case of the cases file
//! (tools/dialect/pg-cases.txt, maria-cases.txt) runs in the server's
//! client and in `xqlite sql` with the dialect on; the rows, the column
//! names (of results with rows) and the "ERROR:" lines must be the same.
//! (Was tools/dialect/pg-diff.sh and maria-diff.sh.)
//!
//! A case starts with a line "-- case: NAME" and runs on an empty
//! database. The cases run in parallel:
//!
//! - PostgreSQL: each worker has a database of its own (xqt_dialect_N,
//!   made before and dropped after the run), and each case starts, as
//!   before, by dropping and making its schema public.
//! - MariaDB: every case runs in the database main, which the cases name
//!   (information_schema queries, main.t) and so do MariaDB's error
//!   messages ("Table 'main.x' doesn't exist"). The server runs one case
//!   at a time; the xqlite side of the cases runs in parallel.
//!
//! The server is reached with $PG_PSQL / $MARIA_CLIENT, split on blanks
//! as the shell did, by default `podman exec -i` into the containers
//!
//!     podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
//!     podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
//!
//! Not part of `zig build check`: it needs a server.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqt = @import("xqt");
const Check = xqt.Check;

pub const usage =
    \\usage: xqt dialect-diff pg|mariadb [CASES-FILE]
    \\
    \\  pg        tools/dialect/pg-cases.txt against PostgreSQL ($PG_PSQL,
    \\            default "podman exec -i xq-pg psql -U postgres")
    \\  mariadb   tools/dialect/maria-cases.txt against MariaDB ($MARIA_CLIENT,
    \\            default "podman exec -i xq-maria mariadb -uroot")
    \\
    \\Start the server first:
    \\  podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
    \\  podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
    \\
;

const Dialect = struct {
    /// "pg-diff", for the last line.
    tag: []const u8,
    server: []const u8,
    cases: []const u8,
    env: []const u8,
    default_client: []const u8,
    container: []const u8,
    /// Arguments after the client command.
    client_args: []const []const u8,
    /// Sent to the server before each case.
    prelude: []const u8,
    /// Sent to xqlite before each case.
    xq_prelude: []const u8,
    norm_server: *const fn (Allocator, []const u8) Allocator.Error![]u8,
    norm_xq: *const fn (Allocator, []const u8) Allocator.Error![]u8,
    /// Whether each worker gets a database of its own (else all share
    /// the prelude's database and the server runs one case at a time).
    databases: bool,
};

const pg: Dialect = .{
    .tag = "pg-diff",
    .server = "PostgreSQL",
    .cases = "tools/dialect/pg-cases.txt",
    .env = "PG_PSQL",
    .default_client = "podman exec -i xq-pg psql -U postgres",
    .container = "podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine",
    .client_args = &.{ "-q", "-A", "-F|" },
    .prelude = "SET client_min_messages = warning; DROP SCHEMA public CASCADE; CREATE SCHEMA public;\n",
    .xq_prelude = ".dialect postgres\n.headers on\n",
    .norm_server = normPg,
    .norm_xq = normXqPg,
    .databases = true,
};

const maria: Dialect = .{
    .tag = "maria-diff",
    .server = "MariaDB",
    .cases = "tools/dialect/maria-cases.txt",
    .env = "MARIA_CLIENT",
    .default_client = "podman exec -i xq-maria mariadb -uroot",
    .container = "podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11",
    .client_args = &.{ "--batch", "--raw", "--force", "--unbuffered" },
    .prelude = "DROP DATABASE IF EXISTS main; CREATE DATABASE main CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; USE main; SET NAMES utf8mb4 COLLATE utf8mb4_general_ci;\n",
    .xq_prelude = ".dialect mariadb\n.headers on\n.nullvalue NULL\n",
    .norm_server = normMaria,
    .norm_xq = normXqMaria,
    .databases = false,
};

/// The most databases a run makes: more workers gain nothing, and each
/// CREATE DATABASE costs a copy of template1.
const max_databases = 8;

const Case = struct {
    name: []const u8,
    sql: []const u8,
    /// The normalized outputs, set by the check.
    server: []const u8 = "",
    xq: []const u8 = "",
};

/// The server's databases, one per worker; a case takes a free one. With
/// one database, the cases take turns.
const Slots = struct {
    names: [][]const u8,
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
    d: *const Dialect,
    client: []const []const u8,
    slots: *Slots,
};

pub fn run(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (args.len < 1 or args.len > 2) return usageError(out);
    const d: *const Dialect = if (std.mem.eql(u8, args[0], "pg") or std.mem.eql(u8, args[0], "postgres"))
        &pg
    else if (std.mem.eql(u8, args[0], "mariadb") or std.mem.eql(u8, args[0], "maria"))
        &maria
    else
        return usageError(out);
    const cases_path = if (args.len == 2) args[1] else try std.fs.path.join(arena, &.{ cfg.root, d.cases });
    const text = Io.Dir.cwd().readFileAlloc(io, cases_path, arena, .unlimited) catch |err| {
        try out.print("xqt dialect-diff: cannot read {s}: {t}\n", .{ cases_path, err });
        return 2;
    };
    const cases = try parseCases(arena, text);

    // The client command, split as the shell splits an unquoted variable.
    const client_text = cfg.environ.get(d.env) orelse d.default_client;
    var client: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, client_text, " \t\n");
    while (words.next()) |w| try client.append(arena, w);
    try client.appendSlice(arena, d.client_args);

    // Is the server there?
    const probe = runMerged(arena, io, client.items, "SELECT 1;\n") catch |err|
        Merged{ .ok = false, .out = try std.fmt.allocPrint(arena, "cannot run {s}: {t}", .{ client.items[0], err }) };
    if (!probe.ok) {
        try out.print(
            \\xqt dialect-diff: cannot reach the {s} server with "{s}" (${s}):
            \\{s}
            \\Start it with
            \\  {s}
            \\or set ${s} to a client command that reaches one.
            \\
        , .{ d.server, client_text, d.env, std.mem.trimEnd(u8, probe.out, "\n"), d.container, d.env });
        try out.flush();
        return 1;
    }

    const n_slots = if (d.databases) @max(1, @min(cfg.jobs, cases.len, max_databases)) else 1;
    var slots: Slots = .{
        .names = try arena.alloc([]const u8, n_slots),
        .free = try .initCapacity(arena, n_slots),
    };
    for (0..n_slots) |i| slots.free.appendAssumeCapacity(n_slots - 1 - i);
    if (d.databases) {
        var make: Io.Writer.Allocating = .init(arena);
        var drop: Io.Writer.Allocating = .init(arena);
        for (slots.names, 0..) |*name, i| {
            name.* = try std.fmt.allocPrint(arena, "xqt_dialect_{d}", .{i});
            try make.writer.print("DROP DATABASE IF EXISTS {s};\nCREATE DATABASE {s};\n", .{ name.*, name.* });
            try drop.writer.print("DROP DATABASE IF EXISTS {s};\n", .{name.*});
        }
        const r = try runMerged(arena, io, client.items, make.written());
        if (!r.ok) {
            try out.print("xqt dialect-diff: cannot make the databases of the workers:\n{s}", .{r.out});
            return 1;
        }
        defer _ = runMerged(arena, io, client.items, drop.written()) catch {};
        return runCases(gpa, io, cfg, out, d, client.items, &slots, cases);
    }
    return runCases(gpa, io, cfg, out, d, client.items, &slots, cases);
}

fn runCases(gpa: Allocator, io: Io, cfg: *const xqt.Config, out: *Io.Writer, d: *const Dialect, client: []const []const u8, slots: *Slots, cases: []Case) !u8 {
    var ctx: Ctx = .{ .d = d, .client = client, .slots = slots };
    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "dialect-diff", .show = .failures });
    defer suite.deinit();
    for (cases) |*cs| try suite.add(cs.name, runCase, .{ &ctx, cs });
    suite.run();

    var fail: usize = 0;
    var errors: usize = 0;
    var dw: Io.Writer.Allocating = .init(gpa);
    defer dw.deinit();
    for (cases, 0..) |cs, i| {
        if (suite.outcome(i).status == .failed) {
            errors += 1;
            continue;
        }
        if (std.mem.eql(u8, cs.server, cs.xq)) continue;
        fail += 1;
        try out.print("DIFF {s}\n", .{cs.name});
        dw.clearRetainingCapacity();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        try xqt.diff.write(&dw.writer, scratch.allocator(), d.server, "xqlite", cs.server, cs.xq, .{});
        var diff_lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, dw.written(), "\n"), '\n');
        var n: usize = 0;
        while (diff_lines.next()) |line| : (n += 1) {
            if (n == 40) break;
            try out.print("  {s}\n", .{line});
        }
    }
    try out.print("{s}: {d}/{d} cases agree", .{ d.tag, cases.len - fail - errors, cases.len });
    if (errors > 0) try out.print(" ({d} could not run)", .{errors});
    try out.writeAll("\n");
    try out.flush();
    return @intFromBool(fail + errors > 0);
}

fn runCase(c: *Check, ctx: *Ctx, cs: *Case) !void {
    const d = ctx.d;
    const server_in = try std.mem.concat(c.arena, u8, &.{ d.prelude, cs.sql });
    const server_raw = blk: {
        const slot = ctx.slots.acquire(c.io);
        defer ctx.slots.release(c.io, slot);
        const argv = if (d.databases)
            try std.mem.concat(c.arena, []const u8, &.{ ctx.client, &.{ "-d", ctx.slots.names[slot] } })
        else
            ctx.client;
        break :blk (try runMerged(c.arena, c.io, argv, server_in)).out;
    };
    const xq_in = try std.mem.concat(c.arena, u8, &.{ d.xq_prelude, cs.sql });
    const xq_raw = (try runMerged(c.arena, c.io, &.{ c.cfg.xq, "sql" }, xq_in)).out;
    cs.server = try d.norm_server(c.keep, server_raw);
    cs.xq = try d.norm_xq(c.keep, xq_raw);
}

fn usageError(out: *Io.Writer) !u8 {
    try out.writeAll(usage);
    return 2;
}

/// The cases of a cases file: a line "-- case: NAME" starts one, and the
/// lines up to the next are its SQL (each ended by a newline). Lines
/// before the first case are left out.
fn parseCases(arena: Allocator, text: []const u8) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    var sql: std.ArrayList(u8) = .empty;
    var it = lines(text);
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "-- case:")) {
            if (cases.items.len > 0) cases.items[cases.items.len - 1].sql = try sql.toOwnedSlice(arena);
            const name = std.mem.trimStart(u8, line["-- case:".len..], " ");
            try cases.append(arena, .{ .name = name, .sql = "" });
        } else if (cases.items.len > 0) {
            try sql.appendSlice(arena, line);
            try sql.append(arena, '\n');
        }
    }
    if (cases.items.len > 0) cases.items[cases.items.len - 1].sql = try sql.toOwnedSlice(arena);
    return cases.items;
}

/// The lines of `text` as awk reads records: a last line without a
/// newline is a line, a final newline does not start one.
fn lines(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    var it = std.mem.splitScalar(u8, body, '\n');
    if (text.len == 0) it.index = null;
    return it;
}

// ---------------------------------------------------------------- normalizing

/// psql prints a header and "(N rows)" for every result: keep the header
/// only above rows, as the shell does. Errors become "ERROR: message".
/// Booleans print as t/f, which the dialect returns as integers 1/0.
fn normPg(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var skip = false;
    var it = lines(text);
    while (it.next()) |line| {
        if (pgError(line)) |msg| {
            try out.appendSlice(gpa, "ERROR: ");
            try out.appendSlice(gpa, msg);
            try out.append(gpa, '\n');
            continue;
        }
        if (startsWithLineN(line) or startsWithAny(line, &.{ "DETAIL:", "HINT:", "CONTEXT:", "NOTICE:", "psql:" })) {
            skip = true;
            continue;
        }
        if (skip and std.mem.startsWith(u8, line, " ")) continue;
        skip = false;
        if (rowCount(line)) |n| {
            if (n > 0) try out.appendSlice(gpa, buf.items);
            buf.clearRetainingCapacity();
            continue;
        }
        var fields = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (fields.next()) |f| {
            if (!first) try buf.append(gpa, '|');
            first = false;
            try buf.appendSlice(gpa, if (std.mem.eql(u8, f, "t")) "1" else if (std.mem.eql(u8, f, "f")) "0" else f);
        }
        try buf.append(gpa, '\n');
    }
    try out.appendSlice(gpa, buf.items);
    return out.toOwnedSlice(gpa);
}

/// /^(psql:[^ ]* )?ERROR: +/: the message after it.
fn pgError(line: []const u8) ?[]const u8 {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "psql:")) {
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
            if (std.mem.startsWith(u8, rest[sp + 1 ..], "ERROR: ")) rest = rest[sp + 1 ..];
        }
    }
    if (!std.mem.startsWith(u8, rest, "ERROR: ")) return null;
    return std.mem.trimStart(u8, rest["ERROR:".len..], " ");
}

/// /^LINE [0-9]+:/
fn startsWithLineN(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "LINE ")) return false;
    var i: usize = 5;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    return i > 5 and i < line.len and line[i] == ':';
}

fn startsWithAny(line: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, line, p)) return true;
    return false;
}

/// /^\([0-9]+ rows?\)$/: N.
fn rowCount(line: []const u8) ?u64 {
    if (line.len < 2 or line[0] != '(' or line[line.len - 1] != ')') return null;
    const inner = line[1 .. line.len - 1];
    const sp = std.mem.indexOfScalar(u8, inner, ' ') orelse return null;
    const word = inner[sp + 1 ..];
    if (!std.mem.eql(u8, word, "row") and !std.mem.eql(u8, word, "rows")) return null;
    const digits = inner[0..sp];
    if (digits.len == 0) return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseUnsigned(u64, digits, 10) catch std.math.maxInt(u64);
}

/// xqlite's error lines become "ERROR: message", without the lines of
/// context under them.
fn normXq(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var skip = false;
    var it = lines(text);
    while (it.next()) |line| {
        if (xqError(line)) |msg| {
            try out.appendSlice(gpa, "ERROR: ");
            try out.appendSlice(gpa, msg);
            try out.append(gpa, '\n');
            skip = true;
            continue;
        }
        if (skip and std.mem.startsWith(u8, line, "  ")) continue;
        skip = false;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// /^(Parse error|Error|Runtime error) near line [0-9]+: /: what follows
/// the first ": ".
fn xqError(line: []const u8) ?[]const u8 {
    for ([_][]const u8{ "Parse error", "Error", "Runtime error" }) |p| {
        if (!std.mem.startsWith(u8, line, p)) continue;
        const rest = line[p.len..];
        if (!std.mem.startsWith(u8, rest, " near line ")) continue;
        var i: usize = " near line ".len;
        const start = i;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == start or !std.mem.startsWith(u8, rest[i..], ": ")) continue;
        // sub(/^[^:]*: /, ...): the prefix has no colon before ": ".
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        return line[colon + 2 ..];
    }
    return null;
}

fn normXqPg(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    return normXq(gpa, text);
}

fn normXqMaria(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const t = try normXq(gpa, text);
    defer gpa.free(t);
    return normNum(gpa, t);
}

/// The client prints tab-separated rows with a header line per result
/// (none for an empty one) and, with --force, the statement that failed
/// between dashed lines; errors become "ERROR: message".
fn normMaria(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var echoed = false;
    var blank = false;
    var it = lines(text);
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "--------------")) {
            echoed = !echoed;
            if (!echoed) blank = true;
            continue;
        }
        if (echoed) continue;
        if (blank and line.len == 0) {
            blank = false;
            continue;
        }
        blank = false;
        if (mariaError(line)) |msg| {
            try out.appendSlice(gpa, "ERROR: ");
            try out.appendSlice(gpa, msg);
            try out.append(gpa, '\n');
            continue;
        }
        for (line) |ch| try out.append(gpa, if (ch == '\t') '|' else ch);
        try out.append(gpa, '\n');
    }
    return normNum(gpa, out.items);
}

/// /^ERROR [0-9]+ \([0-9A-Z]+\)( at line [0-9]+)?: /: what follows.
fn mariaError(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "ERROR ")) return null;
    var i: usize = "ERROR ".len;
    i = digitsEnd(line, i) orelse return null;
    if (!std.mem.startsWith(u8, line[i..], " (")) return null;
    i += 2;
    const start = i;
    while (i < line.len and (std.ascii.isDigit(line[i]) or std.ascii.isUpper(line[i]))) i += 1;
    if (i == start or i >= line.len or line[i] != ')') return null;
    i += 1;
    if (std.mem.startsWith(u8, line[i..], " at line ")) {
        if (digitsEnd(line, i + " at line ".len)) |j| {
            if (std.mem.startsWith(u8, line[j..], ": ")) return line[j + 2 ..];
        }
    }
    if (std.mem.startsWith(u8, line[i..], ": ")) return line[i + 2 ..];
    return null;
}

/// The end of the digits at `i`, null if there are none.
fn digitsEnd(s: []const u8, i: usize) ?usize {
    var j = i;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    return if (j == i) null else j;
}

/// Fields (split on '|') with a fraction lose their trailing zeros, and
/// then a trailing dot: MariaDB's DECIMAL prints 3.5000, the dialect's
/// REAL 3.5.
fn normNum(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = lines(text);
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        var first = true;
        while (fields.next()) |f| {
            if (!first) try out.append(gpa, '|');
            first = false;
            try out.appendSlice(gpa, if (isFraction(f)) trimFraction(f) else f);
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// /^-?[0-9]+\.[0-9]+$/
fn isFraction(f: []const u8) bool {
    var i: usize = @intFromBool(std.mem.startsWith(u8, f, "-"));
    const int_end = digitsEnd(f, i) orelse return false;
    if (int_end >= f.len or f[int_end] != '.') return false;
    i = digitsEnd(f, int_end + 1) orelse return false;
    return i == f.len;
}

fn trimFraction(f: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, f, "0");
    return if (std.mem.endsWith(u8, t, ".")) t[0 .. t.len - 1] else t;
}

// ---------------------------------------------------------------- processes

const Merged = struct {
    /// It exited with status 0.
    ok: bool,
    /// Standard output and standard error, as one pipe got them (`2>&1`).
    out: []u8,
};

/// Runs `argv` with `input` on its standard input and its standard output
/// and error on one pipe, as `2>&1` in a shell pipeline: the order in
/// which the program wrote them is kept.
fn runMerged(gpa: Allocator, io: Io, argv: []const []const u8, input: []const u8) !Merged {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const r: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const w: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer r.close(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .{ .file = w },
        .stderr = .{ .file = w },
    }) catch |err| {
        w.close(io);
        return err;
    };
    w.close(io);
    defer if (child.id != null) xqt.proc.kill(io, &child);
    const stdin = child.stdin.?;
    child.stdin = null;
    const feeder = try std.Thread.spawn(.{}, feed, .{ io, stdin, input });
    defer feeder.join();
    var buf: [4096]u8 = undefined;
    var reader = r.readerStreaming(io, &buf);
    const out = reader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
    const term = try child.wait(io);
    return .{ .ok = term == .exited and term.exited == 0, .out = out };
}

fn feed(io: Io, file: Io.File, input: []const u8) void {
    defer file.close(io);
    file.writeStreamingAll(io, input) catch {};
}

test normPg {
    const a = std.testing.allocator;
    const got = try normPg(a,
        \\a|b
        \\t|x
        \\(1 row)
        \\c
        \\(0 rows)
        \\psql:<stdin>:3: ERROR:  relation "x" does not exist
        \\LINE 1: SELECT * FROM x;
        \\                      ^
        \\f
        \\
    );
    defer a.free(got);
    try std.testing.expectEqualStrings("a|b\n1|x\nERROR: relation \"x\" does not exist\n0\n", got);
}

test normMaria {
    const a = std.testing.allocator;
    const got = try normMaria(a, "a\tb\n3.5000\t10.0\n--------------\nSELECT x\n--------------\n\nERROR 1146 (42S02) at line 3: Table 'main.x' doesn't exist\n-1.50\t1.0x\n");
    defer a.free(got);
    try std.testing.expectEqualStrings("a|b\n3.5|10\nERROR: Table 'main.x' doesn't exist\n-1.5|1.0x\n", got);
}

test normXq {
    const a = std.testing.allocator;
    const got = try normXqMaria(a, "x\nParse error near line 2: no such table: t\n  SELECT * FROM t;\n         ^--- error here\n2.50\n");
    defer a.free(got);
    try std.testing.expectEqualStrings("x\nERROR: no such table: t\n2.5\n", got);
}

test parseCases {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = try parseCases(arena.allocator(), "-- header\n\n-- case: one\nSELECT 1;\n\n-- case:two\nSELECT 2;");
    try std.testing.expectEqual(2, cases.len);
    try std.testing.expectEqualStrings("one", cases[0].name);
    try std.testing.expectEqualStrings("SELECT 1;\n\n", cases[0].sql);
    try std.testing.expectEqualStrings("two", cases[1].name);
    try std.testing.expectEqualStrings("SELECT 2;\n", cases[1].sql);
}
