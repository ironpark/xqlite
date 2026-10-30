//! End-to-end tests of the SQL layer: open a connection on an in-memory
//! file system, run statements, and check results and errors.

const std = @import("std");
const thunk = @import("xqlite_storage").thunk;
const testing = std.testing;
const int = @import("sqlite_int.zig");
const main_mod = @import("main.zig");
const legacy = @import("legacy.zig");
const prepare = @import("prepare.zig");
const api = @import("../vdbe/api.zig");
const MemVfs = @import("xqlite_vfs").mem.MemVfs;

const RC = int.RC;

/// A connection to "test.db" on a private in-memory file system, or on
/// the file system of another connection (openOn).
pub const Conn = struct {
    /// The file system: `own` unless opened with openOn().
    mem: *MemVfs,
    own: MemVfs,
    db: *int.Sqlite3,

    pub fn open(c: *Conn) !void {
        return c.openWith(null);
    }

    /// Open "test.db" holding `image`, if given.
    pub fn openWith(c: *Conn, image: ?[]const u8) !void {
        c.own = MemVfs.init(testing.allocator, testing.io);
        c.mem = &c.own;
        errdefer c.own.deinit();
        if (image) |bytes| {
            const f = try c.mem.interface().open("test.db", .{ .create = true });
            defer f.close();
            try f.write(bytes, 0);
        }
        try c.connect();
    }

    /// Open another connection to "test.db" of `mem`, which stays owned
    /// by its connection and must outlive this one.
    pub fn openOn(c: *Conn, mem: *MemVfs) !void {
        c.own = undefined;
        c.mem = mem;
        try c.connect();
    }

    fn connect(c: *Conn) !void {
        var db: ?*int.Sqlite3 = null;
        const rc = main_mod.open(c.mem.interface(), "test.db", .{}, &db);
        c.db = db orelse return error.OutOfMemory;
        if (rc != RC.OK) {
            std.debug.print("open: {s}\n", .{main_mod.errmsg(c.db)});
            _ = main_mod.close(c.db);
            return error.OpenFailed;
        }
    }

    /// Close and open the connection again on the same file system.
    pub fn reopen(c: *Conn) !void {
        try testing.expectEqual(RC.OK, main_mod.close(c.db));
        var db: ?*int.Sqlite3 = null;
        const rc = main_mod.open(c.mem.interface(), "test.db", .{}, &db);
        c.db = db orelse return error.OutOfMemory;
        if (rc != RC.OK) return error.OpenFailed;
    }

    pub fn close(c: *Conn) void {
        std.testing.expectEqual(RC.OK, main_mod.close(c.db)) catch unreachable;
        if (c.mem == &c.own) c.own.deinit();
    }

    /// Run `sql`; fail the test with the error message if it fails.
    pub fn exec(c: *Conn, sql: []const u8) !void {
        var msg: ?[:0]u8 = null;
        const rc = legacy.exec(c.db, sql, null, null, &msg);
        if (rc != RC.OK) {
            std.debug.print("{s}\n  -> {s}\n", .{ sql, msg orelse "?" });
            if (msg) |m| @import("malloc.zig").free(m.ptr);
            return error.ExecFailed;
        }
    }

    /// Run `sql` and return its rows, a line each with the columns
    /// separated by "|" and NULL as "NULL". The caller frees the result.
    pub fn query(c: *Conn, sql: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(testing.allocator);
        var msg: ?[:0]u8 = null;
        const rc = legacy.execWith(c.db, sql, &out, collect, &msg);
        if (rc != RC.OK) {
            std.debug.print("{s}\n  -> {s}\n", .{ sql, msg orelse "?" });
            if (msg) |m| @import("malloc.zig").free(m.ptr);
            return error.ExecFailed;
        }
        return out.toOwnedSlice(testing.allocator);
    }

    pub fn collect(out: *std.ArrayList(u8), values: []const ?[*:0]const u8, _: []const [*:0]const u8) bool {
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
        defer if (msg) |m| @import("malloc.zig").free(m.ptr);
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
    // Arithmetic on NULL, integers, reals and text that looks numeric.
    try c.expectRows("SELECT NULL*2, 2*NULL, NULL+NULL, typeof(NULL-1), 3*2, typeof(3*2), 3*2.0, '4'+1, typeof('4'+1), '1.5'*2", "NULL|NULL|NULL|null|6|integer|6.0|5|integer|3.0\n");
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
    try c.expectRows("SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name", "table|t1|t1\nindex|t1_b|t1\ntable|t2|t2\ntable|wr|wr\n");
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
    try c.expectRows("SELECT type, name, sql FROM sqlite_schema WHERE type = 'view' ORDER BY name", "view|v|CREATE VIEW v AS SELECT a * 10 AS ten, upper(b) FROM t WHERE a > 1\n" ++
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
    c.db.flags.ForeignKeys = true;
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

test "sql: window functions" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(
        \\CREATE TABLE t(id INTEGER PRIMARY KEY, g TEXT, v INT);
        \\INSERT INTO t VALUES(1,'a',10),(2,'a',20),(3,'a',20),(4,'b',5),(5,'b',NULL),(6,'b',7),(7,'c',3);
    );
    // Ranking functions over a named window.
    try c.expectRows(
        "SELECT id, row_number() OVER w, rank() OVER w, dense_rank() OVER w, percent_rank() OVER w, round(cume_dist() OVER w, 2), ntile(2) OVER w FROM t WINDOW w AS (PARTITION BY g ORDER BY v) ORDER BY id",
        "1|1|1|1|0.0|0.33|1\n2|2|2|2|0.5|1.0|1\n3|3|2|2|0.5|1.0|2\n4|2|2|2|0.5|0.67|1\n5|1|1|1|0.0|0.33|1\n6|3|3|3|1.0|1.0|2\n7|1|1|1|0.0|1.0|1\n",
    );
    // ROWS, RANGE and GROUPS frames, EXCLUDE GROUP.
    try c.expectRows(
        "SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING), count(v) OVER (ORDER BY v RANGE BETWEEN 5 PRECEDING AND CURRENT ROW), group_concat(id, '.') OVER (ORDER BY v GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE GROUP) FROM t ORDER BY id",
        "1|30|3|6.2.3\n2|50|2|1\n3|45|2|1\n4|25|2|7.6\n5|12|0|7\n6|10|3|4.1\n7|10|1|5.4\n",
    );
    // EXCLUDE CURRENT ROW and EXCLUDE TIES.
    try c.expectRows(
        "SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW), count(*) OVER (ORDER BY v RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING EXCLUDE TIES) FROM t ORDER BY id",
        "1|NULL|3\n2|10|1\n3|30|1\n4|50|5\n5|55|7\n6|55|4\n7|62|6\n",
    );
    // lead(), lag(), first_value(), last_value() and nth_value().
    try c.expectRows(
        "SELECT id, lead(v) OVER (ORDER BY id), lag(v, 2, -1) OVER (ORDER BY id), first_value(v) OVER w, last_value(v) OVER w, nth_value(v, 2) OVER w FROM t WINDOW w AS (PARTITION BY g ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) ORDER BY id",
        "1|20|-1|10|20|20\n2|20|-1|10|20|20\n3|5|10|10|20|20\n4|NULL|20|5|7|NULL\n5|7|20|5|7|NULL\n6|3|5|5|7|NULL\n7|NULL|NULL|3|3|NULL\n",
    );
    // Sliding min() and max(), and FILTER.
    try c.expectRows(
        "SELECT id, max(v) OVER (ORDER BY id ROWS 2 PRECEDING), min(v) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING), avg(v) FILTER (WHERE id % 2) OVER (ORDER BY id) FROM t ORDER BY id",
        "1|10|10|10.0\n2|20|5|10.0\n3|20|5|15.0\n4|20|5|15.0\n5|20|3|15.0\n6|7|3|15.0\n7|7|3|11.0\n",
    );
    // A window over an aggregate.
    try c.expectRows("SELECT g, sum(v), sum(sum(v)) OVER (ORDER BY g) FROM t GROUP BY g", "a|50|50\nb|12|62\nc|3|65\n");

    try c.expectError("SELECT row_number() FROM t", "misuse of window function row_number()");
    try c.expectError("SELECT sum(v) FROM t WHERE sum(v) OVER () > 1", "misuse of window function sum()");
    try c.expectError("SELECT sum(v) OVER w FROM t", "no such window: w");
    try c.expectError("SELECT abs(v) OVER () FROM t", "abs() may not be used as a window function");
    try c.expectError("SELECT rank() FILTER (WHERE 1) OVER () FROM t", "FILTER clause may only be used with aggregate window functions");
    try c.expectError("SELECT sum(v) OVER (RANGE 1 PRECEDING) FROM t", "RANGE with offset PRECEDING/FOLLOWING requires one ORDER BY expression");
    try c.expectError("SELECT row_number() OVER () FROM t ORDER BY sum(v)", "misuse of aggregate: sum()");
    try c.expectError("SELECT sum(v) OVER (ROWS BETWEEN CURRENT ROW AND 1 PRECEDING) FROM t", "unsupported frame specification");
    try c.expectError("SELECT sum(v) OVER (w PARTITION BY g) FROM t WINDOW w AS (ORDER BY id)", "cannot override PARTITION clause of window: w");
    try c.expectError("SELECT count(DISTINCT v) OVER () FROM t", "DISTINCT is not supported for window functions");
    try c.expectError("WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT row_number() OVER () FROM r WHERE x<3) SELECT * FROM r", "cannot use window functions in recursive queries");
    // Errors found while running.
    try c.expectError("SELECT sum(v) OVER (ORDER BY id ROWS -1 PRECEDING) FROM t", "frame starting offset must be a non-negative integer");
    try c.expectError("SELECT sum(v) OVER (ORDER BY v RANGE 'x' PRECEDING) FROM t", "frame starting offset must be a non-negative number");
    try c.expectError("SELECT ntile(0) OVER (ORDER BY id) FROM t", "argument of ntile must be a positive integer");
    try c.expectError("SELECT nth_value(v, 0) OVER (ORDER BY id) FROM t", "second argument to nth_value must be a positive integer");
}

/// Bytes 18 and 19 of the database file: the write and read versions.
fn fileVersions(c: *Conn) ![2]u8 {
    const f = try c.mem.interface().open("test.db", .{ .read_write = false });
    defer f.close();
    var b: [2]u8 = undefined;
    try f.read(&b, 18);
    return b;
}

test "sql: WAL mode in and out" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b); INSERT INTO t VALUES(1, 'one')");
    try c.expectRows("PRAGMA journal_mode=WAL", "wal\n");
    try testing.expectEqual([2]u8{ 2, 2 }, try fileVersions(&c));
    try c.exec("INSERT INTO t VALUES(2, 'two'); CREATE INDEX t_b ON t(b)");
    try testing.expect(try c.mem.interface().access("test.db-wal", .exists));
    try c.expectRows("PRAGMA journal_mode; PRAGMA main.journal_mode", "wal\nwal\n");
    try c.expectError("BEGIN; PRAGMA journal_mode=DELETE", "cannot change out of wal mode from within a transaction");
    try c.exec("COMMIT");

    // A new connection finds the database in WAL mode, and the last one
    // to close checkpoints and deletes the WAL.
    try c.reopen();
    try testing.expect(!try c.mem.interface().access("test.db-wal", .exists));
    try c.expectRows("SELECT * FROM t ORDER BY b", "1|one\n2|two\n");
    try c.expectRows("PRAGMA journal_mode", "wal\n");
    try c.exec("UPDATE t SET b = b || '!'");
    try c.expectRows("PRAGMA wal_checkpoint(NOOP)", "0|2|0\n");
    try c.expectRows("PRAGMA wal_checkpoint", "0|2|2\n");
    try c.expectRows("PRAGMA wal_checkpoint(TRUNCATE)", "0|0|0\n");
    try c.exec("INSERT INTO t VALUES(3, 'three')");
    try c.expectRows("PRAGMA integrity_check", "ok\n");

    try c.expectRows("PRAGMA journal_mode=DELETE", "delete\n");
    try testing.expect(!try c.mem.interface().access("test.db-wal", .exists));
    try testing.expectEqual([2]u8{ 1, 1 }, try fileVersions(&c));
    try c.expectRows("SELECT count(*) FROM t; PRAGMA wal_checkpoint", "3\n0|-1|-1\n");
    try c.expectError("BEGIN; PRAGMA journal_mode=WAL", "cannot change into wal mode from within a transaction");
    try c.exec("ROLLBACK");
}

test "sql: an empty database in WAL mode" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // The switch commits through the rollback journal; the checkpoint
    // then opens the WAL (C runs PRAGMA table_list for that).
    try c.expectRows("PRAGMA journal_mode=wal; PRAGMA wal_checkpoint; SELECT count(*) FROM sqlite_schema; PRAGMA wal_checkpoint", "wal\n0|0|0\n0\n0|0|0\n");
    try testing.expectEqual([2]u8{ 2, 2 }, try fileVersions(&c));
}

test "sql: WAL readers keep their snapshot while others write" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES(1)");
    var peer: Conn = undefined;
    try peer.openOn(c.mem);
    defer peer.close();
    const r = &peer;

    try r.exec("BEGIN");
    try r.expectRows("SELECT sum(x) FROM t", "1\n");
    try c.exec("INSERT INTO t VALUES(2)");
    try c.exec("INSERT INTO t VALUES(3)");
    try r.expectRows("SELECT sum(x) FROM t", "1\n");
    // The reader cannot write from its old snapshot.
    try r.expectError("INSERT INTO t VALUES(10)", "database is locked");
    try testing.expectEqual(RC.BUSY_SNAPSHOT, main_mod.extendedErrcode(r.db));
    // A checkpoint cannot pass the reader, and RESTART reports busy.
    try c.expectRows("PRAGMA wal_checkpoint", "0|5|3\n");
    try c.expectRows("PRAGMA wal_checkpoint(RESTART)", "1|5|3\n");
    try r.exec("COMMIT");
    try r.expectRows("SELECT sum(x) FROM t", "6\n");
    try c.expectRows("PRAGMA wal_checkpoint(RESTART)", "0|5|5\n");

    // One writer at a time; the other is busy at once without a timeout.
    try c.exec("BEGIN IMMEDIATE; INSERT INTO t VALUES(4)");
    try r.expectError("INSERT INTO t VALUES(5)", "database is locked");
    try r.expectError("BEGIN IMMEDIATE", "database is locked");
    try r.expectRows("SELECT sum(x) FROM t", "6\n");
    try c.exec("COMMIT");
    // With a busy timeout, a short wait succeeds once the writer is done.
    try r.exec("PRAGMA busy_timeout=2000; INSERT INTO t VALUES(5)");
    try c.expectRows("SELECT sum(x) FROM t; PRAGMA integrity_check", "15\nok\n");
    // DELETE mode needs the only connection.
    try c.expectError("PRAGMA journal_mode=DELETE", "database is locked");
    try c.expectRows("PRAGMA journal_mode", "wal\n");
}

test "sql: a statement stepped again after SQLITE_BUSY waits again" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA journal_mode=WAL; CREATE TABLE t(x)");
    var r: Conn = undefined;
    try r.openOn(c.mem);
    defer r.close();
    try c.exec("BEGIN IMMEDIATE; INSERT INTO t VALUES(1)");
    try r.exec("PRAGMA busy_timeout=40");
    var stmt_opt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(r.db, "INSERT INTO t VALUES(2)", &stmt_opt, null));
    const stmt = stmt_opt.?;
    defer _ = api.finalize(stmt);
    // Each step runs the busy handler afresh (vdbe.c resets nBusy), so
    // each one waits out the whole timeout.
    for (0..2) |_| {
        const t0 = std.Io.Timestamp.now(testing.io, .awake);
        try testing.expectEqual(RC.BUSY, api.step(stmt));
        try testing.expect(t0.untilNow(testing.io, .awake).toMilliseconds() >= 35);
    }
    try c.exec("COMMIT");
    try testing.expectEqual(RC.DONE, api.step(stmt));
    try c.expectRows("SELECT x FROM t ORDER BY x", "1\n2\n");
}

test "sql: WAL autocheckpoint, savepoints, rollback and auto_vacuum" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA page_size=1024; PRAGMA auto_vacuum=FULL; PRAGMA journal_mode=WAL");
    try c.exec("PRAGMA wal_autocheckpoint=5; CREATE TABLE t(x)");
    try c.exec("WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<200) INSERT INTO t SELECT randomblob(300) FROM c");
    // The commit left more than 5 frames, so the hook checkpointed them.
    const counts = try c.query("PRAGMA wal_checkpoint(NOOP)");
    defer testing.allocator.free(counts);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, counts, "\n"), '|');
    _ = it.next();
    const n_log = it.next().?;
    try testing.expectEqualStrings(n_log, it.next().?);

    try c.exec("BEGIN; DELETE FROM t WHERE rowid % 2 = 0; SAVEPOINT s; DELETE FROM t; ROLLBACK TO s; RELEASE s; COMMIT");
    try c.expectRows("SELECT count(*) FROM t", "100\n");
    // A large transaction spills frames, then rolls back.
    try c.exec("PRAGMA cache_size=10; BEGIN; UPDATE t SET x = randomblob(300); DELETE FROM t WHERE rowid < 150; ROLLBACK");
    try c.expectRows("SELECT count(*) FROM t; PRAGMA integrity_check", "100\nok\n");
    // auto_vacuum shrinks the image; the checkpoint shrinks the file.
    try c.exec("DELETE FROM t WHERE rowid > 20");
    try c.expectRows("PRAGMA freelist_count; PRAGMA integrity_check", "0\nok\n");
    try c.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    const n_page = try c.query("PRAGMA page_count");
    defer testing.allocator.free(n_page);
    const f = try c.mem.interface().open("test.db", .{ .read_write = false });
    defer f.close();
    const want = try std.fmt.parseInt(u64, std.mem.trimEnd(u8, n_page, "\n"), 10) * 1024;
    try testing.expectEqual(want, try f.fileSize());
}

test "sql: sqlite3_wal_hook and sqlite3_wal_checkpoint_v2" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const Hook = struct {
        calls: u32 = 0,
        last: i32 = 0,
        fn f(self: *@This(), db: *int.Sqlite3, name: [:0]const u8, n_frame: i32) i32 {
            _ = db;
            std.testing.expectEqualStrings("main", name) catch unreachable;
            self.calls += 1;
            self.last = n_frame;
            return RC.OK;
        }
    };
    var hook: Hook = .{};
    try c.exec("PRAGMA journal_mode=WAL; CREATE TABLE t(x)");
    const cb: thunk.Closure(int.WalCallback) = .init(&hook, Hook.f);
    _ = main_mod.walHook(c.db, cb.func, cb.ctx);
    // The hook replaces wal_autocheckpoint.
    try c.expectRows("PRAGMA wal_autocheckpoint", "0\n");
    try c.exec("INSERT INTO t VALUES(1); INSERT INTO t VALUES(2)");
    try testing.expectEqual(@as(u32, 2), hook.calls);
    try testing.expect(hook.last > 0);
    // Read-only statements commit nothing.
    try c.exec("SELECT * FROM t");
    try testing.expectEqual(@as(u32, 2), hook.calls);

    var n_log: i32 = 0;
    var n_ckpt: i32 = 0;
    try testing.expectEqual(RC.OK, main_mod.walCheckpointV2(c.db, "main", .truncate, &n_log, &n_ckpt));
    try testing.expectEqual(@as(i32, 0), n_log);
    try testing.expectEqual(@as(i32, 0), n_ckpt);
    try testing.expectEqual(RC.ERROR, main_mod.walCheckpointV2(c.db, "nosuch", .passive, &n_log, &n_ckpt));
    try testing.expectEqualStrings("unknown database: nosuch", main_mod.errmsg(c.db));
    try testing.expectEqual(@as(i32, -1), n_log);
    try testing.expectEqual(RC.OK, main_mod.walCheckpoint(c.db, null));
    // Back to an autocheckpoint every 1000 frames.
    _ = main_mod.walAutocheckpoint(c.db, 1000);
    try c.expectRows("PRAGMA wal_autocheckpoint", "1000\n");
}

// ======================================================= result codes

/// Run `sql` with prepareV2() and step() to its end, which must be an
/// error with the extended code `extended` and the message `msg`. The
/// code comes back from step() and finalize() as the primary code, and
/// in full once extended result codes are on.
fn expectStepError(c: *Conn, sql: []const u8, extended: i32, msg: []const u8) !void {
    for ([_]bool{ false, true }) |ext_on| {
        main_mod.extendedResultCodes(c.db, ext_on);
        defer main_mod.extendedResultCodes(c.db, false);
        const want = if (ext_on) extended else extended & 0xff;
        var stmt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
        try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, sql, &stmt, null));
        var finalized = false;
        defer if (!finalized) {
            _ = api.finalize(stmt.?);
        };
        var rc = api.step(stmt.?);
        while (rc == RC.ROW) rc = api.step(stmt.?);
        testing.expectEqual(want, rc) catch |err| {
            std.debug.print("{s}: {s}\n", .{ sql, main_mod.errmsg(c.db) });
            return err;
        };
        try testing.expectEqual(extended, main_mod.extendedErrcode(c.db));
        try testing.expectEqual(want, main_mod.errcode(c.db));
        try testing.expectEqualStrings(msg, main_mod.errmsg(c.db));
        finalized = true;
        try testing.expectEqual(want, api.finalize(stmt.?));
        try testing.expectEqualStrings(msg, main_mod.errmsg(c.db));
    }
}

test "sql: extended result codes and messages of the VM" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a UNIQUE, b NOT NULL, c CHECK(c>0), d INTEGER PRIMARY KEY); INSERT INTO t VALUES(1, 1, 1, 1)");
    try expectStepError(&c, "INSERT INTO t VALUES(1, 2, 2, 2)", RC.CONSTRAINT_UNIQUE, "UNIQUE constraint failed: t.a");
    try expectStepError(&c, "INSERT INTO t VALUES(2, NULL, 2, 2)", RC.CONSTRAINT_NOTNULL, "NOT NULL constraint failed: t.b");
    try expectStepError(&c, "INSERT INTO t VALUES(2, 2, 0, 2)", RC.CONSTRAINT_CHECK, "CHECK constraint failed: c>0");
    try expectStepError(&c, "INSERT INTO t VALUES(2, 2, 2, 1)", RC.CONSTRAINT_PRIMARYKEY, "UNIQUE constraint failed: t.d");
    try c.exec("CREATE TABLE s(a INTEGER) STRICT");
    try expectStepError(&c, "INSERT INTO s VALUES('x')", RC.CONSTRAINT_DATATYPE, "cannot store TEXT value in INTEGER column s.a");
    // OP_MustBeInt.
    try expectStepError(&c, "SELECT 1 LIMIT 'x'", RC.MISMATCH, "datatype mismatch");
    // OP_Halt with a message of the program.
    try c.exec("CREATE TABLE tt(x); CREATE TRIGGER tr BEFORE INSERT ON tt BEGIN SELECT RAISE(ABORT, 'stop'); END");
    try expectStepError(&c, "INSERT INTO tt VALUES(1)", RC.CONSTRAINT_TRIGGER, "stop");
    // Errors of opcodes without an extended code.
    try expectStepError(&c, "RELEASE nosuch", RC.ERROR, "no such savepoint: nosuch");
    try expectStepError(&c, "ROLLBACK", RC.ERROR, "cannot rollback - no transaction is active");
    try c.exec("BEGIN");
    try expectStepError(&c, "BEGIN", RC.ERROR, "cannot start a transaction within a transaction");
    try c.exec("COMMIT");
    // SQLITE_LIMIT_LENGTH: OP_Concat and OP_String8.
    _ = main_mod.limit(c.db, .length, 100);
    try expectStepError(&c, "SELECT printf('%.*c', 60, 'x') || printf('%.*c', 60, 'y')", RC.TOOBIG, "string or blob too big");
    try expectStepError(&c, "SELECT zeroblob(200)", RC.TOOBIG, "string or blob too big");
    _ = main_mod.limit(c.db, .length, 1000000000);
    // The statement still works after all that.
    try c.expectRows("SELECT a, b, c, d FROM t", "1|1|1|1\n");
}

test "sql: foreign key errors keep their extended code" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA foreign_keys=ON; CREATE TABLE p(id INTEGER PRIMARY KEY); INSERT INTO p VALUES(1)");
    try c.exec("CREATE TABLE ci(x REFERENCES p(id)); CREATE TABLE cd(x REFERENCES p(id) DEFERRABLE INITIALLY DEFERRED)");
    // Immediate: the statement fails (OP_FkCheck).
    try expectStepError(&c, "INSERT INTO ci VALUES(5)", RC.CONSTRAINT_FOREIGNKEY, "FOREIGN KEY constraint failed");
    // Deferred: the COMMIT fails and the transaction stays open.
    try c.exec("BEGIN; INSERT INTO cd VALUES(7)");
    try expectStepError(&c, "COMMIT", RC.CONSTRAINT_FOREIGNKEY, "FOREIGN KEY constraint failed");
    try testing.expect(!main_mod.getAutocommit(c.db));
    try expectStepError(&c, "RELEASE nosuch", RC.ERROR, "no such savepoint: nosuch");
    try c.exec("SAVEPOINT sp");
    // Releasing the outermost savepoint commits, and fails the same way.
    try c.exec("ROLLBACK; SAVEPOINT sp; INSERT INTO cd VALUES(8)");
    try expectStepError(&c, "RELEASE sp", RC.CONSTRAINT_FOREIGNKEY, "FOREIGN KEY constraint failed");
    try testing.expect(!main_mod.getAutocommit(c.db));
    try c.exec("ROLLBACK");
    try c.expectRows("SELECT count(*) FROM cd", "0\n");
    // A deferred violation fixed before the commit is fine.
    try c.exec("BEGIN; INSERT INTO cd VALUES(9); INSERT INTO p VALUES(9); COMMIT");
    try c.expectRows("SELECT x FROM cd", "9\n");
}

/// failcode(code[, msg]): fails with result code `code` (and message `msg`).
fn failcode(ctx: *@import("../vdbe/vdbe_int.zig").Context, argv: []*@import("../vdbe/vdbe_int.zig").Mem) void {
    if (argv.len > 1) api.resultError(ctx, api.valueText(argv[1]).?);
    api.resultErrorCode(ctx, @intCast(api.valueInt64(argv[0])));
}

test "sql: the result codes of application functions reach the API" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const callback = @import("callback.zig");
    const utf8 = @import("../vdbe/vdbe_int.zig").ENC.UTF8;
    try testing.expectEqual(RC.OK, callback.createFunction(c.db, "failcode", -1, utf8, null, failcode, null, null, null));
    var buf: [128]u8 = undefined;
    const IOERR_WRITE = RC.IOERR | (3 << 8);
    const CONSTRAINT_FUNCTION = RC.CONSTRAINT | (4 << 8);
    for ([_]struct { i32, []const u8 }{
        .{ IOERR_WRITE, "disk I/O error" },
        .{ RC.BUSY_SNAPSHOT, "database is locked" },
        .{ RC.CORRUPT, "database disk image is malformed" },
        .{ CONSTRAINT_FUNCTION, "constraint failed" },
        .{ RC.ERROR_MISSING_COLLSEQ, "SQL logic error" },
        .{ RC.ABORT_ROLLBACK, "abort due to ROLLBACK" },
    }) |case| {
        const sql = try std.fmt.bufPrint(&buf, "SELECT failcode({d})", .{case[0]});
        try expectStepError(&c, sql, case[0], case[1]);
    }
    try expectStepError(&c, "SELECT failcode(1555, 'mine')", RC.CONSTRAINT_PRIMARYKEY, "mine");
    // Codes the VM also raises itself keep the function's message.
    try expectStepError(&c, "SELECT failcode(18, 'too long')", RC.TOOBIG, "too long");
    try expectStepError(&c, "SELECT failcode(7, 'no room')", RC.NOMEM, "no room");
    try expectStepError(&c, "SELECT failcode(9, 'stopped')", RC.INTERRUPT, "stopped");
    // An aggregate that fails at its step and at its end.
    try c.exec("CREATE TABLE t(x); INSERT INTO t VALUES(1), (2)");
    try expectStepError(&c, "SELECT max(failcode(2067, 'agg')) FROM t", RC.CONSTRAINT_UNIQUE, "agg");
}

/// A VFS over a MemVfs whose file reads or writes fail with `fault` while
/// it is set.
const FaultVfs = struct {
    inner: @import("xqlite_vfs").vfs.Vfs,
    var fault_read: ?@import("xqlite_vfs").vfs.Error = null;
    var fault_write: ?@import("xqlite_vfs").vfs.Error = null;
    var file_vtable: @import("xqlite_vfs").vfs.File.VTable = undefined;
    var inner_read: *const fn (*anyopaque, []u8, u64) @import("xqlite_vfs").vfs.Error!usize = undefined;
    var inner_write: *const fn (*anyopaque, []const u8, u64) @import("xqlite_vfs").vfs.Error!void = undefined;

    const V = @import("xqlite_vfs").vfs;
    const vtable: V.Vfs.VTable = .{ .open = open, .delete = delete, .access = access, .randomness = randomness, .sleep = sleep };

    fn interface(self: *FaultVfs) V.Vfs {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn cast(ptr: *anyopaque) *FaultVfs {
        return @ptrCast(@alignCast(ptr));
    }
    fn open(ptr: *anyopaque, path: ?[]const u8, flags: V.OpenFlags) V.Error!V.File {
        const f = try cast(ptr).inner.open(path, flags);
        // The files of a MemVfs share one vtable: patch a copy of it.
        inner_read = f.vtable.read;
        inner_write = f.vtable.write;
        file_vtable = f.vtable.*;
        file_vtable.read = read;
        file_vtable.write = write;
        return .{ .ptr = f.ptr, .vtable = &file_vtable };
    }
    fn read(ptr: *anyopaque, buf: []u8, offset: u64) V.Error!usize {
        if (fault_read) |e| return e;
        return inner_read(ptr, buf, offset);
    }
    fn write(ptr: *anyopaque, buf: []const u8, offset: u64) V.Error!void {
        if (fault_write) |e| return e;
        return inner_write(ptr, buf, offset);
    }
    fn delete(ptr: *anyopaque, path: []const u8, sync_dir: bool) V.Error!void {
        return cast(ptr).inner.delete(path, sync_dir);
    }
    fn access(ptr: *anyopaque, path: []const u8, mode: V.AccessMode) V.Error!bool {
        return cast(ptr).inner.access(path, mode);
    }
    fn randomness(ptr: *anyopaque, buf: []u8) void {
        cast(ptr).inner.randomness(buf);
    }
    fn sleep(ptr: *anyopaque, microseconds: u32) u32 {
        return cast(ptr).inner.sleep(microseconds);
    }
};

test "sql: errors of the storage layers keep their extended code" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES(1)");
    var peer: Conn = undefined;
    try peer.openOn(c.mem);
    defer peer.close();
    try peer.exec("BEGIN");
    try peer.expectRows("SELECT x FROM t", "1\n");
    try c.exec("INSERT INTO t VALUES(2)");
    // OP_Transaction returns BUSY_SNAPSHOT as it is (vdbe_return).
    try expectStepError(&peer, "INSERT INTO t VALUES(3)", RC.BUSY_SNAPSHOT, "database is locked");
    try peer.exec("COMMIT");
}

test "sql: a corrupt page is SQLITE_CORRUPT" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE big(x); INSERT INTO big SELECT randomblob(900) FROM (SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5)");
    try c.expectRows("SELECT rootpage FROM sqlite_schema WHERE name = 'big'", "2\n");
    {
        const f = try c.mem.interface().open("test.db", .{ .read_write = true });
        defer f.close();
        try f.write(&.{0x7f}, 1 * 4096);
    }
    try c.reopen();
    try expectStepError(&c, "SELECT count(*) FROM big", RC.CORRUPT, "database disk image is malformed");
}

test "sql: I/O errors of the VFS reach the API" {
    var mem = MemVfs.init(testing.allocator, testing.io);
    defer mem.deinit();
    var fv: FaultVfs = .{ .inner = mem.interface() };
    defer FaultVfs.fault_read = null;
    defer FaultVfs.fault_write = null;
    var c: Conn = .{ .mem = &mem, .own = undefined, .db = undefined };
    var opened: ?*int.Sqlite3 = null;
    try testing.expectEqual(RC.OK, main_mod.open(fv.interface(), "test.db", .{}, &opened));
    c.db = opened.?;
    defer _ = main_mod.close(c.db);
    try c.exec("CREATE TABLE t(x); INSERT INTO t VALUES(1)");
    for ([_]struct { @import("xqlite_vfs").vfs.Error, i32, []const u8 }{
        .{ error.IoErr, RC.IOERR, "disk I/O error" },
        .{ error.DiskFull, RC.FULL, "database or disk is full" },
        .{ error.ReadOnly, RC.READONLY, "attempt to write a readonly database" },
    }) |case| {
        FaultVfs.fault_write = case[0];
        try expectStepError(&c, "INSERT INTO t VALUES(2)", case[1], case[2]);
        FaultVfs.fault_write = null;
        try c.expectRows("SELECT x FROM t", "1\n");
    }
    // A read that fails: the schema is read again after a change by
    // another connection.
    var other_opened: ?*int.Sqlite3 = null;
    try testing.expectEqual(RC.OK, main_mod.open(mem.interface(), "test.db", .{}, &other_opened));
    const other = other_opened.?;
    defer _ = main_mod.close(other);
    var msg: ?[:0]u8 = null;
    try testing.expectEqual(RC.OK, legacy.exec(other, "CREATE TABLE u(y)", null, null, &msg));
    FaultVfs.fault_read = error.IoErr;
    var stmt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
    const rc = prepare.prepareV2(c.db, "SELECT x FROM t", &stmt, null);
    if (rc == RC.OK) {
        try testing.expectEqual(RC.IOERR, api.step(stmt.?));
        _ = api.finalize(stmt.?);
    } else {
        try testing.expectEqual(RC.IOERR, rc);
    }
    try testing.expectEqual(RC.IOERR, main_mod.extendedErrcode(c.db));
    try testing.expectEqualStrings("disk I/O error", main_mod.errmsg(c.db));
    FaultVfs.fault_read = null;
    try c.expectRows("SELECT x FROM t", "1\n");
}

test "sql: error offsets of messages that quote a token or an expression" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a, b); CREATE TEMP TABLE tt(x)");
    try c.exec("CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END");
    // The offsets sqlite3 3.54.1 reports (the carets of its shell).
    for ([_]struct { []const u8, []const u8, i32 }{
        .{ "SELECT * FROM t WHERE a=1 frob", "near \"frob\": syntax error", 26 },
        .{ "SELECT * FROM t t1 LEFT FOO BAR JOIN t t2", "unknown join type: LEFT FOO BAR", 19 },
        .{ "CREATE TABLE t(z)", "table t already exists", 13 },
        .{ "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END", "trigger tr already exists", 15 },
        .{ "SELECT abs(a ORDER BY b) FROM t", "ORDER BY may not be used with non-aggregate abs()", 7 },
        .{ "CREATE VIEW main.v AS SELECT * FROM temp.tt", "view v cannot reference objects in database temp", 17 },
        .{ "SELECT max() FROM t", "wrong number of arguments to function max()", 7 },
        .{ "SELECT * FROM t WHERE nosuchcol=1", "no such column: nosuchcol", 22 },
    }) |case| {
        var stmt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
        try testing.expectEqual(RC.ERROR, prepare.prepareV2(c.db, case[0], &stmt, null));
        try testing.expectEqualStrings(case[1], main_mod.errmsg(c.db));
        testing.expectEqual(case[2], main_mod.errorOffset(c.db)) catch |err| {
            std.debug.print("{s}\n", .{case[0]});
            return err;
        };
    }
}

test "sql: %T records the error offset only while an error is formatted" {
    const printf = @import("printf.zig");
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const sql = "SELECT frob FROM t";
    var p: int.Parse = .{ .db = c.db, .arena = testing.allocator, .tail = sql };
    c.db.parse = &p;
    defer c.db.parse = null;
    const tok: int.Token = .init(sql[7..11]);
    // As in sqlite3ErrorMsg(): -2 while the message is formatted.
    c.db.err_byte_offset = -2;
    const msg = try printf.mprintfLimit(c.db, testing.allocator, 100, "near \"%T\"", &.{.{ .token = &tok }});
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("near \"frob\"", msg);
    try testing.expectEqual(@as(i32, 7), c.db.err_byte_offset);
    // Otherwise (sqlite3MPrintf(db, "CREATE VIRTUAL TABLE %T", ...)) it
    // is left alone, as is a token outside the statement.
    c.db.err_byte_offset = -1;
    const other = try printf.mprintfLimit(c.db, testing.allocator, 100, "%T", &.{.{ .token = &tok }});
    defer testing.allocator.free(other);
    try testing.expectEqual(@as(i32, -1), c.db.err_byte_offset);
    const outside: int.Token = .init("frob");
    c.db.err_byte_offset = -2;
    const third = try printf.mprintfLimit(c.db, testing.allocator, 100, "%T", &.{.{ .token = &outside }});
    defer testing.allocator.free(third);
    try testing.expectEqual(@as(i32, -2), c.db.err_byte_offset);
    c.db.err_byte_offset = -1;
}
