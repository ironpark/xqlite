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
pub const Conn = struct {
    mem: MemVfs,
    db: *int.Sqlite3,

    pub fn open(c: *Conn) !void {
        return c.openWith(null);
    }

    /// Open "test.db" holding `image`, if given.
    pub fn openWith(c: *Conn, image: ?[]const u8) !void {
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

    /// Close and open the connection again on the same file system.
    pub fn reopen(c: *Conn) !void {
        try testing.expectEqual(RC.OK, main_mod.close(c.db));
        const rc = main_mod.open(testing.allocator, c.mem.interface(), "test.db", .{}, &c.db);
        if (rc != RC.OK) return error.OpenFailed;
    }

    pub fn close(c: *Conn) void {
        std.testing.expectEqual(RC.OK, main_mod.close(c.db)) catch unreachable;
        c.mem.deinit();
    }

    /// Run `sql`; fail the test with the error message if it fails.
    pub fn exec(c: *Conn, sql: []const u8) !void {
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
    pub fn query(c: *Conn, sql: []const u8) ![]u8 {
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

    pub fn collect(ctx: ?*anyopaque, values: []const ?[*:0]const u8, _: []const [*:0]const u8) bool {
        const out: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
        for (values, 0..) |val, i| {
            if (i > 0) out.append(testing.allocator, '|') catch return true;
            out.appendSlice(testing.allocator, if (val) |z| std.mem.span(z) else "NULL") catch return true;
        }
        out.append(testing.allocator, '\n') catch return true;
        return false;
    }

    /// `sql` must return exactly `expected`.
    pub fn expectRows(c: *Conn, sql: []const u8, expected: []const u8) !void {
        const got = try c.query(sql);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(expected, got) catch |err| {
            std.debug.print("query: {s}\n", .{sql});
            return err;
        };
    }

    /// Run `sql`, which must fail with `expected` as the message.
    pub fn expectError(c: *Conn, sql: []const u8, expected: []const u8) !void {
        var msg: ?[:0]u8 = null;
        const rc = legacy.exec(c.db, sql, null, null, &msg);
        defer if (msg) |m| testing.allocator.free(m);
        try testing.expect(rc != RC.OK);
        try testing.expectEqualStrings(expected, msg.?);
    }

    /// The result column names of `sql`, separated by "|".
    pub fn expectColumns(c: *Conn, sql: []const u8, expected: []const u8) !void {
        var stmt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
        try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, sql, &stmt, null));
        defer _ = api.finalize(stmt.?);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        for (0..api.columnCount(stmt.?)) |i| {
            if (i > 0) try out.append(testing.allocator, '|');
            try out.appendSlice(testing.allocator, api.columnName(stmt.?, i).?);
        }
        try testing.expectEqualStrings(expected, out.items);
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

test "sql: triggers" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT)");
    try c.exec("CREATE TABLE log(x TEXT)");
    try c.exec("CREATE TRIGGER ti AFTER INSERT ON t BEGIN INSERT INTO log VALUES('ins ' || new.a || ' ' || new.b); END");
    try c.exec("CREATE TRIGGER tb BEFORE INSERT ON t WHEN new.b = 'bad' BEGIN SELECT RAISE(ABORT, 'no bad'); END");
    try c.exec("CREATE TRIGGER tg BEFORE INSERT ON t WHEN new.b = 'skip' BEGIN SELECT RAISE(IGNORE); END");
    try c.exec("CREATE TRIGGER tu AFTER UPDATE OF b ON t BEGIN INSERT INTO log VALUES('upd ' || old.b || '->' || new.b); END");
    try c.exec("CREATE TRIGGER td BEFORE DELETE ON t BEGIN INSERT INTO log VALUES('del ' || old.a); END");
    try c.exec("INSERT INTO t VALUES(1, 'one'), (2, 'two'), (4, 'skip')");
    try c.exec("INSERT INTO t(b) VALUES('three')");
    try c.expectError("INSERT INTO t VALUES(9, 'bad')", "no bad");
    try c.exec("UPDATE t SET b = 'TWO' WHERE a = 2");
    try c.exec("UPDATE t SET a = a + 10 WHERE a = 1");
    try c.exec("DELETE FROM t WHERE a = 3");
    try c.expectRows("SELECT * FROM t", "2|TWO\n11|one\n");
    try c.expectRows("SELECT * FROM log", "ins 1 one\nins 2 two\nins 3 three\nupd two->TWO\ndel 3\n");

    // INSTEAD OF triggers on a view.
    try c.exec("DELETE FROM log");
    try c.exec("CREATE VIEW v AS SELECT a, b FROM t");
    try c.exec("CREATE TRIGGER vi INSTEAD OF INSERT ON v BEGIN INSERT INTO t VALUES(new.a, upper(new.b)); END");
    try c.exec("CREATE TRIGGER vu INSTEAD OF UPDATE ON v BEGIN UPDATE t SET b = new.b || '!' WHERE a = old.a; END");
    try c.exec("CREATE TRIGGER vd INSTEAD OF DELETE ON v BEGIN DELETE FROM t WHERE a = old.a; END");
    try c.exec("INSERT INTO v VALUES(5, 'five')");
    try c.exec("UPDATE v SET b = 'x' WHERE a = 2");
    try c.exec("DELETE FROM v WHERE a = 11");
    try c.expectRows("SELECT * FROM t", "2|x!\n5|FIVE\n");
    try c.expectRows("SELECT * FROM log", "ins 5 FIVE\nupd TWO->x!\ndel 11\n");

    // The triggers are read back with the schema.
    try c.exec("DROP TRIGGER tu");
    try c.reopen();
    try c.expectRows("SELECT name FROM sqlite_schema WHERE type = 'trigger' ORDER BY name", "tb\ntd\ntg\nti\nvd\nvi\nvu\n");
    try c.exec("INSERT INTO v VALUES(6, 'six')");
    try c.exec("UPDATE t SET b = 'y' WHERE a = 2");
    try c.expectRows("SELECT x FROM log WHERE rowid > 3", "ins 6 SIX\n");

    try c.expectError("CREATE TRIGGER x BEFORE INSERT ON v BEGIN SELECT 1; END", "cannot create BEFORE trigger on view: v");
    try c.expectError("CREATE TRIGGER x INSTEAD OF INSERT ON t BEGIN SELECT 1; END", "cannot create INSTEAD OF trigger on table: t");
    try c.expectError("CREATE TRIGGER x AFTER INSERT ON nosuch BEGIN SELECT 1; END", "no such table: main.nosuch");
    try c.expectError("CREATE TRIGGER x AFTER INSERT ON sqlite_schema BEGIN SELECT 1; END", "cannot create trigger on system table");
    try c.expectError("CREATE TRIGGER ti AFTER INSERT ON t BEGIN SELECT 1; END", "trigger ti already exists");
    try c.exec("CREATE TRIGGER IF NOT EXISTS ti AFTER INSERT ON t BEGIN SELECT 1; END");
    try c.expectError("CREATE TEMP TRIGGER main.x AFTER INSERT ON t BEGIN SELECT 1; END", "temporary trigger may not have qualified name");
    try c.expectError("DROP TRIGGER nosuch", "no such trigger: nosuch");
    try c.exec("DROP TRIGGER IF EXISTS nosuch");
    try c.expectError("SELECT RAISE(ABORT, 'x')", "RAISE() may only be used within a trigger-program");

    // DROP TABLE drops its triggers.
    try c.exec("DROP VIEW v");
    try c.exec("DROP TABLE t");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE type = 'trigger'", "0\n");
}

test "sql: foreign keys" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // PRAGMA foreign_keys=ON.
    c.db.flags |= int.DbFlag.ForeignKeys;
    try c.exec("CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT UNIQUE)");
    try c.exec("CREATE TABLE c(x INTEGER PRIMARY KEY, pid REFERENCES p(id) ON DELETE CASCADE ON UPDATE CASCADE, pname REFERENCES p(name) ON DELETE SET NULL)");
    try c.exec("CREATE TABLE r(y REFERENCES p ON DELETE RESTRICT)");
    try c.exec("CREATE TABLE d(z REFERENCES p DEFERRABLE INITIALLY DEFERRED)");
    try c.exec("INSERT INTO p VALUES(1, 'a'), (2, 'b'), (3, 'c')");
    try c.exec("INSERT INTO c VALUES(10, 1, 'a'), (11, 2, 'b'), (12, 2, NULL), (13, NULL, 'c')");
    try c.expectError("INSERT INTO c VALUES(14, 9, NULL)", "FOREIGN KEY constraint failed");
    try c.expectError("INSERT INTO c VALUES(15, NULL, 'zz')", "FOREIGN KEY constraint failed");
    try c.exec("UPDATE p SET id = 20 WHERE id = 2");
    try c.expectRows("SELECT * FROM c ORDER BY x", "10|1|a\n11|20|b\n12|20|NULL\n13|NULL|c\n");
    try c.exec("DELETE FROM p WHERE id = 1");
    try c.expectRows("SELECT * FROM c ORDER BY x", "11|20|b\n12|20|NULL\n13|NULL|c\n");
    try c.exec("DELETE FROM p WHERE name = 'c'");
    try c.expectRows("SELECT * FROM c ORDER BY x", "11|20|b\n12|20|NULL\n13|NULL|NULL\n");
    try c.exec("INSERT INTO r VALUES(20)");
    try c.expectError("DELETE FROM p WHERE id = 20", "FOREIGN KEY constraint failed");
    try c.expectError("UPDATE c SET pid = 99 WHERE x = 11", "FOREIGN KEY constraint failed");

    // A deferred constraint is checked at COMMIT, which fails and leaves
    // the transaction open.
    try c.exec("BEGIN");
    try c.exec("INSERT INTO d VALUES(77)");
    try c.expectError("COMMIT", "FOREIGN KEY constraint failed");
    try c.exec("INSERT INTO p VALUES(77, 'q')");
    try c.exec("COMMIT");
    try c.expectRows("SELECT * FROM d", "77\n");

    try c.expectError("DROP TABLE p", "FOREIGN KEY constraint failed");
    try c.exec("DELETE FROM r; DELETE FROM d; DELETE FROM c");
    try c.exec("DROP TABLE p");
    try c.expectRows("SELECT name FROM sqlite_schema ORDER BY 1", "c\nd\nr\n");

    // A self-referencing table, a composite key, a mismatch.
    try c.exec("CREATE TABLE emp(id INTEGER PRIMARY KEY, boss REFERENCES emp(id) ON DELETE CASCADE)");
    try c.exec("INSERT INTO emp VALUES(1, NULL), (2, 1), (3, 2), (4, 4)");
    try c.expectError("INSERT INTO emp VALUES(5, 9)", "FOREIGN KEY constraint failed");
    try c.exec("DELETE FROM emp WHERE id = 1");
    try c.expectRows("SELECT * FROM emp", "4|4\n");
    try c.exec("CREATE TABLE pk2(a, b, PRIMARY KEY(a, b)) WITHOUT ROWID");
    try c.exec("CREATE TABLE ch2(x, y, FOREIGN KEY(x, y) REFERENCES pk2 ON UPDATE CASCADE)");
    try c.exec("INSERT INTO pk2 VALUES(1, 'x'), (2, 'y')");
    try c.exec("INSERT INTO ch2 VALUES(1, 'x'), (2, 'y'), (NULL, 'q')");
    try c.expectError("INSERT INTO ch2 VALUES(1, 'y')", "FOREIGN KEY constraint failed");
    try c.exec("UPDATE pk2 SET b = 'z' WHERE a = 2");
    try c.expectRows("SELECT * FROM ch2", "1|x\n2|z\nNULL|q\n");
    try c.exec("CREATE TABLE bad(q REFERENCES emp(boss))");
    try c.expectError("INSERT INTO bad VALUES(1)", "foreign key mismatch - \"bad\" referencing \"emp\"");
}

test "sql: REINDEX" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t1(a TEXT COLLATE NOCASE, b, c);
        \\CREATE INDEX i1 ON t1(a);
        \\CREATE INDEX i2 ON t1(b+c);
        \\CREATE TABLE t2(x PRIMARY KEY, y) WITHOUT ROWID;
        \\INSERT INTO t1 VALUES('A',1,2),('b',3,4),('a',5,6);
        \\INSERT INTO t2 VALUES(1,'x'),(2,'y');
        \\REINDEX; REINDEX t1; REINDEX main.i2; REINDEX nocase; REINDEX expressions; REINDEX t2;
    );
    try c.expectRows("SELECT b FROM t1 WHERE a='a' ORDER BY b", "1\n5\n");
    try c.expectRows("SELECT b FROM t1 WHERE b+c=7", "3\n");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
    try c.expectError("REINDEX nosuch", "unable to identify the object to be reindexed");
}

test "sql: SAVEPOINT, RELEASE and ROLLBACK TO" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a UNIQUE, b);
        \\INSERT INTO t VALUES(1, 'x');
        \\SAVEPOINT s1;
        \\INSERT INTO t VALUES(2, randomblob(5000));
        \\SAVEPOINT s2;
        \\UPDATE t SET b = 'y';
        \\DELETE FROM t WHERE a = 1;
        \\ROLLBACK TO s2;
    );
    try c.expectRows("SELECT a, length(b) FROM t ORDER BY a", "1|1\n2|5000\n");
    try c.exec("INSERT INTO t VALUES(3, 'z'); ROLLBACK TO s1;");
    try c.expectRows("SELECT a FROM t", "1\n");
    // RELEASE of the outermost savepoint commits.
    try c.exec("INSERT INTO t VALUES(4, 'w'); RELEASE s1;");
    try c.reopen();
    try c.expectRows("SELECT a FROM t ORDER BY a", "1\n4\n");
    try c.expectError("RELEASE s1", "no such savepoint: s1");

    // Inside BEGIN, a savepoint nests in the transaction.
    try c.exec("BEGIN; SAVEPOINT a; DELETE FROM t; SAVEPOINT b; INSERT INTO t VALUES(5, 'v'); RELEASE a;");
    try c.expectRows("SELECT a FROM t", "5\n");
    try c.exec("ROLLBACK");
    try c.expectRows("SELECT a FROM t ORDER BY a", "1\n4\n");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
}

test "sql: a failing statement inside a transaction undoes only itself" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a UNIQUE); INSERT INTO t VALUES(3); BEGIN; INSERT INTO t VALUES(10);");
    try c.expectError("INSERT INTO t VALUES(1),(2),(3)", "UNIQUE constraint failed: t.a");
    try c.exec("COMMIT");
    try c.expectRows("SELECT a FROM t ORDER BY a", "3\n10\n");
}

test "sql: RETURNING" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL)");
    try c.expectRows("INSERT INTO t(b, c) VALUES('x', 1), ('y', 2.5) RETURNING *", "1|x|1.0\n2|y|2.5\n");
    try c.expectRows("UPDATE t SET c = c + 1 WHERE a > 1 RETURNING a, c, (SELECT count(*) FROM t) AS n", "2|3.5|2\n");
    try c.expectRows("DELETE FROM t WHERE a = 1 RETURNING b || '!'", "x!\n");
    try c.expectRows("SELECT a, b, c FROM t", "2|y|3.5\n");
    try c.expectError("INSERT INTO t(b) VALUES('q') RETURNING t.*", "RETURNING may not use \"TABLE.*\" wildcards");
    try c.expectError("CREATE TRIGGER tr AFTER INSERT ON t BEGIN DELETE FROM t RETURNING *; END", "near \"RETURNING\": syntax error");
}

test "sql: UPSERT" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT UNIQUE, n INT DEFAULT 0);
        \\INSERT INTO t VALUES(1, 'x', 0), (2, 'y', 0);
        \\INSERT INTO t VALUES(1, 'z', 5) ON CONFLICT(a) DO UPDATE SET n = n + excluded.n;
        \\INSERT INTO t VALUES(9, 'y', 7) ON CONFLICT(b) DO UPDATE SET n = n + 10 WHERE excluded.n > 5;
        \\INSERT INTO t VALUES(9, 'y', 1) ON CONFLICT(b) DO UPDATE SET n = n + 100 WHERE excluded.n > 5;
        \\INSERT INTO t VALUES(1, 'q', 0) ON CONFLICT DO NOTHING;
        \\INSERT INTO t VALUES(2, 'x', 0) ON CONFLICT(b) DO UPDATE SET n = -1 ON CONFLICT(a) DO UPDATE SET n = -2;
    );
    try c.expectRows("SELECT * FROM t ORDER BY a", "1|x|-1\n2|y|10\n");
    try c.expectRows("INSERT INTO t VALUES(3, 'x', 0) ON CONFLICT DO UPDATE SET n = 42 RETURNING a, n", "1|42\n");
    try c.expectError("INSERT INTO t VALUES(4, 'w', 0) ON CONFLICT(n) DO NOTHING", "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
}

test "sql: CREATE TABLE ... AS SELECT" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE src(a INTEGER PRIMARY KEY, b TEXT, c REAL);
        \\INSERT INTO src VALUES(1, 'x', 1.5), (2, 'y', 2), (3, 'z', NULL);
        \\CREATE TABLE t1 AS SELECT * FROM src;
        \\CREATE TABLE t2 AS SELECT a + 1 AS n, upper(b) FROM src WHERE a > 1 ORDER BY a DESC;
    );
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 't1'", "CREATE TABLE t1(a INT,b TEXT,c REAL)\n");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 't2'", "CREATE TABLE t2(n,\"upper(b)\")\n");
    try c.expectRows("SELECT * FROM t1", "1|x|1.5\n2|y|2.0\n3|z|NULL\n");
    try c.expectRows("SELECT * FROM t2", "4|Z\n3|Y\n");
    try c.expectError("CREATE TABLE t2 AS SELECT 1", "table t2 already exists");
}

test "sql: ALTER TABLE RENAME TO" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t1(a INTEGER PRIMARY KEY, b UNIQUE, c CHECK(t1.c > 0));
        \\CREATE INDEX t1c ON t1(c) WHERE t1.c > 1;
        \\CREATE TABLE t2(x REFERENCES t1(a), y);
        \\CREATE VIEW v1 AS SELECT t1.a, x.b FROM t1, t1 AS x;
        \\CREATE TRIGGER tr1 AFTER INSERT ON t1 BEGIN INSERT INTO t2 VALUES(new.a, new.b); END;
        \\CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT);
        \\INSERT INTO s VALUES(NULL);
        \\INSERT INTO t1 VALUES(1, 2, 3);
    );
    try c.exec("ALTER TABLE t1 RENAME TO \"new t\"");
    try c.expectRows("SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 's%' ORDER BY name",
        \\table|new t|new t|CREATE TABLE "new t"(a INTEGER PRIMARY KEY, b UNIQUE, c CHECK("new t".c > 0))
        \\index|t1c|new t|CREATE INDEX t1c ON "new t"(c) WHERE "new t".c > 1
        \\table|t2|t2|CREATE TABLE t2(x REFERENCES "new t"(a), y)
        \\trigger|tr1|new t|CREATE TRIGGER tr1 AFTER INSERT ON "new t" BEGIN INSERT INTO t2 VALUES(new.a, new.b); END
        \\view|v1|v1|CREATE VIEW v1 AS SELECT "new t".a, x.b FROM "new t", "new t" AS x
        \\
    );
    try c.expectRows("SELECT name FROM sqlite_schema WHERE name LIKE 'sqlite_autoindex%'", "sqlite_autoindex_new t_1\n");
    try c.exec("ALTER TABLE s RENAME TO s2");
    try c.expectRows("SELECT * FROM sqlite_sequence", "s2|1\n");
    try c.exec("INSERT INTO \"new t\" VALUES(2, 3, 4)");
    try c.expectRows("SELECT * FROM t2", "1|2\n2|3\n");

    try c.expectError("ALTER TABLE t2 RENAME TO \"NEW T\"", "there is already another table or index with this name: NEW T");
    try c.expectError("ALTER TABLE t2 RENAME TO t1c", "there is already another table or index with this name: t1c");
    try c.expectError("ALTER TABLE t2 RENAME TO sqlite_t", "object name reserved for internal use: sqlite_t");
    try c.expectError("ALTER TABLE v1 RENAME TO v2", "view v1 may not be altered");
    try c.expectError("ALTER TABLE sqlite_sequence RENAME TO x", "table sqlite_sequence may not be altered");
    try c.expectError("ALTER TABLE nosuch RENAME TO x", "no such table: nosuch");
    // The internal functions are not visible to ordinary statements.
    try c.expectError("SELECT sqlite_rename_table('main', 'table', 't', 'CREATE TABLE t(a)', 't', 'u', 0)", "no such function: sqlite_rename_table");
}

test "sql: ALTER TABLE RENAME COLUMN" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, "b b" TEXT, c, d AS (c * 2), FOREIGN KEY(c) REFERENCES t(a));
        \\CREATE TABLE u(x REFERENCES t(a), y, FOREIGN KEY(y) REFERENCES t);
        \\CREATE INDEX ti ON t("b b", lower(c)) WHERE c > 0;
        \\CREATE VIEW v AS SELECT a AS k, [b b], t.c FROM t WHERE c IN (SELECT c FROM t) ORDER BY a;
        \\CREATE TRIGGER tr BEFORE UPDATE OF c ON t WHEN new.c > old.c BEGIN UPDATE u SET y = new.c WHERE x = old.a; INSERT INTO t(a, c) VALUES(NULL, new.c); END;
    );
    try c.exec("ALTER TABLE t RENAME COLUMN c TO \"select\"");
    try c.exec("ALTER TABLE t RENAME [b b] TO bb");
    try c.exec("ALTER TABLE t RENAME COLUMN a TO id");
    try c.expectRows("SELECT sql FROM sqlite_schema ORDER BY name",
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, "bb" TEXT, "select", d AS ("select" * 2), FOREIGN KEY("select") REFERENCES t(id))
        \\CREATE INDEX ti ON t("bb", lower("select")) WHERE "select" > 0
        \\CREATE TRIGGER tr BEFORE UPDATE OF "select" ON t WHEN new."select" > old."select" BEGIN UPDATE u SET y = new."select" WHERE x = old.id; INSERT INTO t(id, "select") VALUES(NULL, new."select"); END
        \\CREATE TABLE u(x REFERENCES t(id), y, FOREIGN KEY(y) REFERENCES t)
        \\CREATE VIEW v AS SELECT id AS k, "bb", t."select" FROM t WHERE "select" IN (SELECT "select" FROM t) ORDER BY id
        \\
    );
    try c.expectError("ALTER TABLE t RENAME COLUMN nosuch TO x", "no such column: \"nosuch\"");
    try c.expectError("ALTER TABLE t RENAME COLUMN bb TO id", "error in table t after rename: duplicate column name: id");
    try c.expectError("ALTER TABLE t RENAME COLUMN bb TO rowid", "cannot rename to rowid alias: rowid");
    try c.expectError("ALTER TABLE v RENAME COLUMN k TO kk", "cannot rename columns of view \"v\"");
}

test "sql: ALTER TABLE RENAME COLUMN with double-quoted strings" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a, b);
        \\CREATE VIEW v AS SELECT "lit", a, "b" FROM t;
        \\CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT "x"'y', new.a; END;
    );
    try c.exec("ALTER TABLE t RENAME COLUMN a TO aa");
    try c.expectRows("SELECT sql FROM sqlite_schema ORDER BY name",
        \\CREATE TABLE t(aa, b)
        \\CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 'x' 'y', new.aa; END
        \\CREATE VIEW v AS SELECT 'lit', aa, "b" FROM t
        \\
    );
}

test "sql: ALTER TABLE ADD COLUMN" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a INTEGER PRIMARY KEY, b, CHECK(b IS NOT 0));
        \\CREATE TABLE e(a);
        \\INSERT INTO t VALUES(1, 2);
    );
    try c.exec("ALTER TABLE t ADD COLUMN c TEXT DEFAULT 'it''s' NOT NULL ; ");
    try c.exec("ALTER TABLE t ADD d AS (a + b)");
    try c.expectRows("SELECT * FROM t", "1|2|it's|3\n");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 't'", "CREATE TABLE t(a INTEGER PRIMARY KEY, b, c TEXT DEFAULT 'it''s' NOT NULL, d AS (a + b), CHECK(b IS NOT 0))\n");
    try c.expectError("ALTER TABLE t ADD COLUMN x NOT NULL", "Cannot add a NOT NULL column with default value NULL");
    try c.expectError("ALTER TABLE t ADD COLUMN x DEFAULT CURRENT_TIME", "Cannot add a column with non-constant default");
    try c.expectError("ALTER TABLE t ADD COLUMN x AS (b) STORED", "cannot add a STORED column");
    try c.expectError("ALTER TABLE t ADD COLUMN x DEFAULT 0 CHECK(x <> 0)", "CHECK constraint failed");
    try c.expectError("ALTER TABLE t ADD COLUMN x PRIMARY KEY", "Cannot add a PRIMARY KEY column");
    try c.expectError("ALTER TABLE t ADD COLUMN x UNIQUE", "Cannot add a UNIQUE column");
    try c.expectError("ALTER TABLE t ADD COLUMN b", "duplicate column name: b");
    try c.expectError("ALTER TABLE t ADD COLUMN oid", "cannot add rowid alias: oid");
    // Constraints that only existing rows break are fine on an empty table.
    try c.exec("ALTER TABLE e ADD COLUMN x NOT NULL");
    try c.exec("ALTER TABLE e ADD COLUMN y DEFAULT CURRENT_TIME");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 'e'", "CREATE TABLE e(a, x NOT NULL, y DEFAULT CURRENT_TIME)\n");
    try c.reopen();
    try c.expectRows("SELECT * FROM t", "1|2|it's|3\n");
}

test "sql: ALTER TABLE DROP COLUMN" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE r(a INTEGER PRIMARY KEY, b REAL, c, d UNIQUE, e AS (a * 2));
        \\CREATE TABLE w(k, v, x, PRIMARY KEY(v, k)) WITHOUT ROWID;
        \\CREATE INDEX ri ON r(c);
        \\INSERT INTO r VALUES(1, 2, 3, 4), (5, 6.5, 'x', 8);
        \\INSERT INTO w VALUES(1, 2, 3), (4, 5, 6);
    );
    try c.expectError("ALTER TABLE r DROP COLUMN c", "error in index ri after drop column: no such column: c");
    try c.expectError("ALTER TABLE r DROP COLUMN a", "cannot drop PRIMARY KEY column: \"a\"");
    try c.expectError("ALTER TABLE r DROP COLUMN d", "cannot drop UNIQUE column: \"d\"");
    try c.expectError("ALTER TABLE r DROP COLUMN nosuch", "no such column: \"nosuch\"");
    try c.exec("DROP INDEX ri; ALTER TABLE r DROP COLUMN c; ALTER TABLE r DROP COLUMN e");
    try c.expectRows("SELECT a, b, typeof(b), d FROM r", "1|2.0|real|4\n5|6.5|real|8\n");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 'r'", "CREATE TABLE r(a INTEGER PRIMARY KEY, b REAL, d UNIQUE)\n");
    try c.exec("ALTER TABLE w DROP COLUMN x");
    try c.expectRows("SELECT * FROM w", "1|2\n4|5\n");
    try c.expectError("ALTER TABLE w DROP COLUMN k", "cannot drop PRIMARY KEY column: \"k\"");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
}

test "sql: ALTER TABLE constraints" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a INT CONSTRAINT nn NOT NULL, b CONSTRAINT ck CHECK(b > 0), c, CONSTRAINT pk PRIMARY KEY(a));
        \\INSERT INTO t VALUES(1, 2, NULL);
    );
    try c.exec("ALTER TABLE t DROP CONSTRAINT ck");
    try c.exec("ALTER TABLE t ALTER COLUMN a DROP NOT NULL");
    try c.exec("ALTER TABLE t ADD CONSTRAINT pos CHECK(a > 0) -- comment");
    try c.exec("ALTER TABLE t ALTER b SET NOT NULL");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 't'", "CREATE TABLE t(a INT, b NOT NULL, c, CONSTRAINT pk PRIMARY KEY(a), CONSTRAINT pos CHECK(a > 0))\n");
    try c.expectError("ALTER TABLE t ALTER c SET NOT NULL", "constraint failed");
    try c.expectError("ALTER TABLE t ADD CHECK(b > 5)", "constraint failed");
    try c.expectError("ALTER TABLE t ADD CONSTRAINT POS CHECK(1)", "constraint POS already exists");
    try c.expectError("ALTER TABLE t DROP CONSTRAINT pk", "constraint may not be dropped: pk");
    try c.expectError("ALTER TABLE t DROP CONSTRAINT nosuch", "no such constraint: nosuch");
    try c.expectError("ALTER TABLE t ALTER nosuch DROP NOT NULL", "no such column: nosuch");
    try c.expectError("INSERT INTO t VALUES(-1, 1, 1)", "CHECK constraint failed: pos");
}

test "sql: ALTER TABLE with PRAGMA writable_schema and legacy_alter_table" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(a, b);
        \\CREATE VIEW v AS SELECT a, b FROM t;
        \\PRAGMA writable_schema=ON;
        \\UPDATE sqlite_schema SET sql='CREATE VIEW v AS SELECT nosuch FROM t' WHERE name='v';
    );
    // The broken view is kept as it is.
    try c.exec("ALTER TABLE t RENAME COLUMN a TO aa");
    try c.exec("ALTER TABLE t RENAME TO t2");
    try c.expectRows("SELECT sql FROM sqlite_schema ORDER BY name",
        \\CREATE TABLE "t2"(aa, b)
        \\CREATE VIEW v AS SELECT nosuch FROM t
        \\
    );
    try c.exec("PRAGMA writable_schema=OFF; DROP VIEW v; CREATE VIEW v AS SELECT aa, b FROM t2; PRAGMA legacy_alter_table=ON");
    try c.exec("ALTER TABLE t2 RENAME TO t3");
    try c.expectRows("SELECT sql FROM sqlite_schema ORDER BY name",
        \\CREATE TABLE "t3"(aa, b)
        \\CREATE VIEW v AS SELECT aa, b FROM t2
        \\
    );
}

test "sql: a failed ALTER TABLE in a transaction" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE e1(a, b, c CHECK(b > 0)); INSERT INTO e1 VALUES(1, 2, 3);");
    try c.exec("BEGIN; CREATE TABLE zz(x);");
    try c.expectError("ALTER TABLE e1 DROP COLUMN b", "error in table e1 after drop column: no such column: b");
    try c.expectRows("SELECT * FROM e1", "1|2|3\n");
    try c.exec("ROLLBACK");
    // The schema in memory is that of the rolled back transaction: the
    // statement is compiled again.
    try c.expectRows("SELECT * FROM e1", "1|2|3\n");
    try c.expectRows("SELECT count(*) FROM sqlite_schema", "1\n");
}
