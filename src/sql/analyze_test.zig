//! End-to-end tests of ANALYZE and PRAGMA optimize, in the style of
//! sql_test.zig. The expected rows are sqlite3 3.54.1's.

const std = @import("std");
const testing = std.testing;

const Conn = @import("sql_test.zig").Conn;

const schema =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b, c, d);
    \\CREATE INDEX tb ON t(b);
    \\CREATE INDEX tbc ON t(b, c);
    \\CREATE UNIQUE INDEX tc ON t(c);
    \\CREATE INDEX td ON t(d) WHERE d IS NOT NULL;
    \\CREATE TABLE w(x, y, z, PRIMARY KEY(x, y)) WITHOUT ROWID;
    \\CREATE TABLE n(q);
    \\CREATE TABLE e(q);
    \\CREATE INDEX eq ON e(q);
    \\CREATE VIEW v AS SELECT * FROM t;
    \\WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<1000)
    \\  INSERT INTO t SELECT i, i%10, i, CASE WHEN i%50=0 THEN i%3 END FROM c;
    \\WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<300)
    \\  INSERT INTO w SELECT i%7, i, i%13 FROM c;
    \\INSERT INTO n VALUES(1),(2);
;

test "analyze: sqlite_stat1 rows" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    // Every table in the order of the schema hash; a partial index counts
    // its own rows; an empty table and a view get no row; a table without
    // indexes gets its row count.
    try c.expectRows("ANALYZE; SELECT rowid, * FROM sqlite_stat1",
        \\1|t|td|20 7
        \\2|t|tc|1000 1
        \\3|t|tbc|1000 100 1
        \\4|t|tb|1000 100
        \\5|w|w|300 43 1
        \\6|n|NULL|2
        \\
    );
    // ANALYZE of a table replaces its rows; analysis_limit scans only part
    // of each index.
    try c.expectRows("PRAGMA analysis_limit=20; ANALYZE t; PRAGMA analysis_limit=0; SELECT rowid, * FROM sqlite_stat1",
        \\20
        \\0
        \\5|w|w|300 43 1
        \\6|n|NULL|2
        \\7|t|td|20 7
        \\8|t|tc|1000 1
        \\9|t|tbc|1000 21 1
        \\10|t|tb|1000 21
        \\
    );
    // A WITHOUT ROWID table, and a single index (schema.index).
    try c.expectRows("ANALYZE w; ANALYZE main.tb; SELECT rowid, * FROM sqlite_stat1",
        \\6|n|NULL|2
        \\7|t|td|20 7
        \\8|t|tc|1000 1
        \\9|t|tbc|1000 21 1
        \\11|w|w|300 43 1
        \\12|t|tb|1000 100
        \\
    );
    try c.expectRows("ANALYZE v; ANALYZE main; ANALYZE sqlite_schema; SELECT count(*) FROM sqlite_stat1", "6\n");
    try c.expectError("ANALYZE nosuch", "no such table: nosuch");
    try c.expectError("ANALYZE main.nosuch", "no such table: main.nosuch");
    try c.expectError("ANALYZE nodb.t", "unknown database nodb");

    // The TEMP database is analyzed only when named.
    try c.exec("CREATE TEMP TABLE tt(a, b); CREATE INDEX tta ON tt(a); INSERT INTO tt VALUES(1,1),(1,2),(2,3)");
    try c.expectRows("ANALYZE; SELECT count(*) FROM temp.sqlite_schema WHERE name='sqlite_stat1'", "0\n");
    try c.expectRows("ANALYZE temp; SELECT * FROM temp.sqlite_stat1", "tt|tta|3 2\n");
}

test "analyze: the planner uses the statistics" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(x, y, z);
        \\CREATE INDEX tx ON t(x);
        \\CREATE INDEX ty ON t(y);
        \\CREATE INDEX tz ON t(z);
        \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<3000)
        \\  INSERT INTO t SELECT i%2, i%1000, 1 FROM n;
    );
    const q = "EXPLAIN QUERY PLAN SELECT * FROM t WHERE z=1 AND x=1 AND y=5";
    try c.expectRows(q, "3|0|62|SEARCH t USING INDEX tz (z=?)\n");
    // The same connection plans with the new statistics ...
    try c.expectRows("ANALYZE; SELECT * FROM sqlite_stat1", "t|tz|3000 3000\nt|ty|3000 3\nt|tx|3000 1500\n");
    try c.expectRows(q, "3|0|48|SEARCH t USING INDEX ty (y=?)\n");
    // ... and so does the next one, which reads them with the schema.
    try c.reopen();
    try c.expectRows(q, "3|0|48|SEARCH t USING INDEX ty (y=?)\n");
    try c.expectRows("DELETE FROM sqlite_stat1; ANALYZE sqlite_schema; " ++ q, "3|0|60|SEARCH t USING INDEX tz (z=?)\n");
}

test "analyze: PRAGMA optimize" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    // Before any ANALYZE, mask 0x10000 checks every table.
    try c.expectRows("PRAGMA optimize(-1)",
        \\ANALYZE "main"."t"
        \\ANALYZE "main"."w"
        \\ANALYZE "main"."n"
        \\
    );
    try c.exec("ANALYZE");
    // Bit 0x02 off: nothing.
    try c.expectRows("PRAGMA optimize(1)", "");
    try c.expectRows("PRAGMA optimize(3); PRAGMA optimize(0x10003)", "");
    // A table that grew 10-fold, and an index without statistics.
    try c.exec("INSERT INTO n SELECT a FROM t");
    try c.expectRows("PRAGMA optimize(3)", "");
    try c.expectRows("PRAGMA optimize(0x10003)", "ANALYZE \"main\".\"n\"\n");
    try c.exec("CREATE INDEX wz ON w(z)");
    try c.expectRows("PRAGMA main.optimize(3)", "ANALYZE \"main\".\"w\"\n");
    try c.expectRows("PRAGMA optimize; SELECT * FROM sqlite_stat1 WHERE tbl='w'", "w|wz|300 24\nw|w|300 43 1\n");
    try c.expectRows("PRAGMA optimize(3)", "");
}
