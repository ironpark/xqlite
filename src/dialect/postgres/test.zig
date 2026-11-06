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
        // A constraint's halt differs only in its error, PostgreSQL's
        // (P4, and P3 and P5 that say where the key's values are).
        if (o.p5 & vi.P5_ConstraintDialect != 0 and (o.opcode == .Halt or o.opcode == .HaltIfNull)) continue;
        try testing.expectEqual(q.p3, o.p3);
        // Arithmetic of an integer: P5 the width PostgreSQL checks.
        switch (o.opcode) {
            .Add, .Subtract, .Multiply, .Divide, .Remainder => if (q.p5 == 0 and o.p5 != 0) continue,
            else => {},
        }
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
    // avg() of integers is a numeric (a key: its text shown).
    try c.expectRows("SELECT dept, count(*), sum(salary), avg(salary)::text FROM emp GROUP BY dept HAVING count(*) > 1", "1|2|180|90.0000000000000000\n");
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
    try c.expectRows("SELECT NOT true OR true, NOT (true OR true), 7 / 2, -7 / 2, 7 % 3, (7.0 / 2)::text", "1|0|3|-3|1|3.5000000000000000\n");
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
    try c.expectRows("SELECT '42'::int + 1, CAST('7' AS bigint), 42::text || 'x', 'abcdef'::varchar(3), 'abc'::char(1), 3.14159::numeric(4,2)::text", "43|7|42x|abc|a|3.14\n");
    try c.expectRows("SELECT 't'::boolean, 'off'::bool, 1::boolean, '2024-03-05'::date, '2024-03-05 10:11:12.5'::timestamp, '10:11'::time", "1|0|1|2024-03-05|2024-03-05 10:11:12.5|10:11:00\n");
    try c.expectRows("SELECT date '2024-03-05', timestamp '2024-03-05 01:02:03', '\\x0aff'::bytea, '{\"a\":1}'::jsonb", "2024-03-05|2024-03-05 01:02:03|\n\xff|{\"a\": 1}\n");
    try c.expectError("SELECT 'maybe'::boolean", "invalid input syntax for type boolean: \"maybe\"");
    try c.expectError("SELECT 1::nosuchtype", "type \"nosuchtype\" does not exist");
    try c.expectError("SELECT '{1}'::date[]", "invalid input syntax for type date: \"1\"");
    // Strings.
    try c.expectRows("SELECT substring('hello' FROM 2 FOR 3), substring('hello' FROM 3), substring('hello', 2, 2), position('l' IN 'hello'), strpos('hello', 'lo')", "ell|llo|el|3|4\n");
    try c.expectRows("SELECT trim('  x  '), trim(BOTH 'x' FROM 'xxaxx'), trim(LEADING 'x' FROM 'xxa'), trim(TRAILING FROM 'a  '), btrim('xax', 'x'), ltrim('  a'), rtrim('a  ')", "x|a|a|a|a|a|a\n");
    try c.expectRows("SELECT left('hello', 2), left('hello', -2), right('hello', 2), right('hello', -2), length('héllo'), char_length('ab'), octet_length('é')", "he|hel|lo|llo|5|2|2\n");
    try c.expectRows("SELECT concat('a', NULL, 1, true), concat_ws('-', 'a', NULL, 'b'), upper('abc'), lower('ABC'), repeat('ab', 3), reverse('abc')", "a11|a-b|ABC|abc|ababab|cba\n");
    try c.expectRows("SELECT lpad('7', 3, '0'), rpad('ab', 4), split_part('a,b,c', ',', 2), starts_with('hello', 'he'), replace('aXbX', 'X', '-'), ascii('A'), chr(66)", "007|ab  |b|1|a-b-|65|B\n");
    // Numbers.
    try c.expectRows("SELECT abs(-3), round(2.567, 2)::text, floor(-2.5)::text, ceil(2.1)::text, ceiling(2.9)::text, trunc(2.7)::text, sqrt(16), power(2, 10), mod(-7, 3), sign(-4), ln(1), log(100), exp(0)", "3|2.57|-3|3|3|2|4.0|1024.0|-1|-1|0.0|2.0|1.0\n");
    try c.expectError("SELECT sqrt(-1)", "cannot take square root of a negative number");
    // numeric's (pkg/decimal/src/math.zig): PostgreSQL's digits and scale.
    try c.expectRows("SELECT sqrt(2.0)::text, exp(1.0)::text, ln(2.0)::text, log(2, 8)::text, (2::numeric ^ 0.5)::text, factorial(5)::text, width_bucket(5.35, 0.024, 10.06, 5)", "1.414213562373095|2.7182818284590452|0.6931471805599453|3.0000000000000000|1.4142135623730950|120|3\n");
    try c.expectError("SELECT ln(0.0)", "cannot take logarithm of zero");
    try c.expectError("SELECT mod(1, 0)", "division by zero");
    try c.expectRows("SELECT random() >= 0 AND random() < 1, length(gen_random_uuid()::text), pi() > 3.14", "1|36|1\n");
    // Dates.
    try c.expectRows("SELECT extract(year FROM date '2024-03-05'), extract(month FROM '2024-03-05'::date), date_part('day', '2024-03-05'), extract(quarter FROM '2024-08-01'), extract(epoch FROM '1970-01-02')", "2024|3|5|3|86400\n");
    try c.expectRows("SELECT now() = current_timestamp, length(now()::text) > 18, current_date = date('now'), now()::date = current_date", "1|1|1|1\n");
    try c.expectRows("SELECT version() LIKE 'PostgreSQL %', current_user, current_database(), current_schema", "1|postgres|postgres|public\n");
    // JSON operators.
    try c.expectRows("SELECT '{\"a\": {\"b\": 2}}'::json -> 'a' ->> 'b'", "2\n");
}

test "pg: intervals are BLOBs, an older database's TEXT" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE iv (id int, v interval DEFAULT '2 hours')");
    try c.exec("INSERT INTO iv VALUES (1, '1 mon'), (2, '30 days'), (3, '1 day'), (4, '-1 day'), (5, 'infinity'), (6, NULL)");
    try c.exec("INSERT INTO iv (id) VALUES (7)");
    try c.expectRows("SELECT typeof(v), length(v), v::text FROM iv WHERE id IN (1, 7) ORDER BY id", "blob|32|1 mon\nblob|32|02:00:00\n");
    try c.expectError("INSERT INTO iv VALUES (8, 'soon')", "invalid input syntax for type interval: \"soon\"");
    // '1 mon' = '30 days' (PostgreSQL's), other values: they compute
    // differently.
    try c.expectRows("SELECT a.id, b.id FROM iv a JOIN iv b ON a.v = b.v AND a.id < b.id", "1|2\n");
    try c.expectRows("SELECT (date '2024-02-01' + v)::text FROM iv WHERE id IN (1, 2) ORDER BY id", "2024-03-01 00:00:00\n2024-03-02 00:00:00\n");
    try c.expectRows("SELECT min(id), count(*) FROM iv GROUP BY v ORDER BY 1", "1|2\n3|1\n4|1\n5|1\n6|1\n7|1\n");
    try c.expectRows("SELECT count(*) FROM (SELECT DISTINCT v FROM iv) AS d", "6\n");
    try c.expectRows("SELECT id FROM iv WHERE v > '29 days' ORDER BY v, id", "1\n2\n5\n");
    try c.expectRows("SELECT id FROM iv WHERE v IN ('720 hours', '1 day') ORDER BY id", "1\n2\n3\n");
    try c.expectRows("SELECT sum(v)::text, avg(v)::text FROM iv WHERE id < 5", "1 mon 30 days|15 days\n");
    try c.expectRows("SELECT sum(v)::text FROM iv", "infinity\n");
    try c.expectRows("SELECT justify_days(sum(v))::text, isfinite(max(v)) FROM iv WHERE id < 5", "2 mons|1\n");
    // An index orders the BLOBs; SQLite's dialect reads the view (its
    // comparison calls engine functions).
    try c.exec("CREATE INDEX iv_v ON iv (v)");
    try c.exec("CREATE VIEW iv_short AS SELECT id FROM iv WHERE v < '1 week' AND v <> '-1 day'");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT id FROM iv_short ORDER BY id", "3\n7\n");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
    try c.expectRows("SELECT xq_pg_iv_text(v) FROM iv INDEXED BY iv_v WHERE v >= xq_pg_iv_key('1 day') AND v <= xq_pg_iv_high('30 days') ORDER BY v", "1 day\n30 days\n1 mon\n");
    // An older database: its interval column is TEXT, and stays it.
    try c.exec("INSERT INTO xq_catalog VALUES ('old', '', 'dialect', 'postgres'), ('old', 'id', 'type', 'integer'), ('old', 'v', 'type', 'interval')");
    try c.exec("CREATE TABLE old (id INTEGER, v TEXT) STRICT");
    main_mod.setDialect(c.db, .postgres);
    try c.exec("INSERT INTO old VALUES (1, '1 mon'), (2, interval '30 days'), (3, '25 hours'), (4, (SELECT v FROM iv WHERE id = 3))");
    try c.expectError("INSERT INTO old VALUES (5, 'infinity')", "interval out of range");
    try c.expectRows("SELECT typeof(v), v FROM old ORDER BY v, id", "text|1 day\ntext|25:00:00\ntext|1 mon\ntext|30 days\n");
    try c.expectRows("SELECT o.id, i.id FROM old o JOIN iv i ON o.v = i.v ORDER BY 1, 2", "1|1\n1|2\n2|1\n2|2\n4|3\n");
    try c.expectRows("SELECT (v + interval '1 hour')::text FROM old WHERE id = 3", "26:00:00\n");
    try c.exec("UPDATE old SET v = v * 2 WHERE id = 3");
    try c.expectRows("SELECT v FROM old WHERE id = 3", "50:00:00\n");
}

test "pg: IntervalStyle changes the text of intervals, not what is stored" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE iv (id int, v interval, a interval[])");
    try c.exec("INSERT INTO iv VALUES (1, '1 day 2 hours', ARRAY[interval '1 day'])");
    try c.exec("CREATE VIEW iv_text AS SELECT v::text AS t FROM iv");
    try c.exec("SET IntervalStyle = iso_8601");
    try c.expectRows("SHOW IntervalStyle", "iso_8601\n");
    try c.expectRows("SELECT v::text, v || '', a, t, to_json(v) FROM iv, iv_text", "P1DT2H|P1DT2H|{\"1 day\"}|P1DT2H|\"P1DT2H\"\n");
    try c.exec("INSERT INTO iv VALUES (2, 'P1DT2H', ARRAY[interval 'PT1H'])");
    try c.exec("SET IntervalStyle = 'SQL_Standard'");
    try c.expectRows("SELECT v::text FROM iv ORDER BY id", "1 2:00:00\n1 2:00:00\n");
    // The leading sign of sql_standard's input, in a cast and stored.
    try c.exec("INSERT INTO iv VALUES (3, '-1 2:00', NULL)");
    try c.expectRows("SELECT interval '-1 2:00' = v, '-1 2:00'::text::interval = v FROM iv WHERE id = 3", "1|1\n");
    try c.exec("RESET IntervalStyle");
    try c.expectRows("SELECT v::text, a::text FROM iv ORDER BY id", "1 day 02:00:00|{\"1 day\"}\n1 day 02:00:00|{01:00:00}\n-1 days -02:00:00|NULL\n");
    try c.expectError("SET IntervalStyle = iso8601", "invalid value for parameter \"IntervalStyle\": \"iso8601\"\nHINT:  Available values: postgres, postgres_verbose, sql_standard, iso_8601.");
    // The text of the session is not deterministic: no index of it, as
    // PostgreSQL's interval_out() is stable.
    try c.expectError("CREATE INDEX iv_t ON iv ((v::text))", "non-deterministic functions prohibited in index expressions");
    try c.expectError("CREATE TABLE ivg (v interval, t text GENERATED ALWAYS AS (v::text) STORED)", "non-deterministic functions prohibited in generated columns");
    // A CHECK may call it.
    try c.exec("CREATE TABLE ivc (v interval CHECK (v::text <> '00:00:00'))");
    try c.exec("INSERT INTO ivc VALUES ('1 day')");
    try c.expectError("INSERT INTO ivc VALUES ('0')", "new row for relation \"ivc\" violates check constraint \"ivc_v_check\"\nDETAIL:  Failing row contains (00:00:00).");
    // Stable: a constant's text is made once, when the statement first
    // needs it (after a set_config() before it in the row, as PostgreSQL;
    // a later row's set_config() is not seen, as stable allows).
    try c.expectRows("SELECT set_config('IntervalStyle', 'iso_8601', false), '1 day'::interval::text", "iso_8601|P1D\n");
    try c.expectRows("SELECT set_config('IntervalStyle', CASE WHEN g = 2 THEN 'postgres' ELSE 'iso_8601' END, false), '1 day'::interval::text FROM (VALUES (1), (2)) v(g)", "iso_8601|P1D\npostgres|P1D\n");
    try c.expectRows("SELECT '1 day'::interval::text", "1 day\n");
}

test "pg: operators of dates, timestamps and intervals" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // Dates: days, the difference of two, an interval makes a timestamp.
    try c.expectRows("SELECT '2024-01-01'::date + 1, 1 + date '2024-12-31', date '2024-03-01' - 1, date '2024-03-01' - date '2024-02-01', date '2024-01-02' - '2024-01-01'", "2024-01-02|2025-01-01|2024-02-29|29|1\n");
    try c.expectRows("SELECT date '2024-01-31' + interval '1 month', date '2023-01-31' + interval '1 month', date '2024-01-01' - interval '1 hour', date '2024-01-01' + time '10:30'", "2024-02-29 00:00:00|2023-02-28 00:00:00|2023-12-31 23:00:00|2024-01-01 10:30:00\n");
    // Timestamps: months clamped to the end of the month, then days,
    // then time; the difference an interval of days and time.
    try c.expectRows("SELECT timestamp '2024-01-31 10:00' + interval '1 month 1 day', timestamp '2024-01-01' + '1 day', (timestamp '2024-01-02 02:00' - timestamp '2024-01-01')::text, (timestamp '2024-01-01' - timestamp '2024-01-02 02:00')::text", "2024-03-01 10:00:00|2024-01-02 00:00:00|1 day 02:00:00|-1 days -02:00:00\n");
    try c.expectRows("SELECT (timestamp '2024-01-01 10:00' - date '2024-01-01')::text, '2024-01-01 10:00:00+02:00'::timestamptz + interval '1 day'", "10:00:00|2024-01-02 08:00:00\n");
    try c.expectRows("SELECT now() - interval '1 day' < now(), now() + '1 hour' > now(), current_date + 1 > current_date", "1|1|1\n");
    // Times wrap around midnight.
    try c.expectRows("SELECT time '23:00' + interval '2 hours', (time '10:00' - time '08:30')::text, time '01:00' - interval '2 hours'", "01:00:00|01:30:00|23:00:00\n");
    // Intervals in PostgreSQL's output style.
    try c.expectRows("SELECT interval '1 day' || '', interval '1 day 2 hours'::text, (interval '38 months')::text, (interval '90 minutes')::text, (-interval '1 month')::text, (interval '-1 day' + interval '1 hour')::text", "1 day|1 day 02:00:00|3 years 2 mons|01:30:00|-1 mons|-1 days +01:00:00\n");
    try c.expectRows("SELECT concat(interval '1 year 2 months' + interval '1 year', '|', interval '1 day' - interval '2 hours', '|', interval '1 day' * 2, '|', 2 * interval '1 hour', '|', interval '1 month' / 2, '|', interval '1 day' / 3, '|', interval '1 hour' * 1.5)", "2 years 2 mons|1 day -02:00:00|2 days|02:00:00|15 days|08:00:00|01:30:00\n");
    // Intervals compare and sort in their order, not their text's.
    try c.expectRows("SELECT interval '1 day' > interval '2 hours', interval '1 mon' = interval '30 days', interval '25 hours' > '1 day'", "1|1|1\n");
    try c.exec("CREATE TABLE ev (id int, d date, ts timestamp, iv interval)");
    try c.exec("INSERT INTO ev VALUES (1, '2024-01-31', '2024-01-31 10:00:00', '1 day'), (2, '2024-02-29', '2024-02-29 00:00:00', '2 hours'), (3, '2024-03-01', '2024-03-01 12:00:00', '1 mon')");
    try c.expectRows("SELECT id FROM ev ORDER BY iv", "2\n1\n3\n");
    // Stored as PostgreSQL reads and writes the type: '2 hours' is
    // '02:00:00', a timestamptz in UTC; what it does not read is an error.
    try c.expectRows("SELECT iv::text FROM ev ORDER BY id", "1 day\n02:00:00\n1 mon\n");
    try c.exec("CREATE TABLE stamp (tz timestamptz, d date)");
    try c.exec("INSERT INTO stamp VALUES ('2024-01-01 10:00:00+02', '2024-1-5')");
    try c.expectRows("SELECT * FROM stamp", "2024-01-01 08:00:00|2024-01-05\n");
    try c.expectError("INSERT INTO stamp (d) VALUES ('nope')", "invalid input syntax for type date: \"nope\"");
    try c.expectRows("SELECT d + id, ts + iv, d - date '2024-01-01' FROM ev ORDER BY id", "2024-02-01|2024-02-01 10:00:00|30\n2024-03-02|2024-02-29 02:00:00|59\n2024-03-04|2024-04-01 12:00:00|60\n");
    // Comparisons of dates and timestamps are of their ISO text.
    try c.expectRows("SELECT id FROM ev WHERE d > '2024-02-01' AND ts < timestamp '2024-03-01 12:00' ORDER BY id", "2\n");
    try c.expectRows("SELECT count(*) FROM ev WHERE d BETWEEN date '2024-01-01' AND '2024-02-29'", "2\n");
    // A view, a CHECK keep the functions the operators chose: what they
    // mean in every dialect.
    try c.exec("CREATE VIEW ev_next AS SELECT id, d + 1 AS next, ts - interval '1 hour' AS before, -iv AS neg FROM ev WHERE id < 3");
    try c.expectRows("SELECT id, next, before, neg::text FROM ev_next ORDER BY id", "1|2024-02-01|2024-01-31 09:00:00|-1 days\n2|2024-03-01|2024-02-28 23:00:00|-02:00:00\n");
    // Its interval comparison is of BLOBs and keys (engine functions,
    // which SQLite's dialect reads too).
    try c.exec("CREATE VIEW ev_short AS SELECT id FROM ev WHERE iv < interval '1 week'");
    try c.expectRows("SELECT * FROM ev_short ORDER BY id", "1\n2\n");
    try c.exec("CREATE TABLE span (a date, b date CHECK (b - a <= 7))");
    try c.exec("INSERT INTO span VALUES ('2024-01-01', '2024-01-08')");
    try c.expectError("INSERT INTO span VALUES ('2024-01-01', '2024-01-09')", "new row for relation \"span\" violates check constraint \"span_b_check\"\nDETAIL:  Failing row contains (2024-01-01, 2024-01-09).");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT id FROM ev_short ORDER BY id", "1\n2\n");
    try c.expectRows("SELECT next FROM ev_next WHERE id = 1", "2024-02-01\n");
    try c.expectRows("SELECT d + 1 FROM ev WHERE id = 1", "2025\n");
    main_mod.setDialect(c.db, .postgres);
    // Casts read PostgreSQL's input and write its output.
    try c.expectRows("SELECT timestamp '2024-01-02 03:04:05.50', '2024-01-01 10:00:00+02'::timestamptz, '10:11:12.25'::time, 'epoch'::date, 'today'::date = current_date", "2024-01-02 03:04:05.5|2024-01-01 08:00:00|10:11:12.25|1970-01-01|1\n");
    try c.expectError("SELECT '2024-02-30'::date", "date/time field value out of range: \"2024-02-30\"");
    // A string literal with an integer is read as an integer.
    try c.expectRows("SELECT '2' + 1, 10 - '3'", "3|7\n");
    try c.expectError("SELECT 'a' + 1", "invalid input syntax for type integer: \"a\"");
    // No operator for the types: PostgreSQL's errors.
    try c.expectError("SELECT date '2024-01-01' + 'abc'::text", "operator does not exist: date + text\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    try c.expectError("SELECT timestamp '2024-01-01' + 1", "operator does not exist: timestamp without time zone + integer\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    try c.expectError("SELECT d + ts FROM ev", "operator does not exist: date + timestamp without time zone\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    try c.expectError("SELECT true + 1", "operator does not exist: boolean + integer\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    try c.expectError("SELECT 1.5::float8 % 2", "operator does not exist: double precision % integer\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    try c.expectError("SELECT -'a'::text", "operator does not exist: - text\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    try c.expectError("SELECT date '2024-01-01' + '1 day'", "operator is not unique: date + unknown\nHINT:  Could not choose a best candidate operator. You might need to add explicit type casts.");
    // Bad values, results out of range.
    try c.expectError("SELECT d + interval 'abc' FROM ev", "invalid input syntax for type interval: \"abc\"");
    try c.expectError("SELECT 'x'::date + 1", "invalid input syntax for type date: \"x\"");
    try c.expectError("SELECT interval '1 day' / 0", "division by zero");
    try c.expectError("SELECT date '5874897-12-31' + 1", "date out of range");
    // An operand of no known type (a SQLite table's column), a parameter
    // or NULL never fails: the operator is SQLite's or the row they fit.
    try c.exec("PRAGMA xq_dialect = 'sqlite'; CREATE TABLE lite (a); INSERT INTO lite VALUES ('2024-01-01'); PRAGMA xq_dialect = 'postgres'");
    try c.expectRows("SELECT a + 1, a || 'x' FROM lite", "2025|2024-01-01x\n");
    try c.expectRows("SELECT date '2024-01-01' + NULL, timestamp '2024-01-01' + NULL", "NULL|NULL\n");
    var stmt: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT timestamp '2024-01-01' + $1", &stmt, null));
    defer _ = api.finalize(stmt.?);
    try testing.expectEqual(RC.OK, api.bindText(stmt.?, 1, "1 day 2 hours"));
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqualStrings("2024-01-02 02:00:00", api.columnText(stmt.?, 0).?);
}

test "pg: regular expression operators" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.expectRows("SELECT 'abc' ~ '^a', 'abc' ~ '^b', 'ABC' ~* '^a', 'abc' !~ 'z', 'abc' !~* 'A', 'pg_toast' ~ '^(pg_toast)$', NULL ~ 'a'", "1|0|1|1|0|1|NULL\n");
    try c.exec("CREATE TABLE names (n text)");
    try c.exec("INSERT INTO names VALUES ('pg_x'), ('abc'), ('Abd')");
    try c.expectRows("SELECT n FROM names WHERE n !~ '^pg_' AND n ~* '^a' ORDER BY n", "Abd\nabc\n");
    try c.exec("CREATE VIEW names_a AS SELECT n FROM names WHERE n ~ '^a'");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT n FROM names_a", "abc\n");
    main_mod.setDialect(c.db, .postgres);
    try c.expectError("SELECT 'a' ~ '('", "invalid regular expression: parentheses () not balanced");
    // The older engine function of the schema of older databases keeps
    // its meaning (a backslash-letter is the letter).
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT xq_pg_regex('ay', 'a\\y', ''), xq_pg_re('ay', 'a\\y', ''), xq_pg_re('a y', 'a\\y', '')", "1|0|1\n");
    main_mod.setDialect(c.db, .postgres);
}

test "pg: regular expression functions, SIMILAR TO, substring" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.expectRows("SELECT regexp_match('abc01234xyz', '(.*?)(\\d+)(.*)'), regexp_match('abcd', '(a|ab)(c|bcd)(d*)'), regexp_match('aaa', '(a*)+'), regexp_match('abab', '(ab)\\1')", "{abc,0,\"\"}|{ab,c,d}|{\"\"}|{ab}\n");
    try c.expectRows("SELECT regexp_replace('foobarbaz', 'b(..)', 'X\\1Y', 'g'), regexp_count('ABCABC', 'b', 1, 'i'), regexp_instr('aébc', 'b'), regexp_substr('ABCDEFGHI', '(c..)(...)', 1, 1, 'i', 2), regexp_like('Hello', 'hello', 'i')", "fooXarYXazY|2|3|FGH|1\n");
    try c.expectRows("SELECT regexp_split_to_array('a,b,,c', ','), regexp_split_to_array('abc', '')", "{a,b,\"\",c}|{a,b,c}\n");
    try c.expectRows("SELECT m[1], m[2] FROM regexp_matches('a1b22', '([a-z])(\\d+)', 'g') AS m", "a|1\nb|22\n");
    try c.expectRows("SELECT regexp_split_to_table('a b  c', '\\s+')", "a\nb\nc\n");
    try c.expectRows("SELECT 'abc' SIMILAR TO 'a%', 'abc' SIMILAR TO '(a|b)_c', 'abc' NOT SIMILAR TO 'b%', 'a_b' SIMILAR TO 'a#_b' ESCAPE '#'", "1|1|1|1\n");
    try c.expectRows("SELECT substring('foobar' FROM 'o(.)b'), substring('foobar' SIMILAR '%#\"o_b#\"%' ESCAPE '#'), substring('hello' FROM 2 FOR 3)", "o|oob|ell\n");
    try c.expectError("SELECT regexp_match('a', 'a', 'g')", "regexp_match() does not support the \"global\" option\nHINT:  Use the regexp_matches function instead.");
    try c.expectError("SELECT 'a' SIMILAR TO 'a' ESCAPE 'xy'", "invalid escape string\nHINT:  Escape string must be empty or one character.");
}

test "pg: standard_conforming_strings" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.expectRows("SELECT length('a\\tb')", "4\n");
    try c.exec("SET standard_conforming_strings = off");
    try c.expectRows("SELECT length('a\\tb'), 'it\\'s', E'x\\ty' = 'x\\ty'", "3|it's|1\n");
    try c.expectError("SELECT U&'d\\0061t'", "unsafe use of string constant with Unicode escapes\nDETAIL:  String constants with Unicode escapes cannot be used when \"standard_conforming_strings\" is off.");
    try c.exec("RESET standard_conforming_strings");
    try c.expectRows("SELECT length('a\\tb'), U&'d\\0061t'", "4|dat\n");
    // Checked as PostgreSQL checks them; SHOW prints a Boolean on or off,
    // an enum as listed.
    try c.exec("SET standard_conforming_strings = 0");
    try c.expectRows("SHOW standard_conforming_strings", "off\n");
    try c.expectError("SET standard_conforming_strings = maybe", "parameter \"standard_conforming_strings\" requires a Boolean value");
    try c.expectRows("SHOW standard_conforming_strings", "off\n");
    try c.exec("RESET standard_conforming_strings");
    try c.expectError("SET client_min_messages = loud", "invalid value for parameter \"client_min_messages\": \"loud\"\nHINT:  Available values: debug5, debug4, debug3, debug2, debug1, log, notice, warning, error.");
    try c.expectRows("SELECT set_config('client_min_messages', 'DEBUG', false)", "debug2\n");
    try c.exec("RESET client_min_messages");
}

test "pg: json and jsonb" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // json keeps the text, jsonb is normalized.
    try c.expectRows(
        "SELECT '{\"b\":1,  \"a\":2, \"b\":3}'::json, '{\"b\":1, \"aa\":[1,2], \"a\":2, \"b\":3}'::jsonb, '1e2'::jsonb, '1.50'::jsonb",
        "{\"b\":1,  \"a\":2, \"b\":3}|{\"a\": 2, \"b\": 3, \"aa\": [1, 2]}|100|1.50\n",
    );
    try c.expectError("SELECT '{'::jsonb", "invalid input syntax for type json\nDETAIL:  The input string ended unexpectedly.\nCONTEXT:  JSON data, line 1: {");
    try c.expectError("SELECT '\"\\u0000\"'::jsonb", "unsupported Unicode escape sequence\nDETAIL:  \\u0000 cannot be converted to text.\nCONTEXT:  JSON data, line 1: \"\\u0000...");
    // Operators.
    try c.expectRows(
        "SELECT '{\"a\": {\"y\":1,  \"x\":2}}'::json -> 'a', '{\"a\": {\"y\":1, \"x\":2}}'::jsonb -> 'a', '[1,2,3]'::jsonb -> -1, '{\"a\":\"x\"}'::jsonb ->> 'a'",
        "{\"y\":1,  \"x\":2}|{\"x\": 2, \"y\": 1}|3|x\n",
    );
    try c.expectRows("SELECT '{\"a\": {\"b\": [1,2]}}'::jsonb #> '{a,b,1}', '{\"a\": {\"b\": [1,2]}}'::json #>> '{a,b}'", "2|[1,2]\n");
    try c.expectRows(
        "SELECT '{\"a\":1,\"b\":2}'::jsonb @> '{\"a\":1}', '{\"a\":1}'::jsonb <@ '{\"a\":2}', '[1,2]'::jsonb @> '1', '{\"a\":1}'::jsonb ? 'a', '{\"a\":1}'::jsonb ?| array['x','a'], '{\"a\":1}'::jsonb ?& '{a,x}'",
        "1|0|1|1|1|0\n",
    );
    try c.expectRows(
        "SELECT '{\"a\":1}'::jsonb || '{\"b\":2}', '[1]'::jsonb || '2', '{\"a\":1,\"b\":2}'::jsonb - 'a', '[1,2,3]'::jsonb - 1, '{\"a\":1,\"b\":2}'::jsonb - array['a','b'], '{\"a\":{\"b\":1}}'::jsonb #- '{a,b}'",
        "{\"a\": 1, \"b\": 2}|[1, 2]|{\"b\": 2}|[1, 3]|{}|{\"a\": {}}\n",
    );
    try c.expectError("SELECT '{\"a\":1}'::jsonb - 1", "cannot delete from object using integer index");
    try c.expectError("SELECT '[1]'::json || '[2]'::json", "operator does not exist: json || json\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    // jsonb compares and sorts as jsonb.
    try c.expectRows("SELECT '{\"b\":1,\"a\":2}'::jsonb = '{\"a\": 2, \"b\": 1}', '1.0'::jsonb = '1'::jsonb, '{}'::jsonb > '[1,2]'::jsonb, '[1]'::jsonb < '[0,0]'::jsonb", "1|1|1|1\n");
    // Functions.
    try c.expectRows(
        "SELECT jsonb_build_object('a', 1, 'b', true, 'c', null), json_build_object('a', 1, 'b', 'x'), json_build_array(1, 'a', null), to_json('a\"b'::text), to_jsonb(1 > 0)",
        "{\"a\": 1, \"b\": true, \"c\": null}|{\"a\" : 1, \"b\" : \"x\"}|[1, \"a\", null]|\"a\\\"b\"|true\n",
    );
    try c.expectRows("SELECT jsonb_typeof('[1]'), json_array_length('[1,2,3]'), jsonb_extract_path_text('{\"a\":{\"b\":\"x\"}}', 'a', 'b'), jsonb_strip_nulls('{\"a\":null,\"b\":1}')", "array|3|x|{\"b\": 1}\n");
    try c.expectRows("SELECT jsonb_set('{\"a\":1}', '{b}', '2'), jsonb_insert('[1,2]', '{0}', '0'), jsonb_set_lax('{\"a\":1}', '{a}', null, true, 'delete_key')", "{\"a\": 1, \"b\": 2}|[0, 1, 2]|{}\n");
    try c.expectRows("SELECT jsonb_pretty('{\"a\":[1],\"b\":{}}')", "{\n    \"a\": [\n        1\n    ],\n    \"b\": {\n    }\n}\n");
    try c.expectRows(
        "SELECT JSON_OBJECT('a' : 1, 'b' VALUE 'x'), JSON_ARRAY(1, null, 'a'), JSON_OBJECT('a': 1 RETURNING jsonb), json_object('{a,1}')",
        "{\"a\" : 1, \"b\" : \"x\"}|[1, \"a\"]|{\"a\": 1}|{\"a\" : \"1\"}\n",
    );
    try c.expectRows("SELECT '{\"a\":1}' IS JSON OBJECT, '[1]' IS NOT JSON, '{\"a\":1,\"a\":2}' IS JSON WITH UNIQUE KEYS", "1|0|0\n");
    // jsonpath.
    try c.expectRows(
        "SELECT jsonb_path_query_array('{\"a\":[1,2,3,4]}', '$.a[*] ? (@ > 2)'), '{\"a\":[1,2]}'::jsonb @? '$.a[*] ? (@ == 2)', '{\"a\":1}'::jsonb @@ '$.a == 1', jsonb_path_query_first('{\"a\":10}', '$.a / 4')",
        "[3, 4]|1|1|2.5000000000000000\n",
    );
    // Set-returning functions, in FROM and in the select list.
    try c.expectRows("SELECT * FROM jsonb_each('{\"b\":1, \"a\":\"x\"}')", "a|\"x\"\nb|1\n");
    try c.expectColumns("SELECT * FROM json_each_text('{\"a\":1}') AS t(k, v)", "k|v");
    try c.expectRows("SELECT * FROM jsonb_array_elements('[10,20]') WITH ORDINALITY AS t(v, n)", "10|1\n20|2\n");
    try c.expectRows("SELECT * FROM json_to_record('{\"a\":1,\"b\":\"x\",\"c\":{\"d\":1}}') AS x(a int, b text, c jsonb)", "1|x|{\"d\": 1}\n");
    try c.expectRows("SELECT jsonb_array_elements_text('[1,2,3]') AS a, jsonb_object_keys('{\"x\":1}') AS b", "1|x\n2|NULL\n3|NULL\n");
    try c.expectError("SELECT * FROM jsonb_each('[1]')", "cannot call jsonb_each on a non-object");
    // Columns: jsonb stored normalized, json checked.
    try c.exec(
        \\CREATE TABLE ev (id int PRIMARY KEY, data jsonb NOT NULL DEFAULT '{"z": 1, "a": 2}', raw json, ok boolean);
        \\INSERT INTO ev VALUES (1, '{"tags":["a","b"],"n":1}', '{"b" :  1}', true), (2, '{"tags":["c"],"n":2}', '[1]', false);
        \\INSERT INTO ev (id) VALUES (3);
    );
    try c.expectRows("SELECT id, data::text, raw FROM ev ORDER BY id", "1|{\"n\": 1, \"tags\": [\"a\", \"b\"]}|{\"b\" :  1}\n2|{\"n\": 2, \"tags\": [\"c\"]}|[1]\n3|{\"a\": 2, \"z\": 1}|NULL\n");
    try c.expectError("INSERT INTO ev (id, raw) VALUES (4, 'x')", "invalid input syntax for type json\nDETAIL:  Token \"x\" is invalid.\nCONTEXT:  JSON data, line 1: x");
    try c.exec("UPDATE ev SET data = data || '{\"m\": 0}' WHERE id = 3");
    try c.expectRows("SELECT data::text FROM ev WHERE id = 3", "{\"a\": 2, \"m\": 0, \"z\": 1}\n");
    try c.expectRows("SELECT id FROM ev WHERE data = '{\"z\":1, \"m\":0, \"a\":2}'", "3\n");
    try c.expectRows("SELECT id, t.value FROM ev, jsonb_array_elements_text(ev.data -> 'tags') AS t ORDER BY 1, 2", "1|a\n1|b\n2|c\n");
    try c.expectRows("SELECT id, jsonb_array_elements_text(data -> 'tags') AS tag FROM ev ORDER BY id, tag", "1|a\n1|b\n2|c\n");
    try c.expectRows(
        "SELECT json_agg(ev ORDER BY id) FROM ev WHERE id < 3",
        "[{\"id\":1,\"data\":{\"n\": 1, \"tags\": [\"a\", \"b\"]},\"raw\":{\"b\" :  1},\"ok\":true}, \n {\"id\":2,\"data\":{\"n\": 2, \"tags\": [\"c\"]},\"raw\":[1],\"ok\":false}]\n",
    );
    try c.expectRows("SELECT jsonb_agg(data -> 'n' ORDER BY id), json_object_agg(id, ok) FROM ev", "[1, 2, null]|{ \"1\" : true, \"2\" : false, \"3\" : null }\n");
    try c.expectRows("SELECT row_to_json(e) FROM (SELECT id, ok FROM ev WHERE id = 1) e", "{\"id\":1,\"ok\":true}\n");
    // A gin index is a B-tree index of the column.
    try c.exec("CREATE INDEX ON ev USING gin (data jsonb_path_ops)");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'ev' AND sql IS NOT NULL", "ev_data_idx\n");
    // The schema keeps SQLite text: a view of JSON operators.
    try c.exec("CREATE VIEW evv AS SELECT id, data -> 'n' AS n, data ? 'tags' AS has FROM ev");
    try c.expectRows("SELECT id, n::text, has FROM evv ORDER BY id", "1|1|1\n2|2|1\n3|NULL|0\n");
    try c.expectRows("SELECT sql LIKE '%xq_pg_jsonb_get(%' AND sql LIKE '%xq_pg_jsonb_exists(%' FROM sqlite_schema WHERE name = 'evv'", "1\n");
}

test "pg: jsonb's operators by the type of a column of a subquery, a CTE, a view" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE ej (id int PRIMARY KEY, d jsonb, r json);
        \\INSERT INTO ej VALUES (1, '{"a":1,"b":[1,2]}', '{"x" :  1}'), (2, '{"a":2}', '[1]'), (3, '[0]', NULL);
    );
    try c.expectRows("SELECT (s.d || '{\"c\":3}')::text FROM (SELECT d FROM ej WHERE id = 1) s", "{\"a\": 1, \"b\": [1, 2], \"c\": 3}\n");
    try c.expectRows("WITH w AS (SELECT id, d FROM ej) SELECT (w.d -> 'a')::text, (w.d - 'a')::text, (w.d #> '{b,1}')::text FROM w ORDER BY id", "1|{\"b\": [1, 2]}|2\n2|{}|NULL\nNULL|[0]|NULL\n");
    try c.expectRows("SELECT id FROM (SELECT id, d AS x FROM ej) s WHERE s.x = '{\"b\":[1,2],  \"a\":1}'", "1\n");
    try c.expectRows("SELECT x::text FROM (SELECT d AS x FROM ej) s ORDER BY x", "[0]\n{\"a\": 2}\n{\"a\": 1, \"b\": [1, 2]}\n");
    // (A compound sorts jsonb by the collation, which orders text, not
    // JSONB: sorted outside it.)
    try c.expectRows("SELECT d::text FROM (SELECT d FROM ej UNION ALL SELECT '{}') u ORDER BY d DESC LIMIT 2", "{\"a\": 1, \"b\": [1, 2]}\n{\"a\": 2}\n");
    try c.expectRows("SELECT (coalesce(d, '{}') || '{\"m\":1}')::text, (CASE WHEN id = 1 THEN d ELSE '[]' END || '[9]')::text FROM ej WHERE id = 2", "{\"a\": 2, \"m\": 1}|[9]\n");
    try c.expectRows("SELECT ((SELECT d FROM ej WHERE id = 2) || '{\"y\":1}')::text, to_json(s.d) FROM (SELECT d FROM ej WHERE id = 3) s", "{\"a\": 2, \"y\": 1}|[0]\n");
    try c.expectError("SELECT s.r || s.r FROM (SELECT r FROM ej) s", "operator does not exist: json || json\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
    // excluded.* and RETURNING's columns are of the table's types.
    try c.expectRows("INSERT INTO ej VALUES (2, '{\"b\":3}') ON CONFLICT (id) DO UPDATE SET d = ej.d || excluded.d RETURNING (d || '{\"r\":1}')::text", "{\"a\": 2, \"b\": 3, \"r\": 1}\n");
    try c.exec("UPDATE ej SET d = '{\"a\":2}' WHERE id = 2");
    // A view's column is of the type of its query's.
    try c.exec("CREATE VIEW ev AS SELECT id, d, d || '{\"z\":0}' AS dz FROM ej");
    try c.expectRows("SELECT (dz || '{\"q\":1}')::text, (d -> 'a')::text FROM ev WHERE id = 2", "{\"a\": 2, \"q\": 1, \"z\": 0}|2\n");
    try c.expectRows("SELECT id FROM ev WHERE d = '{\"a\": 2}'", "2\n");
    // The text the schema keeps says what was chosen, inside a CTE too,
    // so that it means the same in every dialect.
    try c.exec("CREATE VIEW cv AS WITH w AS (SELECT id, d || '{\"c\":1}' AS e FROM ej) SELECT id, e -> 'c' AS c FROM w");
    try c.expectRows("SELECT instr(sql, 'xq_pg_jsonb_concat(\"d\"') > 0, instr(sql, 'xq_pg_jsonb_get(\"e\"') > 0 FROM sqlite_schema WHERE name = 'cv'", "1|1\n");
    try c.exec("CREATE VIEW ov AS SELECT x FROM (SELECT d AS x FROM ej) s ORDER BY 1");
    try c.expectRows("SELECT instr(sql, 'ORDER BY xq_pg_jsonb_key(\"x\")') > 0 FROM sqlite_schema WHERE name = 'ov'", "1\n");
    try c.exec("CREATE TABLE ck (j jsonb CHECK (j -> 'a' = '1'))");
    try c.exec("INSERT INTO ck VALUES ('{\"a\": 1}')");
    try c.expectError("INSERT INTO ck VALUES ('{\"a\": 2}')", "new row for relation \"ck\" violates check constraint \"ck_j_check\"\nDETAIL:  Failing row contains ({\"a\": 2}).");
    try c.exec("CREATE INDEX ck_a ON ck ((j -> 'a'))");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE sql LIKE '%xq_pg_jsonb_get(\"j\", ''a'')%'", "2\n");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT id, json(c) FROM cv ORDER BY id", "1|1\n2|1\n3|NULL\n");
    // A view of SQLite's dialect means SQLite's operators where it is read.
    try c.exec("CREATE VIEW sv AS SELECT json(d) || '{\"b\":2}' AS x FROM ej WHERE id = 2");
    main_mod.setDialect(c.db, .postgres);
    try c.expectRows("SELECT x FROM sv", "{\"a\":2}{\"b\":2}\n");
}

test "pg: numbers in JSON as PostgreSQL spells them" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // double precision as float8out(): the shortest digits that read back,
    // no ".0", an exponent of two digits at least; numeric with its digits.
    try c.expectRows(
        "SELECT to_json(100.0::float8), to_json(1e20::float8), to_json(1e-5::float8), to_json(0.1::float8 + 0.2::float8), to_json(1e15::float8), to_json(123456789012345.0::float8), to_json(1.1::real)",
        "100|1e+20|1e-05|0.30000000000000004|1e+15|123456789012345|1.1\n",
    );
    try c.expectRows("SELECT to_jsonb(100.0::float8), to_jsonb(1e20::float8), to_json(1.50), to_jsonb(1.50), json_build_array(2::numeric(5,2), 1.5 + 1)", "100|100000000000000000000|1.50|1.50|[2.00, 2.5]\n");
    try c.exec(
        \\CREATE TABLE fj (id int PRIMARY KEY, f float8, n numeric(6,2));
        \\INSERT INTO fj VALUES (1, 100, 1.5), (2, 2.5e-7, 2), (3, NULL, NULL);
    );
    try c.expectRows("SELECT row_to_json(t) FROM fj t ORDER BY id", "{\"id\":1,\"f\":100,\"n\":1.50}\n{\"id\":2,\"f\":2.5e-07,\"n\":2.00}\n{\"id\":3,\"f\":null,\"n\":null}\n");
    try c.expectRows("SELECT json_agg(f ORDER BY id), jsonb_agg(n ORDER BY id), json_build_object('f', max(f)) FROM fj", "[100, 2.5e-07, null]|[1.50, 2.00, null]|{\"f\" : 100}\n");
    try c.expectRows("SELECT to_json(s.f) FROM (SELECT f FROM fj WHERE id = 2) s", "2.5e-07\n");
}

test "pg: parameters" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    var stmt: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT $2 - $1, $1", &stmt, null));
    defer _ = api.finalize(stmt.?);
    try testing.expectEqual(@as(usize, 2), api.bindParameterCount(stmt.?));
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
    try c.expectError("INSERT INTO kv (k, v) VALUES ('e', 1)", "duplicate key value violates unique constraint \"kv_pkey\"\nDETAIL:  Key (k)=(e) already exists.");
    try c.expectError("INSERT INTO kv (k, v) VALUES ('f', NULL)", "null value in column \"v\" of relation \"kv\" violates not-null constraint\nDETAIL:  Failing row contains (f, null, null).");
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

test "pg: uuid is 16 bytes, an older table's text column stays text" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (u uuid PRIMARY KEY, n int, d uuid DEFAULT 'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11', g uuid DEFAULT gen_random_uuid())");
    try c.exec("INSERT INTO t (u, n) VALUES ('{11111111-1111-1111-1111-111111111111}', 1), ('22222222222222222222222222222222', 2)");
    try c.expectRows("SELECT typeof(u), length(u), hex(u), hex(d), length(g), n FROM t ORDER BY u",
        \\blob|16|11111111111111111111111111111111|A0EEBC999C0B4EF8BB6D6BB9BD380A11|16|1
        \\blob|16|22222222222222222222222222222222|A0EEBC999C0B4EF8BB6D6BB9BD380A11|16|2
        \\
    );
    try c.expectRows("SELECT n FROM t WHERE u = '22222222-2222-2222-2222-222222222222'", "2\n");
    try c.expectRows("SELECT u::text, u || '!' FROM t WHERE u IN ('11111111111111111111111111111111')", "11111111-1111-1111-1111-111111111111|11111111-1111-1111-1111-111111111111!\n");
    try c.expectError("INSERT INTO t (u) VALUES ('11111111-1111-1111-1111-11111111111')", "invalid input syntax for type uuid: \"11111111-1111-1111-1111-11111111111\"");
    try c.expectRows("SELECT uuid_extract_version(uuidv4()), uuid_extract_version(uuidv7()), uuid_extract_version(gen_random_uuid()), uuid_extract_timestamp('017F22E2-79B0-7CC3-98C4-DC0C0C07398F')", "4|7|4|2022-02-22 19:22:22\n");
    // A literal compared with the column is read once, and the key's
    // index is used.
    try c.expectRows("EXPLAIN SELECT n FROM t WHERE u = '22222222-2222-2222-2222-222222222222'", "3|0|39|SEARCH t USING INDEX sqlite_autoindex_t_1 (u=?)\n");
    // A table made before: its uuid column is TEXT, and stays so.
    try c.exec("CREATE TABLE o (u text PRIMARY KEY, n int)");
    main_mod.setDialect(c.db, .sqlite);
    try c.exec("UPDATE xq_catalog SET value = 'uuid' WHERE tbl = 'o' AND col = 'u'");
    main_mod.setDialect(c.db, .postgres);
    try c.exec("INSERT INTO o VALUES ('{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}', 1), (gen_random_uuid(), 2)");
    try c.exec("INSERT INTO o SELECT u, n + 10 FROM t");
    try c.expectRows("SELECT typeof(u), length(u) FROM o GROUP BY 1, 2", "text|36\n");
    try c.expectRows("SELECT n FROM o WHERE u = 'a0eebc999c0b4ef8bb6d6bb9bd380a11'", "1\n");
    try c.expectRows("SELECT o.n FROM o JOIN t ON t.u = o.u ORDER BY 1", "11\n12\n");
    try c.expectRows("SELECT uuid_extract_version(u) FROM o WHERE n = 2", "4\n");
    try c.exec("INSERT INTO t (u, n) SELECT u, n + 100 FROM o WHERE n = 1");
    try c.expectRows("SELECT typeof(u) FROM t WHERE n = 101", "blob\n");
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
        \\CREATE TABLE "ty"("i2" INTEGER CONSTRAINT "smallint out of range" CHECK(("i2" BETWEEN -32768 AND 32767)), "i4" INTEGER CONSTRAINT "integer out of range" CHECK(("i4" BETWEEN -2147483648 AND 2147483647)), "i8" INTEGER, "r" REAL, "d" REAL, "n" BLOB CONSTRAINT "invalid input syntax for type numeric" CHECK(xq_dec_valid("n", 6, 2)), "b" INTEGER CONSTRAINT "invalid input syntax for type boolean" CHECK(("b" IN (0, 1))), "t" TEXT, "vc" TEXT CONSTRAINT "value too long for type character varying(3)" CHECK((length("vc") <= 3)), "ch" TEXT CONSTRAINT "value too long for type character(2)" CHECK((length("ch") <= 2)), "by" BLOB, "dt" TEXT, "ts" TEXT, "tz" TEXT, "tm" TEXT, "u" BLOB CONSTRAINT "invalid input syntax for type uuid" CHECK((length("u") = 16)), "j" BLOB CONSTRAINT "invalid input syntax for type json" CHECK(json_valid("j", 8))) STRICT
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
    try c.expectRows("SELECT i2, i4, r, n::text, b, vc FROM ty WHERE i2 = 1", "1|2|4.0|5.25|1|abc\n");
    // A numeric is stored as pkg/decimal's key.
    try c.expectRows("SELECT n::text, typeof(n) FROM ty WHERE i2 IS NULL ORDER BY n", "1.50|blob\n7.00|blob\n");
    try c.expectError("INSERT INTO ty (i4) VALUES ('x')", "invalid input syntax for type integer: \"x\"");
    // A numeric stored into an integer is rounded (PostgreSQL's assignment
    // cast).
    try c.exec("INSERT INTO ty (i4, vc) VALUES (1.5, 'r')");
    try c.expectRows("SELECT i4 FROM ty WHERE vc = 'r'", "2\n");
    try c.exec("DELETE FROM ty WHERE vc = 'r'");
    try c.expectError("INSERT INTO ty (i2) VALUES (40000)", "smallint out of range");
    try c.expectError("INSERT INTO ty (i4) VALUES (3000000000)", "integer out of range");
    try c.expectError("INSERT INTO ty (vc) VALUES ('abcd')", "value too long for type character varying(3)");
    try c.expectError("INSERT INTO ty (b) VALUES (2)", "invalid input syntax for type boolean");
    try c.expectError("INSERT INTO ty (j) VALUES ('{')", "invalid input syntax for type json\nDETAIL:  The input string ended unexpectedly.\nCONTEXT:  JSON data, line 1: {");
    try c.expectError("INSERT INTO ty (n) VALUES ('abc')", "invalid input syntax for type numeric: \"abc\"");
    // A string is read as PostgreSQL reads the column type's input.
    try c.expectError("INSERT INTO ty (b) VALUES ('x')", "invalid input syntax for type boolean: \"x\"");
    try c.exec("INSERT INTO ty (i2, b, n) VALUES (9, 'on', ' 2.75 ')");
    try c.expectRows("SELECT b, n::text FROM ty WHERE i2 = 9", "1|2.75\n");
    try c.expectError("INSERT INTO ty (by) VALUES (1)", "cannot store INT value in BLOB column ty.by");
    try c.expectError("CREATE TABLE bad (x nosuchtype)", "type \"nosuchtype\" does not exist");
    try c.expectError("CREATE TABLE bad (x serial[])", "array of serial is not implemented");
    try c.expectError("CREATE TABLE bad (x nosuch[])", "type \"nosuch[]\" does not exist");
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
    try c.expectError("INSERT INTO s (id, v) VALUES (4, 'dup')", "duplicate key value violates unique constraint \"s_pkey\"\nDETAIL:  Key (id)=(4) already exists.");

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
    try c.expectError("INSERT INTO g (id, v) VALUES (1, 'x')", "cannot insert a non-DEFAULT value into column \"id\"\nDETAIL:  Column \"id\" is an identity column defined as GENERATED ALWAYS.\nHINT:  Use OVERRIDING SYSTEM VALUE to override.");
    try c.expectError("UPDATE g SET id = 1", "column \"id\" can only be updated to DEFAULT\nDETAIL:  Column \"id\" is an identity column defined as GENERATED ALWAYS.");
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
    try c.expectError("INSERT INTO child (id, qty) VALUES (2, 0)", "new row for relation \"child\" violates check constraint \"child_qty_check\"\nDETAIL:  Failing row contains (2, null, 0, null, 0).");
    try c.expectError("INSERT INTO child (id, parent_id, label) VALUES (1, 1, 'b')", "duplicate key value violates unique constraint \"child_pk\"\nDETAIL:  Key (id)=(1) already exists.");
    try c.expectError("INSERT INTO child (id, parent_id, label) VALUES (2, 1, 'a')", "duplicate key value violates unique constraint \"child_parent_id_label_key\"\nDETAIL:  Key (parent_id, label)=(1, a) already exists.");
    try c.expectError("INSERT INTO child (id, parent_id) VALUES (2, 9)", "insert or update on table \"child\" violates foreign key constraint \"child_parent_id_fkey\"\nDETAIL:  Key (parent_id)=(9) is not present in table \"parent\".");
    try c.expectError("INSERT INTO child (id) VALUES (-1)", "new row for relation \"child\" violates check constraint \"child_check\"\nDETAIL:  Failing row contains (-1, null, 1, null, 2).");
    // Indexes: PostgreSQL's names when none is given.
    try c.exec("CREATE INDEX ON child (qty); CREATE INDEX ON child (qty); CREATE UNIQUE INDEX IF NOT EXISTS lbl ON child (lower(label)) WHERE label IS NOT NULL");
    try c.exec("CREATE INDEX CONCURRENTLY child_lbl_desc ON child USING btree (label DESC NULLS LAST)");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE type = 'index' AND sql IS NOT NULL ORDER BY name", "child_lbl_desc\nchild_qty_idx\nchild_qty_idx1\nlbl\n");
    try c.exec("DROP INDEX child_qty_idx1; DROP INDEX IF EXISTS nosuch");
    try c.expectError("DROP INDEX nosuch", "index \"nosuch\" does not exist");
    try c.expectError("CREATE INDEX x ON child USING gist (label)", "index method \"gist\" is not supported");
    // ALTER TABLE.
    try c.exec("ALTER TABLE child ADD COLUMN note varchar(5)");
    try c.exec("ALTER TABLE child ADD COLUMN IF NOT EXISTS note text");
    try c.exec("ALTER TABLE child RENAME COLUMN note TO memo");
    try c.expectError("INSERT INTO child (id, memo) VALUES (3, 'toolong')", "value too long for type character varying(5)");
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
    // SELECT ... INTO is CREATE TABLE AS.
    try c.exec("SELECT id, label INTO copy FROM kid WHERE id > 0");
    try c.exec("WITH k AS (SELECT label FROM kid) SELECT label INTO TEMP TABLE copy_t FROM k");
    try c.expectRows("SELECT * FROM copy; SELECT * FROM copy_t", "1|a\na\n");
    try c.expectError("INSERT INTO copy SELECT 2, 'b' INTO other", "SELECT ... INTO is not allowed here");
    try c.exec("DROP TABLE copy; DROP TABLE copy_t");
    // A scalar subquery's error is its own, not a syntax error.
    try c.expectError("SELECT (SELECT 1 FROM pg_catalog.nosuch)", "relation \"pg_catalog.nosuch\" does not exist");
    // Several tables in one statement, in order.
    try c.exec("CREATE TABLE d1 (a int); CREATE TABLE d2 (b int GENERATED ALWAYS AS IDENTITY)");
    try c.exec("DROP TABLE d1, d2");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name IN ('d1', 'd2')", "0\n");
    try c.expectError("DROP TABLE kid, nosuch", "table \"nosuch\" does not exist");
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
        \\id|1|NO|integer|NULL|32|0|int4|nextval('person_id_seq'::regclass)
        \\name|2|NO|character varying|40|NULL|NULL|varchar|NULL
        \\born|3|YES|date|NULL|NULL|NULL|date|NULL
        \\score|4|YES|numeric|NULL|5|1|numeric|NULL
        \\
    );
    try c.expectRows("SELECT c.table_name, count(*) FROM information_schema.tables t JOIN information_schema.columns c ON c.table_name = t.table_name GROUP BY 1 ORDER BY 1", "adults|1\nlite|3\nperson|4\n");
    try c.expectRows("SELECT schemaname, tablename, hasindexes FROM pg_catalog.pg_tables WHERE schemaname <> 'pg_catalog' ORDER BY 2", "public|lite|0\npublic|person|1\n");
    try c.expectRows("SELECT tablename FROM pg_tables WHERE tablename LIKE 'pe%'", "person\n");
    try c.expectRows("SELECT viewname FROM pg_views WHERE schemaname = 'public'", "adults\n");
    // The INTEGER PRIMARY KEY has its index, as in PostgreSQL.
    try c.expectRows("SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1",
        \\person_name_idx|CREATE INDEX person_name_idx ON public.person USING btree (name)
        \\person_pkey|CREATE UNIQUE INDEX person_pkey ON public.person USING btree (id)
        \\
    );
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
    try c.expectError("SELECT * FROM nosuchschema.person", "relation \"nosuchschema.person\" does not exist");
}

test "pg: the catalog relations' columns are of the types their casts were" {
    const pgc = @import("pgcatalog.zig");
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE SEQUENCE s");
    try c.exec("CREATE TABLE t (id serial PRIMARY KEY, a int NOT NULL DEFAULT 1 CHECK (a > 0), b text UNIQUE, r int REFERENCES t (id), f boolean)");
    try c.exec("CREATE INDEX t_ab ON t (a, lower(b)) WHERE a > 2");
    try c.exec("CREATE VIEW v AS SELECT a, b FROM t");
    try c.exec("COMMENT ON TABLE t IS 'tee'");
    inline for (pgc.relations) |r| {
        const typed = comptime pgc.viewText(r);
        const cast = comptime pgc.castViewText(r);
        // The same declared types and types of the result columns.
        var a: ?*vi.Vdbe = null;
        var b: ?*vi.Vdbe = null;
        try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, typed, &a, null));
        defer _ = api.finalize(a.?);
        try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, cast, &b, null));
        defer _ = api.finalize(b.?);
        for (0..api.columnCount(b.?)) |i| {
            const x = api.columnDecltype(a.?, i) orelse "";
            const y = api.columnDecltype(b.?, i) orelse "";
            testing.expectEqualStrings(y, x) catch |err| {
                std.debug.print("{s} column {d}\n", .{ r.name, i });
                return err;
            };
            try testing.expect(std.meta.eql(b.?.xq_col_types[i], a.?.xq_col_types[i]));
        }
        // And the same rows.
        try c.expectRows("SELECT count(*) FROM (" ++ typed ++ " EXCEPT " ++ cast ++ ") x", "0\n");
        try c.expectRows("SELECT count(*) FROM (" ++ cast ++ " EXCEPT " ++ typed ++ ") x", "0\n");
    }
    // A condition on a key column is the virtual table's (bestIndex()),
    // of an OID, of another type, or NULL.
    try c.expectRows("SELECT attname FROM pg_attribute WHERE attrelid = 't'::regclass AND attnum > 0 ORDER BY attnum", "id\na\nb\nr\nf\n");
    try c.expectRows("SELECT count(*) FROM pg_attribute WHERE attrelid = (SELECT oid::text FROM pg_class WHERE relname = 't')", "11\n");
    try c.expectRows("SELECT count(*) FROM pg_attribute WHERE attrelid = NULL", "0\n");
    try c.expectRows("SELECT count(*) FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid WHERE c.relname = 't'", "11\n");
    try c.expectRows("SELECT relname FROM pg_class WHERE oid = 1259", "pg_class\n");
    try c.expectRows("SELECT count(*) FROM pg_constraint WHERE conrelid = 't'::regclass", "6\n");
    try c.expectRows("SELECT count(*) FROM pg_index WHERE indrelid = 't'::regclass", "3\n");
}

test "pg: error positions and DETAIL, HINT, CONTEXT lines" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a int, b bool, n numeric(4,4), j jsonb, s text UNIQUE)");
    // The offsets psql shows as LINE 1 and its caret (from 0 here).
    for ([_]struct { []const u8, []const u8, i32 }{
        .{ "SELECT * FROM nosuch", "relation \"nosuch\" does not exist", 14 },
        .{ "INSERT INTO nosuch VALUES (1)", "relation \"nosuch\" does not exist", 12 },
        .{ "SELECT 'x'::int", "invalid input syntax for type integer: \"x\"", 7 },
        .{ "SELECT 'a' + 1", "invalid input syntax for type integer: \"a\"", 7 },
        .{ "SELECT bool 'maybe'", "invalid input syntax for type boolean: \"maybe\"", 12 },
        // Even where no row reads it, as PostgreSQL's parser.
        .{ "SELECT 'x'::int FROM t WHERE false", "invalid input syntax for type integer: \"x\"", 7 },
        .{ "INSERT INTO t (b) VALUES ('maybe')", "invalid input syntax for type boolean: \"maybe\"", 26 },
        .{ "UPDATE t SET n = 'abc'", "invalid input syntax for type numeric: \"abc\"", 17 },
        .{ "SELECT '{bad'::jsonb", "invalid input syntax for type json\nDETAIL:  Token \"bad\" is invalid.\nCONTEXT:  JSON data, line 1: {bad", 7 },
        .{ "SELECT true + 1", "operator does not exist: boolean + integer\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.", 12 },
        .{ "SELECT nosuchfunc(1)", "function nosuchfunc(integer) does not exist\nHINT:  No function matches the given name and argument types. You might need to add explicit type casts.", 7 },
    }) |case| {
        var stmt: ?*vi.Vdbe = null;
        try testing.expectEqual(RC.ERROR, prepare.prepareV2(c.db, case[0], &stmt, null));
        errdefer std.debug.print("{s}\n", .{case[0]});
        try testing.expectEqualStrings(case[1], main_mod.errmsg(c.db));
        try testing.expectEqual(case[2], main_mod.errorOffset(c.db));
    }
    // Run-time errors have no position: a numeric(4,4)'s overflow is one
    // (PostgreSQL reads the literal without the type's parameters).
    try c.expectError("INSERT INTO t (n) VALUES ('1.0')", "numeric field overflow\nDETAIL:  A field with precision 4, scale 4 must round to an absolute value less than 1.");
    try testing.expectEqual(@as(i32, -1), main_mod.errorOffset(c.db));
    try c.exec("INSERT INTO t (s) VALUES ('x')");
    try c.expectError("INSERT INTO t (s) VALUES ('x')", "duplicate key value violates unique constraint \"t_s_key\"\nDETAIL:  Key (s)=(x) already exists.");
    // The fields of the message.
    const f = @import("../../sql/util.zig").splitFields(main_mod.errmsg(c.db), c.db.err_state.?.fields);
    try testing.expectEqualStrings("duplicate key value violates unique constraint \"t_s_key\"", f.message);
    try testing.expectEqualStrings("Key (s)=(x) already exists.", f.detail.?);
    // A value the message quotes is no field, whatever its text.
    try c.expectError("SELECT E'1\\nHINT:  x'::int", "invalid input syntax for type integer: \"1\nHINT:  x\"");
    const g = @import("../../sql/util.zig").splitFields(main_mod.errmsg(c.db), c.db.err_state.?.fields);
    try testing.expectEqualStrings("invalid input syntax for type integer: \"1\nHINT:  x\"", g.message);
    try testing.expect(g.hint == null);
    // One the key holds is the DETAIL's.
    try c.expectError("INSERT INTO t (s) VALUES (E'y\\nHINT:  z'), (E'y\\nHINT:  z')", "duplicate key value violates unique constraint \"t_s_key\"\nDETAIL:  Key (s)=(y\nHINT:  z) already exists.");
    const h = @import("../../sql/util.zig").splitFields(main_mod.errmsg(c.db), c.db.err_state.?.fields);
    try testing.expectEqualStrings("Key (s)=(y\nHINT:  z) already exists.", h.detail.?);
    try testing.expect(h.hint == null);
}

test "pg: a call no function matches names the argument types" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a int, b text, c numeric(5,2), d timestamp, e varchar(3))");
    const hint = "\nHINT:  No function matches the given name and argument types. You might need to add explicit type casts.";
    const cases = [_][2][]const u8{
        .{ "SELECT foo(1, 'a')", "function foo(integer, unknown) does not exist" },
        .{ "SELECT foo(NULL, 1.5, 3000000000, true, '{1}'::int[], now())", "function foo(unknown, numeric, bigint, boolean, integer[], timestamp with time zone) does not exist" },
        .{ "SELECT foo()", "function foo() does not exist" },
        .{ "SELECT foo(a, b, c, d, e) FROM t", "function foo(integer, text, numeric, timestamp without time zone, character varying) does not exist" },
        .{ "SELECT foo(a + 1, upper(b)) FROM t", "function foo(integer, text) does not exist" },
        // A function of another number of arguments.
        .{ "SELECT round(1, 2, 3)", "function round(integer, integer, integer) does not exist" },
        .{ "SELECT count(1, 2)", "function count(integer, integer) does not exist" },
        .{ "SELECT upper()", "function upper() does not exist" },
    };
    for (cases) |k| {
        const want = try std.mem.concat(testing.allocator, u8, &.{ k[1], hint });
        defer testing.allocator.free(want);
        try c.expectError(k[0], want);
        try testing.expectEqual(@as(i32, 7), main_mod.errorOffset(c.db));
    }
    // An error of an argument comes first, as PostgreSQL resolves the
    // arguments before the call.
    try c.expectError("SELECT foo(x) FROM t", "column \"x\" does not exist");
    // SQLite's dialect keeps SQLite's message.
    main_mod.setDialect(c.db, .sqlite);
    try c.expectError("SELECT foo(1)", "no such function: foo");
    try c.expectError("SELECT upper()", "wrong number of arguments to function upper()");
}

/// The notices (int.Notice) of `sql` compiled in the connection's dialect,
/// one "SQLSTATE message" line each (and its DETAIL).
fn expectNotices(c: *Conn, sql: []const u8, want: []const u8) !void {
    var v: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, sql, &v, null));
    defer _ = api.finalize(v.?);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (v.?.xq_notices) |n| {
        try out.print(testing.allocator, "{s} {s}\n", .{ &n.sqlstate, n.fields.message });
        if (n.fields.detail) |d| try out.print(testing.allocator, "DETAIL: {s}\n", .{d});
    }
    try testing.expectEqualStrings(want, out.items);
    while (api.step(v.?) == RC.ROW) {}
}

test "pg: notices of what IF EXISTS and IF NOT EXISTS skip" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try expectNotices(&c, "DROP TABLE IF EXISTS a, b", "00000 table \"a\" does not exist, skipping\n00000 table \"b\" does not exist, skipping\n");
    try expectNotices(&c, "DROP VIEW IF EXISTS v", "00000 view \"v\" does not exist, skipping\n");
    try expectNotices(&c, "DROP INDEX IF EXISTS i", "00000 index \"i\" does not exist, skipping\n");
    try expectNotices(&c, "DROP SEQUENCE IF EXISTS s", "00000 sequence \"s\" does not exist, skipping\n");
    try expectNotices(&c, "DROP SCHEMA IF EXISTS s", "00000 schema \"s\" does not exist, skipping\n");
    try expectNotices(&c, "ALTER TABLE IF EXISTS t ADD COLUMN b int", "00000 relation \"t\" does not exist, skipping\n");
    try expectNotices(&c, "CREATE TABLE t (a int)", "");
    try expectNotices(&c, "CREATE TABLE IF NOT EXISTS t (a int)", "42P07 relation \"t\" already exists, skipping\n");
    try expectNotices(&c, "CREATE INDEX i ON t (a)", "");
    try expectNotices(&c, "CREATE INDEX IF NOT EXISTS i ON t (a)", "42P07 relation \"i\" already exists, skipping\n");
    try expectNotices(&c, "CREATE SEQUENCE s", "");
    try expectNotices(&c, "CREATE SEQUENCE IF NOT EXISTS s", "42P07 relation \"s\" already exists, skipping\n");
    // A relation of the name that is not a table: skipped too.
    try expectNotices(&c, "CREATE TABLE IF NOT EXISTS s (a int)", "42P07 relation \"s\" already exists, skipping\n");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name = 's'", "0\n");
    try expectNotices(&c, "ALTER TABLE t ADD COLUMN IF NOT EXISTS a int", "42701 column \"a\" of relation \"t\" already exists, skipping\n");
    try expectNotices(&c, "ALTER TABLE t DROP COLUMN IF EXISTS z", "00000 column \"z\" of relation \"t\" does not exist, skipping\n");
    try expectNotices(&c, "CREATE SCHEMA sc", "");
    try expectNotices(&c, "CREATE SCHEMA IF NOT EXISTS sc", "42P06 schema \"sc\" already exists, skipping\n");
    try expectNotices(&c, "CREATE TABLE sc.x (a int)", "");
    try expectNotices(&c, "CREATE TABLE IF NOT EXISTS sc.x (a int)", "42P07 relation \"x\" already exists, skipping\n");
    try expectNotices(&c, "DROP SCHEMA sc CASCADE", "00000 drop cascades to table sc.x\n");
    try c.exec("CREATE SCHEMA sc; CREATE TABLE sc.x (a int); CREATE TABLE sc.y (a int)");
    // A line for each object (in the order of the schema's hash, not
    // PostgreSQL's order of creation).
    {
        var v: ?*vi.Vdbe = null;
        try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "DROP SCHEMA sc CASCADE", &v, null));
        defer _ = api.finalize(v.?);
        const n = v.?.xq_notices;
        try testing.expectEqual(@as(usize, 1), n.len);
        try testing.expectEqualStrings("drop cascades to 2 other objects", n[0].fields.message);
        const d = n[0].fields.detail.?;
        try testing.expect(std.mem.eql(u8, d, "drop cascades to table sc.x\ndrop cascades to table sc.y") or
            std.mem.eql(u8, d, "drop cascades to table sc.y\ndrop cascades to table sc.x"));
        while (api.step(v.?) == RC.ROW) {}
    }
    try expectNotices(&c, "DROP TABLE IF EXISTS t", "");
    // client_min_messages: what a client is sent (Db.noticeLevel()).
    const dialect = @import("../dialect.zig");
    try testing.expectEqual(int.Notice.Level.notice, dialect.noticeLevel(c.db));
    try c.exec("SET client_min_messages = warning");
    try testing.expectEqual(int.Notice.Level.warning, dialect.noticeLevel(c.db));
    try c.exec("SET client_min_messages TO DEBUG1");
    try testing.expectEqual(int.Notice.Level.debug, dialect.noticeLevel(c.db));
    try c.exec("RESET client_min_messages");
    try testing.expectEqual(int.Notice.Level.notice, dialect.noticeLevel(c.db));
    // SQLite's dialect has none.
    main_mod.setDialect(c.db, .sqlite);
    try expectNotices(&c, "DROP TABLE IF EXISTS nope", "");
    try expectNotices(&c, "CREATE TABLE IF NOT EXISTS lt (a)", "");
    try expectNotices(&c, "CREATE TABLE IF NOT EXISTS lt (a)", "");
    try testing.expectEqual(int.Notice.Level.debug, dialect.noticeLevel(c.db));
}

test "pg: errors in PostgreSQL's words" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a int, b int); CREATE TABLE u (a int)");
    try c.expectError("SELECT * FROM nosuch", "relation \"nosuch\" does not exist");
    try c.expectError("SELECT nosuch FROM t", "column \"nosuch\" does not exist");
    try c.expectError("SELECT a FROM t, u", "column reference \"a\" is ambiguous");
    try c.expectError("SELECT nosuchfunc(1)", "function nosuchfunc(integer) does not exist\nHINT:  No function matches the given name and argument types. You might need to add explicit type casts.");
    try c.expectError("CREATE TABLE t (x int)", "relation \"t\" already exists");
    try c.expectError("SELECT 1 FROM t WHERE", "syntax error at end of input");
    try c.expectError("SELECT a b c FROM t", "syntax error at or near \"c\"");
    try c.expectError("SELECT ARRAY[]", "cannot determine type of empty array\nHINT:  Explicitly cast to the desired type, for example ARRAY[]::integer[].");
    try c.expectError("SELECT 1 FROM t LATERAL", "syntax error at or near \"LATERAL\"");
    try c.expectError("CREATE TYPE mood AS ENUM ('a')", "CREATE TYPE is not supported");
    try c.expectError("LISTEN chan", "syntax error at or near \"LISTEN\"");
    try c.expectError("SELECT 1 ## 2", "operator does not exist: ##\nHINT:  No operator matches the given name and argument types. You might need to add explicit type casts.");
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
    // ANALYZE takes PostgreSQL's arguments: VERBOSE, schema public.
    try c.exec("INSERT INTO t VALUES (1, 'x'), (1, 'y'), (2, 'z')");
    try expectSameCode(&c, "ANALYZE VERBOSE public.t", "ANALYZE main.t");
    try expectSameCode(&c, "ANALYZE t_a", "ANALYZE t_a");
    try c.expectRows("ANALYZE public.t; SELECT tbl, idx, stat FROM sqlite_stat1", "t|t_a|3 2\n");
    try c.expectRows("ANALYZE; SELECT count(*) FROM sqlite_stat1 WHERE tbl = 't'", "1\n");
    try c.expectError("ANALYZE nosuch", "relation \"nosuch\" does not exist");
    // Back to SQLite.
    try c.exec("PRAGMA xq_dialect = 'sqlite'");
    try c.expectRows("SELECT 'a' LIKE 'A'", "1\n");
}

test "pg: what the schema keeps means the same in every dialect" {
    try @import("../dialect.zig").Dialect.requireBuilt(&.{.mariadb});
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE w (s text, n int CHECK (greatest(n, 0) < 100));
        \\INSERT INTO w VALUES ('Abc', 1), ('abc', 2);
        \\CREATE VIEW wv AS SELECT s, s LIKE 'a%' AS cs, s ILIKE 'a\_%' AS ci, greatest(n, 5) AS g, 7 / 2 AS d, 'x' || NULL AS c, n::boolean AS b FROM w ORDER BY n;
    );
    const rows = "Abc|0|0|5|3|NULL|1\nabc|1|0|5|3|NULL|1\n";
    try c.expectRows("SELECT * FROM wv", rows);
    try c.expectRows("SELECT instr(sql, 'xq_postgres_greatest(') > 0 FROM sqlite_schema WHERE name = 'wv'", "1\n");
    for ([_]@import("../dialect.zig").Dialect{ .sqlite, .mariadb }) |d| {
        main_mod.setDialect(c.db, d);
        try c.expectRows("SELECT * FROM wv", rows);
        try c.expectError("INSERT INTO w VALUES ('x', 200)", if (d == .sqlite) "CHECK constraint failed: w_n_check" else "CONSTRAINT `w_n_check` failed for `main`.`w`");
    }
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

test "pg: schemas" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE SCHEMA sales;
        \\CREATE TABLE sales.orders (id serial PRIMARY KEY, amt int, note varchar(5));
        \\CREATE TABLE orders (id int);
        \\CREATE INDEX ON sales.orders (amt);
        \\CREATE INDEX by_note ON sales.orders (note);
        \\CREATE SEQUENCE sales.tickets START 10;
        \\INSERT INTO sales.orders (amt) VALUES (10), (20);
        \\CREATE VIEW sales.big AS SELECT o.id FROM sales.orders o WHERE amt > 10;
    );
    // Objects of the schema are main objects named "sales.x"; the registry
    // is a row of xq_catalog.
    try c.expectRows("SELECT type, name FROM sqlite_schema WHERE name LIKE 'sales.%' ORDER BY name", "view|sales.big\nindex|sales.by_note\ntable|sales.orders\nindex|sales.orders_amt_idx\n");
    try c.expectRows("SELECT col, value FROM xq_catalog WHERE tbl = '' AND key = 'schema'", "sales|postgres\n");
    try c.expectRows("SELECT name FROM xq_sequence ORDER BY name", "sales.orders_id_seq\nsales.tickets\n");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 'sales.big'", "CREATE VIEW \"sales.big\" AS SELECT \"o\".\"id\" FROM \"sales.orders\" AS \"o\" WHERE (\"amt\" > 10)\n");
    // Qualified names everywhere; the table's bare name qualifies columns.
    try c.expectRows("SELECT orders.id, sales.orders.amt FROM sales.orders ORDER BY 1", "1|10\n2|20\n");
    try c.expectRows("UPDATE sales.orders SET amt = orders.amt + 1 WHERE id = 1 RETURNING orders.amt", "11\n");
    try c.expectRows("SELECT * FROM sales.big ORDER BY 1", "1\n2\n");
    try c.expectRows("SELECT nextval('sales.tickets'), nextval('SALES.TICKETS')", "10|11\n");
    try c.expectRows("SELECT count(*) FROM orders", "0\n");
    try c.expectRows("SELECT table_schema, table_name FROM information_schema.tables ORDER BY 1, 2", "public|orders\nsales|big\nsales|orders\n");
    try c.expectRows("SELECT schemaname, indexname FROM pg_indexes WHERE schemaname <> 'pg_catalog' ORDER BY 2", "sales|by_note\nsales|orders_amt_idx\nsales|orders_pkey\n");
    // Errors in PostgreSQL's words.
    try c.expectError("CREATE SCHEMA sales", "schema \"sales\" already exists");
    try c.expectError("CREATE SCHEMA pg_x", "unacceptable schema name \"pg_x\"\nDETAIL:  The prefix \"pg_\" is reserved for system schemas.");
    try c.expectError("CREATE SCHEMA \"a.b\"", "xqlite: a schema name cannot contain \".\"");
    try c.expectError("CREATE TABLE nosuch.t (a int)", "schema \"nosuch\" does not exist");
    try c.expectError("SELECT * FROM nosuch.t", "relation \"nosuch.t\" does not exist");
    try c.expectError("SELECT * FROM sales.nosuch", "relation \"sales.nosuch\" does not exist");
    try c.expectError("CREATE TABLE sales.orders (a int)", "relation \"orders\" already exists");
    try c.expectError("DROP TABLE sales.nosuch", "table \"nosuch\" does not exist");
    try c.expectError("DROP SCHEMA sales", "cannot drop schema sales because other objects depend on it\nDETAIL:  view sales.big depends on schema sales\ntable sales.orders depends on schema sales\nsequence sales.tickets depends on schema sales\nHINT:  Use DROP ... CASCADE to drop the dependent objects too.");
    // ALTER TABLE keeps the table in its schema.
    try c.exec("ALTER TABLE sales.orders RENAME TO ord");
    try c.expectRows("SELECT count(*) FROM sales.ord", "2\n");
    try c.expectRows("SELECT * FROM sales.big ORDER BY 1", "1\n2\n");
    // DROP SCHEMA ... CASCADE drops everything, catalog and sequences too.
    try c.exec("DROP SCHEMA sales CASCADE");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE name LIKE 'sales.%'", "");
    try c.expectRows("SELECT count(*) FROM xq_catalog WHERE tbl LIKE 'sales.%' OR col = 'sales'", "0\n");
    try c.expectRows("SELECT count(*) FROM xq_sequence", "0\n");
    try c.expectError("SELECT * FROM sales.ord", "relation \"sales.ord\" does not exist");
    try c.exec("DROP SCHEMA IF EXISTS sales");
    try c.exec("PRAGMA integrity_check");
}

test "pg: search_path" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE SCHEMA a;
        \\CREATE SCHEMA b;
        \\CREATE TABLE a.t (x int);
        \\CREATE TABLE b.t (x int);
        \\CREATE TABLE t (x int);
        \\INSERT INTO a.t VALUES (1);
        \\INSERT INTO b.t VALUES (2);
        \\INSERT INTO t VALUES (3);
    );
    try c.expectRows("SHOW search_path", "\"$user\", public\n");
    try c.expectColumns("SHOW search_path", "search_path");
    try c.expectRows("SELECT current_schema(), current_schema, current_schemas(true)", "public|public|{pg_catalog,public}\n");
    // A prepared statement is compiled again when search_path changes.
    var stmt: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT x FROM t", &stmt, null));
    defer _ = api.finalize(stmt.?);
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqual(@as(i64, 3), api.columnInt64(stmt.?, 0));
    _ = api.reset(stmt.?);
    try c.exec("SET search_path TO b, a");
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqual(@as(i64, 2), api.columnInt64(stmt.?, 0));
    _ = api.reset(stmt.?);
    try c.expectRows("SHOW search_path", "b, a\n");
    try c.expectRows("SELECT current_schema(), current_schemas(false)", "b|{b,a}\n");
    // DDL creates in the first schema of the path; names resolve along it.
    try c.exec("SET search_path = a, public; CREATE TABLE u (y int); INSERT INTO u VALUES (5)");
    try c.expectRows("SELECT y FROM a.u", "5\n");
    try c.expectRows("SELECT x, y FROM t JOIN u ON true", "1|5\n");
    try c.exec("CREATE SEQUENCE q; CREATE TABLE ser (id serial, v int); INSERT INTO ser (v) VALUES (1)");
    try c.expectRows("SELECT nextval('q'), currval('a.q')", "1|1\n");
    try c.expectRows("SELECT name FROM xq_sequence ORDER BY name", "a.q\na.ser_id_seq\n");
    try c.exec("SET search_path = nonexistent");
    try c.expectError("CREATE TABLE w (z int)", "no schema has been selected to create in");
    try c.expectError("SELECT x FROM t", "relation \"t\" does not exist");
    try c.expectRows("SELECT current_schema() IS NULL", "1\n");
    try c.exec("RESET search_path");
    try c.expectRows("SELECT x FROM t", "3\n");
    try c.exec("SET SCHEMA 'b'");
    try c.expectRows("SELECT x FROM t", "2\n");
    try c.expectError("SET nosuch = 1", "unrecognized configuration parameter \"nosuch\"");
    try c.exec("SET application_name = 'xq'");
    try c.expectRows("SHOW application_name", "xq\n");
    // The SQLite dialect sees the mangled names.
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT x FROM \"b.t\"", "2\n");
}

test "pg: DDL in an attached database" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\ATTACH ':memory:' AS aux;
        \\CREATE TABLE aux.t (id int PRIMARY KEY, v varchar(3));
        \\CREATE INDEX ON aux.t (v);
        \\CREATE VIEW aux.tv AS SELECT v FROM aux.t;
        \\INSERT INTO aux.t VALUES (1, 'a');
        \\ALTER TABLE aux.t ADD COLUMN w int;
    );
    try c.expectRows("SELECT type, name FROM aux.sqlite_schema ORDER BY name", "table|t\nindex|t_v_idx\nview|tv\ntable|xq_catalog\n");
    try c.expectRows("SELECT v FROM aux.tv", "a\n");
    try c.expectError("INSERT INTO aux.t VALUES (2, 'long')", "value too long for type character varying(3)");
    try c.expectError("CREATE SEQUENCE aux.s", "xqlite: sequences are only supported in public and in schemas of CREATE SCHEMA");
    try c.expectError("CREATE SCHEMA aux", "schema \"aux\" already exists");
    try c.exec("DROP VIEW aux.tv; DROP TABLE aux.t");
    try c.expectRows("SELECT count(*) FROM aux.sqlite_schema WHERE name <> 'xq_catalog'", "0\n");
}

const catalog = @import("../../catalog/catalog.zig");
const Type = @import("../../sql/types.zig").Type;

/// Expect the declared type the catalog in memory has for column `col`
/// of `tbl` (in main) to be `want`.
fn expectDecl(c: *Conn, tbl: []const u8, col: []const u8, want: ?[]const u8) !void {
    const m = try catalog.meta(c.db, "main", tbl);
    const got = if (m) |x| x.declType(col) else null;
    if (want) |w| {
        try testing.expectEqualStrings(w, got orelse return error.TestExpectedEqual);
    } else try testing.expectEqual(@as(?[]const u8, null), got);
}

fn expectNoMeta(c: *Conn, tbl: []const u8) !void {
    try testing.expectEqual(@as(?*const catalog.TableMeta, null), try catalog.meta(c.db, "main", tbl));
}

test "pg: the catalog in memory follows DDL, rollbacks and other connections" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a varchar(5), id int GENERATED ALWAYS AS IDENTITY)");
    const m = (try catalog.meta(c.db, "main", "t")).?;
    // Read once.
    try testing.expectEqual(m, (try catalog.meta(c.db, "main", "t")).?);
    try testing.expectEqual(@import("../dialect.zig").Dialect.postgres, m.dialect);
    try testing.expectEqualStrings("postgres", m.dialect_name.?);
    const a = m.column("A").?;
    try testing.expectEqualStrings("character varying(5)", a.decl_type.?);
    try testing.expectEqual(Type{ .logical = .varchar, .length = 5 }, a.type);
    const id = m.column("id").?;
    try testing.expectEqualStrings("t_id_seq", id.identity.?);
    try testing.expect(id.always());
    try testing.expectEqualStrings("always", m.value("ID", catalog.Key.identity_kind).?);
    try expectNoMeta(&c, "nosuch");

    // ALTER TABLE: ADD COLUMN, RENAME COLUMN, RENAME TO, then DROP.
    try c.exec("ALTER TABLE t ADD COLUMN b numeric(10,2)");
    try expectDecl(&c, "t", "b", "numeric(10,2)");
    try testing.expectEqual(Type{ .logical = .numeric, .precision = 10, .scale = 2 }, (try catalog.meta(c.db, "main", "t")).?.column("b").?.type);
    try c.exec("ALTER TABLE t RENAME COLUMN a TO a2");
    try expectDecl(&c, "t", "a", null);
    try expectDecl(&c, "t", "a2", "character varying(5)");
    try c.exec("ALTER TABLE t RENAME TO u");
    try expectNoMeta(&c, "t");
    try expectDecl(&c, "u", "a2", "character varying(5)");
    // The identity still numbers the renamed table's column.
    try c.expectRows("INSERT INTO u (a2) VALUES ('x') RETURNING id", "1\n");
    try c.expectError("INSERT INTO u (id) VALUES (5)", "cannot insert a non-DEFAULT value into column \"id\"\nDETAIL:  Column \"id\" is an identity column defined as GENERATED ALWAYS.\nHINT:  Use OVERRIDING SYSTEM VALUE to override.");
    try c.exec("DROP TABLE u");
    try expectNoMeta(&c, "u");
    // Made again, of other types.
    try c.exec("CREATE TABLE u (a2 text)");
    try expectDecl(&c, "u", "a2", "text");
    try c.exec("INSERT INTO u (a2) VALUES ('long text')");

    // A rolled back CREATE TABLE, and an ALTER rolled back to a
    // savepoint.
    try c.exec("BEGIN; CREATE TABLE r (x varchar(3))");
    try expectDecl(&c, "r", "x", "character varying(3)");
    try c.exec("ROLLBACK");
    try expectNoMeta(&c, "r");
    try c.exec("BEGIN; SAVEPOINT s; ALTER TABLE u ADD COLUMN y char(2)");
    try expectDecl(&c, "u", "y", "character(2)");
    try c.exec("ROLLBACK TO SAVEPOINT s");
    try expectDecl(&c, "u", "y", null);
    try c.exec("COMMIT");

    // A write without a schema change, in a transaction rolled back.
    try c.exec("BEGIN");
    try catalog.set(c.db, "main", "u", "a2", "pg.note", "x");
    try testing.expectEqualStrings("x", (try catalog.meta(c.db, "main", "u")).?.value("a2", "pg.note").?);
    try c.exec("ROLLBACK");
    try testing.expectEqual(@as(?[]const u8, null), (try catalog.meta(c.db, "main", "u")).?.value("a2", "pg.note"));

    // The DDL of another connection, seen once this one sees the schema
    // change.
    var c2: Conn = undefined;
    try c2.openOn(c.mem);
    defer c2.close();
    main_mod.setDialect(c2.db, .postgres);
    try c2.exec("ALTER TABLE u ADD COLUMN z varchar(7)");
    try c.expectRows("SELECT count(z) FROM u", "0\n");
    try expectDecl(&c, "u", "z", "character varying(7)");
    try c2.exec("DROP TABLE u");
    try c.expectError("SELECT * FROM u", "relation \"u\" does not exist");
    try expectNoMeta(&c, "u");
}

test "pg: the schema's expressions in PostgreSQL's words" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // The engine's calls the frontend stored (xq_dec_key(), xq_pg_iv()
    // ...) shown as PostgreSQL's deparser prints the expressions.
    try c.exec("CREATE TABLE d (id int, n numeric(10,2) CHECK (n >= 0), iv interval DEFAULT '2 hours', v varchar(5), j jsonb, ok boolean, g numeric GENERATED ALWAYS AS (n * 2) STORED, CONSTRAINT dc CHECK (v = 'x' OR (j ->> 'a') = 'b' AND ok = 't'))");
    try c.exec("CREATE INDEX d_n ON d ((n + 1)) WHERE iv > '1 hour'");
    try c.exec("CREATE VIEW dv AS SELECT id, n FROM d WHERE n < 10");
    try c.expectRows("SELECT conname, pg_get_constraintdef(oid), pg_get_constraintdef(oid, true), conkey FROM pg_constraint WHERE conrelid = 'd'::regclass AND contype = 'c' ORDER BY 1",
        \\d_n_check|CHECK ((n >= (0)::numeric))|CHECK (n >= 0::numeric)|{2}
        \\dc|CHECK ((((v)::text = 'x'::text) OR (((j ->> 'a'::text) = 'b'::text) AND (ok = true))))|CHECK (v::text = 'x'::text OR (j ->> 'a'::text) = 'b'::text AND ok = true)|{4,5,6}
        \\
    );
    try c.expectRows("SELECT a.attname, pg_get_expr(adbin, adrelid), pg_get_expr(adbin, adrelid, true) FROM pg_attrdef JOIN pg_attribute a ON a.attrelid = adrelid AND a.attnum = adnum WHERE adrelid = 'd'::regclass ORDER BY 1",
        \\g|(n * (2)::numeric)|n * 2::numeric
        \\iv|'02:00:00'::interval|'02:00:00'::interval
        \\
    );
    try c.expectRows("SELECT pg_get_indexdef('d_n'::regclass), pg_get_indexdef('d_n'::regclass, 1, true)",
        \\CREATE INDEX d_n ON public.d USING btree (((n + (1)::numeric))) WHERE (iv > '01:00:00'::interval)|(n + 1::numeric)
        \\
    );
    try c.expectRows("SELECT pg_get_viewdef('dv'::regclass, true)", " SELECT id,\n    n\n   FROM d\n  WHERE n < 10::numeric;\n");
    // What is stored stays the engine's.
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name = 'dv' AND sql LIKE '%xq_dec_key(10)%'", "1\n");
}

test "pg: system catalogs" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE p (id serial PRIMARY KEY, name varchar(20) NOT NULL UNIQUE)");
    try c.exec("CREATE TABLE t (a int PRIMARY KEY, b text DEFAULT 'x' CHECK (length(b) > 1), c numeric(10,2), p int REFERENCES p(id) ON DELETE CASCADE, CONSTRAINT ck CHECK (a > 0 AND c IS NOT NULL), UNIQUE (b, c))");
    try c.exec("CREATE INDEX t_b ON t (lower(b)) WHERE a > 5");
    try c.exec("CREATE VIEW v AS SELECT a, b FROM t WHERE a > 1");
    try c.exec("CREATE SCHEMA sales");
    try c.exec("CREATE TABLE sales.orders (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, at timestamptz DEFAULT now(), flag boolean NOT NULL DEFAULT false)");
    try c.expectRows("SELECT n.nspname, c.relname, c.relkind, c.relnatts, c.relchecks, c.relhasindex, c.relhastriggers FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1, 2",
        \\public|p|r|2|0|1|1
        \\public|p_id_seq|S|3|0|0|0
        \\public|p_name_key|i|1|0|0|0
        \\public|p_pkey|i|1|0|0|0
        \\public|t|r|4|2|1|1
        \\public|t_b|i|1|0|0|0
        \\public|t_b_c_key|i|2|0|0|0
        \\public|t_pkey|i|1|0|0|0
        \\public|v|v|2|0|0|0
        \\sales|orders|r|3|0|1|0
        \\sales|orders_id_seq|S|3|0|0|0
        \\sales|orders_pkey|i|1|0|0|0
        \\
    );
    // One OID in every catalog, the reg* casts and ::oid.
    try c.expectRows("SELECT 't'::regclass::oid = (SELECT oid FROM pg_class WHERE relname = 't'), (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid WHERE c.relname = 't'), (SELECT count(*) FROM pg_index WHERE indrelid = 't'::regclass), 'pg_class'::regclass::oid, 'public'::regnamespace::oid, 'integer'::regtype::oid, 'character varying'::regtype::oid", "1|10|3|1259|2200|23|1043\n");
    try c.expectRows("SELECT 't'::regclass, 'sales.orders'::regclass, 'p'::regclass::text, 23::regtype, 2200::regnamespace, 'pg_catalog.array_in'::regproc", "t|sales.orders|p|integer|public|array_in\n");
    try c.expectError("SELECT 'nosuch'::regclass", "relation \"nosuch\" does not exist");
    try c.expectRows("SELECT to_regclass('nosuch') IS NULL, to_regclass('t') = 't'::regclass", "1|1\n");
    // An OID stays when other objects come and go.
    const before = try c.query("SELECT 't'::regclass::oid");
    defer testing.allocator.free(before);
    try c.exec("CREATE TABLE zz (x int); DROP TABLE zz; CREATE TABLE aa (x int)");
    const after = try c.query("SELECT 't'::regclass::oid");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try c.exec("DROP TABLE aa");
    // Built-in types are PostgreSQL's.
    try c.expectRows("SELECT oid, typname, typlen, typcategory FROM pg_type WHERE typname IN ('int4', 'text', 'varchar', '_int4', 'jsonb') ORDER BY oid", "23|int4|4|N\n25|text|-1|S\n1007|_int4|-1|A\n1043|varchar|-1|S\n3802|jsonb|-1|U\n");
    try c.expectRows("SELECT count(*) FROM pg_type WHERE typrelid = 't'::regclass AND typname = 't' AND typtype = 'c'", "1\n");
    // Columns, as psql's \d reads them.
    try c.expectRows(
        \\SELECT a.attname, format_type(a.atttypid, a.atttypmod),
        \\  (SELECT pg_get_expr(d.adbin, d.adrelid, true) FROM pg_attrdef d WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum AND a.atthasdef),
        \\  a.attnotnull, a.attidentity
        \\FROM pg_attribute a WHERE a.attrelid = 'sales.orders'::regclass AND a.attnum > 0 ORDER BY a.attnum
    ,
        \\id|bigint|NULL|1|a
        \\at|timestamp with time zone|now()|0|
        \\flag|boolean|false|1|
        \\
    );
    try c.expectRows("SELECT attname, pg_get_expr(d.adbin, d.adrelid) FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum WHERE d.adrelid IN ('p'::regclass, 't'::regclass) ORDER BY 1", "b|'x'::text\nid|nextval('p_id_seq'::regclass)\n");
    try c.expectRows("SELECT attname, format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'v'::regclass ORDER BY attnum", "a|integer\nb|text\n");
    // PostgreSQL 18: a NOT NULL (and a primary key's column) is a
    // constraint too.
    try c.expectRows("SELECT conname, contype, pg_get_constraintdef(oid, true) FROM pg_constraint WHERE conrelid = 't'::regclass ORDER BY 1",
        \\ck|c|CHECK (a > 0 AND c IS NOT NULL)
        \\t_a_not_null|n|NOT NULL a
        \\t_b_c_key|u|UNIQUE (b, c)
        \\t_b_check|c|CHECK (length(b) > 1)
        \\t_p_fkey|f|FOREIGN KEY (p) REFERENCES p(id) ON DELETE CASCADE
        \\t_pkey|p|PRIMARY KEY (a)
        \\
    );
    try c.expectRows("SELECT c2.relname, i.indisprimary, i.indisunique, i.indkey, pg_get_indexdef(i.indexrelid, 0, true) FROM pg_index i JOIN pg_class c2 ON c2.oid = i.indexrelid WHERE i.indrelid = 't'::regclass ORDER BY 1",
        \\t_b|0|0|0|CREATE INDEX t_b ON t USING btree (lower(b)) WHERE a > 5
        \\t_b_c_key|0|1|2 3|CREATE UNIQUE INDEX t_b_c_key ON t USING btree (b, c)
        \\t_pkey|1|1|1|CREATE UNIQUE INDEX t_pkey ON t USING btree (a)
        \\
    );
    try c.expectRows("SELECT pg_get_constraintdef(oid), pg_get_indexdef('t_b'::regclass) FROM pg_constraint WHERE conname = 'ck'", "CHECK (((a > 0) AND (c IS NOT NULL)))|CREATE INDEX t_b ON public.t USING btree (lower(b)) WHERE (a > 5)\n");
    try c.expectRows("SELECT pg_get_viewdef('v'::regclass)", " SELECT a,\n    b\n   FROM t\n  WHERE (a > 1);\n");
    try c.expectRows("SELECT pg_get_serial_sequence('p', 'id'), pg_get_serial_sequence('sales.orders', 'id'), pg_get_serial_sequence('t', 'a')", "public.p_id_seq|sales.orders_id_seq|NULL\n");
    try c.expectRows("SELECT d.refobjid = 'p'::regclass, d.refobjsubid, d.deptype FROM pg_depend d WHERE d.objid = 'p_id_seq'::regclass", "1|1|a\n");
    // Visibility follows search_path; a name off the path is qualified.
    try c.expectRows("SELECT relname, pg_table_is_visible(oid) FROM pg_class WHERE relname IN ('t', 'orders') ORDER BY 1", "orders|0\nt|1\n");
    try c.exec("SET search_path TO sales, public");
    try c.expectRows("SELECT 'orders'::regclass, pg_table_is_visible('orders'::regclass)", "orders|1\n");
    try c.exec("RESET search_path");
    // psql's spellings: OPERATOR(), COLLATE pg_catalog.default, three-part
    // column names.
    try c.expectRows("SELECT pg_catalog.pg_class.relname FROM pg_catalog.pg_class WHERE relname OPERATOR(pg_catalog.=) 't' COLLATE pg_catalog.default", "t\n");
    // information_schema's constraints.
    try c.expectRows("SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 't' ORDER BY 1", "ck|CHECK\nt_a_not_null|CHECK\nt_b_c_key|UNIQUE\nt_b_check|CHECK\nt_p_fkey|FOREIGN KEY\nt_pkey|PRIMARY KEY\n");
    try c.expectRows("SELECT constraint_name, column_name, ordinal_position FROM information_schema.key_column_usage WHERE table_name = 't' ORDER BY 1, 3", "t_b_c_key|b|1\nt_b_c_key|c|2\nt_p_fkey|p|1\nt_pkey|a|1\n");
    try c.expectRows("SELECT typeof(ordinal_position), typeof(character_maximum_length), table_catalog FROM information_schema.columns WHERE table_name = 'p' AND column_name = 'name'", "integer|integer|postgres\n");
    // COMMENT ON, for obj_description() and col_description().
    try c.exec("COMMENT ON TABLE t IS 'the t'");
    try c.exec("COMMENT ON COLUMN sales.orders.at IS 'when'");
    // (pg_description has plpgsql's too.)
    try c.expectRows("SELECT obj_description('t'::regclass, 'pg_class'), col_description('sales.orders'::regclass, 2), (SELECT count(*) FROM pg_description)", "the t|when|3\n");
    try c.exec("COMMENT ON TABLE t IS NULL");
    try c.expectRows("SELECT obj_description('t'::regclass)", "NULL\n");
    try c.expectError("COMMENT ON COLUMN t.nosuch IS 'x'", "column \"nosuch\" of relation \"t\" does not exist");
    // The constant and empty relations psql and drivers read.
    try c.expectRows("SELECT datname, pg_encoding_to_char(encoding) FROM pg_database", "postgres|UTF8\n");
    try c.expectRows("SELECT rolname, rolsuper, pg_get_userbyid(oid) FROM pg_roles", "postgres|1|postgres\n");
    try c.expectRows("SELECT amname FROM pg_am WHERE oid = 403", "btree\n");
    try c.expectRows("SELECT count(*) FROM pg_trigger UNION ALL SELECT count(*) FROM pg_policy UNION ALL SELECT count(*) FROM pg_inherits", "0\n0\n0\n");
    try c.expectRows("SELECT has_table_privilege('t', 'SELECT'), has_schema_privilege('public', 'USAGE'), pg_size_pretty(20000::bigint)", "1|1|20 kB\n");
    // Nothing of this is in the file, nor seen by SQLite's dialect.
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name LIKE 'pg%'", "0\n");
    try c.expectError("SELECT * FROM pg_class", "no such table: pg_class");
    main_mod.setDialect(c.db, .postgres);
    try c.exec("PRAGMA integrity_check");
}

test "pg: settings" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.expectRows("SHOW server_version", "18.6 (xqlite)\n");
    try c.expectRows("SHOW server_version_num", "180006\n");
    try c.expectRows("SELECT current_setting('server_version_num')::int >= 180000, version() LIKE 'PostgreSQL 18.%'", "1|1\n");
    try c.expectColumns("SHOW DateStyle", "DateStyle");
    try c.expectRows("SHOW TRANSACTION ISOLATION LEVEL", "read committed\n");
    try c.expectRows("SHOW integer_datetimes", "on\n");
    try c.expectRows("SHOW standard_conforming_strings", "on\n");
    try c.expectError("SET server_version = '1'", "parameter \"server_version\" cannot be changed");
    try c.exec("SET extra_float_digits = 3");
    try c.exec("SET TIME ZONE INTERVAL '+00:00' HOUR TO MINUTE");
    try c.expectRows("SHOW TimeZone", "+00:00\n");
    try c.exec("SET TIME ZONE LOCAL");
    try c.expectRows("SHOW timezone", "UTC\n");
    try c.expectRows("SELECT setting, source FROM pg_settings WHERE name = 'extra_float_digits'", "3|session\n");
    try c.expectRows("SELECT count(*) > 40, count(*) FILTER (WHERE name LIKE 'xqlite%') FROM pg_settings", "1|0\n");
    try c.expectRows("SELECT count(*) > 0 FROM (SELECT 1) x", "1\n");
    // A startup setting is what RESET goes back to.
    try c.expectRows("SELECT xq_pg_startup_setting('application_name', 'app1')", "app1\n");
    try c.exec("SET application_name = 'other'");
    try c.exec("RESET application_name");
    try c.expectRows("SHOW application_name", "app1\n");
    try c.exec("RESET ALL");
    try c.expectRows("SHOW application_name", "app1\n");
}

test "pg: arrays" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // The text of an array of a type is canonical: its elements read and
    // written as the type does.
    try c.expectRows("SELECT '{ 1 , 01, NULL}'::int[], '{yes,off}'::bool[], '{1.50,1e2}'::numeric[], '{\"a b\",c}'::text[], '[0:1]={1,2}'::int[], '{{1,2},{3,4}}'::int[]", "{1,1,NULL}|{t,f}|{1.50,100}|{\"a b\",c}|[0:1]={1,2}|{{1,2},{3,4}}\n");
    try c.expectError("SELECT '{a}'::int[]", "invalid input syntax for type integer: \"a\"");
    try c.expectError("SELECT '{1,2'::int[]", "malformed array literal: \"{1,2\"\nDETAIL:  Unexpected end of input.");
    try c.expectError("SELECT '{{1},{2,3}}'::int[]", "malformed array literal: \"{{1},{2,3}}\"\nDETAIL:  Multidimensional arrays must have sub-arrays with matching dimensions.");
    try c.expectColumns("SELECT '{1}'::int[], ARRAY[1], '{a}'::text[]", "int4|array|text");
    // Columns: TEXT with a check, the declared type in the catalog, values
    // stored canonical.
    try c.exec("CREATE TABLE t (id int, a int[], b bool[], s varchar(10)[])");
    try c.exec("INSERT INTO t VALUES (1, '{3, 1, 2}', '{yes}', '{x,y}'), (2, NULL, ARRAY[false], '{}')");
    try c.expectError("INSERT INTO t VALUES (3, '{x}', NULL, NULL)", "invalid input syntax for type integer: \"x\"");
    try c.expectError("INSERT INTO t VALUES (3, 'x', NULL, NULL)", "malformed array literal: \"x\"\nDETAIL:  Array value must start with \"{\" or dimension information.");
    try c.expectRows("SELECT id, a, b, s FROM t ORDER BY id", "1|{3,1,2}|{t}|{x,y}\n2|NULL|{f}|{}\n");
    try c.expectRows("SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 't'::regclass AND attnum > 1 ORDER BY attnum", "integer[]\nboolean[]\ncharacter varying(10)[]\n");
    try c.expectRows("SELECT instr(sql, '\"a\" TEXT') > 0 FROM sqlite_schema WHERE name = 't'", "1\n");
    // Constructors.
    try c.expectRows("SELECT ARRAY[1,2], ARRAY[true,false], ARRAY['a','b c'], ARRAY[[1,2],[3,4]], ARRAY[1.50, 2], ARRAY[]::int[]", "{1,2}|{t,f}|{a,\"b c\"}|{{1,2},{3,4}}|{1.50,2}|{}\n");
    try c.expectRows("SELECT ARRAY(SELECT id FROM t ORDER BY id DESC), ARRAY(SELECT 1 WHERE false), (SELECT array_agg(id ORDER BY id DESC) FROM t)", "{2,1}|{}|{2,1}\n");
    try c.expectRows("SELECT array_agg(b ORDER BY id) FROM t", "{{t},{f}}\n");
    try c.expectError("SELECT ARRAY[]", "cannot determine type of empty array\nHINT:  Explicitly cast to the desired type, for example ARRAY[]::integer[].");
    // ANY and ALL.
    try c.expectRows("SELECT 1 = ANY(ARRAY[1,2]), 3 = ANY(ARRAY[1,NULL]), 1 = ALL(ARRAY[1,NULL]), 2 = ALL(ARRAY[1,NULL]), 1 = ANY('{}'::int[]), 1 = ALL('{}'::int[]), 1 < ANY(ARRAY[0,2])", "1|NULL|NULL|0|0|1|1\n");
    try c.expectRows("SELECT id FROM t WHERE 2 = ANY(a)", "1\n");
    try c.expectRows("SELECT 'ab' LIKE ANY(ARRAY['a%','x']), 'AB' ILIKE ALL(ARRAY['a%','%b']), 'public' = ANY(current_schemas(true)), true = ANY(ARRAY[false, true])", "1|1|1|1\n");
    try c.expectRows("SELECT id FROM t WHERE id > ANY(SELECT id FROM t)", "2\n");
    try c.expectError("SELECT 1 = ANY(1)", "op ANY/ALL (array) requires array on right side");
    // Subscripts and slices, as the element type's values.
    try c.expectRows("SELECT a[1], a[2] + 1, a[5], a[2:3], a[:1], b[1], typeof(a[1]) FROM t WHERE id = 1", "3|2|NULL|{1,2}|{3}|1|integer\n");
    try c.expectRows("SELECT ('{{1,2},{3,4}}'::int[])[2][1], ('{{1,2},{3,4}}'::int[])[2], ('[0:1]={7,8}'::int[])[0], (current_schemas(true))[1]", "3|NULL|7|pg_catalog\n");
    try c.exec("UPDATE t SET a[2] = 10, b[3] = true WHERE id = 1");
    try c.expectRows("SELECT a, b FROM t WHERE id = 1", "{3,10,2}|{t,NULL,t}\n");
    // Operators and functions.
    try c.expectRows("SELECT ARRAY[1,2] || 3, 0 || ARRAY[1,2], ARRAY[1] || ARRAY[2,3], ARRAY[1,2] @> ARRAY[2], ARRAY[1] <@ ARRAY[1,2], ARRAY[1,2] && ARRAY[3]", "{1,2,3}|{0,1,2}|{1,2,3}|1|1|0\n");
    try c.expectRows("SELECT ARRAY[10] > ARRAY[9], ARRAY[1,2] = '{1, 2}', ARRAY['b'] > ARRAY['a','z'], ARRAY[1] < ARRAY[1,0]", "1|1|1|1\n");
    try c.expectRows("SELECT array_length('{{1,2,3},{4,5,6}}'::int[], 2), array_lower('[0:1]={1,2}'::int[], 1), array_dims('{{1,2,3},{4,5,6}}'::int[]), cardinality(ARRAY[1,2]), array_ndims(ARRAY[[1]])", "3|0|[1:2][1:3]|2|2\n");
    try c.expectRows("SELECT array_position(ARRAY['a','b'], 'b'), array_positions(ARRAY[1,2,1], 1), array_append(ARRAY[true], false), array_remove(ARRAY[1,2,1], 1), array_replace(ARRAY[1,2,1], 1, 9)", "2|{1,3}|{t,f}|{2}|{9,2,9}\n");
    try c.expectRows("SELECT string_to_array('a,b,,c', ',', ''), array_to_string(ARRAY[1,NULL,3], ',', '*'), array_to_json(ARRAY[true])", "{a,b,NULL,c}|1,*,3|[true]\n");
    try c.expectRows("SELECT a FROM (VALUES ('{10}'::int[]), ('{9}'), ('{1,2}')) v(a) ORDER BY a", "{1,2}\n{9}\n{10}\n");
    // unnest(), generate_subscripts(), _pg_expandarray().
    try c.expectRows("SELECT * FROM unnest(ARRAY[1,2], ARRAY['a','b','c'])", "1|a\n2|b\nNULL|c\n");
    try c.expectRows("SELECT x, n FROM unnest(ARRAY['a','b']) WITH ORDINALITY AS u(x, n)", "a|1\nb|2\n");
    try c.expectRows("SELECT t.id, u FROM t, unnest(t.s) u ORDER BY 1, 2", "1|x\n1|y\n");
    try c.expectRows("SELECT unnest(ARRAY[1,2]), generate_subscripts(ARRAY['a','b'], 1)", "1|1\n2|2\n");
    try c.expectRows("SELECT (information_schema._pg_expandarray(ARRAY[5,6])).n, (information_schema._pg_expandarray(ARRAY[5,6])).x", "1|5\n2|6\n");
    // A query of no columns; tableoid; psql's \\dx; pg_type's other
    // types and the arrays of row types; pg_range.
    try c.expectRows("SELECT EXISTS (SELECT FROM t WHERE id = 1), (SELECT count(*) FROM (SELECT FROM t) s)", "1|2\n");
    try c.expectRows("SELECT t.tableoid = 't'::regclass, tableoid::regclass FROM t LIMIT 1", "1|t\n");
    try c.expectRows("SELECT k.tableoid::regclass, count(*) > 0 FROM pg_constraint k GROUP BY 1", "pg_constraint|1\n");
    try c.expectRows("SELECT ae.n, e.extversion, d.description FROM pg_extension e JOIN pg_available_extensions() ae(n, v, c) ON ae.n = e.extname LEFT JOIN pg_description d ON d.objoid = e.oid AND d.classoid = 'pg_extension'::regclass", "plpgsql|1.0|PL/pgSQL procedural language\n");
    try c.expectRows("SELECT a.typname, a.typelem = r.oid, r.typarray = a.oid FROM pg_type r JOIN pg_type a ON a.oid = r.typarray WHERE r.typrelid = 't'::regclass", "_t|1|1\n");
    try c.expectRows("SELECT typname, typarray FROM pg_type WHERE typname IN ('point', 'tsvector', '_pg_stat_io', '_record') ORDER BY 1", "_pg_stat_io|0\n_record|0\npoint|1017\ntsvector|3643\n");
    try c.expectRows("SELECT t.typname, s.typname FROM pg_range r JOIN pg_type t ON t.oid = r.rngtypid JOIN pg_type s ON s.oid = r.rngsubtype ORDER BY 1", "daterange|date\nint4range|int4\nint8range|int8\nnumrange|numeric\ntsrange|timestamp\ntstzrange|timestamptz\n");
    // The catalog's arrays.
    try c.exec("CREATE TABLE p (id int PRIMARY KEY, k int, UNIQUE (k, id))");
    try c.expectRows("SELECT conkey, conkey[1] FROM pg_constraint WHERE conrelid = 'p'::regclass AND contype = 'u'", "{2,1}|2\n");
    try c.expectRows("SELECT indkey, indkey[0], indkey[1] FROM pg_index WHERE indrelid = 'p'::regclass ORDER BY indkey::text", "1|1|NULL\n2 1|2|1\n");
    try c.expectRows("SELECT a.attname FROM pg_constraint con JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey) WHERE con.conrelid = 'p'::regclass AND con.contype = 'u' ORDER BY a.attnum", "id\nk\n");
    // The types: of the columns, of a parameter compared with ANY.
    var stmt: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT b, a[1], ARRAY[true] FROM t WHERE id = ANY($1)", &stmt, null));
    defer _ = api.finalize(stmt.?);
    const engine = @import("../../api/engine.zig");
    try testing.expectEqual(@as(?Type, .{ .logical = .array, .element = .boolean }), engine.resultType(stmt.?, 0));
    try testing.expectEqualStrings("integer", api.columnDecltype(stmt.?, 1).?);
    try testing.expectEqualStrings("boolean[]", api.columnDecltype(stmt.?, 2).?);
    try testing.expectEqual(@as(?Type, .{ .logical = .array, .element = .int4 }), engine.paramType(stmt.?, 1));
    try testing.expectEqual(RC.OK, api.bindText(stmt.?, 1, "{2,3}"));
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqualStrings("{f}", api.columnText(stmt.?, 0).?);
}

test "pg: arrays in the text the schema keeps" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE t (id int, a int[], b bool[], s text[]);
        \\INSERT INTO t VALUES (1, '{3,1,2}', '{t,f}', '{x,y}');
        \\CREATE VIEW v AS SELECT id, a[1] AS first, 2 = ANY(a) AS has2, b[1] AS b1, s || 'z'::text AS s2, ARRAY[true, b[2]] AS bb FROM t;
        \\CREATE VIEW w AS SELECT a > '{3}' AS gt, a < '{10}' AS lt FROM t;
    );
    const rows = "1|3|1|1|{x,y,z}|{t,f}\n";
    try c.expectRows("SELECT * FROM v", rows);
    // Arrays compare in their collation (the dialect's: a view that
    // compares arrays is not read in another dialect).
    try c.expectRows("SELECT * FROM w", "1|1\n");
    try c.expectRows("SELECT instr(sql, 'xq_pg_subscript_k(') > 0 FROM sqlite_schema WHERE name = 'v'", "1\n");
    try c.expectRows("SELECT instr(sql, 'COLLATE xq_pg_array_num') > 0 FROM sqlite_schema WHERE name = 'w'", "1\n");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT * FROM v", rows);
    try c.expectError("INSERT INTO t (a) VALUES ('x')", "CHECK constraint failed: malformed array literal");
}

// ================================================================ numeric

test "pg: numeric columns store keys, in index order" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE n (id int, v numeric(12,4)); CREATE INDEX n_v ON n (v)");
    try c.exec("INSERT INTO n VALUES (1, 10), (2, 9.5), (3, -1), (4, '1e7'), (5, 'NaN'), (6, -0.0001), (7, 0.1 + 0.2)");
    try c.expectRows("SELECT typeof(v), count(*) FROM n GROUP BY 1", "blob|7\n");
    try c.expectRows("SELECT id FROM n ORDER BY v", "3\n6\n7\n2\n1\n4\n5\n");
    try c.expectRows("SELECT id FROM n WHERE v = 0.3", "7\n");
    try c.expectRows("SELECT id FROM n WHERE v > 9.5 AND v < 'NaN' ORDER BY v", "1\n4\n");
    // sqlite3 cannot write a number into the column.
    main_mod.setDialect(c.db, .sqlite);
    defer main_mod.setDialect(c.db, .postgres);
    try c.expectError("INSERT INTO n VALUES (8, 1.5)", "cannot store REAL value in BLOB column n.v");
    try c.expectError("INSERT INTO n VALUES (8, x'40')", "CHECK constraint failed: invalid input syntax for type numeric");
    try c.exec("INSERT INTO n VALUES (8, xq_dec_key('2.5'))");
    try c.expectRows("SELECT xq_dec_text(v) FROM n WHERE id = 8", "2.5\n");
}

test "pg: numeric columns of numbers (made before numerics were keys) keep numbers" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // What the PostgreSQL frontend made of `n numeric(6,2)` before.
    main_mod.setDialect(c.db, .sqlite);
    try c.exec(
        \\CREATE TABLE xq_catalog(tbl TEXT NOT NULL,col TEXT NOT NULL,key TEXT NOT NULL,value,PRIMARY KEY(tbl,col,key))WITHOUT ROWID;
        \\CREATE TABLE old (id INTEGER, n ANY CONSTRAINT "invalid input syntax for type numeric" CHECK (typeof(n) IN ('integer', 'real', 'null'))) STRICT;
        \\INSERT INTO xq_catalog VALUES ('old', '', 'dialect', 'postgres'), ('old', 'n', 'type', 'numeric(6,2)'), ('old', 'id', 'type', 'integer');
    );
    main_mod.setDialect(c.db, .postgres);
    try c.exec("INSERT INTO old VALUES (1, 1.5), (2, '2.25'), (3, 7)");
    try c.exec("INSERT INTO old SELECT 4, n * 2 FROM old WHERE id = 1");
    try c.exec("UPDATE old SET n = n + 0.1 WHERE id = 3");
    try c.expectRows("SELECT id, n, typeof(n) FROM old ORDER BY id", "1|1.5|real\n2|2.25|real\n3|7.1|real\n4|3|integer\n");
    try c.expectRows("SELECT id FROM old WHERE n = 3", "4\n");
    try c.expectRows("SELECT (n * n)::text FROM old WHERE id = 2", "5.0625\n");
}

test "pg: to_char, to_number, pg_input_is_valid and the calls told an argument's type" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE f (i int, b bigint, n numeric, d float8, t timestamp, z timestamptz, v interval)");
    try c.exec("INSERT INTO f VALUES (-42, 4567890123456789, -34338492.215397047, 0.125, '2001-02-16 20:38:40', '2001-02-16 20:38:40+02', '1 year 2 mons 3 days 04:05:06')");
    try c.expectRows("SELECT to_char(i, 'S999'), to_char(b, '9G999G999G999G999G999'), to_char(n, 'FM999999999.999'), to_char(d, '9.99') FROM f", " -42| 4,567,890,123,456,789|-34338492.215|  .12\n");
    try c.expectRows("SELECT to_char(t, 'YYYY-MM-DD HH24:MI TZ'), to_char(z, 'HH24:MI TZ'), to_char(v, 'YYYY MM DD HH24:MI:SS') FROM f", "2001-02-16 20:38 |18:38 UTC|0001 02 03 04:05:06\n");
    try c.expectRows("SELECT to_char(i, 'FMRN'), to_char(12, '99th'), to_number('-34,338,492.654,878', '99G999G999D999G999')::text FROM f", "###############| 12th|-34338492.654878\n");
    try c.expectError("SELECT to_char(1, '9.9.9')", "multiple decimal points");
    try c.expectError("SELECT to_char(3, '9V999999999')", "integer out of range");
    try c.expectRows("SELECT pg_input_is_valid('34', 'int4'), pg_input_is_valid('asdf', 'int4'), pg_input_is_valid('1234.567', 'numeric(7,4)')", "1|0|0\n");
    try c.expectRows("SELECT message, detail, sql_error_code FROM pg_input_error_info('1234.567', 'numeric(7,4)')", "numeric field overflow|A field with precision 7, scale 4 must round to an absolute value less than 10^3.|22003\n");
    try c.expectRows("SELECT gcd(i, 18), lcm(b, 2), gcd(4331.250::numeric, 463.75000::numeric)::text FROM f", "6|9135780246913578|8.75000\n");
    try c.expectError("SELECT gcd((-2147483648)::int4, 0::int4)", "integer out of range");
    try c.expectRows("SELECT date_trunc('hour', t), (t AT TIME ZONE 'UTC')::text, z AT TIME ZONE 'EST' FROM f", "2001-02-16 20:00:00|2001-02-16 20:38:40|2001-02-16 13:38:40\n");
    try c.expectRows("SELECT to_date('20100309', 'YYYYMMDD'), booleq(true, false), float8(b) = 4567890123456789 FROM f", "2010-03-09|0|1\n");
}

test "pg: a CHECK, an index and a view tell the type of an argument as a query does" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE k (z timestamptz, a int, b bigint, n numeric, y text, CHECK (to_char(z, 'TZ') <> ''), CONSTRAINT g CHECK (gcd(a, 0) > 0), CHECK (lcm(b, 2) >= 0), CHECK ((z AT TIME ZONE 'UTC') IS NOT NULL), CHECK (y IS NULL OR timezone(y, z) IS NOT NULL), CHECK (gcd(n, a) > 0), CHECK (lcm(b, a) >= 0), CHECK (z AT TIME ZONE 'UTC' AT TIME ZONE 'EST' > z))");
    // The schema keeps the engine's calls with the type, PostgreSQL's
    // text shows the calls written.
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name = 'k' AND sql LIKE '%xq_pg_to_char(\"z\", ''TZ'', 7)%' AND sql LIKE '%xq_pg_gcd(\"a\", 0, 32)%' AND sql LIKE '%xq_pg_lcm(\"b\", 2, 64)%' AND sql LIKE '%xq_pg_at_time_zone(''UTC'', \"z\", 7)%' AND sql LIKE '%xq_pg_timezone(\"y\", \"z\", 7)%'", "1\n");
    try c.expectRows("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'k'::regclass AND contype = 'c' ORDER BY conname, 1",
        \\CHECK ((gcd(a, 0) > 0))
        \\CHECK ((((z AT TIME ZONE 'UTC'::text) AT TIME ZONE 'EST'::text) > z))
        \\CHECK (((y IS NULL) OR (timezone(y, z) IS NOT NULL)))
        \\CHECK (((z AT TIME ZONE 'UTC'::text) IS NOT NULL))
        \\CHECK ((gcd(n, (a)::numeric) > (0)::numeric))
        \\CHECK ((lcm(b, (2)::bigint) >= 0))
        \\CHECK ((lcm(b, (a)::bigint) >= 0))
        \\CHECK ((to_char(z, 'TZ'::text) <> ''::text))
        \\
    );
    // As the query reads the values: a timestamptz's zone, an integer's
    // range.
    try c.expectRows("SELECT to_char('2001-02-16 20:38:40+02'::timestamptz, 'TZ')", "UTC\n");
    try c.exec("INSERT INTO k VALUES ('2001-02-16 20:38:40+02', 4, 6)");
    try c.expectError("INSERT INTO k VALUES ('2001-02-16 20:38:40+02', -2147483648, 6)", "integer out of range");
    try c.exec("CREATE INDEX k_y ON k (to_char(z, 'YYYY TZ'))");
    try c.expectRows("SELECT pg_get_indexdef('k_y'::regclass)", "CREATE INDEX k_y ON public.k USING btree (to_char(z, 'YYYY TZ'::text))\n");
    try c.expectRows("SELECT a FROM k WHERE to_char(z, 'YYYY TZ') = '2001 UTC'", "4\n");
    try c.exec("CREATE VIEW kv AS SELECT to_char(z, 'HH24 TZ') AS h, gcd(a, 6) AS g FROM k");
    try c.expectRows("SELECT h, g FROM kv", "18 UTC|2\n");
    try c.expectRows("SELECT pg_get_viewdef('kv')", " SELECT to_char(z, 'HH24 TZ'::text) AS h,\n    gcd(a, 6) AS g\n   FROM k;\n");
    // A table made before keeps the calls without the type, which read
    // the values by their storage (a timestamp: no zone), as sqlite3 with
    // the extension does.
    main_mod.setDialect(c.db, .sqlite);
    try c.exec("CREATE TABLE o (z TEXT, CHECK (xq_postgres_to_char(z, 'TZ') = ''))");
    try c.exec("INSERT INTO xq_catalog VALUES ('o', '', 'dialect', 'postgres'), ('o', 'z', 'type', 'timestamp with time zone')");
    main_mod.setDialect(c.db, .postgres);
    try c.exec("INSERT INTO o VALUES ('2001-02-16 20:38:40+02')");
    try c.expectRows("SELECT to_char(z, 'TZ') FROM o", "UTC\n");
}

test "pg: a string literal met by a boolean is read when the statement is compiled" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE b (x boolean, CHECK (x IN ('t') OR x = 'f'))");
    // No row reaches the comparison: the literal fails the statement.
    try c.expectError("SELECT * FROM b WHERE x = 'xyz'", "invalid input syntax for type boolean: \"xyz\"");
    try c.expectError("SELECT * FROM b WHERE 'xyz' <> x", "invalid input syntax for type boolean: \"xyz\"");
    try c.expectError("SELECT * FROM b WHERE x IN ('xyz')", "invalid input syntax for type boolean: \"xyz\"");
    try c.expectError("SELECT 1 WHERE '2024-02-30' <= ('a' LIKE 'h%')", "invalid input syntax for type boolean: \"2024-02-30\"");
    try c.expectRows("SELECT true IN ('yes'), false NOT IN ('t'), true = ' on '", "1|1|1\n");
    // The schema's text says the boolean it read; one that is no boolean
    // fails CREATE as in PostgreSQL.
    try c.exec("CREATE VIEW bv AS SELECT x = 't' AS a, x NOT IN ('no') AS o FROM b");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE sql LIKE '%xq_pg_bool(''t'')%' AND sql LIKE '%NOT IN (xq_pg_bool(''no''))%'", "1\n");
    try c.exec("INSERT INTO b VALUES (true)");
    try c.expectRows("SELECT a, o FROM bv", "1|1\n");
    try c.expectRows("SELECT pg_get_viewdef('bv')", " SELECT (x = true) AS a,\n    (x <> false) AS o\n   FROM b;\n");
    try c.expectError("CREATE VIEW bw AS SELECT 1 FROM b WHERE x = 'xyz'", "invalid input syntax for type boolean: \"xyz\"");
    try c.expectError("CREATE TABLE bc (x boolean CHECK (x <> 'xyz'))", "invalid input syntax for type boolean: \"xyz\"");
    try c.expectError("CREATE TABLE bc (x boolean CHECK (x IN ('xyz')))", "invalid input syntax for type boolean: \"xyz\"");
}

test "pg: a list of IN and the values of CASE read their string literals as a boolean among them" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    // As PostgreSQL's common type of the list, of the results.
    try c.expectRows("SELECT true IN ('yes', 'no'), 'on' IN (true, false), true NOT IN ('f', '0'), CASE WHEN false THEN true ELSE 'no' END, CASE true WHEN 'yes' THEN 1 ELSE 2 END", "1|1|1|0|1\n");
    try c.expectError("SELECT 'x' IN (true, false)", "invalid input syntax for type boolean: \"x\"");
    try c.expectError("SELECT true IN ('t', 'maybe')", "invalid input syntax for type boolean: \"maybe\"");
    try c.expectError("SELECT CASE WHEN true THEN true ELSE 'zz' END", "invalid input syntax for type boolean: \"zz\"");
    try c.expectError("SELECT CASE true WHEN 'q' THEN 1 END", "invalid input syntax for type boolean: \"q\"");
    // A list of no boolean compares text.
    try c.expectRows("SELECT 'yes' IN ('yes', 'no')", "1\n");
    // The schema's text reads them so: a CHECK of true holds.
    try c.exec("CREATE TABLE b (n int, x boolean, CHECK (x IN ('t', 'f')), CHECK (CASE WHEN n > 0 THEN x ELSE 'yes' END), CHECK ('on' IN (x, true, false)))");
    try c.exec("INSERT INTO b VALUES (1, true), (-1, false)");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name = 'b' AND sql LIKE '%IN (xq_pg_bool(''t''), xq_pg_bool(''f''))%' AND sql LIKE '%ELSE xq_pg_bool(''yes'')%'", "1\n");
    try c.expectRows("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'b'::regclass AND contype = 'c' ORDER BY 1",
        \\CHECK (
        \\CASE
        \\    WHEN (n > 0) THEN x
        \\    ELSE true
        \\END)
        \\CHECK (((true = ANY (ARRAY[true, false])) OR (true = x)))
        \\CHECK ((x = ANY (ARRAY[true, false])))
        \\
    );
    try c.exec("CREATE VIEW bv AS SELECT x IN ('t', 'f') AS i, CASE x WHEN 'on' THEN 1 END AS w FROM b");
    try c.expectRows("SELECT i, w FROM bv ORDER BY w", "1|1\n1|NULL\n");
    try c.expectError("CREATE TABLE bc (x boolean CHECK (x IN ('t', 'xyz')))", "invalid input syntax for type boolean: \"xyz\"");
    try c.expectError("CREATE VIEW bw AS SELECT CASE WHEN x THEN x ELSE 'xyz' END FROM b", "invalid input syntax for type boolean: \"xyz\"");
}

test "pg: the catalogs' snapshot keeps no rows while the connection is idle" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a int)");
    // A nested loop reads pg_attribute's rows once a statement.
    try c.expectRows("SELECT count(*) FROM pg_class c, pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND c.oid >= 16384", "1\n");
    const s: *const @import("pgcatalog.zig").Snapshot = @ptrCast(@alignCast(c.db.xq.postgres.catalog.?));
    try testing.expectEqual(@as(u32, 1), s.refs);
    try testing.expectEqual(@as(u32, 0), s.lazy.filled.count());
    try c.expectRows("SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace", "1\n");
}

test "pg: the system relations are in their own catalogs" {
    var c: Conn = undefined;
    try openPg(&c);
    defer c.close();
    try c.expectRows("SELECT relname, relkind, relnamespace, reltype, relnatts, relhasindex, relisshared FROM pg_class WHERE oid = 'pg_class'::regclass", "pg_class|r|11|83|34|1|0\n");
    try c.expectRows("SELECT c.relname, n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relname IN ('tables', 'pg_tables', 'pg_database') ORDER BY 1", "pg_database|pg_catalog\npg_tables|pg_catalog\ntables|information_schema\n");
    try c.expectRows("SELECT attname, format_type(atttypid, atttypmod), attnotnull FROM pg_attribute WHERE attrelid = 'pg_namespace'::regclass AND attnum > 0 ORDER BY attnum", "oid|oid|1\nnspname|name|1\nnspowner|oid|1\nnspacl|aclitem[]|0\n");
    try c.expectRows("SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = 'information_schema.tables'::regclass AND attnum = 1", "information_schema.sql_identifier\n");
    try c.expectRows("SELECT pg_get_indexdef(i.indexrelid), pg_get_constraintdef(k.oid) FROM pg_index i JOIN pg_constraint k ON k.conindid = i.indexrelid WHERE i.indrelid = 'pg_namespace'::regclass ORDER BY 1", "CREATE UNIQUE INDEX pg_namespace_nspname_index ON pg_catalog.pg_namespace USING btree (nspname)|UNIQUE (nspname)\n" ++
        "CREATE UNIQUE INDEX pg_namespace_oid_index ON pg_catalog.pg_namespace USING btree (oid)|PRIMARY KEY (oid)\n");
    try c.expectRows("SELECT 'pg_class'::regclass, 'information_schema.columns'::regclass, pg_table_is_visible('pg_type'::regclass), pg_table_is_visible('information_schema.tables'::regclass)", "pg_class|information_schema.columns|1|0\n");
    try c.expectRows("SELECT typname, typtype, typrelid FROM pg_type WHERE oid IN (83, 13341) ORDER BY 1", "cardinal_number|d|0\npg_class|c|1259\n");
    // Each column of the relation is in pg_attribute, in its order.
    inline for (.{ "pg_class", "pg_attribute", "pg_constraint", "pg_type", "pg_index", "pg_proc", "pg_namespace", "information_schema.views" }) |r| {
        var stmt: ?*vi.Vdbe = null;
        try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT string_agg(attname, '|' ORDER BY attnum) FROM pg_attribute WHERE attrelid = '" ++ r ++ "'::regclass AND attnum > 0", &stmt, null));
        defer _ = api.finalize(stmt.?);
        try testing.expectEqual(RC.ROW, api.step(stmt.?));
        try c.expectColumns("SELECT * FROM " ++ r, api.columnText(stmt.?, 0).?);
    }
    // Hidden where PostgreSQL hides them (psql's \dt).
    try c.exec("CREATE TABLE t (a int)");
    try c.expectRows("SELECT c.relname FROM pg_class c LEFT JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p', '') AND n.nspname <> 'pg_catalog' AND n.nspname !~ '^pg_toast' AND n.nspname <> 'information_schema' AND pg_table_is_visible(c.oid)", "t\n");
}
