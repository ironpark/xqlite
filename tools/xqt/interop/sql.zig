//! The SQL layer against sqlite3: the same statements run by `xqlite sql`
//! and by sqlite3 on databases written by either, which must pass
//! sqlite3's integrity check and give the same query results.
//! (Was tools/interop-sql.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "sql";
pub const about = "same SQL on files written by either engine: results, integrity_check";

pub fn register(s: *xqt.Suite) !void {
    try s.add("written by xqlite", writtenByXqlite, .{});
    try s.add("sqlite3 file changed by xqlite", changedByXqlite, .{});
    try s.add("both orders give the content of sqlite3 alone", sameAsSqlite3, .{});
    try s.add("auto-vacuum file changed by xqlite", autoVacuum, .{});
}

const schema =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL);
    \\CREATE INDEX t_b ON t(b);
    \\CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
    \\CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, x UNIQUE);
    \\CREATE VIEW vt AS SELECT b, count(*) AS n FROM t GROUP BY b;
;
const fill =
    \\WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<2000)
    \\INSERT INTO t SELECT n, 'name' || (n % 97), n * 1.5 FROM c;
    \\INSERT INTO w SELECT b, count(*) FROM t GROUP BY b;
    \\INSERT INTO s(x) SELECT a FROM t WHERE a % 3 = 0;
;
const churn =
    \\DELETE FROM t WHERE a % 7 = 0;
    \\UPDATE t SET b = upper(b), c = c + 1 WHERE a % 5 = 0;
    \\UPDATE w SET v = v * 10 WHERE k > 'name5';
    \\DELETE FROM w WHERE k LIKE '%3';
    \\DELETE FROM s WHERE id > 600;
    \\INSERT INTO s(x) VALUES('new');
    \\CREATE INDEX t_c ON t(c);
    \\CREATE TABLE gone(z); INSERT INTO gone SELECT a FROM t; DROP TABLE gone;
;
const queries =
    \\SELECT count(*), sum(a), min(b), max(b), total(c) FROM t;
    \\SELECT k, v FROM w ORDER BY k LIMIT 5;
    \\SELECT * FROM sqlite_sequence;
    \\SELECT max(id), count(*) FROM s;
    \\SELECT * FROM vt ORDER BY n DESC, b LIMIT 3;
    \\SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;
;

/// sqlite3's integrity_check passes on `db`, and both engines give the
/// same results for `queries` on it.
fn agree(c: *Check, db: []const u8) !void {
    const ok = try c.sqlite3(db, "PRAGMA integrity_check");
    _ = c.expect(std.mem.eql(u8, std.mem.trimEnd(u8, ok, "\n"), "ok"), "integrity_check: {s}", .{ok});
    const x = try c.xqSql(db, queries);
    const s = try c.sqlite3(db, queries);
    _ = c.expectSame("results", "xqlite", x, "sqlite3", s);
}

/// 1. xqlite writes everything.
fn writtenByXqlite(c: *Check) !void {
    _ = try c.xqSql("a.db", schema ++ " " ++ fill ++ " " ++ churn);
    try agree(c, "a.db");
}

/// 2. sqlite3 builds, xqlite changes.
fn changedByXqlite(c: *Check) !void {
    _ = try c.sqlite3("b.db", schema ++ " " ++ fill);
    _ = try c.xqSql("b.db", churn);
    try agree(c, "b.db");
}

/// 3. Both orders give the same content as sqlite3 alone.
fn sameAsSqlite3(c: *Check) !void {
    _ = try c.xqSql("a.db", schema ++ " " ++ fill ++ " " ++ churn);
    _ = try c.sqlite3("b.db", schema ++ " " ++ fill);
    _ = try c.xqSql("b.db", churn);
    _ = try c.sqlite3("c.db", schema ++ " " ++ fill ++ " " ++ churn);
    const ref = try c.sqlite3("c.db", queries);
    for ([_][]const u8{ "a.db", "b.db" }) |db| {
        const got = try c.xqSql(db, queries);
        _ = c.expectSame(try std.fmt.allocPrint(c.arena, "{s} against sqlite3 alone", .{db}), "sqlite3 alone", ref, db, got);
    }
}

/// 4. The same on an auto-vacuum database (DROP moves root pages).
fn autoVacuum(c: *Check) !void {
    _ = try c.sqlite3("d.db", "PRAGMA auto_vacuum=FULL; " ++ schema ++ " " ++ fill);
    _ = try c.xqSql("d.db", churn);
    try agree(c, "d.db");
}
