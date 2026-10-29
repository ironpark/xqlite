//! ANALYZE and PRAGMA optimize against sqlite3: on the same data, xqlite
//! and sqlite3 must write the same sqlite_stat1 rows (rowids included),
//! and a database analyzed by either must give the same query plans and
//! PRAGMA optimize decisions when read by the other. The reference sqlite3
//! should be 3.54.1. (Was tools/interop-analyze.sh.)

const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "analyze";
pub const about = "the same sqlite_stat1 rows; plans and PRAGMA optimize on each other's statistics";

pub fn register(s: *xqt.Suite) !void {
    try s.add("sqlite_stat1, plans and PRAGMA optimize", statPlansOptimize, .{});
    try s.add("sqlite_stat1 with analysis_limit", statLimit, .{});
}

// More than 30 tables, so that the schema hash has its largest bucket
// array; skewed columns, partial, expression, NOCASE, UNIQUE and WITHOUT
// ROWID indexes, an empty table, a view, dropped tables.
const schema = schema_head ++ tables() ++ "\nDROP TABLE m3; DROP TABLE m17; DROP TABLE m30;";
const schema_head =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b, c, d TEXT COLLATE NOCASE, e);
    \\CREATE INDEX t_b ON t(b);
    \\CREATE INDEX t_c ON t(c);
    \\CREATE INDEX t_bc ON t(b, c);
    \\CREATE UNIQUE INDEX t_d ON t(d);
    \\CREATE INDEX t_e ON t(e) WHERE e IS NOT NULL;
    \\CREATE INDEX t_x ON t(c % 7, b);
    \\CREATE TABLE w(x, y, z, PRIMARY KEY(x, y)) WITHOUT ROWID;
    \\CREATE INDEX w_z ON w(z);
    \\CREATE TABLE plain(p, q);
    \\CREATE TABLE empty(a);
    \\CREATE INDEX empty_a ON empty(a);
    \\CREATE VIEW v AS SELECT * FROM t;
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<5000)
    \\INSERT INTO t SELECT i, i % 2, i % 700, 'v' || i, CASE WHEN i % 25 = 0 THEN i % 9 END FROM n;
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<800)
    \\INSERT INTO w SELECT i % 30, i, i % 11 FROM n;
    \\INSERT INTO plain VALUES (1, 2), (3, 4);
;

/// Tables m0..m35 with an index and three rows each.
fn tables() []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        for (0..36) |i| {
            const n = std.fmt.comptimePrint("{d}", .{i});
            out = out ++ "\nCREATE TABLE m" ++ n ++ "(k, v); CREATE INDEX m" ++ n ++ "_k ON m" ++ n ++ "(k); INSERT INTO m" ++ n ++
                " VALUES (" ++ n ++ ", 1), (" ++ n ++ ", 2), (" ++ n ++ " + 1, 3);";
        }
        return out;
    }
}

const plans =
    \\EXPLAIN QUERY PLAN SELECT * FROM t WHERE b = 1 AND c = 5;
    \\EXPLAIN QUERY PLAN SELECT * FROM t WHERE b = 1 AND c > 690;
    \\EXPLAIN QUERY PLAN SELECT * FROM t WHERE b = 0 AND e = 3;
    \\EXPLAIN QUERY PLAN SELECT * FROM t, w WHERE t.c = w.z AND w.x = 3;
    \\EXPLAIN QUERY PLAN SELECT * FROM w WHERE z = 1 AND x = 3;
    \\EXPLAIN QUERY PLAN SELECT * FROM t WHERE c % 7 = 1 AND b = 0 AND c = 8;
    \\PRAGMA optimize(-1);
;
const stat = "SELECT rowid, * FROM sqlite_stat1;";
const change = "INSERT INTO plain SELECT a, b FROM t; CREATE INDEX plain_p ON plain(p); DELETE FROM w WHERE y > 20;";

/// base.db built by sqlite3, copied to each name.
fn copies(c: *Check, names: []const []const u8) !void {
    _ = try c.sqlite3("base.db", schema);
    for (names) |n| try c.copyFile("base.db", n);
}

fn integrityOk(c: *Check, db: []const u8, label: []const u8) !void {
    const ok = std.mem.trimEnd(u8, try c.sqlite3(db, "PRAGMA integrity_check"), "\n");
    _ = c.expect(std.mem.eql(u8, ok, "ok"), "integrity_check ({s}): {s}", .{ label, ok });
}

/// 1. The same rows of sqlite_stat1; 2. each reads the other's statistics
/// and gives the same plans as with its own; 3. PRAGMA optimize after the
/// data changed, by each on the other's file.
fn statPlansOptimize(c: *Check) !void {
    try copies(c, &.{ "sq.db", "xq.db" });
    const sq_stat = try c.sqlite3("sq.db", "ANALYZE; " ++ stat);
    const xq_stat = try c.xqSql("xq.db", "ANALYZE; " ++ stat);
    _ = c.expectSame("sqlite_stat1 rows ()", "sq", sq_stat, "xq", xq_stat);
    try integrityOk(c, "xq.db", "");

    const own = try c.sqlite3("sq.db", plans);
    _ = c.expectSame("plans (sq-xq)", "sq-own", own, "sq-xq", try c.sqlite3("xq.db", plans));
    _ = c.expectSame("plans (xq-own)", "sq-own", own, "xq-own", try c.xqSql("xq.db", plans));
    _ = c.expectSame("plans (xq-sq)", "sq-own", own, "xq-sq", try c.xqSql("sq.db", plans));

    const sq_opt = try c.sqlite3("xq.db", change ++ " PRAGMA optimize; " ++ stat);
    const xq_opt = try c.xqSql("sq.db", change ++ " PRAGMA optimize; " ++ stat);
    _ = c.expectSame("PRAGMA optimize", "sq-opt", sq_opt, "xq-opt", xq_opt);
    try integrityOk(c, "sq.db", "sq, optimized");
    try integrityOk(c, "xq.db", "xq, optimized");
}

/// 1. The same rows of sqlite_stat1 with analysis_limit.
fn statLimit(c: *Check) !void {
    try copies(c, &.{ "sqlim.db", "xqlim.db" });
    const sql = "PRAGMA analysis_limit=100; ANALYZE; ANALYZE m5; " ++ stat;
    const sq_stat = try c.sqlite3("sqlim.db", sql);
    const xq_stat = try c.xqSql("xqlim.db", sql);
    _ = c.expectSame("sqlite_stat1 rows (lim)", "sqlim", sq_stat, "xqlim", xq_stat);
    try integrityOk(c, "xqlim.db", "lim");
}
