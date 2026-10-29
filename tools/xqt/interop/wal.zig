//! WAL mode (journal_mode=WAL) between xqlite and sqlite3:
//!   1. WAL databases written by one engine, with frames not yet
//!      checkpointed, read and checkpointed by the other; leaving WAL mode
//!   2. checkpoint modes and their result rows, wal_autocheckpoint, page
//!      sizes 512..65536, auto_vacuum
//!   3. crash recovery: a process dies mid-transaction, mid-commit, right
//!      after the commit frame and mid-checkpoint; each engine recovers a
//!      copy of what is left, and both must agree with the expected content
//!   4. both engines on one database at once: snapshots that outlive other
//!      engines' commits, writer contention and busy_timeout, checkpoints
//!      next to readers, and a randomized stress run of several processes
//!      checked against invariants
//! STRESS_TXNS sets the transactions per stress process (default 3000; 4
//! processes). (Was tools/interop-wal.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;
const crash = xqt.crash;
const proc = xqt.proc;

pub const name = "wal";
pub const about = "WAL files, checkpoints, crash recovery and concurrent processes";

pub fn register(s: *xqt.Suite) !void {
    const a = s.arena.allocator();
    // The longest first.
    try s.add("4) stress run of 2+2 processes", stress, .{});
    for ([_]Engine{ .x, .s }) |reader| {
        try s.add(try std.fmt.allocPrint(a, "4) {s} reader and holder, {s} writer", .{ reader.name(), reader.other().name() }), concurrent, .{reader});
    }
    try s.add("3) sqlite3 killed mid-checkpoint", sqliteKilledMidCheckpoint, .{});
    try s.add("3) sqlite3 killed mid-transaction", sqliteKilledMidTransaction, .{});
    for (crash_cases) |cc| {
        try s.add(try std.fmt.allocPrint(a, "3) xqlite crash ({s})", .{cc.label}), xqliteCrash, .{cc});
    }
    for ([_]bool{ false, true }) |torn| {
        try s.add(if (torn) "3) xqlite crash mid-checkpoint (db:300:torn)" else "3) xqlite crash mid-checkpoint (db:300)", xqliteCrashMidCheckpoint, .{torn});
    }
    for ([_][]const u8{ "512", "1024", "2048", "4096", "8192", "16384", "32768", "65536" }) |ps| {
        for ([_]Engine{ .x, .s }) |writer| {
            try s.add(try std.fmt.allocPrint(a, "2) page_size={s}, {s} first", .{ ps, writer.name() }), pageSize, .{ ps, writer });
        }
    }
    for ([_][]const u8{ "full", "incremental" }) |av| {
        for ([_]Engine{ .x, .s }) |writer| {
            try s.add(try std.fmt.allocPrint(a, "2) auto_vacuum={s}, {s} first", .{ av, writer.name() }), autoVacuum, .{ av, writer });
        }
    }
    for ([_][]const u8{ "PASSIVE", "FULL", "RESTART", "TRUNCATE", "NOOP" }) |mode| {
        try s.add(try std.fmt.allocPrint(a, "2) wal_checkpoint({s})", .{mode}), checkpointMode, .{mode});
    }
    for ([_][]const u8{ "1", "10", "100" }) |n| {
        try s.add(try std.fmt.allocPrint(a, "2) wal_autocheckpoint={s}", .{n}), autocheckpoint, .{n});
    }
    for ([_]Engine{ .x, .s }) |writer| {
        try s.add(try std.fmt.allocPrint(a, "1) WAL of {s}", .{writer.name()}), walOf, .{writer});
    }
    for (2..8) |round| {
        try s.add(try std.fmt.allocPrint(a, "1) turn {d} by {s}", .{ round, turnWriter(round).name() }), turn, .{round});
    }
    for ([_]Engine{ .x, .s }) |leaver| {
        try s.add(try std.fmt.allocPrint(a, "1) {s} leaves WAL mode", .{leaver.name()}), leave, .{leaver});
    }
    for ([_][]const u8{ "DELETE", "WAL" }) |mode| {
        try s.add(try std.fmt.allocPrint(a, "1) read-only {s} database", .{mode}), readOnly, .{mode});
    }
}

// ---------------------------------------------------------------- helpers

const Engine = enum {
    x,
    s,

    fn name(e: Engine) []const u8 {
        return if (e == .x) "xqlite" else "sqlite3";
    }

    fn other(e: Engine) Engine {
        return if (e == .x) .s else .x;
    }

    /// The shell of the engine on `db`, followed by `args`.
    fn argv(e: Engine, c: *Check, db: []const u8, args: []const []const u8) ![]const []const u8 {
        const pre: []const []const u8 = if (e == .x) &.{ c.cfg.xq, "sql", db } else &.{ c.cfg.sqlite3, db };
        return std.mem.concat(c.arena, []const u8, &.{ pre, args });
    }
};

/// `E ENGINE DB ARGS...`, which must succeed: the standard output.
fn E(c: *Check, e: Engine, db: []const u8, args: []const []const u8) ![]const u8 {
    return c.runOk(try e.argv(c, db, args), .{});
}

/// `E ...`, whatever its exit status.
fn runE(c: *Check, e: Engine, db: []const u8, args: []const []const u8) !proc.Result {
    return c.run(try e.argv(c, db, args), .{});
}

/// Without the lines that .dbconfig prints (`grep -v '^ *no_ckpt_on_close'`).
fn dropDbconfig(c: *Check, text: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(c.arena);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (it.peek() == null and line.len == 0) break;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "no_ckpt_on_close")) continue;
        try w.writer.print("{s}\n", .{line});
    }
    return w.written();
}

fn trimmed(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Keeps the WAL on close (the last connection would checkpoint it).
const nockpt = ".dbconfig no_ckpt_on_close on";

/// What `argv [< input] > out 2>&1` writes, in one file as the program
/// interleaves standard output and error, and how it ended.
fn merged(c: *Check, argv: []const []const u8, input: []const u8, out: []const u8) !struct { []const u8, std.process.Child.Term } {
    var p = try c.spawn(argv, .{ .output = out });
    defer p.kill();
    if (input.len > 0) p.write(input) catch |err| switch (err) {
        error.BrokenPipe => {},
        else => |e| return e,
    };
    const term = try p.close();
    return .{ try c.readFile(out), term };
}

/// The database `src` and whatever WAL and -shm it has, copied to `dst`.
fn copyDb(c: *Check, src: []const u8, dst: []const u8) !void {
    for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
        const from = try std.mem.concat(c.arena, u8, &.{ src, suffix });
        const to = try std.mem.concat(c.arena, u8, &.{ dst, suffix });
        try c.remove(to);
        if (suffix.len == 0 or c.exists(from)) try c.copyFile(from, to);
    }
}

/// The size of a file, 0 if there is none.
fn fsize(c: *Check, file: []const u8) !u64 {
    return try c.fileSize(file) orelse 0;
}

/// The .dump of `db` by `e` (which checkpoints and removes the WAL on
/// close).
fn dump(c: *Check, e: Engine, db: []const u8) ![]const u8 {
    return (try runE(c, e, db, &.{".dump"})).stdout;
}

/// `e`'s integrity_check of `db` passes.
fn check(c: *Check, label: []const u8, e: Engine, db: []const u8) !void {
    const ok = trimmed(try E(c, e, db, &.{"PRAGMA integrity_check"}));
    if (!eql(ok, "ok")) return c.abort("{s}: {s} integrity_check: {s}", .{ label, e.name(), ok });
}

/// The frames in the WAL `wal` of page size `ps`.
fn frames(c: *Check, wal: []const u8, ps: u64) !u64 {
    const size = try fsize(c, wal);
    return if (size > 32) (size - 32) / (ps + 24) else 0;
}

/// The write and read format versions of the header, "22" for WAL.
fn versions(c: *Check, db: []const u8) ![]const u8 {
    const r = try c.run(&.{ c.cfg.xq, "dbinfo", db }, .{});
    var w: std.Io.Writer.Allocating = .init(c.arena);
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "write format") == null and std.mem.indexOf(u8, line, "read format") == null) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next();
        _ = fields.next();
        try w.writer.writeAll(fields.next() orelse "");
    }
    return w.written();
}

/// The copies of `db` that each engine recovers and dumps must agree with
/// each other, and with `want` if given.
fn agree(c: *Check, label: []const u8, db: []const u8, want: ?[]const u8) !void {
    try copyDb(c, db, "agree-x.db");
    try copyDb(c, db, "agree-s.db");
    const dx = try dump(c, .x, "agree-x.db");
    const ds = try dump(c, .s, "agree-s.db");
    if (!eql(dx, ds)) return c.abort("{s}: xqlite and sqlite3 read different content", .{label});
    if (want) |w| if (!eql(dx, w)) return c.abort("{s}: content differs from the expected", .{label});
    // Each engine checkpointed its copy: the other must accept the result.
    try check(c, try std.fmt.allocPrint(c.arena, "{s} (checkpointed by xqlite)", .{label}), .s, "agree-x.db");
    try check(c, try std.fmt.allocPrint(c.arena, "{s} (checkpointed by sqlite3)", .{label}), .x, "agree-s.db");
}

const schema =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
    \\CREATE INDEX t_b ON t(b);
    \\CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
;
const fill =
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1500)
    \\INSERT INTO t SELECT i, 'v' || (i*7919 % 1500), zeroblob(i % 700) FROM n;
    \\INSERT INTO w SELECT b, count(*) FROM t GROUP BY b;
;

/// Deterministic changes, round `r`.
fn churn(c: *Check, r: usize) ![]const u8 {
    return std.fmt.allocPrint(c.arena,
        \\DELETE FROM t WHERE a % 7 = {0d};
        \\UPDATE t SET b = b || '.{0d}', c = zeroblob(({0d} * 97 + a) % 900) WHERE a % 5 = {1d};
        \\INSERT INTO t SELECT a + 10000 * ({0d} + 1), 'n{0d}-' || a, zeroblob(a % 300) FROM t WHERE a < 200;
        \\UPDATE w SET v = v + {0d} WHERE k > 'v7';
        \\DELETE FROM w WHERE k LIKE '%{0d}';
    , .{ r, r % 5 });
}

/// A WAL database with the schema and its rows, written by `e`.
fn walDb(c: *Check, e: Engine, db: []const u8) !void {
    _ = try E(c, e, db, &.{ "PRAGMA journal_mode=WAL", schema, fill });
}

// ---------------------------------------------------------------- 1

/// WAL files of one engine read by the other.
fn walOf(c: *Check, writer: Engine) !void {
    const db = "w.db";
    try walDb(c, writer, db);
    const v = try versions(c, db);
    if (!eql(v, "22")) return c.abort("{s}: header versions are {s}, not 2/2", .{ writer.name(), v });
    _ = try E(c, writer, db, &.{ nockpt, try churn(c, 1) });
    if (try frames(c, db ++ "-wal", 4096) <= 10) return c.abort("{s} left no frames", .{writer.name()});
    try agree(c, try std.fmt.allocPrint(c.arena, "WAL of {s}", .{writer.name()}), db, null);
}

fn turnWriter(round: usize) Engine {
    return if (round % 2 == 0) .x else .s;
}

/// Both engines writing in turn, each leaving its frames to the other:
/// the rounds up to `last`, then the check of that one.
fn turn(c: *Check, last: usize) !void {
    const db = "turns.db";
    try walDb(c, .s, db);
    for (2..last + 1) |round| _ = try E(c, turnWriter(round), db, &.{ nockpt, try churn(c, round) });
    try agree(c, try std.fmt.allocPrint(c.arena, "turn {d} by {s}", .{ last, turnWriter(last).name() }), db, null);
}

/// Leaving WAL mode with frames pending: checkpoint, delete the WAL,
/// rewrite the header versions.
fn leave(c: *Check, leaver: Engine) !void {
    const db = "leave.db";
    const other = leaver.other();
    try walDb(c, other, db);
    _ = try E(c, other, db, &.{ nockpt, try churn(c, 3) });
    try copyDb(c, db, "leave-ref.db");
    const want = try dump(c, .s, "leave-ref.db");
    var out = trimmed(try E(c, leaver, db, &.{"PRAGMA journal_mode=DELETE"}));
    if (!eql(out, "delete")) return c.abort("{s} journal_mode=DELETE: {s}", .{ leaver.name(), out });
    if (c.exists(db ++ "-wal")) return c.abort("{s} left the WAL behind", .{leaver.name()});
    const v = try versions(c, db);
    if (!eql(v, "11")) return c.abort("{s}: header versions are {s}, not 1/1", .{ leaver.name(), v });
    out = trimmed(try E(c, other, db, &.{"PRAGMA journal_mode"}));
    if (!eql(out, "delete")) return c.abort("{s} sees journal_mode={s}", .{ other.name(), out });
    if (!eql(try dump(c, other, db), want)) return c.abort("content changed leaving WAL mode", .{});
    try check(c, "after leaving WAL mode", other, db);
}

/// A database file without write permission opens read-only, in rollback
/// and in WAL mode (with a writable WAL and -shm next to it).
fn readOnly(c: *Check, mode: []const u8) !void {
    const db = "ro.db";
    _ = try E(c, .s, db, &.{ try std.fmt.allocPrint(c.arena, "PRAGMA journal_mode={s}", .{mode}), schema, fill });
    _ = try E(c, .s, db, &.{ nockpt, try churn(c, 1) });
    try std.Io.Dir.cwd().setFilePermissions(c.io, try c.path(db), @fromBackingInt(0o444), .{});
    var got: [2][]const u8 = undefined;
    for ([_]Engine{ .x, .s }, &got) |e, *g| {
        // `Q ... > out 2>&1 || echo "exit $?" >> out`: standard error
        // comes first (standard output goes through grep), and the status
        // is grep's, 1 if no line is left.
        const r = try runE(c, e, db, &.{ nockpt, "SELECT count(*), sum(a) FROM t", "INSERT INTO t VALUES(-1, 'x', 1)", "SELECT count(*) FROM t" });
        const out = try dropDbconfig(c, r.stdout);
        g.* = try std.mem.concat(c.arena, u8, &.{ r.stderr, out, if (out.len == 0) "exit 1\n" else "" });
    }
    if (!c.expectSame(try std.fmt.allocPrint(c.arena, "read-only {s} database: results", .{mode}), "xqlite", got[0], "sqlite3", got[1])) return;
    if (std.mem.indexOf(u8, got[0], "attempt to write a readonly database") == null)
        return c.abort("read-only {s} database: {s}", .{ mode, got[0] });
}

// ---------------------------------------------------------------- 2

/// Each engine runs `sql` (which checkpoints) on its own copy of `db`; the
/// outputs and the resulting files must be identical.
fn sameCheckpoint(c: *Check, label: []const u8, db: []const u8, sql: []const u8) !void {
    try copyDb(c, db, "ckpt-x.db");
    try copyDb(c, db, "ckpt-s.db");
    const rx = trimmed(try E(c, .x, "ckpt-x.db", &.{sql}));
    const rs = trimmed(try E(c, .s, "ckpt-s.db", &.{sql}));
    if (!eql(rx, rs)) return c.abort("{s}: '{s}' gives {s} and {s}", .{ label, sql, rx, rs });
    if (!eql(try c.readFile("ckpt-x.db"), try c.readFile("ckpt-s.db"))) return c.abort("{s}: checkpointed files differ", .{label});
}

/// A WAL database with frames pending, written by sqlite3.
fn checkpointBase(c: *Check, db: []const u8) !void {
    try walDb(c, .s, db);
    _ = try E(c, .s, db, &.{ nockpt, try churn(c, 1) });
}

fn checkpointMode(c: *Check, mode: []const u8) !void {
    try checkpointBase(c, "ckpt.db");
    const ck = try std.fmt.allocPrint(c.arena, "PRAGMA wal_checkpoint({s})", .{mode});
    var got: [2][]const u8 = undefined;
    for ([_]Engine{ .x, .s }, &got) |e, *g| {
        const db = if (e == .x) "ckpt-x.db" else "ckpt-s.db";
        try copyDb(c, "ckpt.db", db);
        const argv = try e.argv(c, db, &.{ nockpt, ck, try churn(c, 2), ck, "PRAGMA main.wal_checkpoint", "INSERT INTO t VALUES(99999, 'x', 1)", ck });
        const out, const term = try merged(c, argv, "", "ckpt.out");
        if (!term.success()) return c.abort("{s}: {f}: {s}", .{ e.name(), term, out });
        g.* = try std.fmt.allocPrint(c.arena, "{s}{d}\n{d}\n", .{ out, try fsize(c, try std.mem.concat(c.arena, u8, &.{ db, "-wal" })), try fsize(c, db) });
    }
    if (!eql(got[0], got[1])) {
        c.writeDiff("xqlite", got[0], "sqlite3", got[1]);
        return c.abort("wal_checkpoint({s}): results differ", .{mode});
    }
    try agree(c, try std.fmt.allocPrint(c.arena, "wal_checkpoint({s})", .{mode}), "ckpt-x.db", try dump(c, .s, "ckpt-s.db"));
}

/// The same commits with an autocheckpoint every `n` frames.
fn autocheckpoint(c: *Check, n: []const u8) !void {
    var input: std.Io.Writer.Allocating = .init(c.arena);
    const w = &input.writer;
    try w.print("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint={s}; PRAGMA wal_autocheckpoint;\n", .{n});
    try w.print("{s}\n", .{schema});
    for (0..30) |i| {
        try w.print("INSERT INTO t VALUES({d}, 'r{d}', zeroblob({d} * 211 % 5000));\n", .{ i, i, i });
        try w.writeAll("PRAGMA wal_checkpoint(NOOP);\n");
    }
    var got: [2][]const u8 = undefined;
    for ([_]Engine{ .x, .s }, &got) |e, *g| {
        const db = if (e == .x) "ac-x.db" else "ac-s.db";
        // The SQL goes to standard input, but a shell given an argument
        // after the database runs that and does not read it (as before).
        const out, const term = try merged(c, try e.argv(c, db, &.{nockpt}), input.written(), "ac.out");
        if (!term.success()) return c.abort("{s}: {f}: {s}", .{ e.name(), term, out });
        g.* = out;
    }
    if (!eql(got[0], got[1])) {
        c.writeDiff("xqlite", got[0], "sqlite3", got[1]);
        return c.abort("wal_autocheckpoint={s}: WAL sizes differ", .{n});
    }
}

fn pageSize(c: *Check, ps: []const u8, writer: Engine) !void {
    const db = "ps.db";
    const other = writer.other();
    _ = try E(c, writer, db, &.{ try std.fmt.allocPrint(c.arena, "PRAGMA page_size={s}", .{ps}), "PRAGMA journal_mode=WAL", schema, fill });
    _ = try E(c, writer, db, &.{ nockpt, try churn(c, 4) });
    const got = trimmed(try dropDbconfig(c, (try runE(c, other, db, &.{ nockpt, "PRAGMA page_size" })).stdout));
    if (!eql(got, ps)) return c.abort("page_size={s} not kept", .{ps});
    _ = try E(c, other, db, &.{ nockpt, try churn(c, 5) });
    try agree(c, try std.fmt.allocPrint(c.arena, "page_size={s}, {s} first", .{ ps, writer.name() }), db, null);
    try sameCheckpoint(c, try std.fmt.allocPrint(c.arena, "page_size={s}", .{ps}), db, "PRAGMA wal_checkpoint(TRUNCATE)");
}

fn autoVacuum(c: *Check, av: []const u8, writer: Engine) !void {
    const db = "av.db";
    _ = try E(c, writer, db, &.{ "PRAGMA page_size=1024", try std.fmt.allocPrint(c.arena, "PRAGMA auto_vacuum={s}", .{av}), "PRAGMA journal_mode=WAL", schema, fill });
    _ = try E(c, writer, db, &.{ nockpt, "DELETE FROM t WHERE a > 300", "PRAGMA incremental_vacuum(50)" });
    _ = try E(c, writer.other(), db, &.{ nockpt, "DELETE FROM t WHERE a < 100", "PRAGMA incremental_vacuum" });
    const label = try std.fmt.allocPrint(c.arena, "auto_vacuum={s}", .{av});
    try sameCheckpoint(c, label, db, "PRAGMA auto_vacuum; PRAGMA page_count; PRAGMA freelist_count; PRAGMA wal_checkpoint(TRUNCATE)");
    try check(c, label, .s, "ckpt-x.db");
}

// ---------------------------------------------------------------- 3

/// A database with 1000 pages of 1024 bytes, fully checkpointed.
fn makeDb(c: *Check, db: []const u8) !void {
    for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| try c.remove(try std.mem.concat(c.arena, u8, &.{ db, suffix }));
    _ = try E(c, .s, db, &.{
        "PRAGMA page_size=1024", "PRAGMA journal_mode=WAL", "CREATE TABLE t(x)",
        \\WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<2000)
        \\         INSERT INTO t SELECT zeroblob(300) FROM c
    });
}

const update = "UPDATE t SET x = zeroblob(301)";

/// The content of `makeDb` before and after `update`, and the frames that
/// commit takes.
const Reference = struct { before: []const u8, after: []const u8, n_commit: u64 };

fn reference(c: *Check) !Reference {
    try makeDb(c, "ref.db");
    const before = try dump(c, .s, "ref.db");
    try makeDb(c, "ref-after.db");
    _ = try E(c, .s, "ref-after.db", &.{ nockpt, update });
    const n_commit = try frames(c, "ref-after.db-wal", 1024);
    return .{ .before = before, .after = try dump(c, .s, "ref-after.db"), .n_commit = n_commit };
}

/// xqlite dies at a write to the WAL ($XQLITE_TEST_CRASH, see xqlite's
/// usage): its header is write 1, frame N writes 2N and 2N+1 (header and
/// page). The crash comes after N frames of a spill of an open transaction
/// (cache too small), or part way through or right after the frames of a
/// commit; or it tears the page of the commit frame in half.
const CrashCase = struct {
    label: []const u8,
    /// After this many frames: a number, or of the commit's.
    at: union(enum) { frames: u64, half_commit, commit },
    pragma: ?[]const u8 = null,
    torn: bool = false,
    /// The content to recover: from before the update or after it.
    after: bool,
};

const crash_cases = [_]CrashCase{
    .{ .label = "spill", .at = .{ .frames = 10 }, .pragma = "PRAGMA cache_size=10", .after = false },
    .{ .label = "commit", .at = .half_commit, .after = false },
    .{ .label = "commit-frame", .at = .commit, .after = true },
    .{ .label = "torn-commit-frame", .at = .commit, .torn = true, .after = false },
};

fn xqliteCrash(c: *Check, cc: CrashCase) !void {
    const ref = try reference(c);
    const at: u64 = switch (cc.at) {
        .frames => |n| n,
        .half_commit => ref.n_commit / 2,
        .commit => ref.n_commit,
    };
    const whole = if (cc.torn) at - 1 else at;
    const db = "c.db";
    try makeDb(c, db);
    const e = try crash.xqEnv(c, .wal, @intCast(2 * at + 1), .{ .torn = cc.torn });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.arena, &.{ c.cfg.xq, "sql", db });
    if (cc.pragma) |p| try argv.append(c.arena, p);
    try argv.appendSlice(c.arena, &.{ update, "SELECT 'not crashed'" });
    const r = try c.run(argv.items, .{ .env = e });
    if (std.mem.indexOf(u8, r.stdout, "not crashed") != null or std.mem.indexOf(u8, r.stderr, "not crashed") != null)
        return c.abort("xqlite {s}: did not crash", .{cc.label});
    const n = try frames(c, db ++ "-wal", 1024);
    if (n != whole) return c.abort("xqlite {s}: {d} whole frames, not {d}", .{ cc.label, n, whole });
    try agree(c, try std.fmt.allocPrint(c.arena, "xqlite crash ({s})", .{cc.label}), db, if (cc.after) ref.after else ref.before);
}

/// xqlite dies part way through a checkpoint, at (or tearing) its 300th
/// write to the database file: the file is half updated, but the WAL is
/// intact.
fn xqliteCrashMidCheckpoint(c: *Check, torn: bool) !void {
    const spec = if (torn) "db:300:torn" else "db:300";
    const db = "k.db";
    try makeDb(c, db);
    _ = try E(c, .s, db, &.{ nockpt, update });
    try copyDb(c, db, "k-ref.db");
    const want_after = try dump(c, .s, "k-ref.db");
    const db_before = try c.readFile(db);
    const r = try c.run(&.{ c.cfg.xq, "sql", db, "PRAGMA wal_checkpoint" }, .{ .env = try crash.xqEnv(c, .db, 300, .{ .torn = torn }) });
    if (r.stdout.len + r.stderr.len > 0)
        return c.abort("xqlite did not crash mid-checkpoint ({s}): {s}{s}", .{ spec, r.stderr, r.stdout });
    if (eql(try c.readFile(db), db_before)) return c.abort("the checkpoint wrote nothing ({s})", .{spec});
    try agree(c, try std.fmt.allocPrint(c.arena, "xqlite crash mid-checkpoint ({s})", .{spec}), db, want_after);
}

/// sqlite3 killed mid-transaction, after spilling into the WAL.
fn sqliteKilledMidTransaction(c: *Check) !void {
    try makeDb(c, "ref.db");
    const want_before = try dump(c, .s, "ref.db");
    const db = "s.db";
    try makeDb(c, db);
    const size0 = try fsize(c, db ++ "-wal");
    var sq = try c.spawn(&.{ c.cfg.sqlite3, db }, .{ .output = "s.out" });
    defer sq.kill();
    try sq.write("PRAGMA cache_size=10; BEGIN; " ++ update ++ "; UPDATE t SET x = zeroblob(302);\n");
    var i: usize = 0;
    while (try fsize(c, db ++ "-wal") <= size0 + 100 * 1048) {
        i += 1;
        if (i >= 200) return c.abort("sqlite3 never spilled", .{});
        c.sleep(50);
    }
    sq.kill();
    try agree(c, "sqlite3 killed mid-transaction", db, want_before);
}

/// sqlite3 killed while it checkpoints a large WAL (where exactly it dies
/// varies; the content must not).
fn sqliteKilledMidCheckpoint(c: *Check) !void {
    const db = "m.db";
    try makeDb(c, db);
    _ = try E(c, .s, db, &.{ nockpt, "PRAGMA cache_size=-100000", update, "UPDATE t SET x = zeroblob(303)", "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<40000) INSERT INTO t SELECT zeroblob(50) FROM c" });
    try copyDb(c, db, "m-ref.db");
    const want = try dump(c, .s, "m-ref.db");
    const db_before = try c.readFile(db);
    var sq = try c.spawn(&.{ c.cfg.sqlite3, db }, .{ .output = "m.out" });
    defer sq.kill();
    try sq.write("PRAGMA wal_checkpoint;\n");
    var i: usize = 0;
    while (eql(try c.readFile(db), db_before) and i < 400) {
        i += 1;
        c.sleep(10);
    }
    sq.kill();
    try agree(c, "sqlite3 killed mid-checkpoint", db, want);
}

// ---------------------------------------------------------------- 4

/// Waits until the output file `out` of a shell has a line that starts
/// with `prefix`.
fn waitFor(c: *Check, out: []const u8, prefix: []const u8) !void {
    var i: usize = 0;
    while (true) {
        const text = c.readFile(out) catch "";
        if (row(text, prefix) != null) return;
        i += 1;
        if (i >= 400) return c.abort("timed out waiting for '^{s}' from {s}: {s}", .{ prefix, out, text });
        c.sleep(50);
    }
}

/// The rest of the first line of `text` that starts with `prefix`.
fn row(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}

/// The checkpoint's first column (`${ck%%|*}`).
fn busyColumn(ck: []const u8) []const u8 {
    const t = trimmed(ck);
    return t[0 .. std.mem.indexOfScalar(u8, t, '|') orelse t.len];
}

fn concurrent(c: *Check, reader: Engine) !void {
    const writer = reader.other();
    const rn = reader.name();
    const wn = writer.name();
    const db = "cc.db";
    _ = try E(c, .s, db, &.{ "PRAGMA journal_mode=WAL", "CREATE TABLE t(x)", "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<100) INSERT INTO t SELECT i FROM c" });

    // A reader keeps its snapshot across commits and checkpoints by the
    // other engine, and sees them once its transaction ends.
    {
        var r = try c.spawn(try reader.argv(c, db, &.{}), .{ .output = "r.out" });
        defer r.kill();
        try r.write("BEGIN; SELECT 'r1', count(*), sum(x) FROM t;\n");
        try waitFor(c, "r.out", "r1|");
        if (!(try runE(c, writer, db, &.{ "INSERT INTO t VALUES(1000)", "UPDATE t SET x = x + 1 WHERE x < 10" })).ok())
            return c.abort("{s} could not write next to a {s} reader", .{ wn, rn });
        var ck = try E(c, writer, db, &.{"PRAGMA wal_checkpoint"});
        if (!eql(busyColumn(ck), "0")) return c.abort("{s}: passive checkpoint next to a reader: {s}", .{ wn, ck });
        const all = trimmed((try runE(c, writer, db, &.{ "PRAGMA busy_timeout=200", "PRAGMA wal_checkpoint(RESTART)" })).stdout);
        ck = all[(if (std.mem.lastIndexOfScalar(u8, all, '\n')) |i| i + 1 else 0)..];
        if (!eql(busyColumn(ck), "1")) return c.abort("{s}: RESTART should be busy with a {s} reader: {s}", .{ wn, rn, ck });
        try r.write("SELECT 'r2', count(*), sum(x) FROM t;\n");
        try waitFor(c, "r.out", "r2|");
        try r.write("COMMIT; SELECT 'r3', count(*), sum(x) FROM t;\n");
        try waitFor(c, "r.out", "r3|");
        const out = try c.readFile("r.out");
        const r1 = row(out, "r1|").?;
        const r2 = row(out, "r2|").?;
        const r3 = row(out, "r3|").?;
        if (!eql(r1, "100|5050")) return c.abort("{s} snapshot: {s}", .{ rn, r1 });
        if (!eql(r2, "100|5050")) return c.abort("{s} lost its snapshot: {s}", .{ rn, r2 });
        if (!eql(r3, "101|6059")) return c.abort("{s} after commit: {s}", .{ rn, r3 });
        try r.write(".quit\n");
        _ = r.close() catch {};
        ck = try E(c, writer, db, &.{"PRAGMA wal_checkpoint(RESTART)"});
        if (!eql(busyColumn(ck), "0")) return c.abort("{s}: RESTART after the reader left: {s}", .{ wn, ck });
    }

    // Writers contend: busy at once without a timeout, waiting with one.
    {
        var h = try c.spawn(try reader.argv(c, db, &.{}), .{ .output = "h.out" });
        defer h.kill();
        try h.write("BEGIN IMMEDIATE; INSERT INTO t VALUES(2000); SELECT 'held';\n");
        try waitFor(c, "h.out", "held");
        const busy = try runE(c, writer, db, &.{"INSERT INTO t VALUES(2001)"});
        if (busy.ok()) return c.abort("{s} wrote while {s} held the write lock", .{ wn, rn });
        if (std.mem.indexOf(u8, busy.stdout, "database is locked") == null and std.mem.indexOf(u8, busy.stderr, "database is locked") == null)
            return c.abort("{s}: {s}{s}", .{ wn, busy.stdout, busy.stderr });
        var waiter = try c.spawn(try writer.argv(c, db, &.{ "PRAGMA busy_timeout=10000", "INSERT INTO t VALUES(2002)", "SELECT 'waited'" }), .{ .output = "wait.out" });
        defer waiter.kill();
        // In the background, with no input.
        if (waiter.child.stdin) |f| {
            f.close(c.io);
            waiter.child.stdin = null;
        }
        c.sleep(300);
        try h.write("COMMIT; SELECT 'committed';\n");
        try waitFor(c, "h.out", "committed");
        const term = try waiter.close();
        const wait_out = try c.readFile("wait.out");
        if (!term.success()) return c.abort("{s}: busy_timeout did not wait: {s}", .{ wn, wait_out });
        if (std.mem.indexOf(u8, wait_out, "waited") == null) return c.abort("{s}: {s}", .{ wn, wait_out });
        try h.write(".quit\n");
        _ = h.close() catch {};
    }
    const n = trimmed((try runE(c, reader, db, &.{"SELECT count(*) FROM t WHERE x >= 2000"})).stdout);
    if (!eql(n, "2")) return c.abort("contended writes lost", .{});
    try check(c, try std.fmt.allocPrint(c.arena, "contention ({s} holds)", .{rn}), writer, db);
}

/// One stress process: its engine, its script and what it printed.
const StressProc = struct {
    engine: Engine,
    sql: []const u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    err: ?anyerror = null,
};

const StressRun = struct {
    c: *Check,
    db: []const u8,
    procs: []StressProc,
    /// One per process: proc.run's output is not allocated in the check's
    /// arena, which is not thread-safe.
    arenas: []std.heap.ArenaAllocator,

    fn runOne(r: *StressRun, i: usize) void {
        const p = &r.procs[i];
        const a = r.arenas[i].allocator();
        const argv: []const []const u8 = if (p.engine == .x) &.{ r.c.cfg.xq, "sql", r.db } else &.{ r.c.cfg.sqlite3, r.db };
        const res = proc.run(a, r.c.io, argv, .{ .cwd = r.c.dir, .stdin = p.sql }) catch |err| {
            p.err = err;
            return;
        };
        p.stdout = res.stdout;
        p.stderr = res.stderr;
    }
};

/// What the transactions of a stress script count.
const Counts = struct { log: usize = 0, txn: usize = 0 };

/// The script of stress process `id`: transfers between accounts that
/// keep the total balance constant and log one row each (70%), readers
/// that check the total twice inside one snapshot (25%) and checkpoints of
/// every mode (5%). (awk's rand() made the old script's; this is
/// std.Random with the same seeds.)
fn stressScript(c: *Check, id: u32, seed: u64, cache: u32, sync: []const u8, n: usize, counts: *Counts) ![]const u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    var out: std.Io.Writer.Allocating = .init(c.arena);
    const w = &out.writer;
    try w.print("PRAGMA busy_timeout=60000;\nPRAGMA cache_size={d};\nPRAGMA synchronous={s};\n", .{ cache, sync });
    const modes = [_][]const u8{ "PASSIVE", "FULL", "RESTART", "TRUNCATE" };
    for (1..n + 1) |s| {
        const r = rand.float(f64);
        if (r < 0.70) {
            const a = rand.uintLessThan(u32, 200) + 1;
            const b = rand.uintLessThan(u32, 200) + 1;
            const v = rand.uintLessThan(u32, 100);
            try w.print("BEGIN IMMEDIATE;\nUPDATE acct SET bal = bal - {d} WHERE id = {d};\n", .{ v, a });
            if (rand.float(f64) < 0.1) try w.print("UPDATE log SET note = zeroblob({d}) WHERE id % 37 = {d};\n", .{ rand.uintLessThan(u32, 900), s % 37 });
            try w.print("UPDATE acct SET bal = bal + {d} WHERE id = {d};\n", .{ v, b });
            try w.print("INSERT INTO log(proc, seq, note) VALUES({d}, {d}, zeroblob({d}));\nCOMMIT;\n", .{ id, s, rand.uintLessThan(u32, 500) });
            counts.log += 1;
            counts.txn += 1;
        } else if (r < 0.95) {
            try w.print("BEGIN;\nSELECT 'sum', sum(bal) FROM acct;\nSELECT count(*) FROM log WHERE proc = {d};\n", .{id});
            try w.writeAll("SELECT 'sum', sum(bal) FROM acct;\nCOMMIT;\n");
            counts.txn += 1;
        } else {
            try w.print("PRAGMA wal_checkpoint({s});\n", .{modes[rand.uintLessThan(usize, 4)]});
        }
    }
    return out.written();
}

/// The stress run: 4 processes, 2 per engine, on one database. One process
/// per engine uses a tiny cache, so that transactions spill frames into
/// the WAL before they commit.
fn stress(c: *Check) !void {
    const n: usize = if (c.cfg.environ.get("STRESS_TXNS")) |v|
        std.fmt.parseUnsigned(usize, v, 10) catch return c.abort("STRESS_TXNS={s}", .{v})
    else
        3000;
    const db = "stress.db";
    _ = try E(c, .s, db, &.{
        "PRAGMA journal_mode=WAL",
        "CREATE TABLE acct(id INTEGER PRIMARY KEY, bal INTEGER NOT NULL)",
        "CREATE TABLE log(id INTEGER PRIMARY KEY, proc, seq, note BLOB)",
        "CREATE INDEX log_ps ON log(proc, seq)",
        "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<200) INSERT INTO acct SELECT i, 1000 FROM c",
    });
    var counts: Counts = .{};
    var procs = [_]StressProc{
        .{ .engine = .x, .sql = try stressScript(c, 1, 11, 10, "FULL", n, &counts) },
        .{ .engine = .s, .sql = try stressScript(c, 2, 22, 2000, "NORMAL", n, &counts) },
        .{ .engine = .x, .sql = try stressScript(c, 3, 33, 10, "NORMAL", n, &counts) },
        .{ .engine = .s, .sql = try stressScript(c, 4, 44, 2000, "FULL", n, &counts) },
    };
    var arenas: [procs.len]std.heap.ArenaAllocator = undefined;
    for (&arenas) |*a| a.* = .init(c.suite.gpa);
    defer for (&arenas) |*a| a.deinit();
    var run: StressRun = .{ .c = c, .db = db, .procs = &procs, .arenas = &arenas };
    const started = std.Io.Clock.awake.now(c.io);
    xqt.pool.forEach(procs.len, procs.len, &run, StressRun.runOne);
    const elapsed = started.durationTo(std.Io.Clock.awake.now(c.io)).toMilliseconds();

    var bad: usize = 0;
    var n_snap: usize = 0;
    for (procs, 1..) |p, i| {
        if (p.err) |err| return c.abort("stress process {d}: {t}", .{ i, err });
        if (p.stderr.len > 0) return c.abort("stress process {d}: {s}", .{ i, p.stderr[0..@min(p.stderr.len, 500)] });
        var lines = std.mem.splitScalar(u8, p.stdout, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "sum|")) continue;
            n_snap += 1;
            if (!eql(line, "sum|200000")) bad += 1;
        }
    }
    if (bad != 0) return c.abort("stress: {d} snapshots saw a wrong total", .{bad});
    const want = try std.fmt.allocPrint(c.arena, "ok\n200000|200\n{d}|{d}", .{ counts.log, counts.log });
    for ([_]Engine{ .x, .s }) |e| {
        const r = try runE(c, e, db, &.{ nockpt, "PRAGMA integrity_check", "SELECT sum(bal), count(*) FROM acct", "SELECT count(*), count(DISTINCT proc || '.' || seq) FROM log" });
        const out = trimmed(try dropDbconfig(c, r.stdout));
        if (!eql(out, want)) return c.abort("stress: {s} finds: {s}", .{ e.name(), out });
    }
    try agree(c, "after the stress run", db, null);
    c.print("{d} transactions ({d} writes, {d} snapshot checks) by 2+2 processes in {d}ms", .{ counts.txn, counts.log, n_snap, elapsed });
}
