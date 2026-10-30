//! End-to-end tests of the Oracle dialect: statements compiled by the
//! Oracle frontend on a connection, against the behaviour Oracle
//! documents (and Oracle Database 23ai shows: tools/dialect/
//! oracle-cases.txt).

const std = @import("std");
const testing = std.testing;
const int = @import("../../sql/sqlite_int.zig");
const main_mod = @import("../../sql/main.zig");
const prepare = @import("../../sql/prepare.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const Conn = @import("../../sql/sql_test.zig").Conn;

const RC = int.RC;

fn openOra(c: *Conn) !void {
    try c.open();
    main_mod.setDialect(c.db, .oracle);
}

/// Compile `ora` in the Oracle dialect and `lite` in SQLite's: the same
/// bytecode (the same IR, so the same plan).
fn expectSameCode(c: *Conn, ora: []const u8, lite: []const u8) !void {
    var a: ?*vi.Vdbe = null;
    var b: ?*vi.Vdbe = null;
    main_mod.setDialect(c.db, .oracle);
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, ora, &a, null));
    defer _ = api.finalize(a.?);
    main_mod.setDialect(c.db, .sqlite);
    defer main_mod.setDialect(c.db, .oracle);
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, lite, &b, null));
    defer _ = api.finalize(b.?);
    const x = a.?.ops.items;
    const y = b.?.ops.items;
    testing.expectEqual(y.len, x.len) catch |err| {
        std.debug.print("{s}\n  vs {s}\n", .{ ora, lite });
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

test "oracle: lexical structure" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.expectRows("SELECT 'it''s', q'[it's]', Q'{a}', q'!b!', N'n', 'a' || 'b' FROM dual", "it's|it's|a|b|n|ab\n");
    try c.expectRows("SELECT 1 /* comment */ + 2 -- rest\n FROM dual", "3\n");
    try c.expectRows("SELECT .5, 1e2, 3. FROM dual", "0.5|100.0|3.0\n");
    // Unquoted names fold to upper case, quoted ones keep their case.
    try c.exec("CREATE TABLE Mixed (Id NUMBER, \"Camel\" VARCHAR2(5))");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'xq\\_%' ESCAPE '\\'", "MIXED\n");
    try c.expectColumns("SELECT id, \"Camel\", mixed.ID FROM mixed", "ID|Camel|ID");
    // Expressions are named after their text, upper case, without blanks.
    try c.expectColumns("SELECT count(*), substr( 'ab' , 1 ), 1 + 2 x FROM mixed", "COUNT(*)|SUBSTR('AB',1)|X");
    try c.expectError("SELECT 'abc FROM dual", "ORA-01756: quoted string not properly terminated");
    try c.expectError("SELECT 1 + FROM dual", "ORA-00936: missing expression");
    try c.expectError("SELECT * FROM nosuch", "ORA-00942: table or view \"NOSUCH\" does not exist");
    try c.expectError("SELECT nosuch FROM dual", "ORA-00904: \"NOSUCH\": invalid identifier");
    try c.expectError("FROB", "ORA-00900: invalid SQL statement");
    // A `/` alone on its line ends a statement, as in SQL*Plus.
    try c.exec("INSERT INTO mixed VALUES (1, 'a')\n/\nINSERT INTO mixed VALUES (2, 'b')\n/\n");
    try c.expectRows("SELECT count(*) FROM mixed", "2\n");
    try c.expectRows("SELECT 4 / 2 FROM dual", "2.0\n");
}

test "oracle: the empty string is NULL" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.expectRows("SELECT CASE WHEN '' IS NULL THEN 'null' END, length(''), 'a' || NULL || 'b', NULL || '', NVL2('', 1, 2) FROM dual", "null|NULL|ab|NULL|2\n");
    try c.expectRows("SELECT CONCAT('a', NULL), CONCAT(NULL, ''), SUBSTR('abc', 4), REPLACE('aa', 'a'), TRIM('  '), LPAD('x', 0), UPPER('') FROM dual", "a|NULL|NULL|NULL|NULL|NULL|NULL\n");
    try c.exec("CREATE TABLE s (v VARCHAR2(10), c CHAR(3))");
    try c.exec("INSERT INTO s VALUES ('', 'a'); INSERT INTO s (v) SELECT '' FROM dual; INSERT INTO s VALUES (:1, :2)");
    try c.expectRows("SELECT count(*), count(v), count(c) FROM s", "3|0|1\n");
    // CHAR(n) is blank-padded.
    try c.expectRows("SELECT '[' || c || ']' FROM s WHERE c IS NOT NULL", "[a  ]\n");
    try c.exec("UPDATE s SET v = 'x'; UPDATE s SET v = '' WHERE ROWNUM = 1");
    try c.expectRows("SELECT count(v) FROM s", "2\n");
}

test "oracle: queries" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE dept (id NUMBER(4) PRIMARY KEY, name VARCHAR2(10));
        \\CREATE TABLE emp (id NUMBER(6) PRIMARY KEY, name VARCHAR2(20) NOT NULL, dept NUMBER(4) REFERENCES dept (id), sal NUMBER(8,2));
        \\INSERT INTO dept VALUES (1, 'eng');
        \\INSERT INTO dept VALUES (2, 'ops');
        \\INSERT INTO dept VALUES (3, 'empty');
        \\INSERT INTO emp VALUES (1, 'ann', 1, 100);
        \\INSERT INTO emp VALUES (2, 'bob', 1, 80);
        \\INSERT INTO emp VALUES (3, 'cid', 2, NULL);
        \\INSERT INTO emp VALUES (4, 'dan', NULL, 50);
        \\COMMIT;
    );
    try c.expectRows("SELECT 1 + 1 FROM dual", "2\n");
    // NULLs sort last ascending and first descending.
    try c.expectRows("SELECT name FROM emp ORDER BY sal", "dan\nbob\nann\ncid\n");
    try c.expectRows("SELECT name FROM emp ORDER BY sal DESC", "cid\nann\nbob\ndan\n");
    // ROWNUM: a LIMIT in WHERE, row_number() elsewhere.
    try c.expectRows("SELECT name FROM (SELECT name FROM emp ORDER BY name DESC) WHERE ROWNUM <= 2", "dan\ncid\n");
    try c.expectRows("SELECT name FROM (SELECT name FROM emp ORDER BY name) WHERE ROWNUM < 2", "ann\n");
    try c.expectRows("SELECT count(*) FROM emp WHERE ROWNUM <= 3", "3\n");
    try c.expectRows("SELECT count(*) FROM emp WHERE ROWNUM > 1", "0\n");
    try c.expectRows("SELECT ROWNUM, name FROM (SELECT name FROM emp ORDER BY name) WHERE ROWNUM <= 2", "1|ann\n2|bob\n");
    try c.expectError("SELECT name FROM emp WHERE ROWNUM + 1 = 2", "xqlite: this ROWNUM condition is not supported");
    try c.expectRows("SELECT name FROM emp ORDER BY id OFFSET 1 ROWS FETCH NEXT 2 ROWS ONLY", "bob\ncid\n");
    // The (+) outer joins.
    try c.expectRows("SELECT e.name, d.name FROM emp e, dept d WHERE e.dept = d.id(+) ORDER BY e.id", "ann|eng\nbob|eng\ncid|ops\ndan|NULL\n");
    try c.expectRows("SELECT d.name, count(e.id) FROM emp e, dept d WHERE e.dept(+) = d.id GROUP BY d.name ORDER BY d.name", "empty|0\neng|2\nops|1\n");
    try c.expectRows("SELECT d.name, e.name FROM dept d, emp e WHERE d.id = e.dept(+) AND e.sal(+) > 90 ORDER BY d.id", "eng|ann\nops|NULL\nempty|NULL\n");
    // Set operators, CTEs (recursive without RECURSIVE).
    try c.expectRows("SELECT id FROM dept MINUS SELECT dept FROM emp ORDER BY 1", "3\n");
    try c.expectRows("WITH r (n) AS (SELECT 1 FROM dual UNION ALL SELECT n + 1 FROM r WHERE n < 4) SELECT sum(n) FROM r", "10\n");
    // Functions.
    try c.expectRows("SELECT NVL(sal, 0), NVL2(dept, 'y', 'n'), DECODE(dept, 1, 'one', NULL, 'none', 'other') FROM emp ORDER BY id", "100|y|one\n80|y|one\n0|y|other\n50|n|none\n");
    try c.expectRows("SELECT LISTAGG(name, ',') WITHIN GROUP (ORDER BY name DESC) FROM emp", "dan,cid,bob,ann\n");
    try c.expectRows("SELECT name, RANK() OVER (ORDER BY sal DESC NULLS LAST) FROM emp ORDER BY id", "ann|1\nbob|2\ncid|4\ndan|3\n");
    try c.expectRows("SELECT SUBSTR('abcdef', -3), SUBSTR('abcdef', 0, 2), INSTR('hello world', 'o', 1, 2), INSTR('hello', 'l', -1), INITCAP('hello wORLD') FROM dual", "def|ab|8|4|Hello World\n");
    try c.expectRows("SELECT LPAD('7', 3, '0'), RPAD('abc', 2), TRIM(LEADING 'x' FROM 'xxa'), TRANSLATE('abc', 'ab', 'x') FROM dual", "007|ab|a|xc\n");
    try c.expectRows("SELECT MOD(10, 3), MOD(5, 0), ROUND(2.5), ROUND(-2.5), ROUND(1.005, 2), TRUNC(-2.7), CEIL(2.1), POWER(2, 10), SQRT(16) FROM dual", "1|5|3|-3|1.01|-2|3|1024|4\n");
    try c.expectRows("SELECT GREATEST(1, 3, 2), LEAST('b', 'a'), GREATEST(1, NULL) FROM dual", "3|a|NULL\n");
    try c.expectRows("SELECT TO_CHAR(1234.5, '9,999.99'), TO_CHAR(0.5), TO_CHAR(12, 'FM000'), TO_NUMBER('1,234', '9,999') FROM dual", " 1,234.50|.5|012|1234\n");
    // LIKE is case-sensitive, with no escape character by default.
    try c.expectRows("SELECT count(*) FROM emp WHERE name LIKE 'A%'", "0\n");
    try c.expectRows("SELECT CASE WHEN 'a\\c' LIKE 'a\\c' THEN 1 ELSE 0 END FROM dual", "1\n");
    // A query without Oracle-specific parts is SQLite's query.
    try expectSameCode(&c, "SELECT name FROM emp WHERE id = 1", "SELECT name FROM emp WHERE id = 1");
}

test "oracle: dates" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec("CREATE TABLE d (id NUMBER, d DATE, ts TIMESTAMP(3))");
    try c.exec("INSERT INTO d VALUES (1, DATE '2024-01-31', TIMESTAMP '2024-01-31 10:20:30.5')");
    try c.exec("INSERT INTO d VALUES (2, TO_DATE('29-02-2024 13:45', 'DD-MM-YYYY HH24:MI'), '2024-03-01 00:00:00.123456')");
    try c.expectRows("SELECT d, ts FROM d ORDER BY id", "2024-01-31 00:00:00|2024-01-31 10:20:30.500000\n2024-02-29 13:45:00|2024-03-01 00:00:00.123000\n");
    try c.expectRows("SELECT d + 1, d - 0.5, ADD_MONTHS(d, 1), LAST_DAY(d) FROM d WHERE id = 1", "2024-02-01 00:00:00|2024-01-30 12:00:00|2024-02-29 00:00:00|2024-01-31 00:00:00\n");
    try c.expectRows("SELECT (SELECT d FROM d WHERE id = 2) - (SELECT d FROM d WHERE id = 1) FROM dual", "29.572916666666668\n");
    try c.expectRows("SELECT MONTHS_BETWEEN(DATE '2024-03-31', DATE '2024-01-31'), TRUNC(DATE '2024-05-17', 'MM'), EXTRACT(YEAR FROM d) FROM d WHERE id = 1", "2|2024-05-01 00:00:00|2024\n");
    try c.expectRows("SELECT TO_CHAR(d, 'fmMonth DD, YYYY HH:MI AM') FROM d WHERE id = 2", "February 29, 2024 1:45 PM\n");
    try c.expectRows("SELECT count(*) FROM d WHERE d > SYSDATE - 36500 AND d < SYSDATE", "2\n");
    try c.expectError("INSERT INTO d (d) VALUES ('yesterday')", "ORA-01861: literal does not match format string");
    try c.expectError("SELECT TO_DATE('2024-13-01', 'YYYY-MM-DD') FROM dual", "ORA-01843: not a valid month");
}

test "oracle: DDL, types and constraints" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE ty (
        \\  n NUMBER(5,2), i INTEGER, v VARCHAR2(3), vc VARCHAR2(2 CHAR), ch CHAR(2), r RAW(2), b BOOLEAN,
        \\  f BINARY_DOUBLE, d DATE DEFAULT SYSDATE, x NUMBER CONSTRAINT x_pos CHECK (x > 0),
        \\  CONSTRAINT ty_uq UNIQUE (v)
        \\) TABLESPACE users PCTFREE 10
    );
    try c.exec("INSERT INTO ty (n, i, v, vc, ch, r, b, f) VALUES (1.005, 2.6, 'abc', 'éé', 'x', '0A0B', TRUE, 1)");
    try c.expectRows("SELECT n, i, v, vc, ch, hex(r), b, f, d IS NOT NULL FROM ty", "1.01|3|abc|éé|x |0A0B|1|1.0|1\n");
    try c.expectRows("SELECT typeof(n), typeof(i), typeof(f) FROM ty", "real|integer|real\n");
    try c.expectError("INSERT INTO ty (v) VALUES ('abcd')", "ORA-12899: value too large for column \"TY\".\"V\" (actual: 4, maximum: 3)");
    try c.expectError("INSERT INTO ty (vc) VALUES ('ééé')", "ORA-12899: value too large for column \"TY\".\"VC\" (actual: 3, maximum: 2)");
    try c.expectError("INSERT INTO ty (n) VALUES (1234.5)", "ORA-01438: value larger than specified precision allowed for this column");
    try c.expectError("INSERT INTO ty (i) VALUES ('x')", "ORA-01722: invalid number");
    try c.expectError("INSERT INTO ty (x) VALUES (0)", "CHECK constraint failed: X_POS");
    try c.expectError("INSERT INTO ty (v) VALUES ('abc')", "UNIQUE constraint failed: TY.V");
    try c.exec("UPDATE ty SET n = '12.5'");
    try c.expectRows("SELECT n FROM ty", "12.5\n");
    // The declared types in the catalog and USER_TAB_COLUMNS.
    try c.expectRows("SELECT column_name, data_type, data_length, data_precision, data_scale, nullable FROM user_tab_columns WHERE table_name = 'TY' AND column_id <= 4 ORDER BY column_id",
        \\N|NUMBER|22|5|2|Y
        \\I|NUMBER|22|NULL|0|Y
        \\V|VARCHAR2|3|NULL|NULL|Y
        \\VC|VARCHAR2|8|NULL|NULL|Y
        \\
    );
    // sqlite3 reads the table: STRICT with the checks of the types.
    try c.expectRows("SELECT sql LIKE '%STRICT' FROM sqlite_schema WHERE name = 'TY'", "1\n");
    // Keys are NOT NULL.
    try c.exec("CREATE TABLE k (id NUMBER(10) PRIMARY KEY, v VARCHAR2(5))");
    try c.expectError("INSERT INTO k VALUES (NULL, 'a')", "ORA-01400: cannot insert NULL into (\"K\".\"ID\")");
    try c.expectError("CREATE TABLE k (x NUMBER)", "ORA-00955: name is already used by an existing object");
    // Views, indexes, ALTER, TRUNCATE, COMMENT, RENAME, DROP.
    try c.exec(
        \\INSERT INTO k VALUES (1, 'a');
        \\CREATE OR REPLACE VIEW kv AS SELECT id, v || '!' AS w FROM k;
        \\CREATE OR REPLACE VIEW kv AS SELECT id, v || '?' AS w FROM k WITH READ ONLY;
        \\CREATE UNIQUE INDEX k_v ON k (v DESC);
        \\ALTER TABLE k ADD (n NUMBER DEFAULT 7);
        \\ALTER TABLE k RENAME COLUMN v TO vv;
        \\COMMENT ON TABLE k IS 'keys';
        \\COMMENT ON COLUMN k.vv IS 'a value';
    );
    try c.expectRows("SELECT * FROM kv", "1|a?\n");
    try c.expectRows("SELECT id, vv, n FROM k", "1|a|7\n");
    try c.expectRows("SELECT comments FROM user_tab_comments WHERE table_name = 'K'", "keys\n");
    try c.expectRows("SELECT column_name FROM user_col_comments WHERE table_name = 'K' AND comments IS NOT NULL", "VV\n");
    try c.expectRows("SELECT index_name, uniqueness FROM user_indexes WHERE table_name = 'K'", "K_V|UNIQUE\n");
    try c.exec("ALTER TABLE k DROP COLUMN n; RENAME k TO k2; TRUNCATE TABLE k2");
    try c.expectRows("SELECT count(*) FROM k2", "0\n");
    try c.exec("DROP VIEW kv; DROP TABLE k2 CASCADE CONSTRAINTS PURGE");
    try c.expectError("DROP TABLE k2", "ORA-00942: table or view does not exist");
    try c.expectError("ALTER TABLE ty MODIFY (n NUMBER)", "xqlite: ALTER TABLE ... MODIFY is not supported");
    try c.expectError("BEGIN NULL; END;", "xqlite: PL/SQL is not supported");
}

test "oracle: identity columns and sequences" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE a (id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v VARCHAR2(5));
        \\CREATE TABLE b (id NUMBER GENERATED BY DEFAULT AS IDENTITY (START WITH 100 INCREMENT BY 10), v VARCHAR2(5));
        \\INSERT INTO a (v) VALUES ('x');
        \\INSERT INTO a (v) VALUES ('y');
        \\INSERT INTO b (v) VALUES ('x');
        \\INSERT INTO b (id, v) VALUES (5, 'y');
        \\INSERT INTO b (v) VALUES ('z');
    );
    try c.expectRows("SELECT id, v FROM a", "1|x\n2|y\n");
    try c.expectRows("SELECT id, v FROM b ORDER BY id", "5|y\n100|x\n110|z\n");
    try c.expectError("INSERT INTO a (id, v) VALUES (9, 'z')", "ORA-32795: cannot insert into a generated always identity column");
    try c.expectRows("SELECT column_name, identity_column FROM user_tab_columns WHERE table_name = 'A' ORDER BY column_id", "ID|YES\nV|NO\n");
    try c.exec("CREATE SEQUENCE s START WITH 10 INCREMENT BY 5 NOCACHE NOCYCLE");
    // NEXTVAL increments once per row.
    try c.expectRows("SELECT s.NEXTVAL, s.NEXTVAL, s.CURRVAL FROM dual", "10|10|10\n");
    try c.expectColumns("SELECT s.NEXTVAL FROM dual", "NEXTVAL");
    try c.exec("INSERT INTO a (v) SELECT 'q' || s.NEXTVAL FROM b");
    try c.expectRows("SELECT v FROM a WHERE v LIKE 'q%' ORDER BY v", "q15\nq20\nq25\n");
    try c.expectRows("SELECT sequence_name, increment_by, last_number FROM user_sequences WHERE sequence_name = 'S'", "S|5|30\n");
    try c.expectError("CREATE SEQUENCE s", "ORA-00955: name is already used by an existing object");
    try c.exec("DROP SEQUENCE s");
    try c.expectError("SELECT s.NEXTVAL FROM dual", "ORA-02289: sequence does not exist");
    try c.expectError("DROP SEQUENCE s", "ORA-02289: sequence does not exist");
}

test "oracle: MERGE and INSERT ALL" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE t (id NUMBER PRIMARY KEY, v VARCHAR2(10), n NUMBER);
        \\INSERT INTO t VALUES (1, 'a', 1);
        \\INSERT INTO t VALUES (2, 'b', 2);
        \\INSERT INTO t VALUES (3, 'c', 3);
        \\MERGE INTO t USING (SELECT 1 id, 'A' v FROM dual UNION ALL SELECT 3, 'gone' FROM dual UNION ALL SELECT 4, 'D' FROM dual) s
        \\  ON (t.id = s.id)
        \\  WHEN MATCHED THEN UPDATE SET t.v = s.v, t.n = t.n + 10 DELETE WHERE t.v = 'gone'
        \\  WHEN NOT MATCHED THEN INSERT (id, v, n) VALUES (s.id, s.v, 0);
    );
    try c.expectRows("SELECT id, v, n FROM t ORDER BY id", "1|A|11\n2|b|2\n4|D|0\n");
    try c.expectError("MERGE INTO t USING t s ON (t.id = s.id) WHEN MATCHED THEN UPDATE SET t.id = 1", "ORA-38104: Columns referenced in the ON Clause cannot be updated: \"ID\"");
    try c.exec(
        \\CREATE TABLE lo (id NUMBER, v NUMBER);
        \\CREATE TABLE hi (id NUMBER, v NUMBER);
        \\INSERT FIRST WHEN n < 5 THEN INTO lo VALUES (id, n) ELSE INTO hi VALUES (id, n) SELECT id, n FROM t;
        \\INSERT ALL INTO lo VALUES (id + 100, n) INTO hi (id) VALUES (id + 100) SELECT id, n FROM t WHERE id = 1;
    );
    try c.expectRows("SELECT id, v FROM lo ORDER BY id", "2|2\n4|0\n101|11\n");
    try c.expectRows("SELECT id, v FROM hi ORDER BY id", "1|11\n101|NULL\n");
}

test "oracle: transactions start with the first DML" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec("CREATE TABLE x (id NUMBER)");
    try testing.expect(c.db.auto_commit);
    try c.exec("INSERT INTO x VALUES (1)");
    try testing.expect(!c.db.auto_commit);
    try c.exec("COMMIT");
    try testing.expect(c.db.auto_commit);
    try c.exec("INSERT INTO x VALUES (2); ROLLBACK");
    try c.expectRows("SELECT count(*) FROM x", "1\n");
    try c.exec("INSERT INTO x VALUES (3); SAVEPOINT a; INSERT INTO x VALUES (4); ROLLBACK TO SAVEPOINT a; COMMIT");
    try c.expectRows("SELECT id FROM x ORDER BY id", "1\n3\n");
    // COMMIT and ROLLBACK without a transaction do nothing.
    try c.exec("COMMIT; ROLLBACK; COMMIT WORK");
    // A statement prepared without a transaction runs in one.
    var st: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "INSERT INTO x VALUES (5)", &st, null));
    defer _ = api.finalize(st.?);
    try c.exec("INSERT INTO x VALUES (6)");
    try testing.expectEqual(RC.DONE, api.step(st.?));
    try c.exec("ROLLBACK");
    try c.expectRows("SELECT count(*) FROM x", "2\n");
    // A failing statement leaves no transaction.
    try c.expectError("INSERT INTO x VALUES ('a')", "ORA-01722: invalid number");
    try testing.expect(c.db.auto_commit);
    // Statements that do nothing.
    try c.exec("SET TRANSACTION READ WRITE; ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'; LOCK TABLE x IN EXCLUSIVE MODE");
}

test "oracle: bind variables" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    var st: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT :name || :other, :name, :1 FROM dual", &st, null));
    defer _ = api.finalize(st.?);
    const v = st.?;
    try testing.expectEqual(@as(usize, 2), api.bindParameterCount(v));
    try testing.expectEqualStrings(":other", api.bindParameterName(v, 2).?);
    try testing.expectEqualStrings(":name", api.bindParameterName(v, 1).?);
    try testing.expectEqual(@as(usize, 1), api.bindParameterIndex(v, ":name"));
    try testing.expectEqual(RC.OK, api.bindText(v, 1, "a"));
    try testing.expectEqual(RC.OK, api.bindText(v, 2, "b"));
    try testing.expectEqual(RC.ROW, api.step(v));
    try testing.expectEqualStrings("ab", api.columnText(v, 0).?);
    try testing.expectEqualStrings("a", api.columnText(v, 1).?);
}

test "oracle: data dictionary" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (id NUMBER(10) PRIMARY KEY, ts TIMESTAMP(3) WITH TIME ZONE, note CLOB); CREATE VIEW v AS SELECT id FROM t; CREATE SEQUENCE q");
    try c.expectRows("SELECT table_name, status FROM user_tables", "T|VALID\n");
    try c.expectRows("SELECT owner, table_name FROM all_tables", "MAIN|T\n");
    try c.expectRows("SELECT column_name, data_type, data_scale, nullable FROM user_tab_columns WHERE table_name = 'T' ORDER BY column_id", "ID|NUMBER|0|N\nTS|TIMESTAMP(3) WITH TIME ZONE|3|Y\nNOTE|CLOB|NULL|Y\n");
    try c.expectRows("SELECT view_name FROM user_views", "V\n");
    try c.expectRows("SELECT sequence_name, min_value, increment_by, cycle_flag FROM user_sequences", "Q|1|1|N\n");
    try c.expectRows("SELECT USER FROM dual", "MAIN\n");
}
