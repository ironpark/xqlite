//! End-to-end tests of the SQL layer: open a connection on an in-memory
//! file system, run statements, and check results and errors.

const std = @import("std");
const testing = std.testing;
const int = @import("sqlite_int.zig");
const main_mod = @import("main.zig");
const legacy = @import("legacy.zig");
const prepare = @import("prepare.zig");
const api = @import("../vdbe/api.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;

const RC = int.RC;

/// A connection to "test.db" on a private in-memory file system.
const Conn = struct {
    mem: MemVfs,
    db: *int.Sqlite3,

    fn open(c: *Conn) !void {
        return c.openWith(null);
    }

    /// Open "test.db" holding `image`, if given.
    fn openWith(c: *Conn, image: ?[]const u8) !void {
        c.mem = MemVfs.init(testing.allocator, testing.io);
        if (image) |bytes| {
            const f = try c.mem.interface().open("test.db", .{ .create = true });
            defer f.close();
            try f.write(bytes, 0);
        }
        const rc = main_mod.open(testing.allocator, c.mem.interface(), "test.db", .{}, &c.db);
        if (rc != RC.OK) {
            std.debug.print("open: {s}\n", .{main_mod.errmsg(c.db)});
            return error.OpenFailed;
        }
    }

    fn close(c: *Conn) void {
        std.testing.expectEqual(RC.OK, main_mod.close(c.db)) catch unreachable;
        c.mem.deinit();
    }

    /// Run `sql`; fail the test with the error message if it fails.
    fn exec(c: *Conn, sql: []const u8) !void {
        var msg: ?[:0]u8 = null;
        const rc = legacy.exec(c.db, sql, null, null, &msg);
        if (rc != RC.OK) {
            std.debug.print("{s}\n  -> {s}\n", .{ sql, msg orelse "?" });
            if (msg) |m| testing.allocator.free(m);
            return error.ExecFailed;
        }
    }

    /// Run `sql` and return its rows, a line each with the columns
    /// separated by "|" and NULL as "NULL". The caller frees the result.
    fn query(c: *Conn, sql: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(testing.allocator);
        var msg: ?[:0]u8 = null;
        const rc = legacy.exec(c.db, sql, collect, &out, &msg);
        if (rc != RC.OK) {
            std.debug.print("{s}\n  -> {s}\n", .{ sql, msg orelse "?" });
            if (msg) |m| testing.allocator.free(m);
            return error.ExecFailed;
        }
        return out.toOwnedSlice(testing.allocator);
    }

    fn collect(ctx: ?*anyopaque, values: []const ?[*:0]const u8, _: []const [*:0]const u8) bool {
        const out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
        for (values, 0..) |val, i| {
            if (i > 0) out.append(testing.allocator, '|') catch return true;
            out.appendSlice(testing.allocator, if (val) |z| std.mem.span(z) else "NULL") catch return true;
        }
        out.append(testing.allocator, '\n') catch return true;
        return false;
    }

    /// `sql` must return exactly `expected`.
    fn expectRows(c: *Conn, sql: []const u8, expected: []const u8) !void {
        const got = try c.query(sql);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(expected, got) catch |err| {
            std.debug.print("query: {s}\n", .{sql});
            return err;
        };
    }

    /// Run `sql`, which must fail with `expected` as the message.
    fn expectError(c: *Conn, sql: []const u8, expected: []const u8) !void {
        var msg: ?[:0]u8 = null;
        const rc = legacy.exec(c.db, sql, null, null, &msg);
        defer if (msg) |m| testing.allocator.free(m);
        try testing.expect(rc != RC.OK);
        try testing.expectEqualStrings(expected, msg.?);
    }
};

test "sql: transaction control statements" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("BEGIN; COMMIT;");
    try testing.expect(main_mod.getAutocommit(c.db));
    try c.exec("BEGIN IMMEDIATE");
    try testing.expect(!main_mod.getAutocommit(c.db));
    try c.exec("ROLLBACK");
    try testing.expect(main_mod.getAutocommit(c.db));
    try c.expectError("COMMIT", "cannot commit - no transaction is active");
    try c.expectError("SELEC 1", "near \"SELEC\": syntax error");
}

test "sql: prepare reports the tail and blank input" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    var stmt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
    var tail: []const u8 = "";
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "BEGIN; COMMIT", &stmt, &tail));
    try testing.expectEqualStrings(" COMMIT", tail);
    try testing.expectEqual(RC.DONE, api.step(stmt.?));
    _ = api.finalize(stmt.?);
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "  -- nothing\n", &stmt, &tail));
    try testing.expect(stmt == null);
    try c.exec("COMMIT");
}

test "sql: SELECT without FROM" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("SELECT 1, 'a'||'b', 2*3+1, NULL, 7/2, 7.0/2", "1|ab|7|NULL|3|3.5\n");
    try c.expectRows("SELECT abs(-3), upper('xy'), length('hello'), typeof(1.5), coalesce(NULL, 4)", "3|XY|5|real|4\n");
    try c.expectRows("SELECT 1 WHERE 0", "");
    try c.expectRows("SELECT CASE WHEN 1<2 THEN 'lt' ELSE 'ge' END, 3 IN (1,2,3), 5 BETWEEN 1 AND 4", "lt|1|0\n");
    try c.expectRows("SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 1", "1\n2\n1\n");
    try c.expectRows("SELECT 2 UNION SELECT 1 UNION SELECT 2", "1\n2\n");
    try c.expectRows("VALUES(1,'x'),(2,'y')", "1|x\n2|y\n");
    try c.expectRows("SELECT count(*), sum(1), max(3, 9)", "1|1|9\n");
    try c.expectError("SELECT nosuch(1)", "no such function: nosuch");
    try c.expectError("SELECT * FROM nosuch", "no such table: nosuch");
}

test "sql: SELECT from a database written by sqlite3" {
    var c: Conn = undefined;
    try c.openWith(@embedFile("../testdata/sql.db"));
    defer c.close();
    try c.expectRows("SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name",
        "table|t1|t1\nindex|t1_b|t1\ntable|t2|t2\ntable|wr|wr\n");
    try c.expectRows("SELECT * FROM t1", "1|one|1.5\n2|two|2.5\n3|three|NULL\n4|four|4.0\n5|five|-1.0\n");
    try c.expectRows("SELECT a, b FROM t1 WHERE c > 2 OR c IS NULL", "2|two\n3|three\n4|four\n");
    try c.expectRows("SELECT rowid, upper(b) FROM t1 WHERE a = 3", "3|THREE\n");
    try c.expectRows("SELECT b FROM t1 ORDER BY b DESC LIMIT 2 OFFSET 1", "three\none\n");
    try c.expectRows("SELECT count(*) FROM t1", "5\n");
    try c.expectRows("SELECT count(c), sum(a), avg(a), min(b), max(c) FROM t1", "4|15|3.0|five|4.0\n");
    try c.expectRows("SELECT x, count(*), group_concat(y) FROM t2 GROUP BY x", "1|1|a\n2|2|b,c\n9|1|z\n");
    try c.expectRows("SELECT x FROM t2 GROUP BY x HAVING count(*) > 1", "2\n");
    try c.expectRows("SELECT DISTINCT x FROM t2", "1\n2\n9\n");
    try c.expectRows("SELECT count(DISTINCT x) FROM t2", "3\n");
    try c.expectRows("SELECT * FROM wr", "a|1\nb|2\nc|3\n");
    try c.expectRows("SELECT b, y FROM t1, t2 WHERE a = x", "one|a\ntwo|b\ntwo|c\n");
    try c.expectRows("SELECT b, y FROM t1 JOIN t2 ON a = x AND y <> 'b'", "one|a\ntwo|c\n");
    try c.expectRows("SELECT a, y FROM t1 LEFT JOIN t2 ON a = x WHERE a < 4", "1|a\n2|b\n2|c\n3|NULL\n");
    try c.expectRows("SELECT x FROM t2 WHERE x IN (SELECT a FROM t1)", "1\n2\n2\n");
    try c.expectRows("SELECT (SELECT max(a) FROM t1), EXISTS (SELECT 1 FROM t2 WHERE x = 9)", "5|1\n");
    try c.expectRows("SELECT s.n FROM (SELECT a*10 AS n FROM t1 WHERE a < 3) AS s", "10\n20\n");
    try c.expectRows("WITH c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n < 4) SELECT sum(n) FROM c", "10\n");
    try c.expectError("SELECT nosuch FROM t1", "no such column: nosuch");
}


test "sql: CREATE TABLE, INSERT, UPDATE and DELETE" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT NOT NULL, c REAL DEFAULT 0.5)");
    try c.expectRows("SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema", "table|t|t|2|CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT NOT NULL, c REAL DEFAULT 0.5)\n");
    try c.exec("INSERT INTO t VALUES(1, 'one', 1.0)");
    try c.exec("INSERT INTO t(b) VALUES('two')");
    try c.exec("INSERT INTO t VALUES(NULL, 'three', 3), (10, 'ten', 10)");
    try c.expectRows("SELECT * FROM t", "1|one|1.0\n2|two|0.5\n3|three|3.0\n10|ten|10.0\n");
    try testing.expectEqual(@as(i64, 10), main_mod.lastInsertRowid(c.db));
    try c.expectError("INSERT INTO t VALUES(1, 'dup', 0)", "UNIQUE constraint failed: t.a");
    try c.expectError("INSERT INTO t(a) VALUES(5)", "NOT NULL constraint failed: t.b");
    try c.expectError("INSERT INTO t VALUES(1, 2)", "table t has 3 columns but 2 values were supplied");
    try c.expectError("INSERT INTO t(x) VALUES(1)", "table t has no column named x");
    try c.exec("INSERT OR REPLACE INTO t VALUES(1, 'uno', 1.5)");
    try c.exec("INSERT OR IGNORE INTO t VALUES(2, 'dos', 2.5)");
    try c.expectRows("SELECT a, b FROM t WHERE a < 3", "1|uno\n2|two\n");

    try c.exec("UPDATE t SET c = c * 2 WHERE a >= 3");
    try c.expectRows("SELECT a, c FROM t", "1|1.5\n2|0.5\n3|6.0\n10|20.0\n");
    try c.exec("UPDATE t SET a = 20 WHERE a = 10");
    try c.expectRows("SELECT a, b FROM t WHERE a > 3", "20|ten\n");
    try c.expectError("UPDATE t SET a = 1 WHERE a = 2", "UNIQUE constraint failed: t.a");
    try c.expectError("UPDATE t SET b = NULL", "NOT NULL constraint failed: t.b");

    try c.exec("DELETE FROM t WHERE b LIKE 't%'");
    try c.expectRows("SELECT a, b FROM t", "1|uno\n");
    try c.exec("DELETE FROM t");
    try c.expectRows("SELECT count(*) FROM t", "0\n");
    try c.expectError("INSERT INTO sqlite_schema VALUES(1,2,3,4,5)", "table sqlite_master may not be modified");
}

test "sql: indexes and WITHOUT ROWID tables" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a, b UNIQUE, c)");
    try c.exec("INSERT INTO t VALUES(1, 'x', 10), (2, 'y', 20), (3, 'z', 30)");
    try c.exec("CREATE INDEX t_c ON t(c)");
    try c.expectRows("SELECT name, tbl_name FROM sqlite_schema WHERE type = 'index' ORDER BY name", "sqlite_autoindex_t_1|t\nt_c|t\n");
    try c.expectError("INSERT INTO t VALUES(4, 'x', 40)", "UNIQUE constraint failed: t.b");
    try c.exec("UPDATE t SET b = 'w' WHERE a = 1");
    try c.exec("INSERT INTO t VALUES(4, 'x', 40)");
    try c.exec("DELETE FROM t WHERE c = 20");
    try c.expectRows("SELECT a, b, c FROM t", "1|w|10\n3|z|30\n4|x|40\n");
    try c.expectError("CREATE UNIQUE INDEX t_bad ON t(a > 1)", "UNIQUE constraint failed: index 't_bad'");

    try c.exec("CREATE TABLE w(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID");
    try c.exec("INSERT INTO w VALUES('b', 2), ('a', 1), ('c', 3)");
    try c.expectError("INSERT INTO w VALUES('a', 9)", "UNIQUE constraint failed: w.k");
    try c.exec("UPDATE w SET v = v + 10 WHERE k <> 'b'");
    try c.exec("DELETE FROM w WHERE k = 'b'");
    try c.expectRows("SELECT * FROM w", "a|11\nc|13\n");
    try c.exec("REPLACE INTO w VALUES('a', 0)");
    try c.expectRows("SELECT * FROM w", "a|0\nc|13\n");
}

test "sql: AUTOINCREMENT, INSERT ... SELECT and transactions" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, v)");
    try c.exec("INSERT INTO s(v) VALUES('a'), ('b'), ('c')");
    try c.exec("DELETE FROM s WHERE id = 3");
    try c.exec("INSERT INTO s(v) VALUES('d')");
    try c.expectRows("SELECT * FROM s", "1|a\n2|b\n4|d\n");
    try c.expectRows("SELECT name, seq FROM sqlite_sequence", "s|4\n");

    try c.exec("CREATE TABLE copy(id, v)");
    try c.exec("INSERT INTO copy SELECT * FROM s WHERE id > 1");
    try c.exec("INSERT INTO copy SELECT id + 100, v FROM copy");
    try c.expectRows("SELECT * FROM copy", "2|b\n4|d\n102|b\n104|d\n");

    try c.exec("BEGIN");
    try c.exec("INSERT INTO copy VALUES(0, 'tx')");
    try c.exec("ROLLBACK");
    try c.expectRows("SELECT count(*) FROM copy", "4\n");
    try c.exec("BEGIN; UPDATE copy SET v = upper(v); COMMIT");
    try c.expectRows("SELECT group_concat(v, '') FROM copy", "BDBD\n");
}

test "sql: CHECK constraints" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE p(a INT CHECK(a >= 0), b, CONSTRAINT pos_b CHECK(b > 0))");
    try c.exec("INSERT INTO p VALUES(1, 1)");
    try c.expectError("INSERT INTO p VALUES(-1, 1)", "CHECK constraint failed: a >= 0");
    try c.expectError("INSERT INTO p VALUES(1, 0)", "CHECK constraint failed: pos_b");
    try c.expectError("UPDATE p SET a = -5", "CHECK constraint failed: a >= 0");
}

test "sql: views and DROP" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a, b)");
    try c.exec("INSERT INTO t VALUES(1, 'x'), (2, 'y'), (3, 'z')");
    try c.exec("CREATE VIEW v AS SELECT a * 10 AS ten, upper(b) FROM t WHERE a > 1");
    try c.exec("CREATE VIEW v2(n, s) AS SELECT ten, \"upper(b)\" FROM v");
    try c.expectRows("SELECT * FROM v", "20|Y\n30|Z\n");
    try c.expectRows("SELECT s, n FROM v2 ORDER BY n DESC", "Z|30\nY|20\n");
    try c.expectRows("SELECT count(*) FROM v JOIN t ON ten = a * 10", "2\n");
    try c.expectRows("SELECT type, name, sql FROM sqlite_schema WHERE type = 'view' ORDER BY name",
        "view|v|CREATE VIEW v AS SELECT a * 10 AS ten, upper(b) FROM t WHERE a > 1\n" ++
        "view|v2|CREATE VIEW v2(n, s) AS SELECT ten, \"upper(b)\" FROM v\n");
    try c.expectError("INSERT INTO v VALUES(1, 2)", "cannot modify v because it is a view");
    try c.expectError("DROP TABLE v", "use DROP VIEW to delete view v");
    try c.expectError("DROP VIEW t", "use DROP TABLE to delete table t");
    try c.expectError("CREATE VIEW v AS SELECT 1", "view v already exists");

    try c.exec("CREATE INDEX t_b ON t(b)");
    try c.exec("DROP INDEX t_b");
    try c.expectError("DROP INDEX t_b", "no such index: t_b");
    try c.exec("DROP INDEX IF EXISTS t_b");
    try c.exec("DROP VIEW v2");
    try c.exec("DROP TABLE t");
    try c.expectError("SELECT * FROM v", "no such table: main.t");
    try c.exec("DROP VIEW v");
    try c.expectRows("SELECT count(*) FROM sqlite_schema", "0\n");
    try c.expectError("DROP TABLE t", "no such table: t");
    try c.exec("DROP TABLE IF EXISTS t");
    try c.expectError("DROP TABLE sqlite_schema", "table sqlite_master may not be dropped");
}
