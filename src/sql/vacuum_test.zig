//! Tests of VACUUM and VACUUM INTO (vacuum.zig), the transfer
//! optimization they copy rows with (insert.zig), and the backup API
//! (backup.zig).

const std = @import("std");
const testing = std.testing;
const int = @import("sqlite_int.zig");
const main_mod = @import("main.zig");
const prepare = @import("prepare.zig");
const backup = @import("backup.zig");
const api = @import("../vdbe/api.zig");
const Conn = @import("sql_test.zig").Conn;
const Dialect = @import("../dialect/dialect.zig").Dialect;

const RC = int.RC;
const Vdbe = @import("../vdbe/vdbe_int.zig").Vdbe;

/// A table with holes, an index, a WITHOUT ROWID table, overflow pages,
/// a view and a trigger.
const schema =
    \\CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
    \\CREATE INDEX tb ON t(b);
    \\WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<300)
    \\  INSERT INTO t SELECT i * 3, printf('%.*c', i % 100, 'v'), zeroblob(i % 7 * 1000) FROM n;
    \\DELETE FROM t WHERE a % 2 = 0;
    \\CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
    \\INSERT INTO w SELECT b || a, length(c) FROM t;
    \\CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, x);
    \\INSERT INTO s(x) VALUES(1), (2);
    \\CREATE VIEW tv AS SELECT a, b FROM t;
    \\CREATE TRIGGER ttr AFTER DELETE ON t BEGIN INSERT INTO s(x) VALUES(old.a); END;
;

/// The content of every table, to compare before and after.
const content_sql = "SELECT count(*), sum(a), sum(length(b)), sum(length(c)) FROM t; SELECT count(*), sum(v) FROM w; SELECT * FROM s; SELECT * FROM sqlite_sequence; SELECT count(*) FROM tv";

fn content(c: *Conn) ![]u8 {
    return c.query(content_sql);
}

test "vacuum: VACUUM keeps the content and empties the freelist" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    try c.exec("PRAGMA user_version = 7; PRAGMA application_id = 99");
    const before = try content(&c);
    defer testing.allocator.free(before);
    const cookie = try c.query("PRAGMA schema_version");
    defer testing.allocator.free(cookie);
    const free = try c.query("PRAGMA freelist_count");
    defer testing.allocator.free(free);
    try testing.expect(!std.mem.eql(u8, "0\n", free));

    try c.exec("VACUUM");
    const after = try content(&c);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try c.expectRows("PRAGMA freelist_count", "0\n");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
    try c.expectRows("PRAGMA user_version; PRAGMA application_id", "7\n99\n");
    // The schema cookie goes up by one.
    const n = try std.fmt.parseInt(u32, std.mem.trimEnd(u8, cookie, "\n"), 10);
    var buf: [16]u8 = undefined;
    try c.expectRows("PRAGMA schema_version", try std.fmt.bufPrint(&buf, "{d}\n", .{n + 1}));
    // The rowids are kept, the trigger still fires, the view still works.
    try c.expectRows("SELECT a FROM t ORDER BY a LIMIT 3", "3\n9\n15\n");
    try c.exec("DELETE FROM t WHERE a = 3");
    try c.expectRows("SELECT x FROM s ORDER BY id DESC LIMIT 1", "3\n");
    try c.exec("VACUUM main");
    try c.expectRows("PRAGMA integrity_check", "ok\n");

    // Another connection reads the new schema.
    var d: Conn = undefined;
    try d.openOn(c.mem);
    defer d.close();
    try d.expectRows("SELECT count(*) FROM tv", "149\n");
    try c.exec("VACUUM");
    try d.expectRows("SELECT count(*) FROM t", "149\n");
}

test "vacuum: page_size and auto_vacuum take effect" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    const before = try content(&c);
    defer testing.allocator.free(before);
    // The page size of an existing database changes only by VACUUM.
    try c.exec("PRAGMA page_size = 1024");
    try c.expectRows("PRAGMA page_size", "4096\n");
    try c.exec("VACUUM");
    try c.expectRows("PRAGMA page_size; PRAGMA integrity_check", "1024\nok\n");
    try c.exec("PRAGMA page_size = 65536; VACUUM");
    try c.expectRows("PRAGMA page_size; PRAGMA integrity_check", "65536\nok\n");
    // As does auto-vacuum, on or off.
    try c.exec("PRAGMA auto_vacuum = FULL");
    try c.expectRows("PRAGMA auto_vacuum", "0\n");
    try c.exec("PRAGMA page_size = 512; VACUUM");
    try c.expectRows("PRAGMA auto_vacuum; PRAGMA page_size; PRAGMA integrity_check", "1\n512\nok\n");
    try c.exec("PRAGMA auto_vacuum = INCREMENTAL; VACUUM");
    try c.expectRows("PRAGMA auto_vacuum; PRAGMA integrity_check", "2\nok\n");
    try c.exec("DELETE FROM t WHERE a < 300; PRAGMA incremental_vacuum");
    try c.expectRows("PRAGMA freelist_count; PRAGMA integrity_check", "0\nok\n");
    try c.exec("PRAGMA auto_vacuum = NONE; VACUUM");
    try c.expectRows("PRAGMA auto_vacuum; PRAGMA integrity_check", "0\nok\n");
    try c.reopen();
    try c.expectRows("PRAGMA page_size; PRAGMA auto_vacuum; PRAGMA integrity_check", "512\n0\nok\n");
}

test "vacuum: a WAL database keeps its page size" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("PRAGMA journal_mode = WAL");
    try c.exec(schema);
    try c.exec("PRAGMA page_size = 1024; VACUUM");
    try c.expectRows("PRAGMA page_size; PRAGMA journal_mode; PRAGMA freelist_count; PRAGMA integrity_check", "4096\nwal\n0\nok\n");
    // PRAGMA page_size was forgotten.
    try c.exec("VACUUM INTO 'out.db'; ATTACH 'out.db' AS o");
    try c.expectRows("PRAGMA o.page_size; PRAGMA o.journal_mode", "4096\ndelete\n");
    try c.exec("DETACH o; PRAGMA page_size = 2048; VACUUM INTO 'out2.db'; ATTACH 'out2.db' AS o");
    try c.expectRows("PRAGMA o.page_size; PRAGMA o.integrity_check", "2048\nok\n");
}

test "vacuum: VACUUM INTO" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    const before = try content(&c);
    defer testing.allocator.free(before);
    try c.exec("PRAGMA page_size = 1024; PRAGMA auto_vacuum = 1; VACUUM INTO 'out.db'");
    // The original is unchanged.
    try c.expectRows("PRAGMA page_size; PRAGMA auto_vacuum", "4096\n0\n");
    try c.expectError("VACUUM INTO 'out.db'", "output file already exists");
    try c.expectError("VACUUM INTO 1", "non-text filename");
    try c.expectError("VACUUM INTO NULL", "non-text filename");
    try c.expectError("VACUUM INTO x", "no such column: x");

    var d: Conn = undefined;
    try d.openOn(c.mem);
    defer d.close();
    try d.exec("ATTACH 'out.db' AS o");
    try d.expectRows("PRAGMA o.page_size; PRAGMA o.auto_vacuum; PRAGMA o.freelist_count; PRAGMA o.integrity_check", "1024\n1\n0\nok\n");
    try d.exec("DETACH o");
    _ = main_mod.close(d.db);
    var db: ?*int.Sqlite3 = null;
    try testing.expectEqual(RC.OK, main_mod.open(c.mem.interface(), "out.db", .{}, &db));
    d.db = db.?;
    const copied = try content(&d);
    defer testing.allocator.free(copied);
    try testing.expectEqualStrings(before, copied);

    // An attached database, into a URI with a reserve.
    try c.exec("ATTACH 'aux.db' AS aux; CREATE TABLE aux.u(x); INSERT INTO aux.u VALUES(1), (2)");
    c.db.open_flags.uri = true;
    try c.exec("VACUUM aux INTO 'file:out3.db?reserve=12'");
    try c.exec("ATTACH 'out3.db' AS o3");
    try c.expectRows("SELECT * FROM o3.u; PRAGMA o3.integrity_check", "1\n2\nok\n");
}

test "vacuum: the errors" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(x); INSERT INTO t VALUES(1), (2)");
    try c.expectError("VACUUM nosuch", "unknown database nosuch");
    try c.exec("BEGIN");
    try c.expectError("VACUUM", "cannot VACUUM from within a transaction");
    try c.exec("ROLLBACK; SAVEPOINT s");
    try c.expectError("VACUUM", "cannot VACUUM from within a transaction");
    try c.exec("RELEASE s");

    var stmt: ?*Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT x FROM t", &stmt, null));
    defer _ = api.finalize(stmt.?);
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try c.expectError("VACUUM", "cannot VACUUM - SQL statements in progress");
    _ = api.reset(stmt.?);
    // TEMP is not vacuumed: nothing to do.
    try c.exec("CREATE TEMP TABLE tt(y); VACUUM temp; VACUUM");
    try c.expectRows("SELECT * FROM t; SELECT count(*) FROM tt", "1\n2\n0\n");
    // Everything put back: the connection is in autocommit mode with
    // only its databases.
    try testing.expect(main_mod.getAutocommit(c.db));
    try c.expectRows("SELECT name FROM pragma_database_list", "main\ntemp\n");
    try c.exec("VACUUM INTO 'x.db'");
    try c.expectRows("SELECT name FROM pragma_database_list", "main\ntemp\n");
}

test "vacuum: the transfer optimization copies records and rowids" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE r1(a, b); INSERT INTO r1 VALUES(1, 2), (3, 4); DELETE FROM r1 WHERE a = 1");
    // Without an INTEGER PRIMARY KEY or an index, new rowids.
    try c.exec("CREATE TABLE r2(a, b); INSERT INTO r2 SELECT * FROM r1");
    try c.expectRows("SELECT rowid, * FROM r2", "1|3|4\n");
    try c.exec("INSERT INTO r2 SELECT * FROM r1");
    try c.expectRows("SELECT rowid, * FROM r2", "1|3|4\n2|3|4\n");
    try testing.expectEqual(@as(i64, 2), main_mod.lastInsertRowid(c.db));
    try testing.expectEqual(@as(i64, 1), api.changes(c.db));
    // With an index (on both), the rowids are kept and the index
    // entries copied, but only into an empty table.
    try c.exec("CREATE TABLE q1(a, b); CREATE INDEX q1a ON q1(a); INSERT INTO q1 VALUES(1, 2), (3, 4); DELETE FROM q1 WHERE a = 1");
    try c.exec("CREATE TABLE q2(a, b); CREATE INDEX q2a ON q2(a); INSERT INTO q2 SELECT * FROM q1");
    try c.expectRows("SELECT rowid, a FROM q2 INDEXED BY q2a", "2|3\n");
    try c.exec("INSERT INTO q2 SELECT * FROM q1");
    try c.expectRows("SELECT rowid, a FROM q2 INDEXED BY q2a; PRAGMA integrity_check", "2|3\n3|3\nok\n");
    // A duplicate INTEGER PRIMARY KEY is a constraint error.
    try c.exec("CREATE TABLE p1(a INTEGER PRIMARY KEY, b); INSERT INTO p1 VALUES(1, 'x'); CREATE TABLE p2(a INTEGER PRIMARY KEY, b)");
    try c.exec("INSERT INTO p2 SELECT * FROM p1");
    try c.expectError("INSERT INTO p2 SELECT * FROM p1", "UNIQUE constraint failed: p2.a");
    // Overflow pages are copied.
    try c.exec("CREATE TABLE big1(x); INSERT INTO big1 VALUES(zeroblob(20000)), (randomblob(9000)); CREATE TABLE big2(x)");
    try c.exec("INSERT INTO big2 SELECT * FROM big1");
    try c.expectRows("SELECT count(*) FROM big1, big2 WHERE big1.x = big2.x; PRAGMA integrity_check", "2\nok\n");
}

/// Open connection `name` on the file system of `c`.
fn openOther(c: *Conn, name: []const u8) !*int.Sqlite3 {
    var db: ?*int.Sqlite3 = null;
    try testing.expectEqual(RC.OK, main_mod.open(c.mem.interface(), name, .{}, &db));
    return db.?;
}

test "vacuum: the backup API" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    const before = try content(&c);
    defer testing.allocator.free(before);

    var d: Conn = undefined;
    try d.openOn(c.mem);
    defer d.close();
    _ = main_mod.close(d.db);
    d.db = try openOther(&c, "copy.db");
    try d.exec("PRAGMA page_size = 1024; CREATE TABLE junk(x); INSERT INTO junk VALUES(zeroblob(50000))");

    try testing.expect(backup.init(c.db, "main", c.db, "main") == null);
    try testing.expectEqualStrings("source and destination must be distinct", main_mod.errmsg(c.db));
    try testing.expect(backup.init(d.db, "main", c.db, "nosuch") == null);
    try testing.expectEqualStrings("unknown database nosuch", main_mod.errmsg(d.db));
    try d.exec("BEGIN; SELECT * FROM junk");
    try testing.expect(backup.init(d.db, "main", c.db, "main") == null);
    try testing.expectEqualStrings("destination database is in use", main_mod.errmsg(d.db));
    try d.exec("COMMIT");

    // Five pages a step; the source changes in between.
    const b = backup.init(d.db, "main", c.db, "main").?;
    try testing.expectEqual(RC.OK, backup.step(b, 5));
    const total = backup.pagecount(b);
    try testing.expect(total > 10);
    try testing.expectEqual(total - 5, backup.remaining(b));
    // The source cannot be closed, nor the destination detached, while
    // the backup runs.
    try testing.expectEqual(RC.BUSY, main_mod.close(c.db));
    // A change by the source connection itself is copied along.
    try c.exec("UPDATE t SET b = 'changed' WHERE a = 3");
    try testing.expectEqual(RC.OK, backup.step(b, 5));
    try testing.expectEqual(RC.DONE, backup.step(b, -1));
    try testing.expectEqual(@as(i32, 0), backup.remaining(b));
    try testing.expectEqual(RC.DONE, backup.step(b, -1));
    try testing.expectEqual(RC.OK, backup.finish(b));
    // (As in sqlite3, PRAGMA page_size reports the new size once the
    // database has been read.)
    try d.expectRows("PRAGMA integrity_check; SELECT b FROM t WHERE a = 3; PRAGMA page_size", "ok\nchanged\n4096\n");
    try d.expectError("SELECT * FROM junk", "no such table: junk");
    const copied = try content(&d);
    defer testing.allocator.free(copied);
    const now = try content(&c);
    defer testing.allocator.free(now);
    try testing.expectEqualStrings(now, copied);

    // Back the other way, into an attached database, all at once.
    try c.exec("ATTACH 'aux.db' AS aux");
    try d.exec("DELETE FROM w");
    const b2 = backup.init(c.db, "aux", d.db, "main").?;
    try testing.expectEqual(RC.DONE, backup.step(b2, -1));
    try testing.expectEqual(RC.OK, backup.finish(b2));
    try c.expectRows("SELECT count(*) FROM aux.w; SELECT count(*) FROM aux.t; PRAGMA aux.integrity_check", "0\n150\nok\n");

    // The source of a backup cannot be detached. One left unfinished is
    // rolled back.
    try d.exec("CREATE TABLE marker(x)");
    const b3 = backup.init(d.db, "main", c.db, "aux").?;
    try testing.expectEqual(RC.OK, backup.step(b3, 1));
    try c.expectError("DETACH aux", "database aux is locked");
    try testing.expectEqual(RC.OK, backup.finish(b3));
    try d.expectRows("SELECT count(*) FROM marker", "0\n");
    try c.exec("DETACH aux");
    try testing.expectEqual(RC.OK, backup.finish(null));
    // A backup into TEMP.
    const b4 = backup.init(c.db, "temp", d.db, "main").?;
    try testing.expectEqual(RC.DONE, backup.step(b4, -1));
    try testing.expectEqual(RC.OK, backup.finish(b4));
    try c.expectRows("SELECT count(*) FROM temp.w; SELECT count(*) FROM temp.marker", "0\n0\n");
}

test "vacuum: a backup restarts when another connection changes the source" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec(schema);
    var other: Conn = undefined;
    try other.openOn(c.mem);
    defer other.close();
    var d: Conn = undefined;
    try d.openOn(c.mem);
    defer d.close();
    _ = main_mod.close(d.db);
    d.db = try openOther(&c, "copy.db");

    const b = backup.init(d.db, "main", c.db, "main").?;
    try testing.expectEqual(RC.OK, backup.step(b, 3));
    try other.exec("INSERT INTO w VALUES('new', 1)");
    try testing.expectEqual(RC.DONE, backup.step(b, -1));
    try testing.expectEqual(RC.OK, backup.finish(b));
    try d.expectRows("SELECT v FROM w WHERE k = 'new'; PRAGMA integrity_check", "1\nok\n");
}

test "vacuum: the PostgreSQL and MariaDB dialects pass VACUUM to SQLite" {
    try Dialect.requireBuilt(&.{ .postgres, .mariadb });
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    main_mod.setDialect(c.db, .postgres);
    try c.exec("CREATE TABLE t(id serial PRIMARY KEY, v text); INSERT INTO t(v) VALUES('a'), ('b'); DELETE FROM t WHERE id = 1");
    try c.exec("VACUUM; VACUUM main INTO 'pg.db'");
    try c.expectRows("SELECT * FROM t", "2|b\n");
    main_mod.setDialect(c.db, .mariadb);
    try c.exec("CREATE TABLE u(id int AUTO_INCREMENT PRIMARY KEY, v text); INSERT INTO u(v) VALUES('x')");
    try c.exec("VACUUM");
    try c.expectRows("SELECT * FROM u", "1|x\n");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("PRAGMA freelist_count; PRAGMA integrity_check", "0\nok\n");
}
