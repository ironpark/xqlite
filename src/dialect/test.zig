//! End-to-end tests of the dialect layer: frontend dispatch, dialect
//! function tables and default collations.

const std = @import("std");
const testing = std.testing;
const int = @import("../sql/sqlite_int.zig");
const main_mod = @import("../sql/main.zig");
const prepare = @import("../sql/prepare.zig");
const api = @import("../vdbe/api.zig");
const dialect = @import("dialect.zig");
const Conn = @import("../sql/sql_test.zig").Conn;

const RC = int.RC;

/// SQLite's grammar with the semantic hooks of `d`: the stub frontends
/// of the other dialects cannot parse yet.
fn useHooksOf(c: *Conn, d: dialect.Dialect) void {
    main_mod.setDialect(c.db, d);
    main_mod.setFrontend(c.db, dialect.spec(.sqlite).frontend);
}

test "dialect: SQLite by default, PRAGMA xq_dialect and frontend dispatch" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("PRAGMA xq_dialect", "sqlite\n");
    try c.expectColumns("PRAGMA xq_dialect", "xq_dialect");
    // Not one of SQLite's pragmas.
    try c.expectRows("SELECT count(*) FROM pragma_pragma_list WHERE name LIKE 'xq%'", "0\n");
    try c.expectError("PRAGMA xq_dialect = 'oracle'", "unknown dialect: oracle");

    try c.expectRows("PRAGMA xq_dialect = 'postgres'", "postgres\n");
    try testing.expectEqual(dialect.Dialect.postgres, main_mod.getDialect(c.db));
    // The PostgreSQL frontend runs now.
    try c.expectError("SELECT 1", "postgres dialect: parser not implemented");
    try c.exec("  -- only a comment\n ");
    main_mod.setDialect(c.db, .mariadb);
    try c.expectError("SELECT 1", "mariadb dialect: parser not implemented");

    // The schema is SQLite text in any dialect: a statement of a new
    // connection reads it with SQLite's frontend.
    main_mod.setDialect(c.db, .sqlite);
    try c.exec("CREATE TABLE t(a)");
    try c.reopen();
    main_mod.setDialect(c.db, .postgres);
    try c.expectError("SELECT * FROM t", "postgres dialect: parser not implemented");
    useHooksOf(&c, .postgres);
    try c.expectRows("SELECT count(*) FROM t", "0\n");
}

test "dialect: function tables add and replace functions" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // SQLite: no version(); concat() skips NULLs.
    try c.expectError("SELECT version()", "no such function: version");
    try c.expectRows("SELECT concat('a', NULL, 'b')", "ab\n");

    useHooksOf(&c, .mariadb);
    try c.expectRows("SELECT concat('a', NULL, 'b'), concat('a', 1, 'b')", "NULL|a1b\n");
    try c.expectRows("SELECT version() LIKE '%MariaDB%'", "1\n");
    // Functions of other dialects stay out.
    try c.expectError("SELECT currval('s')", "no such function: currval");

    useHooksOf(&c, .postgres);
    try c.expectRows("SELECT version() LIKE 'PostgreSQL%', concat('a', NULL)", "1|a\n");

    // A statement keeps the dialect it was compiled in, also when a
    // schema change recompiles it.
    useHooksOf(&c, .mariadb);
    var stmt: ?*@import("../vdbe/vdbe_int.zig").Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT concat('a', NULL)", &stmt, null));
    defer _ = api.finalize(stmt.?);
    useHooksOf(&c, .sqlite);
    try c.exec("CREATE TABLE force_reprepare(x)");
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqual(@as(i32, @import("../vdbe/vdbe_int.zig").SQLITE_NULL), api.columnType(stmt.?, 0));
    try testing.expect(stmt.?.xq_lang.dialect == .mariadb);
}

test "dialect: the default collation hook" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a, b COLLATE BINARY); INSERT INTO t VALUES('a', 'a'), ('B', 'B'), ('A', 'A')");
    try c.expectRows("SELECT 'a' = 'A', count(DISTINCT a) FROM t", "0|3\n");
    try c.expectRows("SELECT a FROM t ORDER BY a", "A\nB\na\n");
    // MariaDB compares case-insensitively by default; an explicit
    // collation still wins.
    useHooksOf(&c, .mariadb);
    try c.expectRows("SELECT 'a' = 'A', count(DISTINCT a), count(DISTINCT b) FROM t", "1|2|3\n");
    try c.expectRows("SELECT a FROM t ORDER BY a, rowid", "a\nA\nB\n");
    try c.expectRows("SELECT count(*) FROM t WHERE a = 'b' AND b = 'B'", "1\n");
    try c.expectRows("SELECT count(*) FROM t WHERE b = 'b'", "0\n");
}

test "dialect: a database the SQLite dialect writes has no xqlite tables" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.exec("CREATE TABLE t(a INTEGER PRIMARY KEY AUTOINCREMENT, b); INSERT INTO t(b) VALUES(1)");
    try c.expectRows("SELECT name FROM sqlite_schema ORDER BY name", "sqlite_sequence\nt\n");
}
