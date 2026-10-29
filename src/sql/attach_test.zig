//! Tests of ATTACH and DETACH (attach.zig).

const std = @import("std");
const testing = std.testing;
const int = @import("sqlite_int.zig");
const main_mod = @import("main.zig");
const prepare = @import("prepare.zig");
const attach = @import("attach.zig");
const legacy = @import("legacy.zig");
const api = @import("../vdbe/api.zig");
const vfs = @import("../vfs/vfs.zig");
const MemVfs = @import("../vfs/mem.zig").MemVfs;
const Conn = @import("sql_test.zig").Conn;

const RC = int.RC;
const Vdbe = @import("../vdbe/vdbe_int.zig").Vdbe;

test "attach: ATTACH and DETACH" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a); INSERT INTO t VALUES(1)");
    try c.exec("ATTACH 'aux1.db' AS aux1; ATTACH DATABASE 'aux2.db' AS \"Aux2\"; ATTACH aux3 AS aux3");
    try c.expectRows("SELECT seq, name, file FROM pragma_database_list", "0|main|test.db\n2|aux1|aux1.db\n3|Aux2|aux2.db\n4|aux3|aux3\n");
    try c.exec("CREATE TABLE aux1.t(a); INSERT INTO aux1.t VALUES(2); CREATE TABLE aux2.u(b); CREATE INDEX aux2.i ON u(b)");
    try c.expectRows("SELECT * FROM main.t, aux1.t", "1|2\n");
    // The name of an unqualified table is looked up in main first.
    try c.expectRows("SELECT * FROM t", "1\n");
    try c.expectRows("SELECT type, name, tbl_name, sql FROM aux1.sqlite_schema", "table|t|t|CREATE TABLE t(a)\n");
    try c.expectRows("SELECT name FROM aux1.sqlite_master", "t\n");
    try c.expectRows("SELECT name FROM aux2.sqlite_schema", "u\ni\n");
    try c.expectError("CREATE INDEX aux2.j ON t(a)", "no such table: Aux2.t");
    try c.expectRows("PRAGMA aux1.table_info(t)", "0|a||0|NULL|0\n");
    try c.expectRows("SELECT name FROM pragma_table_info('t', 'aux1')", "a\n");
    try c.expectRows("PRAGMA aux1.integrity_check", "ok\n");
    try c.exec("PRAGMA aux1.user_version = 7");
    try c.expectRows("PRAGMA aux1.user_version; PRAGMA user_version", "7\n0\n");

    try c.expectError("ATTACH 'x.db' AS aux1", "database aux1 is already in use");
    try c.expectError("ATTACH 'x.db' AS MAIN", "database MAIN is already in use");
    try c.expectError("ATTACH 'x.db' AS temp", "database temp is already in use");
    try c.expectError("ATTACH a || b AS c", "no such column: a");
    try c.expectError("DETACH nosuch", "no such database: nosuch");
    try c.expectError("DETACH main", "cannot detach database main");
    // TEMP is a database once its file is open.
    try c.expectError("DETACH temp", "no such database: temp");
    try c.exec("CREATE TEMP TABLE tt(x)");
    try c.expectError("DETACH temp", "cannot detach database temp");
    // The message is cut at 127 bytes.
    const ys: [200]u8 = @splat('y');
    try c.expectError("DETACH x" ++ ys, "no such database: x" ++ ys[0..108]);
    try c.exec("BEGIN; INSERT INTO aux1.t VALUES(3)");
    try c.expectError("DETACH aux1", "database aux1 is locked");
    try c.exec("COMMIT");

    try c.exec("DETACH aux1; DETACH \"aux2\"");
    try c.expectRows("SELECT name FROM pragma_database_list", "main\ntemp\naux3\n");
    try c.expectError("SELECT * FROM aux1.t", "no such table: aux1.t");
    try c.exec("ATTACH 'aux1.db' AS again");
    try c.expectRows("SELECT * FROM again.t", "2\n3\n");
    try c.expectRows("SELECT seq, name FROM pragma_database_list", "0|main\n1|temp\n2|aux3\n3|again\n");
    // ":memory:" and "" are private temporary databases.
    try c.exec("ATTACH ':memory:' AS m; ATTACH '' AS e; CREATE TABLE m.z(q); INSERT INTO m.z VALUES(9)");
    try c.expectRows("SELECT * FROM m.z", "9\n");
    try c.expectRows("SELECT name, file FROM pragma_database_list WHERE seq > 3", "m|\ne|\n");
    try testing.expectEqualStrings("aux1.db", main_mod.dbFilename(c.db, "again").?);
    try testing.expectEqualStrings("", main_mod.dbFilename(c.db, "m").?);
    try testing.expectEqualStrings("test.db", main_mod.dbFilename(c.db, null).?);
    try testing.expect(main_mod.dbFilename(c.db, "nosuch") == null);
    try testing.expectEqual(@as(?bool, false), main_mod.dbReadonly(c.db, "again"));
    try testing.expectEqualStrings("again", main_mod.dbName(c.db, 3).?);
    // Any name will do, however long, quotes and all.
    try c.exec("ATTACH 'aux1.db' AS \"q\"\"uote\"");
    try c.expectRows("SELECT a FROM \"q\"\"uote\".t", "2\n3\n");
    try c.exec("DETACH 'q\"uote'");
    try c.exec("ATTACH 'aux1.db' AS x" ++ ys ++ "; SELECT * FROM x" ++ ys ++ ".t; DETACH x" ++ ys);
    // A NULL name and file are empty strings, which may be attached.
    try c.exec("ATTACH NULL AS NULL");
    try c.expectRows("SELECT quote(name) FROM pragma_database_list WHERE seq = 6", "''\n");
    try c.exec("DETACH ''");
}

test "attach: the limit on attached databases" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    _ = main_mod.limit(c.db, .attached, 2);
    try c.exec("ATTACH 'a.db' AS a; ATTACH 'b.db' AS b");
    try c.expectError("ATTACH 'c.db' AS c", "too many attached databases - max 2");
    try c.exec("DETACH a; ATTACH 'c.db' AS c");
    try c.expectRows("SELECT name FROM pragma_database_list", "main\nb\nc\n");
    // The hard limit is SQLITE_MAX_ATTACHED (10).
    try testing.expectEqual(@as(i32, 2), main_mod.limit(c.db, .attached, 100));
    try testing.expectEqual(@as(i32, 10), main_mod.limit(c.db, .attached, -1));
}

test "attach: a file that cannot be opened or read" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    {
        const f = try c.mem.interface().open("junk.db", .{ .create = true });
        defer f.close();
        const junk: [1024]u8 = @splat('x');
        try f.write(&junk, 0);
    }
    try c.expectError("ATTACH 'junk.db' AS j", "file is not a database");
    main_mod.extendedResultCodes(c.db, true);
    try testing.expectEqual(RC.NOTADB, main_mod.extendedErrcode(c.db));
    try c.expectRows("SELECT name FROM pragma_database_list", "main\n");
    // Without SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE no file is made.
    _ = main_mod.dbConfig(c.db, .enable_attach_create, 0);
    try c.expectError("ATTACH 'new.db' AS n", "unable to open database: new.db");
    try testing.expectEqual(RC.CANTOPEN, main_mod.extendedErrcode(c.db));
    try c.exec("CREATE TABLE t(x)");
    _ = main_mod.dbConfig(c.db, .enable_attach_create, 1);
    try c.exec("ATTACH 'new.db' AS n; CREATE TABLE n.t(x); DETACH n");
    // Without SQLITE_DBCONFIG_ENABLE_ATTACH_WRITE it is read-only.
    _ = main_mod.dbConfig(c.db, .enable_attach_write, 0);
    try c.exec("ATTACH 'new.db' AS n");
    try testing.expectEqual(@as(?bool, true), main_mod.dbReadonly(c.db, "n"));
    try c.expectError("INSERT INTO n.t VALUES(1)", "attempt to write a readonly database");
    try c.expectRows("SELECT count(*) FROM n.t", "0\n");
}

test "attach: URI filenames" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("ATTACH 'file:u.db' AS plain; CREATE TABLE plain.t(x); DETACH plain");
    // Without OpenFlags.uri, "file:u.db" was a file of that name.
    try c.expectRows("SELECT 1", "1\n");
    c.db.open_flags.uri = true;
    try c.exec("ATTACH 'file:u.db?mode=rwc' AS u; CREATE TABLE u.t(x); INSERT INTO u.t VALUES(1); DETACH u");
    try c.exec("ATTACH 'file:u.db?mode=ro' AS ro");
    try c.expectRows("SELECT * FROM ro.t", "1\n");
    try c.expectError("INSERT INTO ro.t VALUES(2)", "attempt to write a readonly database");
    try c.exec("ATTACH 'file:%75.db' AS esc");
    try c.expectRows("SELECT * FROM esc.t", "1\n");
    try c.expectError("ATTACH 'file:none.db?mode=rw' AS n", "unable to open database: file:none.db?mode=rw");
    try c.expectError("ATTACH 'file:u.db?vfs=other' AS n", "no such vfs: other");
    try c.expectError("ATTACH 'file:u.db?mode=x' AS n", "no such access mode: x");
    try c.expectError("ATTACH 'file:u.db?cache=x' AS n", "no such cache mode: x");
    try c.expectError("ATTACH 'file://host/u.db' AS n", "invalid uri authority: host");
    try c.exec("ATTACH 'file:m?mode=memory' AS m; CREATE TABLE m.t(x)");
    try c.expectRows("SELECT name, file FROM pragma_database_list WHERE seq >= 2", "ro|u.db\nesc|u.db\nm|\n");
    // A connection opened read-only may not attach read-write.
    c.db.open_flags.read_only = true;
    c.db.open_flags.create = false;
    try c.expectError("ATTACH 'file:u.db?mode=rw' AS n", "access mode not allowed: rw");
}

/// Prepare `sql` on `c`.
fn prep(c: *Conn, sql: []const u8) !*Vdbe {
    var stmt: ?*Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, sql, &stmt, null));
    return stmt.?;
}

test "attach: DETACH while statements are prepared or running" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(x); INSERT INTO t VALUES(1), (2)");
    try c.exec("ATTACH 'a.db' AS a; CREATE TABLE a.u(y); INSERT INTO a.u VALUES(10), (20)");

    // A statement prepared before the DETACH is compiled again, and
    // finds no table.
    const s = try prep(&c, "SELECT y FROM a.u");
    defer _ = api.finalize(s);
    try testing.expectEqual(RC.ROW, api.step(s));
    _ = api.reset(s);
    try c.exec("DETACH a");
    try testing.expectEqual(RC.ERROR, api.step(s));
    try testing.expectEqualStrings("no such table: a.u", main_mod.errmsg(c.db));
    _ = api.reset(s);
    // ATTACHing the database again makes it work again.
    try c.exec("ATTACH 'a.db' AS a");
    try testing.expectEqual(RC.ROW, api.step(s));
    try testing.expectEqual(@as(i64, 10), api.columnInt64(s, 0));

    // While the statement reads it, the database cannot be detached.
    try c.expectError("DETACH a", "database a is locked");
    // Another database can.
    try c.exec("ATTACH 'b.db' AS b; DETACH b");
    try testing.expectEqual(RC.ROW, api.step(s));
    try testing.expectEqual(@as(i64, 20), api.columnInt64(s, 0));
    try testing.expectEqual(RC.DONE, api.step(s));
    _ = api.reset(s);
    try c.exec("DETACH a");

    // A statement reading main does not keep an attached database busy.
    try c.exec("ATTACH 'a.db' AS a");
    const m = try prep(&c, "SELECT x FROM main.t");
    defer _ = api.finalize(m);
    try testing.expectEqual(RC.ROW, api.step(m));
    try c.exec("DETACH a");
    try testing.expectEqual(RC.ROW, api.step(m));
    try testing.expectEqual(RC.DONE, api.step(m));

    // Nor does one reading a database attached after it, which moves
    // down in db.dbs.
    try c.exec("ATTACH 'a.db' AS a; ATTACH 'b.db' AS b; CREATE TABLE b.w(v); INSERT INTO b.w VALUES(1), (2), (3)");
    const r = try prep(&c, "SELECT v FROM b.w");
    defer _ = api.finalize(r);
    try testing.expectEqual(RC.ROW, api.step(r));
    try c.exec("DETACH a");
    try testing.expectEqual(RC.ROW, api.step(r));
    try testing.expectEqual(RC.ROW, api.step(r));
    try testing.expectEqual(@as(i64, 3), api.columnInt64(r, 0));
    try testing.expectEqual(RC.DONE, api.step(r));
    try testing.expectEqual(RC.ROW, api.step(r));
    try c.expectError("DETACH b", "database b is locked");
    _ = api.reset(r);
    try c.exec("DETACH b");
}

test "attach: TEMP triggers and views on attached tables, and the DbFixer" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(x)");
    try c.exec("ATTACH 'a.db' AS a; CREATE TABLE a.u(y); ATTACH 'b.db' AS b; CREATE TABLE b.log(z)");
    try c.exec("CREATE TEMP TRIGGER tr AFTER INSERT ON a.u BEGIN INSERT INTO b.log VALUES(new.y * 10); END");
    try c.exec("INSERT INTO a.u VALUES(1)");
    try c.expectRows("SELECT * FROM b.log", "10\n");
    try c.exec("CREATE VIEW a.v AS SELECT y FROM u");
    try c.expectRows("SELECT * FROM a.v", "1\n");
    try c.expectError("CREATE VIEW a.v2 AS SELECT * FROM main.t", "view v2 cannot reference objects in database main");
    try c.expectError("CREATE TRIGGER a.tr2 AFTER INSERT ON u BEGIN INSERT INTO main.t VALUES(1); END", "qualified table names are not allowed on INSERT, UPDATE, and DELETE statements within triggers");
    try c.exec("CREATE TRIGGER a.tr3 AFTER INSERT ON u BEGIN INSERT INTO u2 VALUES(new.y); END; CREATE TABLE a.u2(w)");
    try c.exec("INSERT INTO a.u VALUES(2)");
    try c.expectRows("SELECT * FROM a.u2", "2\n");
    try c.expectRows("SELECT * FROM b.log", "10\n20\n");
    // After the DETACH, the TEMP trigger stays, on a table of TEMP
    // itself (which it never fires on, as in sqlite3).
    try c.exec("DETACH a");
    try c.expectRows("SELECT name, tbl_name FROM temp.sqlite_schema", "tr|u\n");
    try c.exec("CREATE TEMP TABLE u(y); INSERT INTO u VALUES(3)");
    try c.exec("ATTACH 'a.db' AS a; INSERT INTO a.u VALUES(4)");
    try c.expectRows("SELECT * FROM b.log", "10\n20\n");
    try c.expectRows("SELECT * FROM a.u2", "2\n4\n");
}

test "attach: the internal ATTACH of VACUUM, and closeDb()" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    const saved = c.db.open_flags;
    c.db.open_flags.read_only = false;
    c.db.open_flags.create = true;
    try c.exec("ATTACH '' AS vacuum_db");
    c.db.open_flags = saved;
    const i_db = c.db.dbs.items.len - 1;
    try testing.expectEqualStrings("vacuum_db", c.db.dbs.items[i_db].name);
    try c.exec("CREATE TABLE vacuum_db.t(x); INSERT INTO vacuum_db.t VALUES(1)");
    attach.closeDb(c.db, i_db);
    try testing.expectEqual(@as(usize, 2), c.db.dbs.items.len);
    try c.expectRows("SELECT name FROM pragma_database_list", "main\n");
}
