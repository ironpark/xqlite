//! End-to-end tests of the PostgreSQL dialect: statements compiled by
//! the PostgreSQL frontend on a connection, against the behaviour
//! PostgreSQL documents.

const std = @import("std");
const testing = std.testing;
const int = @import("../../sql/sqlite_int.zig");
const main_mod = @import("../../sql/main.zig");
const prepare = @import("../../sql/prepare.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const Conn = @import("../../sql/sql_test.zig").Conn;

const RC = int.RC;

fn openPg(c: *Conn) !void {
    try c.open();
    main_mod.setDialect(c.db, .postgres);
}

/// Compile `pg` in the PostgreSQL dialect and `lite` in SQLite's: the
/// same bytecode (the same IR, so the same plan).
fn expectSameCode(c: *Conn, pg: []const u8, lite: []const u8) !void {
    var a: ?*vi.Vdbe = null;
    var b: ?*vi.Vdbe = null;
    main_mod.setDialect(c.db, .postgres);
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, pg, &a, null));
    defer _ = api.finalize(a.?);
    main_mod.setDialect(c.db, .sqlite);
    defer main_mod.setDialect(c.db, .postgres);
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, lite, &b, null));
    defer _ = api.finalize(b.?);
    const x = a.?.ops.items;
    const y = b.?.ops.items;
    testing.expectEqual(y.len, x.len) catch |err| {
        std.debug.print("{s}\n  vs {s}\n", .{ pg, lite });
        return err;
    };
    for (x, y) |o, q| {
        try testing.expectEqual(q.opcode, o.opcode);
        try testing.expectEqual(q.p1, o.p1);
        try testing.expectEqual(q.p2, o.p2);
        try testing.expectEqual(q.p3, o.p3);
        try testing.expectEqual(q.p5, o.p5);
    }
}

test "pg: lexical structure" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.expectRows("SELECT 'it''s', E'a\\tb', $$dollar 'quoted'$$, $tag$x$$y$tag$, 'a'\n 'b'", "it's|a\tb|dollar 'quoted'|x$$y|ab\n");
    try c.expectRows("SELECT 1 /* a /* nested */ comment */ + 2 -- rest\n", "3\n");
    try c.expectRows("SELECT 0x1F, 1_000, .5, 1e2, 2 < -1, 4!=5", "31|1000|0.5|100.0|0|1\n");
    // Unquoted names fold to lower case, quoted ones keep their case.
    try c.exec("CREATE TABLE Mixed (Id int, \"Camel\" text)");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'xq\\_%'", "mixed\n");
    try c.expectColumns("SELECT ID, \"Camel\" FROM MIXED", "id|Camel");
    // Backticks and brackets are not identifiers.
    try c.expectError("SELECT `id` FROM mixed", "syntax error at or near \"`\"");
    try c.expectError("SELECT [id] FROM mixed", "syntax error at or near \"[\"");
    try c.expectError("SELECT 'abc", "unterminated quoted string at or near \"'abc\"");
    try c.expectError("SELECT 1 +", "syntax error at end of input");
    try c.expectError("SELECT * FORM mixed", "syntax error at or near \"FORM\"");
    // Several statements in one text, an empty one.
    try c.exec(";; SELECT 1; ; SELECT 2;");
}

test "pg: SELECT" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE emp (id int PRIMARY KEY, name text NOT NULL, dept int, salary int);
        \\CREATE TABLE dept (id int PRIMARY KEY, title text);
        \\INSERT INTO dept VALUES (1, 'eng'), (2, 'ops'), (3, 'empty');
        \\INSERT INTO emp VALUES (1, 'ann', 1, 100), (2, 'bob', 1, 80), (3, 'cid', 2, NULL), (4, 'dan', NULL, 50);
    );
    try c.expectRows("SELECT name FROM emp WHERE salary > 60 ORDER BY salary", "bob\nann\n");
    // NULLs sort last ascending and first descending, as in PostgreSQL.
    try c.expectRows("SELECT name FROM emp ORDER BY salary", "dan\nbob\nann\ncid\n");
    try c.expectRows("SELECT name FROM emp ORDER BY salary DESC", "cid\nann\nbob\ndan\n");
    try c.expectRows("SELECT name FROM emp ORDER BY salary NULLS FIRST", "cid\ndan\nbob\nann\n");
    try c.expectRows("SELECT name FROM emp ORDER BY salary DESC NULLS LAST", "ann\nbob\ndan\ncid\n");
    try c.expectRows("SELECT DISTINCT dept FROM emp ORDER BY dept", "1\n2\nNULL\n");
    // Joins.
    try c.expectRows("SELECT e.name, d.title FROM emp e JOIN dept d ON d.id = e.dept ORDER BY e.id", "ann|eng\nbob|eng\ncid|ops\n");
    try c.expectRows("SELECT e.name, d.title FROM emp e LEFT JOIN dept d ON d.id = e.dept ORDER BY e.id", "ann|eng\nbob|eng\ncid|ops\ndan|NULL\n");
    try c.expectRows("SELECT e.name, d.title FROM emp e RIGHT JOIN dept d ON d.id = e.dept ORDER BY d.id, e.id", "ann|eng\nbob|eng\ncid|ops\nNULL|empty\n");
    try c.expectRows("SELECT count(*) FROM emp e FULL OUTER JOIN dept d ON d.id = e.dept", "5\n");
    try c.expectRows("SELECT count(*) FROM emp CROSS JOIN dept", "12\n");
    try c.expectRows("SELECT count(*) FROM emp, dept WHERE emp.dept = dept.id", "3\n");
    try c.expectRows("SELECT title FROM dept JOIN (SELECT dept AS id FROM emp WHERE id = 3) s USING (id)", "ops\n");
    try c.expectRows("SELECT count(*) FROM emp NATURAL JOIN dept", "3\n");
    try c.expectRows("SELECT e.name FROM emp e JOIN (dept d JOIN dept d2 ON d2.id = d.id) ON d.id = e.dept WHERE d2.title = 'ops'", "cid\n");
    // Grouping, HAVING, aggregates with FILTER and ORDER BY.
    try c.expectRows("SELECT dept, count(*), sum(salary), avg(salary) FROM emp GROUP BY dept HAVING count(*) > 1", "1|2|180|90.0\n");
    try c.expectRows("SELECT count(*) FILTER (WHERE salary > 60), count(salary), count(DISTINCT dept) FROM emp", "2|3|2\n");
    try c.expectRows("SELECT string_agg(name, ',' ORDER BY name DESC) FROM emp", "dan,cid,bob,ann\n");
    try c.expectRows("SELECT bool_and(salary > 40), bool_or(salary > 90) FROM emp", "1|1\n");
    // Subqueries.
    try c.expectRows("SELECT name FROM emp WHERE dept IN (SELECT id FROM dept WHERE title = 'eng') ORDER BY 1", "ann\nbob\n");
    try c.expectRows("SELECT name FROM emp e WHERE NOT EXISTS (SELECT 1 FROM dept d WHERE d.id = e.dept)", "dan\n");
    try c.expectRows("SELECT (SELECT title FROM dept WHERE id = 2), (SELECT max(salary) FROM emp)", "ops|100\n");
    try c.expectRows("SELECT name FROM emp WHERE dept = ANY (SELECT id FROM dept WHERE id > 1)", "cid\n");
    try c.expectRows("SELECT count(*) FROM emp WHERE dept <> ALL (SELECT id FROM dept WHERE id > 1)", "2\n");
    try c.expectRows("SELECT x FROM (SELECT salary * 2 AS x FROM emp WHERE id = 1) AS t", "200\n");
    try c.expectRows("SELECT a + b FROM (VALUES (1, 2), (3, 4)) AS v(a, b) ORDER BY 1", "3\n7\n");
    // LIMIT/OFFSET and the standard's OFFSET/FETCH.
    try c.expectRows("SELECT id FROM emp ORDER BY id LIMIT 2 OFFSET 1", "2\n3\n");
    try c.expectRows("SELECT id FROM emp ORDER BY id OFFSET 3", "4\n");
    try c.expectRows("SELECT id FROM emp ORDER BY id LIMIT ALL", "1\n2\n3\n4\n");
    try c.expectRows("SELECT id FROM emp ORDER BY id OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY", "2\n3\n");
    try c.expectRows("SELECT id FROM emp ORDER BY id FETCH NEXT ROW ONLY", "1\n");
    try c.expectRows("SELECT id FROM emp ORDER BY id LIMIT 1 FOR UPDATE", "1\n");
    // Set operations: INTERSECT binds tighter than UNION.
    try c.expectRows("SELECT 1 UNION SELECT 2 INTERSECT SELECT 3 ORDER BY 1", "1\n");
    try c.expectRows("SELECT dept FROM emp UNION SELECT id FROM dept ORDER BY 1 NULLS FIRST", "NULL\n1\n2\n3\n");
    try c.expectRows("SELECT 1 UNION ALL SELECT 1", "1\n1\n");
    try c.expectRows("SELECT id FROM dept EXCEPT SELECT dept FROM emp", "3\n");
    try c.expectRows("(SELECT id FROM emp ORDER BY id DESC LIMIT 1) UNION ALL (SELECT id FROM emp ORDER BY id LIMIT 1)", "4\n1\n");
    try c.expectError("SELECT 1 EXCEPT ALL SELECT 2", "EXCEPT ALL is not supported");
    // WITH, recursive or not; VALUES and TABLE as queries.
    try c.expectRows("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 4) SELECT sum(n) FROM r", "10\n");
    try c.expectRows("WITH big AS MATERIALIZED (SELECT * FROM emp WHERE salary >= 80) SELECT count(*) FROM big", "2\n");
    try c.expectRows("VALUES (2, 'b'), (1, 'a') ORDER BY 1", "1|a\n2|b\n");
    try c.expectRows("TABLE dept ORDER BY id DESC LIMIT 1", "3|empty\n");
    // Window functions.
    try c.expectRows("SELECT name, rank() OVER (ORDER BY salary DESC) FROM emp ORDER BY id", "ann|2\nbob|3\ncid|1\ndan|4\n");
    try c.expectRows("SELECT name, sum(salary) OVER w, row_number() OVER w FROM emp WINDOW w AS (PARTITION BY dept ORDER BY id) ORDER BY id", "ann|100|1\nbob|180|2\ncid|NULL|1\ndan|50|1\n");
    try c.expectRows("SELECT id, sum(id) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM emp", "1|1\n2|3\n3|5\n4|7\n");
    try c.expectRows("SELECT id, count(*) OVER (ORDER BY id ROWS UNBOUNDED PRECEDING) FROM emp WHERE id < 3", "1|1\n2|2\n");
    try c.expectError("SELECT DISTINCT ON (dept) name FROM emp", "DISTINCT ON is not supported");
}

test "pg: result column names" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a int, b text)");
    try c.expectColumns("SELECT a, t.b, a + 1, count(*), upper(b), a::text, 1::int, CASE WHEN a > 0 THEN 1 END, EXISTS (SELECT 1), (SELECT b FROM t), true, coalesce(a, 0), a AS \"X\" FROM t", "a|b|?column?|count|upper|a|int4|case|exists|b|bool|coalesce|X");
    try c.expectColumns("SELECT substring(b FROM 1), position('x' IN b), extract(year FROM b), 'x'::varchar, now() FROM t", "substring|position|extract|varchar|now");
    try c.expectColumns("SELECT * FROM (SELECT count(*) FROM t) s", "count");
    try c.expectRows("SELECT count FROM (SELECT count(*) FROM t) s", "0\n");
}

test "pg: expressions and functions" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // Precedence.
    try c.expectRows("SELECT 2 + 3 * 4, (2 + 3) * 4, -2 ^ 2, 2 ^ 3 ^ 2, 1 < 2 = true, 'a' || 'b' = 'ab'", "14|20|4.0|64.0|1|1\n");
    try c.expectRows("SELECT NOT true OR true, NOT (true OR true), 7 / 2, -7 / 2, 7 % 3, 7.0 / 2", "1|0|3|-3|1|3.5\n");
    // Predicates.
    try c.expectRows("SELECT NULL IS NULL, 1 IS NOT NULL, NULL ISNULL, 1 NOTNULL, NULL IS DISTINCT FROM 1, NULL IS NOT DISTINCT FROM NULL", "1|1|1|1|1|1\n");
    try c.expectRows("SELECT true IS TRUE, NULL IS UNKNOWN, false IS NOT TRUE, 2 BETWEEN 1 AND 3, 2 NOT BETWEEN 1 AND 3, 2 IN (1, 2), 2 NOT IN (3)", "1|1|1|1|0|1|1\n");
    // LIKE is case-sensitive, ILIKE is not; \ is the default escape.
    try c.expectRows("SELECT 'abc' LIKE 'a%', 'abc' LIKE 'A%', 'abc' ILIKE 'A%', 'abc' NOT ILIKE 'A_C', 'a%' LIKE 'a\\%', 'ab' LIKE 'a\\%', 'a_' LIKE 'a!_' ESCAPE '!'", "1|0|1|0|1|0|1\n");
    try c.expectRows("SELECT 'abc' ~~ 'a%', 'abc' !~~ 'a%', 'ABC' ~~* 'a%'", "1|0|1\n");
    // CASE, COALESCE, NULLIF, GREATEST/LEAST (which skip NULLs).
    try c.expectRows("SELECT CASE 2 WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'many' END, CASE WHEN false THEN 1 END", "two|NULL\n");
    try c.expectRows("SELECT coalesce(NULL, NULL, 3), nullif(1, 1), nullif(1, 2), greatest(1, NULL, 3), least(NULL, 2, 1), greatest(NULL, NULL)", "3|NULL|1|3|1|NULL\n");
    // Casts.
    try c.expectRows("SELECT '42'::int + 1, CAST('7' AS bigint), 42::text || 'x', 'abcdef'::varchar(3), 'abc'::char(1), 3.14159::numeric(4,2)", "43|7|42x|abc|a|3.14\n");
    try c.expectRows("SELECT 't'::boolean, 'off'::bool, 1::boolean, '2024-03-05'::date, '2024-03-05 10:11:12.5'::timestamp, '10:11'::time", "1|0|1|2024-03-05|2024-03-05 10:11:12|10:11:00\n");
    try c.expectRows("SELECT date '2024-03-05', timestamp '2024-03-05 01:02:03', '\\x0aff'::bytea, '{\"a\": 1}'::jsonb", "2024-03-05|2024-03-05 01:02:03|\n\xff|{\"a\":1}\n");
    try c.expectError("SELECT 'maybe'::boolean", "invalid input syntax for type boolean: \"maybe\"");
    try c.expectError("SELECT 1::nosuchtype", "type \"nosuchtype\" does not exist");
    try c.expectError("SELECT '{1}'::int[]", "arrays are not supported");
    // Strings.
    try c.expectRows("SELECT substring('hello' FROM 2 FOR 3), substring('hello' FROM 3), substring('hello', 2, 2), position('l' IN 'hello'), strpos('hello', 'lo')", "ell|llo|el|3|4\n");
    try c.expectRows("SELECT trim('  x  '), trim(BOTH 'x' FROM 'xxaxx'), trim(LEADING 'x' FROM 'xxa'), trim(TRAILING FROM 'a  '), btrim('xax', 'x'), ltrim('  a'), rtrim('a  ')", "x|a|a|a|a|a|a\n");
    try c.expectRows("SELECT left('hello', 2), left('hello', -2), right('hello', 2), right('hello', -2), length('héllo'), char_length('ab'), octet_length('é')", "he|hel|lo|llo|5|2|2\n");
    try c.expectRows("SELECT concat('a', NULL, 1, true), concat_ws('-', 'a', NULL, 'b'), upper('abc'), lower('ABC'), repeat('ab', 3), reverse('abc')", "a11|a-b|ABC|abc|ababab|cba\n");
    try c.expectRows("SELECT lpad('7', 3, '0'), rpad('ab', 4), split_part('a,b,c', ',', 2), starts_with('hello', 'he'), replace('aXbX', 'X', '-'), ascii('A'), chr(66)", "007|ab  |b|1|a-b-|65|B\n");
    // Numbers.
    try c.expectRows("SELECT abs(-3), round(2.567, 2), floor(-2.5), ceil(2.1), ceiling(2.9), trunc(2.7), sqrt(16), power(2, 10), mod(-7, 3), sign(-4), ln(1), log(100), exp(0)", "3|2.57|-3.0|3.0|3.0|2.0|4.0|1024.0|-1|-1|0.0|2.0|1.0\n");
    try c.expectError("SELECT sqrt(-1)", "cannot take square root of a negative number");
    try c.expectError("SELECT mod(1, 0)", "division by zero");
    try c.expectRows("SELECT random() >= 0 AND random() < 1, length(gen_random_uuid()::text), pi() > 3.14", "1|36|1\n");
    // Dates.
    try c.expectRows("SELECT extract(year FROM date '2024-03-05'), extract(month FROM '2024-03-05'::date), date_part('day', '2024-03-05'), extract(quarter FROM '2024-08-01'), extract(epoch FROM '1970-01-02')", "2024|3|5|3|86400\n");
    try c.expectRows("SELECT now() = current_timestamp, length(now()::text) > 18, current_date = date('now'), now()::date = current_date", "1|1|1|1\n");
    try c.expectRows("SELECT version() LIKE 'PostgreSQL %', current_user, current_database(), current_schema", "1|postgres|main|public\n");
    // JSON operators.
    try c.expectRows("SELECT '{\"a\": {\"b\": 2}}'::json -> 'a' ->> 'b'", "2\n");
}

test "pg: parameters" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    var stmt: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT $2 - $1, $1", &stmt, null));
    defer _ = api.finalize(stmt.?);
    try testing.expectEqual(@as(i32, 2), api.bindParameterCount(stmt.?));
    try testing.expectEqual(RC.OK, api.bindInt64(stmt.?, 1, 10));
    try testing.expectEqual(RC.OK, api.bindInt64(stmt.?, 2, 15));
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqual(@as(i64, 5), api.columnInt64(stmt.?, 0));
    try testing.expectEqual(@as(i64, 10), api.columnInt64(stmt.?, 1));
    try c.expectError("SELECT $0", "there is no parameter $0");
}

test "pg: INSERT, UPDATE, DELETE, RETURNING, ON CONFLICT" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE kv (k text PRIMARY KEY, v int NOT NULL DEFAULT 0, note text)");
    try c.expectRows("INSERT INTO kv (k, v) VALUES ('a', 1), ('b', 2) RETURNING k, v * 10", "a|10\nb|20\n");
    try c.expectRows("INSERT INTO kv VALUES ('c', DEFAULT, 'x') RETURNING *", "c|0|x\n");
    try c.expectRows("INSERT INTO kv (k) VALUES ('d') RETURNING kv.v", "0\n");
    try c.exec("INSERT INTO kv (k, v) SELECT k || '2', v + 100 FROM kv WHERE k < 'c'");
    try c.expectRows("SELECT k, v FROM kv ORDER BY k", "a|1\na2|101\nb|2\nb2|102\nc|0\nd|0\n");
    // ON CONFLICT
    try c.expectRows("INSERT INTO kv (k, v) VALUES ('a', 5) ON CONFLICT (k) DO UPDATE SET v = kv.v + EXCLUDED.v RETURNING v", "6\n");
    try c.expectRows("INSERT INTO kv AS t (k, v) VALUES ('a', 5) ON CONFLICT (k) DO UPDATE SET v = t.v + 1 WHERE t.v < 0 RETURNING v", "");
    try c.expectRows("INSERT INTO kv (k, v) VALUES ('a', 9), ('e', 9) ON CONFLICT DO NOTHING RETURNING k", "e\n");
    try c.expectRows("INSERT INTO kv (k, v) VALUES ('e', 1) ON CONFLICT (k) DO NOTHING RETURNING k", "");
    try c.expectError("INSERT INTO kv (k, v) VALUES ('e', 1) ON CONFLICT DO UPDATE SET v = 2", "ON CONFLICT DO UPDATE requires inference specification or constraint name");
    try c.expectError("INSERT INTO kv (k, v) VALUES ('e', 1)", "UNIQUE constraint failed: kv.k");
    try c.expectError("INSERT INTO kv (k, v) VALUES ('f', NULL)", "NOT NULL constraint failed: kv.v");
    // UPDATE, with FROM and DEFAULT.
    try c.expectRows("UPDATE kv SET v = v + 1, note = 'u' WHERE k IN ('b', 'c') RETURNING k, v, note", "b|3|u\nc|1|u\n");
    try c.exec("CREATE TABLE bonus (k text, amount int); INSERT INTO bonus VALUES ('a', 1000)");
    try c.expectRows("UPDATE kv SET v = kv.v + b.amount FROM bonus b WHERE b.k = kv.k RETURNING kv.k, kv.v", "a|1006\n");
    try c.expectRows("UPDATE kv AS t SET (v, note) = (7, 'pair') WHERE t.k = 'd' RETURNING t.*", "d|7|pair\n");
    try c.expectRows("UPDATE kv SET v = DEFAULT WHERE k = 'd' RETURNING v", "0\n");
    // DELETE, with USING.
    try c.expectRows("DELETE FROM kv WHERE k LIKE '%2' RETURNING k", "a2\nb2\n");
    try c.expectRows("DELETE FROM kv k USING bonus b WHERE b.k = k.k RETURNING k.k, k.v", "a|1006\n");
    try c.expectRows("SELECT k FROM kv ORDER BY k", "b\nc\nd\ne\n");
    try c.exec("TRUNCATE TABLE kv");
    try c.expectRows("SELECT count(*) FROM kv", "0\n");
    // WITH before DML.
    try c.exec("WITH src(k) AS (VALUES ('w1'), ('w2')) INSERT INTO kv (k) SELECT k FROM src");
    try c.exec("WITH old AS (SELECT 'w1' AS k) DELETE FROM kv WHERE k IN (SELECT k FROM old)");
    try c.expectRows("SELECT k FROM kv", "w2\n");
    try c.expectError("INSERT INTO nosuch VALUES (1)", "relation \"nosuch\" does not exist");
    try c.expectError("UPDATE kv SET nosuch = 1", "column \"nosuch\" does not exist");
}

test "pg: transactions and savepoints" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (x int)");
    try c.exec("BEGIN; INSERT INTO t VALUES (1); COMMIT");
    try c.exec("BEGIN WORK; INSERT INTO t VALUES (2); ROLLBACK WORK");
    try c.exec("START TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ WRITE; INSERT INTO t VALUES (3); END");
    try c.exec("BEGIN TRANSACTION; INSERT INTO t VALUES (4); SAVEPOINT s; INSERT INTO t VALUES (5); ROLLBACK TO SAVEPOINT s; INSERT INTO t VALUES (6); RELEASE SAVEPOINT s; COMMIT TRANSACTION");
    try c.exec("BEGIN; INSERT INTO t VALUES (7); SAVEPOINT a; INSERT INTO t VALUES (8); RELEASE a; ABORT");
    try c.expectRows("SELECT x FROM t ORDER BY x", "1\n3\n4\n6\n");
    try c.expectError("COMMIT AND CHAIN", "AND CHAIN is not supported");
}

test "pg: types are strict" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE ty (
        \\  i2 smallint, i4 integer, i8 bigint, r real, d double precision, n numeric(6,2),
        \\  b boolean, t text, vc varchar(3), ch char(2), by bytea,
        \\  dt date, ts timestamp, tz timestamptz, tm time, u uuid, j jsonb)
    );
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 'ty'",
        \\CREATE TABLE "ty"("i2" INTEGER CONSTRAINT "smallint out of range" CHECK(("i2" BETWEEN -32768 AND 32767)), "i4" INTEGER CONSTRAINT "integer out of range" CHECK(("i4" BETWEEN -2147483648 AND 2147483647)), "i8" INTEGER, "r" REAL, "d" REAL, "n" ANY CONSTRAINT "invalid input syntax for type numeric" CHECK((typeof("n") IN ('integer', 'real', 'null'))), "b" INTEGER CONSTRAINT "invalid input syntax for type boolean" CHECK(("b" IN (0, 1))), "t" TEXT, "vc" TEXT CONSTRAINT "value too long for type character varying(3)" CHECK((length("vc") <= 3)), "ch" TEXT CONSTRAINT "value too long for type character(2)" CHECK((length("ch") <= 2)), "by" BLOB, "dt" TEXT, "ts" TEXT, "tz" TEXT, "tm" TEXT, "u" TEXT, "j" TEXT CONSTRAINT "invalid input syntax for type json" CHECK(json_valid("j"))) STRICT
        \\
    );
    try c.expectRows("SELECT col, value FROM xq_catalog WHERE tbl = 'ty' AND key = 'type' ORDER BY col",
        \\b|boolean
        \\by|bytea
        \\ch|character(2)
        \\d|double precision
        \\dt|date
        \\i2|smallint
        \\i4|integer
        \\i8|bigint
        \\j|jsonb
        \\n|numeric(6,2)
        \\r|real
        \\t|text
        \\tm|time without time zone
        \\ts|timestamp without time zone
        \\tz|timestamp with time zone
        \\u|uuid
        \\vc|character varying(3)
        \\
    );
    try c.exec("INSERT INTO ty (i2, i4, i8, r, n, b, vc, j) VALUES (1, '2', 3, 4, 5.25, true, 'abc', '{}')");
    try c.exec("INSERT INTO ty (n) VALUES ('1.5'), ('7')");
    try c.expectRows("SELECT i2, i4, r, n, b, vc FROM ty WHERE i2 = 1", "1|2|4.0|5.25|1|abc\n");
    try c.expectRows("SELECT n, typeof(n) FROM ty WHERE i2 IS NULL ORDER BY n", "1.5|real\n7|integer\n");
    try c.expectError("INSERT INTO ty (i4) VALUES ('x')", "cannot store TEXT value in INTEGER column ty.i4");
    try c.expectError("INSERT INTO ty (i4) VALUES (1.5)", "cannot store REAL value in INTEGER column ty.i4");
    try c.expectError("INSERT INTO ty (i2) VALUES (40000)", "CHECK constraint failed: smallint out of range");
    try c.expectError("INSERT INTO ty (i4) VALUES (3000000000)", "CHECK constraint failed: integer out of range");
    try c.expectError("INSERT INTO ty (vc) VALUES ('abcd')", "CHECK constraint failed: value too long for type character varying(3)");
    try c.expectError("INSERT INTO ty (b) VALUES (2)", "CHECK constraint failed: invalid input syntax for type boolean");
    try c.expectError("INSERT INTO ty (j) VALUES ('{')", "CHECK constraint failed: invalid input syntax for type json");
    try c.expectError("INSERT INTO ty (n) VALUES ('abc')", "CHECK constraint failed: invalid input syntax for type numeric");
    try c.expectError("INSERT INTO ty (by) VALUES (1)", "cannot store INT value in BLOB column ty.by");
    try c.expectError("CREATE TABLE bad (x nosuchtype)", "type \"nosuchtype\" does not exist");
    try c.expectError("CREATE TABLE bad (x int[])", "arrays are not supported");
    try c.expectError("CREATE TABLE bad (x int, x text)", "column \"x\" specified more than once");
}

test "pg: SERIAL and IDENTITY" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE s (id serial PRIMARY KEY, v text)");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 's'",
        \\CREATE TABLE "s"("id" INTEGER NOT NULL DEFAULT (nextval('s_id_seq')) PRIMARY KEY CONSTRAINT "integer out of range" CHECK(("id" BETWEEN -2147483648 AND 2147483647)), "v" TEXT) STRICT
        \\
    );
    try c.expectRows("SELECT name, start_value, max_value FROM xq_sequence", "s_id_seq|1|2147483647\n");
    try c.expectRows("INSERT INTO s (v) VALUES ('a'), ('b') RETURNING id", "1\n2\n");
    try c.expectRows("INSERT INTO s VALUES (DEFAULT, 'c') RETURNING id", "3\n");
    try c.expectRows("INSERT INTO s (id, v) VALUES (10, 'd') RETURNING id", "10\n");
    // The sequence numbers the rows, whatever the rowid: as in
    // PostgreSQL, 10 does not move it.
    try c.expectRows("INSERT INTO s (v) SELECT 'e' RETURNING id", "4\n");
    try c.expectRows("INSERT INTO s DEFAULT VALUES RETURNING id, v", "5|NULL\n");
    try c.expectRows("SELECT currval('s_id_seq'), lastval()", "5|5\n");
    try c.expectError("INSERT INTO s (id, v) VALUES (4, 'dup')", "UNIQUE constraint failed: s.id");

    // bigserial that is not the key; GENERATED ... AS IDENTITY.
    try c.exec(
        \\CREATE TABLE g (
        \\  id bigint GENERATED ALWAYS AS IDENTITY (START WITH 100 INCREMENT BY 10) PRIMARY KEY,
        \\  n bigserial, k int GENERATED BY DEFAULT AS IDENTITY, v text)
    );
    try c.expectRows("SELECT tbl, col, key, value FROM xq_catalog WHERE tbl = 'g' AND key LIKE 'identity%' ORDER BY col, key",
        \\g|id|identity|g_id_seq
        \\g|id|identity_kind|always
        \\g|k|identity|g_k_seq
        \\g|k|identity_kind|by default
        \\g|n|identity|g_n_seq
        \\
    );
    try c.expectRows("INSERT INTO g (v) VALUES ('a'), ('b') RETURNING id, n, k", "100|1|1\n110|2|2\n");
    try c.expectRows("INSERT INTO g (k, v) VALUES (50, 'c') RETURNING id, n, k", "120|3|50\n");
    try c.expectError("INSERT INTO g (id, v) VALUES (1, 'x')", "cannot insert a non-DEFAULT value into column \"id\"");
    try c.expectError("UPDATE g SET id = 1", "column \"id\" can only be updated to DEFAULT");
    try c.expectRows("INSERT INTO g (id, v) OVERRIDING SYSTEM VALUE VALUES (1, 'x') RETURNING id", "1\n");
    try c.expectRows("INSERT INTO g (id, v) VALUES (DEFAULT, 'y') RETURNING id", "130\n");
    try c.expectRows("SELECT table_name, column_name, data_type, is_identity, identity_generation FROM information_schema.columns WHERE table_name = 'g' ORDER BY ordinal_position",
        \\g|id|bigint|YES|ALWAYS
        \\g|n|bigint|NO|NULL
        \\g|k|integer|YES|BY DEFAULT
        \\g|v|text|NO|NULL
        \\
    );
    // TRUNCATE ... RESTART IDENTITY; DROP TABLE drops the sequences.
    try c.exec("TRUNCATE g RESTART IDENTITY");
    try c.expectRows("INSERT INTO g (v) VALUES ('z') RETURNING id, n", "100|1\n");
    try c.exec("DROP TABLE g");
    try c.expectRows("SELECT name FROM xq_sequence", "s_id_seq\n");
    try c.expectRows("SELECT count(*) FROM xq_catalog WHERE tbl = 'g'", "0\n");
    try c.expectError("CREATE TABLE bad (id serial GENERATED ALWAYS AS IDENTITY)", "multiple default values specified for column \"id\" of table \"bad\"");
    try c.expectError("CREATE TABLE bad (id text GENERATED ALWAYS AS IDENTITY)", "identity column type must be smallint, integer, or bigint");
}

test "pg: sequences" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE SEQUENCE seq START WITH 5 INCREMENT BY 5 MAXVALUE 15");
    try c.expectRows("SELECT nextval('seq'), nextval('seq'), currval('seq')", "5|10|10\n");
    try c.expectRows("SELECT nextval('seq')", "15\n");
    try c.expectError("SELECT nextval('seq')", "nextval: reached maximum value of sequence \"seq\" (15)");
    try c.exec("CREATE SEQUENCE IF NOT EXISTS seq");
    try c.expectError("CREATE SEQUENCE seq", "relation \"seq\" already exists");
    try c.exec("CREATE SEQUENCE down INCREMENT -1 MINVALUE -3 MAXVALUE -1 CYCLE");
    try c.expectRows("SELECT nextval('down'), nextval('down'), nextval('down'), nextval('down')", "-1|-2|-3|-1\n");
    try c.expectError("CREATE SEQUENCE zero INCREMENT BY 0", "INCREMENT must not be zero");
    try c.exec("DROP SEQUENCE seq");
    try c.exec("DROP SEQUENCE IF EXISTS seq");
    try c.expectError("DROP SEQUENCE seq", "sequence \"seq\" does not exist");
    try c.expectError("SELECT nextval('seq')", "relation \"seq\" does not exist");
    try c.expectRows("SELECT sequence_name, start_value, increment, cycle_option FROM information_schema.sequences", "down|-1|-1|YES\n");
}

test "pg: DDL" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE parent (id int PRIMARY KEY, code text UNIQUE NOT NULL);
        \\CREATE TABLE IF NOT EXISTS child (
        \\  id int,
        \\  parent_id int REFERENCES parent (id) ON DELETE CASCADE,
        \\  qty int CHECK (qty > 0) DEFAULT 1,
        \\  label text COLLATE "C",
        \\  total int GENERATED ALWAYS AS (qty * 2) STORED,
        \\  CONSTRAINT child_pk PRIMARY KEY (id),
        \\  UNIQUE (parent_id, label),
        \\  CHECK (id > 0)
        \\);
    );
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 'child'",
        \\CREATE TABLE "child"("id" INTEGER CONSTRAINT "integer out of range" CHECK(("id" BETWEEN -2147483648 AND 2147483647)), "parent_id" INTEGER REFERENCES "parent"("id") ON DELETE CASCADE CONSTRAINT "integer out of range" CHECK(("parent_id" BETWEEN -2147483648 AND 2147483647)), "qty" INTEGER CONSTRAINT "child_qty_check" CHECK(("qty" > 0)) DEFAULT (1) CONSTRAINT "integer out of range" CHECK(("qty" BETWEEN -2147483648 AND 2147483647)), "label" TEXT COLLATE BINARY, "total" INTEGER GENERATED ALWAYS AS (("qty" * 2)) STORED CONSTRAINT "integer out of range" CHECK(("total" BETWEEN -2147483648 AND 2147483647)), CONSTRAINT "child_pk" PRIMARY KEY("id"), UNIQUE("parent_id", "label"), CONSTRAINT "child_check" CHECK(("id" > 0))) STRICT
        \\
    );
    try c.exec("CREATE TABLE IF NOT EXISTS child (x int)");
    try c.expectError("CREATE TABLE child (x int)", "relation \"child\" already exists");
    try c.exec("INSERT INTO parent VALUES (1, 'p'); INSERT INTO child (id, parent_id, label) VALUES (1, 1, 'a')");
    try c.expectRows("SELECT qty, total FROM child", "1|2\n");
    try c.expectError("INSERT INTO child (id, qty) VALUES (2, 0)", "CHECK constraint failed: child_qty_check");
    try c.expectError("INSERT INTO child (id) VALUES (-1)", "CHECK constraint failed: child_check");
    // Indexes: PostgreSQL's names when none is given.
    try c.exec("CREATE INDEX ON child (qty); CREATE INDEX ON child (qty); CREATE UNIQUE INDEX IF NOT EXISTS lbl ON child (lower(label)) WHERE label IS NOT NULL");
    try c.exec("CREATE INDEX CONCURRENTLY child_lbl_desc ON child USING btree (label DESC NULLS LAST)");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE type = 'index' AND sql IS NOT NULL ORDER BY name", "child_lbl_desc\nchild_qty_idx\nchild_qty_idx1\nlbl\n");
    try c.exec("DROP INDEX child_qty_idx1; DROP INDEX IF EXISTS nosuch");
    try c.expectError("DROP INDEX nosuch", "index \"nosuch\" does not exist");
    try c.expectError("CREATE INDEX x ON child USING gin (label)", "index method \"gin\" is not supported");
    // ALTER TABLE.
    try c.exec("ALTER TABLE child ADD COLUMN note varchar(5)");
    try c.exec("ALTER TABLE child ADD COLUMN IF NOT EXISTS note text");
    try c.exec("ALTER TABLE child RENAME COLUMN note TO memo");
    try c.expectError("INSERT INTO child (id, memo) VALUES (3, 'toolong')", "CHECK constraint failed: value too long for type character varying(5)");
    try c.exec("ALTER TABLE child RENAME TO kid");
    try c.expectRows("SELECT col, value FROM xq_catalog WHERE tbl = 'kid' AND key = 'type' AND col IN ('memo', 'qty') ORDER BY col", "memo|character varying(5)\nqty|integer\n");
    try c.exec("ALTER TABLE kid DROP COLUMN memo; ALTER TABLE kid DROP COLUMN IF EXISTS memo");
    try c.expectRows("SELECT count(*) FROM xq_catalog WHERE tbl = 'kid' AND col = 'memo'", "0\n");
    try c.expectError("ALTER TABLE nosuch RENAME TO x", "relation \"nosuch\" does not exist");
    try c.exec("ALTER TABLE IF EXISTS nosuch RENAME TO x");
    // Views.
    try c.exec("CREATE VIEW v AS SELECT id, qty * 10, upper(label) FROM kid WHERE label ILIKE 'A%' ORDER BY id");
    try c.expectColumns("SELECT * FROM v", "id|?column?|upper");
    try c.expectRows("SELECT * FROM v", "1|10|A\n");
    try c.exec("CREATE OR REPLACE VIEW v (a, b) AS SELECT 1, 2");
    try c.expectRows("SELECT a, b FROM v", "1|2\n");
    try c.exec("CREATE OR REPLACE VIEW w AS SELECT code FROM parent");
    try c.expectRows("SELECT * FROM w", "p\n");
    try c.exec("DROP VIEW w; DROP VIEW IF EXISTS w");
    try c.expectError("DROP VIEW w", "view \"w\" does not exist");
    // CREATE TABLE AS, DROP TABLE.
    try c.exec("CREATE TABLE copy AS SELECT id, label FROM kid");
    try c.expectRows("SELECT * FROM copy", "1|a\n");
    try c.exec("DROP TABLE copy; DROP TABLE IF EXISTS copy CASCADE");
    try c.expectError("DROP TABLE copy", "table \"copy\" does not exist");
    try c.expectError("DROP TABLE kid, parent", "dropping several objects in one statement is not supported");
    try c.exec("PRAGMA integrity_check");
}

test "pg: information_schema and pg_catalog" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // Without a catalog yet (only SQLite-dialect tables).
    main_mod.setDialect(c.db, .sqlite);
    try c.exec("CREATE TABLE lite (a INTEGER, b TEXT, c)");
    main_mod.setDialect(c.db, .postgres);
    try c.expectRows("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'lite'", "a|bigint\nb|text\nc|text\n");
    try c.exec("CREATE TABLE person (id serial PRIMARY KEY, name varchar(40) NOT NULL, born date, score numeric(5,1))");
    try c.exec("CREATE VIEW adults AS SELECT name FROM person");
    try c.exec("CREATE INDEX person_name_idx ON person (name)");
    try c.expectRows("SELECT table_name, table_type FROM information_schema.tables ORDER BY table_name", "adults|VIEW\nlite|BASE TABLE\nperson|BASE TABLE\n");
    try c.expectRows(
        \\SELECT column_name, ordinal_position, is_nullable, data_type, character_maximum_length, numeric_precision, numeric_scale, udt_name, column_default
        \\FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'person' ORDER BY ordinal_position
    ,
        \\id|1|NO|integer|NULL|32|0|int4|nextval('person_id_seq')
        \\name|2|NO|character varying|40|NULL|NULL|varchar|NULL
        \\born|3|YES|date|NULL|NULL|NULL|date|NULL
        \\score|4|YES|numeric|NULL|5|1|numeric|NULL
        \\
    );
    try c.expectRows("SELECT c.table_name, count(*) FROM information_schema.tables t JOIN information_schema.columns c ON c.table_name = t.table_name GROUP BY 1 ORDER BY 1", "adults|1\nlite|3\nperson|4\n");
    try c.expectRows("SELECT schemaname, tablename, hasindexes FROM pg_catalog.pg_tables ORDER BY 2", "public|lite|0\npublic|person|1\n");
    try c.expectRows("SELECT tablename FROM pg_tables WHERE tablename LIKE 'p%'", "person\n");
    try c.expectRows("SELECT viewname FROM pg_views", "adults\n");
    try c.expectRows("SELECT indexname, indexdef FROM pg_indexes", "person_name_idx|CREATE INDEX \"person_name_idx\" ON \"person\"(\"name\")\n");
    try c.expectRows("SELECT sequencename, last_value FROM pg_sequences", "person_id_seq|NULL\n");
    try c.expectRows("SELECT schema_name FROM information_schema.schemata ORDER BY 1", "information_schema\npg_catalog\npublic\n");
    try c.expectError("SELECT * FROM information_schema.nosuch", "relation \"information_schema.nosuch\" does not exist");
    // A view over the catalog is stored as SQLite text.
    try c.exec("CREATE VIEW cols AS SELECT table_name, column_name FROM information_schema.columns WHERE table_name = 'person'");
    try c.expectRows("SELECT count(*) FROM cols", "4\n");
    // A table of that name wins over pg_catalog's view, as on the path.
    try c.exec("CREATE TABLE pg_views (x int)");
    try c.expectRows("SELECT count(*) FROM pg_views", "0\n");
    // public is main.
    try c.expectRows("SELECT count(*) FROM public.person", "0\n");
    try c.expectError("SELECT * FROM nosuchschema.person", "schema \"nosuchschema\" does not exist");
}

test "pg: errors in PostgreSQL's words" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a int, b int); CREATE TABLE u (a int)");
    try c.expectError("SELECT * FROM nosuch", "relation \"nosuch\" does not exist");
    try c.expectError("SELECT nosuch FROM t", "column \"nosuch\" does not exist");
    try c.expectError("SELECT a FROM t, u", "column reference \"a\" is ambiguous");
    try c.expectError("SELECT nosuchfunc(1)", "function nosuchfunc() does not exist");
    try c.expectError("CREATE TABLE t (x int)", "relation \"t\" already exists");
    try c.expectError("SELECT 1 FROM t WHERE", "syntax error at end of input");
    try c.expectError("SELECT a b c FROM t", "syntax error at or near \"c\"");
    try c.expectError("SELECT ARRAY[1]", "ARRAY is not supported");
    try c.expectError("SELECT 1 FROM t LATERAL", "syntax error at or near \"LATERAL\"");
    try c.expectError("CREATE TYPE mood AS ENUM ('a')", "CREATE TYPE is not supported");
    try c.expectError("LISTEN chan", "syntax error at or near \"LISTEN\"");
    try c.expectError("SELECT 1 # 2", "operator does not exist: #");
}

test "pg: SQLite's administrative statements; the same code as SQLite" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a int, b text); CREATE INDEX t_a ON t (a)");
    try c.expectRows("PRAGMA table_info(t)", "0|a|INTEGER|0|NULL|0\n1|b|TEXT|0|NULL|0\n");
    // EXPLAIN is SQLite's EXPLAIN QUERY PLAN.
    const plan = try c.query("EXPLAIN SELECT b FROM t WHERE a = 1");
    defer testing.allocator.free(plan);
    try testing.expect(std.mem.endsWith(u8, plan, "|SEARCH t USING INDEX t_a (a=?)\n"));
    // Without PostgreSQL-specific semantics, a query lowers to SQLite's
    // own tree, so to the same bytecode.
    try expectSameCode(&c, "SELECT b, count(*) FROM t WHERE a > $1 GROUP BY b HAVING count(*) > 1", "SELECT b, count(*) FROM t WHERE a > ?1 GROUP BY b HAVING count(*) > 1");
    try expectSameCode(&c, "SELECT x.a FROM t x JOIN t y ON x.a = y.a LEFT JOIN t z USING (b) WHERE x.b IN ('p', 'q') LIMIT 5 OFFSET 1", "SELECT x.a FROM t x JOIN t y ON x.a = y.a LEFT JOIN t z USING (b) WHERE x.b IN ('p', 'q') LIMIT 5 OFFSET 1");
    try expectSameCode(&c, "WITH w AS (SELECT a FROM t) SELECT a FROM w UNION ALL SELECT a + 1 FROM t", "WITH w AS (SELECT a FROM t) SELECT a FROM w UNION ALL SELECT a + 1 AS \"?column?\" FROM t");
    try expectSameCode(&c, "INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y') ON CONFLICT DO NOTHING", "INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y') ON CONFLICT DO NOTHING");
    try expectSameCode(&c, "UPDATE t SET b = 'z' WHERE a = 1 RETURNING a", "UPDATE t SET b = 'z' WHERE a = 1 RETURNING a");
    try expectSameCode(&c, "DELETE FROM t WHERE b IS NULL", "DELETE FROM t WHERE b IS NULL");
    try expectSameCode(&c, "SELECT a FROM t ORDER BY a NULLS FIRST", "SELECT a FROM t ORDER BY a");
    // A key or NOT NULL column needs no NULLS LAST (an index gives the
    // order), unless the name is an alias of a result column.
    try c.exec("CREATE TABLE k (id int PRIMARY KEY, n int NOT NULL, m int)");
    try expectSameCode(&c, "SELECT id FROM k ORDER BY id", "SELECT id FROM k ORDER BY id");
    try expectSameCode(&c, "SELECT k.n FROM k ORDER BY k.n, m DESC", "SELECT k.n FROM k ORDER BY k.n, m DESC NULLS FIRST");
    try expectSameCode(&c, "SELECT m FROM k ORDER BY m", "SELECT m FROM k ORDER BY m NULLS LAST");
    try expectSameCode(&c, "SELECT x.id FROM k LEFT JOIN k x ON x.n = k.id ORDER BY x.id", "SELECT x.id FROM k LEFT JOIN k x ON x.n = k.id ORDER BY x.id NULLS LAST");
    try c.exec("INSERT INTO k VALUES (1, 1, NULL), (2, 2, 5)");
    try c.expectRows("SELECT m AS id FROM k ORDER BY id", "5\nNULL\n");
    // Back to SQLite.
    try c.exec("PRAGMA xq_dialect = 'sqlite'");
    try c.expectRows("SELECT 'a' LIKE 'A'", "1\n");
}

test "pg: a database written in the dialect" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE app_user (id bigserial PRIMARY KEY, email varchar(100) UNIQUE NOT NULL, active boolean NOT NULL DEFAULT true, created_at timestamptz DEFAULT now());
        \\INSERT INTO app_user (email) VALUES ('a@x'), ('b@x');
    );
    // Read back by a new connection (the SQLite schema, the catalog).
    try c.reopen();
    main_mod.setDialect(c.db, .postgres);
    try c.expectRows("SELECT id, email, active, created_at IS NOT NULL FROM app_user ORDER BY id", "1|a@x|1|1\n2|b@x|1|1\n");
    try c.expectRows("INSERT INTO app_user (email, active) VALUES ('c@x', false) RETURNING id, active", "3|0\n");
    try c.expectRows("SELECT data_type FROM information_schema.columns WHERE column_name = 'created_at'", "timestamp with time zone\n");
    try c.exec("PRAGMA integrity_check");
}
