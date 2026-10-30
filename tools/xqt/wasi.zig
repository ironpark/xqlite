//! `xqt wasi`: xqlite built for wasm32-wasi (`zig build -Dtarget=wasm32-wasi`)
//! run under a WASI runtime (wasmtime), against sqlite3 and the native
//! xqlite: SQL results, transactions with the rollback journal and WAL,
//! reopening, crash recovery in both directions and each dialect. Every
//! file the WASI build writes must pass sqlite3's integrity_check.
//! `zig build test-wasi` runs it.

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const usage =
    \\usage: xqt wasi [--wasm PATH] [--runtime PROG]
    \\  --wasm PATH      xqlite for wasm32-wasi  ($XQ_WASM, default ROOT/zig-out/bin/xqlite.wasm)
    \\  --runtime PROG   the WASI runtime        ($WASMTIME, default wasmtime on PATH);
    \\                   run as PROG run --dir . WASM ARGS...
    \\
;

/// The WASI build and how to run it.
const Wasi = struct {
    wasm: []const u8,
    runtime: []const u8,

    /// `xqlite ARGS...` under the runtime, in the check's directory (the
    /// only one the program can see); must succeed.
    fn xq(w: Wasi, c: *Check, args: []const []const u8) ![]const u8 {
        const argv = try std.mem.concat(c.arena, []const u8, &.{ &.{ w.runtime, "run", "--dir", ".", w.wasm }, args });
        return c.runOk(argv, .{});
    }

    fn sql(w: Wasi, c: *Check, db: []const u8, text: []const u8) ![]const u8 {
        return w.xq(c, &.{ "sql", db, text });
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, cfg: *const xqt.Config, out: *std.Io.Writer, args: []const []const u8) !u8 {
    var w: Wasi = .{
        .wasm = cfg.environ.get("XQ_WASM") orelse try std.fs.path.join(gpa, &.{ cfg.root, "zig-out", "bin", "xqlite.wasm" }),
        .runtime = cfg.environ.get("WASMTIME") orelse "wasmtime",
    };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--wasm") and i + 1 < args.len) {
            i += 1;
            w.wasm = args[i];
        } else if (std.mem.eql(u8, args[i], "--runtime") and i + 1 < args.len) {
            i += 1;
            w.runtime = args[i];
        } else {
            try out.writeAll(usage);
            return 2;
        }
    }
    // Checks run in directories of their own.
    w.wasm = try xqt.Config.absolute(gpa, io, w.wasm);
    w.runtime = try xqt.Config.absolute(gpa, io, w.runtime);
    var suite: xqt.Suite = .init(gpa, io, cfg, out, .{ .name = "wasi" });
    defer suite.deinit();
    try suite.add("runtime and module", runtimeWorks, .{w});
    try suite.add("same results as sqlite3", sameResults, .{w});
    try suite.add("transactions with the rollback journal", journal, .{w});
    try suite.add("WAL: write, reopen, read by sqlite3", wal, .{w});
    try suite.add("WAL left by a killed sqlite3 is recovered", walRecovery, .{w});
    try suite.add("hot journal left under WASI, rolled back by sqlite3", hotJournal, .{w});
    inline for (dialects) |d| try suite.add("dialect " ++ d[0] ++ ": same as native xqlite", dialect, .{ w, @as([]const u8, d[1]) });
    suite.run();
    try suite.summary();
    return @intFromBool(suite.failed() > 0);
}

fn integrityOk(c: *Check, db: []const u8) !void {
    const ok = try c.sqlite3(db, "PRAGMA integrity_check");
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, ok, "\n"), "ok")) return c.abort("integrity_check of {s}: {s}", .{ db, ok });
}

/// The runtime runs the module at all (else every other check fails the
/// same way).
fn runtimeWorks(c: *Check, w: Wasi) !void {
    if (!c.exists(w.wasm)) return c.abort("no {s}: zig build -Dtarget=wasm32-wasi", .{w.wasm});
    const r = c.run(&.{ w.runtime, "--version" }, .{}) catch return c.abort("cannot run {s} (install wasmtime)", .{w.runtime});
    if (!r.ok()) return c.abort("{s} --version: {f}", .{ w.runtime, r });
    const got = try w.sql(c, ":memory:", "SELECT 1 + 1, sqlite_version(), typeof(random()), length(datetime('now'))");
    _ = c.expectSame("output", "want", "2|3.54.1|integer|19\n", "got", got);
}

const schema =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL);
    \\CREATE INDEX t_b ON t(b);
    \\CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
    \\WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<3000)
    \\INSERT INTO t SELECT n, 'name' || (n % 97), n * 1.5 FROM c;
    \\INSERT INTO w SELECT b, count(*) FROM t GROUP BY b;
    \\DELETE FROM t WHERE a % 7 = 0;
    \\UPDATE t SET b = upper(b), c = c + 1 WHERE a % 5 = 0;
    \\CREATE TABLE big(x); INSERT INTO big SELECT randomblob(5000) FROM t WHERE a < 50;
;
const queries =
    \\SELECT count(*), sum(a), min(b), max(b), total(c) FROM t;
    \\SELECT k, v FROM w ORDER BY k LIMIT 5;
    \\SELECT count(*), sum(length(x)) FROM big;
    \\SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;
;

/// The WASI build writes a database (with overflow pages and a
/// WITHOUT ROWID table); sqlite3 checks it and gives the same results.
fn sameResults(c: *Check, w: Wasi) !void {
    _ = try w.sql(c, "a.db", schema);
    try integrityOk(c, "a.db");
    _ = c.expectSame("results", "sqlite3", try c.sqlite3("a.db", queries), "wasi", try w.sql(c, "a.db", queries));
}

const transactions =
    \\PRAGMA journal_mode=delete;
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b);
    \\BEGIN; INSERT INTO t VALUES(1, 'one'); INSERT INTO t VALUES(2, 'two'); COMMIT;
    \\BEGIN; INSERT INTO t VALUES(3, 'gone'); UPDATE t SET b = 'x'; ROLLBACK;
    \\SAVEPOINT s1; INSERT INTO t VALUES(4, 'four');
    \\SAVEPOINT s2; DELETE FROM t; ROLLBACK TO s2; RELEASE s1;
    \\BEGIN IMMEDIATE; UPDATE t SET b = b || '!' WHERE a > 1; COMMIT;
    \\WITH RECURSIVE c(n) AS (SELECT 10 UNION ALL SELECT n+1 FROM c WHERE n<2000)
    \\INSERT INTO t SELECT n, randomblob(300) FROM c;
    \\BEGIN; DELETE FROM t WHERE a >= 10; ROLLBACK;
    \\SELECT count(*), group_concat(b) FILTER (WHERE a < 10) FROM t;
;

/// Commit, rollback and savepoints in rollback-journal mode, as sqlite3
/// does them; the journal is gone afterwards.
fn journal(c: *Check, w: Wasi) !void {
    const got = try w.sql(c, "a.db", transactions);
    const want = try c.sqlite3("b.db", transactions);
    // randomblob() differs, its count does not.
    _ = c.expectSame("output", "sqlite3", want, "wasi", got);
    try integrityOk(c, "a.db");
    if (c.exists("a.db-journal")) c.fail("journal left behind", .{});
    _ = c.expectSame("reopened", "sqlite3", try c.sqlite3("a.db", "SELECT count(*), sum(a) FROM t"), "wasi", try w.sql(c, "a.db", "SELECT count(*), sum(a) FROM t"));
}

/// WAL mode under WASI (in-process wal-index), reopened by a second WASI
/// process, then read and written by sqlite3 and read back.
fn wal(c: *Check, w: Wasi) !void {
    const mode = try w.sql(c, "a.db",
        \\PRAGMA journal_mode=wal; CREATE TABLE t(a INTEGER PRIMARY KEY, b);
        \\BEGIN; INSERT INTO t VALUES(1, 'x'); INSERT INTO t VALUES(2, 'y'); COMMIT;
        \\BEGIN; INSERT INTO t VALUES(3, 'z'); ROLLBACK;
        \\WITH RECURSIVE c(n) AS (SELECT 10 UNION ALL SELECT n+1 FROM c WHERE n<1500)
        \\INSERT INTO t SELECT n, randomblob(500) FROM c;
        \\PRAGMA wal_checkpoint(PASSIVE);
        \\INSERT INTO t VALUES(5000, 'after checkpoint');
    );
    _ = c.expect(std.mem.startsWith(u8, mode, "wal\n"), "journal_mode: {s}", .{mode});
    _ = c.expectSame("reopened", "want", "1494\nwal\n", "wasi", try w.sql(c, "a.db", "SELECT count(*) FROM t; PRAGMA journal_mode"));
    try integrityOk(c, "a.db");
    _ = try c.sqlite3("a.db", "INSERT INTO t VALUES(6000, 'sqlite3')");
    _ = c.expectSame("after sqlite3", "want", "1495|6000\n", "wasi", try w.sql(c, "a.db", "SELECT count(*), max(a) FROM t"));
    _ = try w.sql(c, "a.db", "PRAGMA journal_mode=delete");
    if (c.exists("a.db-wal")) c.fail("WAL left behind after journal_mode=delete", .{});
    try integrityOk(c, "a.db");
}

/// sqlite3 is killed with committed transactions in the WAL; the WASI
/// build, which ignores the -shm file, rebuilds the wal-index from the WAL.
fn walRecovery(c: *Check, w: Wasi) !void {
    var sq = try c.spawn(&.{ c.cfg.sqlite3, "a.db" }, .{ .output = "sqlite3.out" });
    defer sq.kill();
    try sq.write(
        \\PRAGMA journal_mode=wal; PRAGMA wal_autocheckpoint=0;
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b);
        \\WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<500)
        \\INSERT INTO t SELECT n, randomblob(100) FROM c;
        \\SELECT 'done';
        \\
    );
    var i: usize = 0;
    while (!std.mem.containsAtLeast(u8, @as([]const u8, c.readFile("sqlite3.out") catch ""), 1, "done")) {
        i += 1;
        if (i >= 100) return c.abort("sqlite3 did not finish", .{});
        c.sleep(50);
    }
    sq.kill();
    const size = try c.fileSize("a.db-wal") orelse 0;
    if (size == 0) return c.abort("no WAL left behind", .{});
    _ = c.expectSame("recovered", "want", "500\nwal\n", "wasi", try w.sql(c, "a.db", "SELECT count(*) FROM t; PRAGMA journal_mode"));
    try integrityOk(c, "a.db");
}

/// `xqlite crash-write` under WASI dies after commit phase one; sqlite3
/// rolls the hot journal back to the original content.
fn hotJournal(c: *Check, w: Wasi) !void {
    _ = try c.sqlite3("a.db",
        \\PRAGMA page_size=1024; CREATE TABLE t(x);
        \\WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<500)
        \\INSERT INTO t SELECT randomblob(200) FROM c;
    );
    const before = try c.sqlite3("a.db", ".dump");
    _ = try w.xq(c, &.{ "crash-write", "a.db", "0xff" });
    if ((try c.fileSize("a.db-journal") orelse 0) == 0) return c.abort("no hot journal left behind", .{});
    try integrityOk(c, "a.db");
    _ = c.expectSame("content after rollback", "before", before, "after", try c.sqlite3("a.db", ".dump"));
}

/// A script per dialect, run by the native xqlite and by the WASI build
/// on files of their own.
const dialects = .{
    .{
        "postgres",
        \\PRAGMA xq_dialect = 'postgres';
        \\CREATE TABLE p(id SERIAL PRIMARY KEY, name VARCHAR(20) NOT NULL, n INTEGER);
        \\INSERT INTO p(name, n) VALUES ('a', 1), ('b', 2);
        \\BEGIN; UPDATE p SET n = n * 10; ROLLBACK;
        \\SELECT id, name, n::text || 'x', 7 / 2 FROM p ORDER BY id;
        \\SELECT table_name FROM information_schema.tables WHERE table_name = 'p';
    },
    .{
        "mariadb",
        \\PRAGMA xq_dialect = 'mariadb';
        \\CREATE TABLE m(id INT AUTO_INCREMENT PRIMARY KEY, s VARCHAR(10));
        \\INSERT INTO m(s) VALUES ('x'), ('y');
        \\INSERT INTO m(id, s) VALUES (1, 'z') ON DUPLICATE KEY UPDATE s = 'dup';
        \\SELECT CONCAT(s, id) FROM m ORDER BY id;
    },
    .{
        "mssql",
        \\PRAGMA xq_dialect = 'mssql';
        \\CREATE TABLE q(id INT IDENTITY(1,1) PRIMARY KEY, s NVARCHAR(10));
        \\INSERT INTO q(s) VALUES ('x'), ('y');
        \\BEGIN TRAN; DELETE FROM q; ROLLBACK TRAN;
        \\SELECT TOP 1 s + 'z' FROM q ORDER BY id DESC;
    },
    .{
        "oracle",
        \\PRAGMA xq_dialect = 'oracle';
        \\CREATE TABLE o(id NUMBER PRIMARY KEY, s VARCHAR2(10));
        \\INSERT INTO o VALUES (1, ''); INSERT INTO o VALUES (2, 'b');
        \\COMMIT;
        \\SELECT id, NVL(s, 'null') FROM o ORDER BY id;
    },
};

fn dialect(c: *Check, w: Wasi, script: []const u8) !void {
    const want = try c.xqSql("native.db", script);
    const got = try w.sql(c, "wasi.db", script);
    _ = c.expectSame("output", "native", want, "wasi", got);
    try integrityOk(c, "wasi.db");
    // Reopened, the catalog brings the dialect's types back.
    _ = c.expectSame("reopened", "native", try c.xqSql("native.db", ".schema"), "wasi", try w.sql(c, "wasi.db", ".schema"));
}
