//! End-to-end tests of the dialect layer: frontend dispatch, dialect
//! function tables, default collations, the catalog and sequences.

const std = @import("std");
const testing = std.testing;
const int = @import("../sql/sqlite_int.zig");
const main_mod = @import("../sql/main.zig");
const prepare = @import("../sql/prepare.zig");
const api = @import("../vdbe/api.zig");
const dialect = @import("dialect.zig");
const ir = @import("../ir/ir.zig");
const catalog = @import("../catalog/catalog.zig");
const sequence = catalog.sequence;
const Conn = @import("../sql/sql_test.zig").Conn;

const RC = int.RC;

/// SQLite's grammar with the semantic hooks of `d`: the stub frontends
/// of the other dialects cannot parse yet.
fn useHooksOf(c: *Conn, d: dialect.Dialect) void {
    main_mod.setDialect(c.db, d);
    main_mod.setFrontend(c.db, dialect.spec(.sqlite).frontend);
}

test {
    _ = @import("postgres/frontend.zig");
    _ = @import("oracle/frontend.zig");
}

test "dialect: SQLite by default, PRAGMA xq_dialect and frontend dispatch" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("PRAGMA xq_dialect", "sqlite\n");
    try c.expectColumns("PRAGMA xq_dialect", "xq_dialect");
    // Not one of SQLite's pragmas.
    try c.expectRows("SELECT count(*) FROM pragma_pragma_list WHERE name LIKE 'xq%'", "0\n");
    try c.expectError("PRAGMA xq_dialect = 'db2'", "unknown dialect: db2");

    try c.expectRows("PRAGMA xq_dialect = 'postgres'", "postgres\n");
    try testing.expectEqual(dialect.Dialect.postgres, main_mod.getDialect(c.db));
    // The PostgreSQL frontend runs now.
    try c.expectError("SELECT 1 +", "syntax error at end of input");
    try c.exec("  -- only a comment\n ");
    main_mod.setDialect(c.db, .mariadb);
    try c.expectRows("SELECT 1", "1\n");

    // The schema is SQLite text in any dialect: a statement of a new
    // connection reads it with SQLite's frontend.
    main_mod.setDialect(c.db, .sqlite);
    try c.exec("CREATE TABLE t(a)");
    try c.reopen();
    main_mod.setDialect(c.db, .postgres);
    try c.expectRows("SELECT count(*) FROM t", "0\n");
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

test "dialect: engine functions and qualified dialect functions are visible in every dialect" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // In the SQLite dialect, as in the schema the IR renders.
    try c.expectRows("SELECT xq_like('a%', 'abc'), xq_like('A%', 'abc'), xq_ilike('A%', 'abc'), xq_div(7, 2), xq_pg_bool('yes')", "1|0|1|3|1\n");
    try c.expectRows("SELECT xq_postgres_greatest(1, NULL, 3), xq_mariadb_concat('a', NULL), xq_postgres_left('abc', 2)", "3|NULL|ab\n");
    try c.expectError("SELECT xq_postgres_nosuch(1)", "no such function: xq_postgres_nosuch");
    // Not shadowed by a dialect; xq_sqlite_<name> is SQLite's built-in.
    useHooksOf(&c, .mariadb);
    try c.expectRows("SELECT xq_like('a%', 'ABC'), xq_postgres_greatest(2, 1), concat('a', NULL), xq_sqlite_concat('a', NULL)", "0|2|NULL|a\n");
    // Usable from the schema with trusted_schema off (innocuous).
    useHooksOf(&c, .sqlite);
    try c.exec("PRAGMA trusted_schema = OFF; CREATE TABLE t (a TEXT CHECK (xq_like('a%', a))); INSERT INTO t VALUES ('ab')");
    try c.expectError("INSERT INTO t VALUES ('Ab')", "CHECK constraint failed: xq_like('a%', a)");
}

test "dialect: sequences" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    useHooksOf(&c, .postgres);
    try c.expectError("SELECT nextval('s')", "relation \"s\" does not exist");
    try sequence.create(c.db, "main", "s", .{}, false);
    try testing.expectError(error.Constraint, sequence.create(c.db, "main", "s", .{}, false));
    try sequence.create(c.db, "main", "s", .{}, true);
    try c.expectError("SELECT currval('s')", "currval of sequence \"s\" is not yet defined in this session");
    try c.expectRows("SELECT nextval('s'), nextval('s')", "1|2\n");
    try c.expectRows("SELECT currval('s'), lastval()", "2|2\n");
    try c.expectRows("SELECT setval('s', 10), nextval('s')", "10|11\n");
    try c.expectRows("SELECT setval('s', 20, false), nextval('s'), currval('s')", "20|20|20\n");
    try c.expectError("SELECT setval('s', 0)", "setval: value 0 is out of bounds for sequence \"s\" (1..9223372036854775807)");

    // Inside an INSERT, and transactional.
    try c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, v)");
    try c.exec("INSERT INTO t VALUES(nextval('s'), 'a'), (nextval('s'), 'b')");
    try c.expectRows("SELECT id, v FROM t", "21|a\n22|b\n");
    try c.exec("BEGIN; SELECT nextval('s'); ROLLBACK");
    try c.expectRows("SELECT nextval('s')", "23\n");

    // Bounds, cycling, descending.
    try sequence.create(c.db, "main", "small", .{ .max = 2 }, false);
    try c.expectRows("SELECT nextval('small'), nextval('small')", "1|2\n");
    try c.expectError("SELECT nextval('small')", "nextval: reached maximum value of sequence \"small\" (2)");
    try sequence.create(c.db, "main", "ring", .{ .min = 1, .max = 2, .cycle = true }, false);
    try c.expectRows("SELECT nextval('ring'), nextval('ring'), nextval('ring')", "1|2|1\n");
    try sequence.create(c.db, "main", "down", .{ .increment = -5, .start = 3, .min = -4, .max = 3 }, false);
    try c.expectRows("SELECT nextval('down'), nextval('down')", "3|-2\n");
    try c.expectError("SELECT nextval('down')", "nextval: reached minimum value of sequence \"down\" (-4)");

    // The Zig API, and drop.
    try testing.expectEqual(@as(i64, 24), try sequence.nextval(c.db, "main", "s"));
    try testing.expectEqual(@as(?i64, 24), sequence.currval(c.db, "s"));
    try testing.expect(try sequence.drop(c.db, "main", "small"));
    try testing.expect(!try sequence.drop(c.db, "main", "small"));

    // The values persist in the file.
    try c.reopen();
    useHooksOf(&c, .mariadb);
    try c.expectRows("SELECT lastval('s'), nextval('s'), lastval('s')", "NULL|25|25\n");
    try c.expectRows("SELECT name, last_value FROM xq_sequence ORDER BY name", "down|-2\nring|1\ns|25\n");
}

/// A frontend that lowers every statement into CREATE TABLE t(a TEXT)
/// STRICT, recording the declared type and an identity sequence in the
/// catalog: the path a real frontend takes for DDL.
fn ddlFrontendRun(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
    p.rc = RC.OK;
    p.tail = sql;
    const decl = "varchar(20)";
    const text = try std.fmt.allocPrintSentinel(p.arena, "CREATE TABLE t(a {s}, id INTEGER) STRICT", .{ir.ddl.strictStorageType(decl)}, 0);
    try ir.stmt.lowerSqliteText(p, text);
    catalog.codeSet(p, "main", "t", "", catalog.Key.dialect, "postgres");
    catalog.codeSet(p, "main", "t", "a", catalog.Key.decl_type, decl);
    catalog.codeSet(p, "main", "t", "id", catalog.Key.identity, "t_id_seq");
    sequence.codeCreate(p, "main", "t_id_seq", .{}, false);
    ir.stmt.finishCoding(p);
    p.tail = sql[sql.len..];
    if (p.rc != RC.DONE) return error.ParseFailed;
}

const ddl_frontend: dialect.Frontend = .{ .run = ddlFrontendRun };

test "dialect: DDL lowered as SQLite text, with catalog entries in the same statement" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    main_mod.setDialect(c.db, .postgres);
    main_mod.setFrontend(c.db, &ddl_frontend);
    try c.exec("create table t (a varchar(20), id serial)");
    useHooksOf(&c, .postgres);
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name='t'", "CREATE TABLE t(a TEXT, id INTEGER) STRICT\n");
    try c.expectRows("SELECT tbl, col, key, value FROM xq_catalog ORDER BY col, key",
        \\t||dialect|postgres
        \\t|a|type|varchar(20)
        \\t|id|identity|t_id_seq
        \\
    );
    // STRICT typing from SQLite's machinery.
    try c.expectError("INSERT INTO t VALUES(x'00', 1)", "cannot store BLOB value in TEXT column t.a");
    try c.exec("INSERT INTO t VALUES('x', nextval('t_id_seq'))");
    try c.expectRows("SELECT a, id FROM t", "x|1\n");
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const got = (try catalog.get(c.db, fba.allocator(), "main", "t", "a", catalog.Key.decl_type)).?;
    try testing.expectEqualStrings("varchar(20)", got);

    // A failing statement leaves nothing behind (one transaction).
    main_mod.setFrontend(c.db, &ddl_frontend);
    var msg: ?[:0]u8 = null;
    try testing.expect(@import("../sql/legacy.zig").exec(c.db, "create table t ()", null, null, &msg) != RC.OK);
    if (msg) |m| @import("../sql/malloc.zig").free(m.ptr);
    useHooksOf(&c, .sqlite);
    try c.expectRows("SELECT count(*) FROM xq_catalog", "3\n");
    try c.exec("PRAGMA integrity_check");
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
