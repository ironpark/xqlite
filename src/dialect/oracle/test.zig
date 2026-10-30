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

test "oracle: JSON type columns and IS JSON" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec("CREATE TABLE j (id NUMBER, d JSON, doc VARCHAR2(200) CHECK (doc IS JSON), s CLOB CONSTRAINT strict_ck CHECK (s IS JSON STRICT WITH UNIQUE KEYS))");
    // TEXT with json_valid() (sqlite3 checks it), the type in the catalog.
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 'J'",
        \\CREATE TABLE "J"("ID" ANY CONSTRAINT "ORA-01722: invalid number" CHECK((typeof("ID") IN ('integer', 'real', 'null'))), "D" TEXT CONSTRAINT "ORA-40441: JSON syntax error" CHECK(json_valid("D")), "DOC" TEXT CHECK(xq_ora_is_json("DOC", 0)) CONSTRAINT "ORA-12899: value too large for column (maximum: 200)" CHECK((octet_length("DOC") <= 200)), "S" TEXT CONSTRAINT "STRICT_CK" CHECK(xq_ora_is_json("S", 3))) STRICT
        \\
    );
    try c.expectRows("SELECT column_name, data_type, data_length FROM user_tab_columns WHERE table_name = 'J' AND column_name = 'D'", "D|JSON|8200\n");
    // Stored as Oracle stores JSON: lax syntax read, numbers canonical,
    // compact.
    try c.exec("INSERT INTO j (id, d) VALUES (1, '{\"a\" : 1, b: [1.50, 1e2, true], \"s\": \"x\"}')");
    try c.exec("INSERT INTO j (id, d) VALUES (2, '[1, \"a\"]'); INSERT INTO j (id, d) VALUES (3, '')");
    try c.expectRows("SELECT id, d FROM j ORDER BY id", "1|{\"a\":1,\"b\":[1.5,100,true],\"s\":\"x\"}\n2|[1,\"a\"]\n3|NULL\n");
    try c.expectError("INSERT INTO j (d) VALUES ('bad')", "ORA-40441: JSON syntax error");
    try c.expectError("INSERT INTO j (d) VALUES ('{\"a\":1,\"a\":2}')", "ORA-40444: JSON processing error");
    try c.exec("INSERT INTO j (doc, s) VALUES ('{a:1}', '{\"b\":2}')");
    try c.expectError("INSERT INTO j (doc) VALUES ('bad')", "CHECK constraint failed: xq_ora_is_json(\"DOC\", 0)");
    try c.expectError("INSERT INTO j (s) VALUES ('{\"a\":1,\"a\":2}')", "CHECK constraint failed: STRICT_CK");
    try c.expectError("INSERT INTO j (s) VALUES ('{a:1}')", "CHECK constraint failed: STRICT_CK");
    // IS JSON: lax by default (Oracle's lax syntax), NULL for NULL.
    try c.expectRows(
        "SELECT CASE WHEN x IS JSON THEN 1 ELSE 0 END, CASE WHEN x IS JSON STRICT THEN 1 ELSE 0 END, CASE WHEN x IS NOT JSON THEN 1 ELSE 0 END FROM (SELECT '{a:1}' x FROM dual UNION ALL SELECT '[1,2,]' FROM dual UNION ALL SELECT 'abc' FROM dual UNION ALL SELECT '1' FROM dual)",
        "1|0|0\n1|0|0\n0|0|1\n1|1|0\n",
    );
    try c.expectRows("SELECT '{\"a\":1,\"a\":2}' IS JSON WITH UNIQUE KEYS, '' IS JSON, '1' IS JSON DISALLOW SCALARS FROM dual", "0|NULL|0\n");
    try c.expectError("SELECT '[1]' IS JSON (ARRAY) FROM dual", "ORA-61763: JSON modifier check on IS JSON is only supported on JSON type.");
}

test "oracle: JSON_VALUE, JSON_QUERY, JSON_EXISTS" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.expectRows(
        \\SELECT JSON_VALUE('{"a":"x"}', '$.a'), JSON_VALUE('{"b":1.50}', '$.b'), JSON_VALUE('{"c":true}', '$.c'), JSON_VALUE('{"d":{"e":1}}', '$.d'),
        \\  JSON_VALUE('{"f":[1,2]}', '$.f[1]'), JSON_VALUE('{"f":5}', '$.f[0]'), JSON_VALUE('[{"a":1},{"a":2}]', '$.a'), JSON_VALUE('{"h":1e-2}', '$.h') FROM dual
    , "x|1.5|true|NULL|2|5|NULL|0.01\n");
    try c.expectRows(
        \\SELECT JSON_VALUE('{"a":"12"}', '$.a' RETURNING NUMBER), JSON_VALUE('{"a":"x"}', '$.a' RETURNING NUMBER), JSON_VALUE('{"a":"x"}', '$.b' DEFAULT 'none' ON EMPTY),
        \\  JSON_VALUE('{"a":{}}', '$.a' DEFAULT 'err' ON ERROR), JSON_VALUE('bad', '$.a'), JSON_VALUE('{"a":"abcdef"}', '$.a' RETURNING VARCHAR2(3) TRUNCATE),
        \\  JSON_VALUE('{"a":1.7}', '$.a' RETURNING NUMBER(2)), JSON_VALUE('{"a":"2024-01-02"}', '$.a' RETURNING DATE), JSON_VALUE('{"a":true}', '$.a' RETURNING BOOLEAN) FROM dual
    , "12|NULL|none|err|NULL|abc|2|2024-01-02 00:00:00|1\n");
    try c.expectRows("SELECT JSON_VALUE('{\"a\":[1,2,3]}', '$.a.size()'), JSON_VALUE('{\"a\":[3,1,2]}', '$.a.max()'), JSON_VALUE('{\"a\":[1,2]}', '$.a[last]'), JSON_VALUE('{\"a b\":1}', '$.\"a b\"'), JSON_VALUE('{\"a\":{\"b\":7}}', '$..b') FROM dual", "3|3|2|1|7\n");
    try c.expectError("SELECT JSON_VALUE('{\"a\":{}}', '$.a' ERROR ON ERROR) FROM dual", "ORA-40456: JSON path '$.a' evaluated to non-scalar value.");
    try c.expectError("SELECT JSON_VALUE('{\"a\":1}', '$.b' ERROR ON EMPTY) FROM dual", "ORA-40462: JSON path '$.b' evaluated to no value.");
    try c.expectError("SELECT JSON_VALUE('bad', '$.a' ERROR ON ERROR) FROM dual", "ORA-40441: JSON syntax error");
    try c.expectError("SELECT JSON_VALUE('{}', 'bad path') FROM dual", "ORA-40597: JSON path expression syntax error ('bad path')");
    try c.expectError("SELECT JSON_VALUE('{}', '$.a[') FROM dual", "ORA-40597: JSON path expression syntax error ('$.a[')");
    // The text JSON_VALUE returns compares with a number as one.
    try c.expectRows("SELECT 1 FROM dual WHERE JSON_VALUE('{\"a\":5}', '$.a') = 5", "1\n");
    try c.expectColumns("SELECT JSON_VALUE('{\"a\":1}', '$.a') FROM dual", "JSON_VALUE('{\"A\":1}','$.A')");

    try c.expectRows(
        \\SELECT JSON_QUERY('{"a" : { "b" : 1, "c" : [ 1 , "x" ] }}', '$.a'), JSON_QUERY('{"a":1}', '$.a'), JSON_QUERY('{"a":1}', '$.a' WITH WRAPPER),
        \\  JSON_QUERY('{"a":[1]}', '$.a' WITH CONDITIONAL WRAPPER), JSON_QUERY('{"a":[1,2]}', '$.a[*]' WITH WRAPPER), JSON_QUERY('{"a":[1,2]}', '$.a[*]'),
        \\  JSON_QUERY('{"a":"x"}', '$.b' EMPTY ARRAY ON EMPTY), JSON_QUERY('{"a":"x"}', '$.b' EMPTY OBJECT ON EMPTY), JSON_QUERY('{a:1.50,b:1e2}', '$') FROM dual
    , "{\"b\":1,\"c\":[1,\"x\"]}|1|[1]|[1]|[1,2]|NULL|[]|{}|{\"a\":1.50,\"b\":1E2}\n");
    try c.expectRows("SELECT JSON_QUERY('{\"a\":{\"b\":1,\"c\":[1,{}]}}', '$.a' PRETTY) FROM dual", "{\n  \"b\" : 1,\n  \"c\" :\n  [\n    1,\n    {\n    }\n  ]\n}\n");
    try c.expectError("SELECT JSON_QUERY('{\"a\":[1,2]}', '$.a[*]' ERROR ON ERROR) FROM dual", "ORA-40480: JSON array wrapper needed for result of JSON query '$.a[*]'");
    try c.expectError("SELECT JSON_QUERY('{\"a\":{\"b\":1}}', '$.a' RETURNING VARCHAR2(5) ERROR ON ERROR) FROM dual", "ORA-40478: output value too large (maximum: 5)");

    try c.expectRows(
        \\SELECT CASE WHEN JSON_EXISTS('{"a":null}', '$.a') THEN 1 ELSE 0 END, CASE WHEN JSON_EXISTS('{"a":1}', '$.b') THEN 1 ELSE 0 END,
        \\  CASE WHEN JSON_EXISTS('{"a":[1,2,3]}', '$.a?(@ > 2)') THEN 1 ELSE 0 END, CASE WHEN JSON_EXISTS('{"a":2}', '$?(@.a == $v)' PASSING 2 AS "v") THEN 1 ELSE 0 END,
        \\  CASE WHEN JSON_EXISTS('[{"a":1},{"a":5}]', '$[*]?(@.a > 3 && @.a < 6)') THEN 1 ELSE 0 END, CASE WHEN JSON_EXISTS('{"a":"xy"}', '$?(@.a starts with "x" || exists(@.b))') THEN 1 ELSE 0 END,
        \\  CASE WHEN JSON_EXISTS('bad', '$') THEN 1 ELSE 0 END, JSON_EXISTS('{"a":"abc"}', '$?(@.a like "a%" && !(@.a has substring "z"))') FROM dual
    , "1|0|1|1|1|1|0|1\n");
    try c.expectError("SELECT JSON_EXISTS('bad', '$' ERROR ON ERROR) FROM dual", "ORA-40441: JSON syntax error");
}

test "oracle: JSON constructors and aggregates" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.expectRows(
        \\SELECT JSON_OBJECT('a' VALUE 1, KEY 'b' VALUE 'x', 'c' : NULL, 'd' VALUE 0.5, 'e' VALUE JSON_OBJECT('f' VALUE 2), 'g' VALUE '{"h":1}',
        \\  'i' VALUE '{"h":1}' FORMAT JSON, 'j' VALUE JSON_ARRAY(1, 'a', NULL), 'k' VALUE DATE '2024-01-02', 'l' VALUE TRUE, 'm' VALUE -1.25, 'o' VALUE 'q"u\o') FROM dual
    , "{\"a\":1,\"b\":\"x\",\"c\":null,\"d\":0.5,\"e\":{\"f\":2},\"g\":\"{\\\"h\\\":1}\",\"i\":{\"h\":1},\"j\":[1,\"a\"],\"k\":\"2024-01-02T00:00:00\",\"l\":true,\"m\":-1.25,\"o\":\"q\\\"u\\\\o\"}\n");
    try c.expectRows(
        \\SELECT JSON_OBJECT('a' VALUE NULL ABSENT ON NULL), JSON_OBJECT(), JSON_ARRAY(), JSON_ARRAY(1, NULL, 2 NULL ON NULL), JSON_ARRAY('[1]' FORMAT JSON, '[1]'),
        \\  JSON_OBJECT('a' VALUE ''), JSON_OBJECT(KEY 'a' IS 1), JSON_OBJECT('k' VALUE JSON_QUERY('{"a":[1]}', '$.a')) FROM dual
    , "{}|{}|[]|[1,null,2]|[[1],\"[1]\"]|{\"a\":null}|{\"a\":1}|{\"k\":[1]}\n");
    try c.expectError("SELECT JSON_OBJECT('a' VALUE 1, 'a' VALUE 2 WITH UNIQUE KEYS) FROM dual", "ORA-40473: duplicate key names 'a' in JSON object");
    try c.expectError("SELECT JSON_ARRAY(1, 2 RETURNING VARCHAR2(3)) FROM dual", "ORA-40478: output value too large (maximum: 3)");
    try c.exec(
        \\CREATE TABLE v (k VARCHAR2(10), n NUMBER, s VARCHAR2(10), j JSON);
        \\INSERT INTO v VALUES ('x', 1, 'a', '{"q":1}');
        \\INSERT INTO v VALUES ('y', 2, NULL, '[2]');
        \\INSERT INTO v VALUES ('z', 3, 'c', NULL);
    );
    // A column: its name as written; *: the columns; a JSON column is JSON.
    try c.expectRows("SELECT JSON_OBJECT(k, v.n) FROM v WHERE k = 'x'", "{\"k\":\"x\",\"n\":1}\n");
    try c.expectRows("SELECT JSON_OBJECT(*) FROM v WHERE k = 'x'", "{\"K\":\"x\",\"N\":1,\"S\":\"a\",\"J\":{\"q\":1}}\n");
    try c.expectRows("SELECT JSON_ARRAY(j) FROM v WHERE k = 'y'", "[[2]]\n");
    try c.expectRows(
        \\SELECT JSON_ARRAYAGG(n ORDER BY n DESC), JSON_ARRAYAGG(s ORDER BY k), JSON_ARRAYAGG(s ORDER BY k NULL ON NULL), JSON_OBJECTAGG(KEY k VALUE s ABSENT ON NULL),
        \\  JSON_ARRAYAGG(JSON_OBJECT('k' VALUE k) ORDER BY k) FROM v
    , "[3,2,1]|[\"a\",\"c\"]|[\"a\",null,\"c\"]|{\"x\":\"a\",\"z\":\"c\"}|[{\"k\":\"x\"},{\"k\":\"y\"},{\"k\":\"z\"}]\n");
    try c.expectRows("SELECT JSON_ARRAYAGG(n), JSON_OBJECTAGG(k VALUE n) FROM v WHERE 1 = 0", "NULL|NULL\n");
    try c.expectRows("SELECT k, JSON_ARRAYAGG(n) FROM v GROUP BY k ORDER BY k", "x|[1]\ny|[2]\nz|[3]\n");
}

test "oracle: JSON_MERGEPATCH, JSON_SERIALIZE, JSON_TRANSFORM" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.expectRows("SELECT JSON_MERGEPATCH('{\"a\":1,\"b\":{\"c\":2,\"d\":3}}', '{\"b\":{\"c\":null,\"e\":4},\"f\":5,\"a\":null}'), JSON_MERGEPATCH('[1]', '{\"a\":1}') FROM dual", "{\"b\":{\"d\":3,\"e\":4},\"f\":5}|{\"a\":1}\n");
    try c.expectError("SELECT JSON_MERGEPATCH('{}', 'bad') FROM dual", "ORA-40629: Patch specification is not valid JSON");
    try c.expectRows("SELECT JSON_SERIALIZE('{\"b\" : 1, a : [1, 2]}'), JSON_SERIALIZE('{\"b\":1,\"a\":2}' ORDERED), JSON_SERIALIZE('{\"a\":\"\\u00e9\"}' ASCII) FROM dual", "{\"b\":1,\"a\":[1,2]}|{\"a\":2,\"b\":1}|{\"a\":\"\\u00E9\"}\n");
    try c.expectRows("SELECT JSON_SERIALIZE('{\"a\":[1],\"d\":{}}' PRETTY) FROM dual", "{\n  \"a\" :\n  [\n    1\n  ],\n  \"d\" :\n  {\n  }\n}\n");
    try c.expectError("SELECT JSON_SERIALIZE('{\"a\":1}' RETURNING VARCHAR2(5)) FROM dual", "ORA-40478: output value too large (maximum: 5)");
    try c.expectRows(
        \\SELECT JSON_TRANSFORM('{"a":1,"b":[1,2],"c":{"d":1}}', SET '$.a' = 2, SET '$.x' = 'y', REMOVE '$.c.d', APPEND '$.b' = 3, RENAME '$.c' = 'cc', INSERT '$.z' = 5) FROM dual
    , "{\"a\":2,\"b\":[1,2,3],\"x\":\"y\",\"cc\":{},\"z\":5}\n");
    try c.expectRows(
        \\SELECT JSON_TRANSFORM('{"a":1}', REPLACE '$.b' = 2), JSON_TRANSFORM('{"a":1}', SET '$.a' = '{"x":1}' FORMAT JSON), JSON_TRANSFORM('{"a":1}', SET '$.a' = NULL),
        \\  JSON_TRANSFORM('{"a":1,"b":2}', KEEP '$.b'), JSON_TRANSFORM('{"a":[1,2,3]}', REMOVE '$.a[1]'), JSON_TRANSFORM('{"a":[1,2]}', INSERT '$.a[0]' = 0), JSON_TRANSFORM('{"a":1}', SET '$.a' = 3.50) FROM dual
    , "{\"a\":1}|{\"a\":{\"x\":1}}|{\"a\":null}|{\"b\":2}|{\"a\":[1,3]}|{\"a\":[0,1,2]}|{\"a\":3.5}\n");
    try c.expectError("SELECT JSON_TRANSFORM('{\"a\":1}', INSERT '$.a' = 2) FROM dual", "ORA-40763: value already exists in JSON_TRANSFORM");
    try c.exec("CREATE TABLE j (d JSON); INSERT INTO j VALUES ('{\"n\":1}'); UPDATE j SET d = JSON_TRANSFORM(d, SET '$.n' = 5)");
    try c.expectRows("SELECT d FROM j", "{\"n\":5}\n");
}

test "oracle: JSON dot notation and JSON_TABLE" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE j (id NUMBER, d JSON, t VARCHAR2(200) CHECK (t IS JSON));
        \\INSERT INTO j VALUES (1, '{"a":1,"b":[1,2,{"c":"x"}],"s":"str","n":null}', '{"a":"s","b":{"x":1},"d":[{"e":1},{"e":2}]}');
        \\INSERT INTO j VALUES (2, '{"a":2}', NULL);
    );
    // On a JSON column the values are JSON ("str"); on a text column a
    // scalar is its SQL value. Several values are an array.
    try c.expectRows("SELECT x.d.a, x.d.b, x.d.b[2].c, x.d.s, x.d.n, x.d.zz, x.d.b.size() FROM j x WHERE id = 1", "1|[1,2,{\"c\":\"x\"}]|\"x\"|\"str\"|null|NULL|3\n");
    try c.expectRows("SELECT x.t.a, x.t.b, x.t.d.e, x.t.a.string() FROM j x WHERE id = 1", "s|{\"x\":1}|[1,2]|s\n");
    try c.expectRows("SELECT x.id FROM j x WHERE x.d.a = 2", "2\n");
    try c.expectColumns("SELECT x.d.a, x.d.b[0] FROM j x WHERE id = 1", "A|B");
    try c.expectError("SELECT nosuch.d.a FROM j x", "ORA-00904: \"NOSUCH\": invalid identifier");

    try c.expectRows(
        \\SELECT jt.* FROM JSON_TABLE('{"items":[{"id":1,"name":"a","tags":["x","y"]},{"id":2,"name":"b","extra":{"q":1}},{"id":"z"}]}', '$.items[*]'
        \\  COLUMNS (rn FOR ORDINALITY, id NUMBER PATH '$.id', name VARCHAR2(10) PATH '$.name', has_tags NUMBER EXISTS PATH '$.tags',
        \\           extra VARCHAR2(100) FORMAT JSON PATH '$.extra', NESTED PATH '$.tags[*]' COLUMNS (tag VARCHAR2(5) PATH '$'))) jt
    , "1|1|a|1|NULL|x\n1|1|a|1|NULL|y\n2|2|b|0|{\"q\":1}|NULL\n3|NULL|NULL|0|NULL|NULL\n");
    try c.expectColumns("SELECT * FROM JSON_TABLE('{\"a\":1}', '$' COLUMNS (a, \"b\" NUMBER, c FOR ORDINALITY))", "A|b|C");
    try c.expectRows("SELECT * FROM JSON_TABLE('{\"A\":1,\"a\":2,\"b\":\"x\"}', '$' COLUMNS (a, \"A\", b))", "2|1|x\n");
    try c.expectRows("SELECT * FROM JSON_TABLE('{\"x\":1,\"a\":[1,2],\"b\":[\"p\"]}', '$' COLUMNS (x NUMBER PATH '$.x', NESTED PATH '$.a[*]' COLUMNS (v NUMBER PATH '$', n FOR ORDINALITY), NESTED PATH '$.b[*]' COLUMNS (w VARCHAR2(5) PATH '$')))", "1|1|1|NULL\n1|2|2|NULL\n1|NULL|NULL|p\n");
    try c.expectRows("SELECT * FROM JSON_TABLE('{\"a\":\"x\"}', '$' COLUMNS (a NUMBER PATH '$.a' DEFAULT -1 ON ERROR, b VARCHAR2(5) PATH '$.b' DEFAULT 'none' ON EMPTY))", "-1|none\n");
    try c.expectRows("SELECT count(*) FROM JSON_TABLE('bad', '$' COLUMNS (a))", "0\n");
    try c.expectError("SELECT * FROM JSON_TABLE('{\"a\":\"x\"}', '$' COLUMNS (a NUMBER PATH '$.a' ERROR ON ERROR))", "ORA-01722: unable to convert string value containing 'x' to a number");
    // Lateral: the document from a table before it; the columns by name,
    // qualified or not, in WHERE and ORDER BY.
    try c.expectRows("SELECT j.id, jt.v FROM j, JSON_TABLE(j.d, '$.b[*]' COLUMNS (v VARCHAR2(20) PATH '$')) jt WHERE v IS NOT NULL ORDER BY j.id, jt.v DESC", "1|2\n1|1\n");
    try c.expectRows("SELECT id, a FROM j, JSON_TABLE(d, '$' COLUMNS (a NUMBER PATH '$.a')) ORDER BY a DESC", "2|2\n1|1\n");
    try c.expectRows("SELECT count(*) FROM j x WHERE EXISTS (SELECT 1 FROM JSON_TABLE(x.d, '$.b[*]' COLUMNS (v NUMBER PATH '$')) t WHERE t.v = 2)", "1\n");
    // A view keeps the table function; it reads from any dialect.
    try c.exec("CREATE VIEW jv AS SELECT id, jt.a FROM j, JSON_TABLE(j.d, '$' COLUMNS (a NUMBER PATH '$.a')) jt");
    try c.expectRows("SELECT * FROM jv ORDER BY id", "1|1\n2|2\n");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT a FROM jv ORDER BY id", "1\n2\n");
}

test "oracle: users are schemas" {
    var c: Conn = undefined;
    try openOra(&c);
    defer c.close();
    try c.exec("CREATE USER hr IDENTIFIED BY pw DEFAULT TABLESPACE users QUOTA UNLIMITED ON users");
    try c.expectError("CREATE USER HR IDENTIFIED BY x", "ORA-01920: user name 'HR' conflicts with another user or role name");
    try c.expectError("CREATE USER main IDENTIFIED BY x", "ORA-01920: user name 'MAIN' conflicts with another user or role name");
    try c.exec("CREATE USER IF NOT EXISTS hr IDENTIFIED BY x");
    try c.exec("ALTER USER hr QUOTA 10M ON users; GRANT CREATE SESSION, CREATE TABLE TO hr; REVOKE CREATE TABLE FROM hr");
    try c.expectError("ALTER USER nobody ACCOUNT LOCK", "ORA-01918: user 'NOBODY' does not exist");
    try c.exec(
        \\CREATE TABLE hr.dept (id NUMBER PRIMARY KEY, dname VARCHAR2(10));
        \\CREATE TABLE hr.emp (id NUMBER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, name VARCHAR2(20), dept NUMBER REFERENCES hr.dept (id));
        \\CREATE TABLE emp (id NUMBER, name VARCHAR2(20));
        \\CREATE INDEX hr.emp_name ON hr.emp (name);
        \\CREATE SEQUENCE hr.s START WITH 5;
        \\INSERT INTO hr.dept VALUES (10, 'sales');
        \\INSERT INTO hr.emp (name, dept) VALUES ('ann', 10);
        \\INSERT INTO hr.emp (name, dept) VALUES ('bob', NULL);
        \\INSERT INTO emp VALUES (1, 'main');
        \\CREATE VIEW hr.v AS SELECT e.name, d.dname FROM hr.emp e JOIN hr.dept d ON d.id = e.dept;
        \\COMMIT;
    );
    // SQLite's names: "HR.EMP" in main; the view's text names them so.
    try c.expectRows("SELECT name FROM sqlite_schema WHERE name LIKE 'HR.%' ORDER BY name", "HR.DEPT\nHR.EMP\nHR.EMP_NAME\nHR.V\n");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name = 'HR.V' AND sql LIKE '%FROM \"HR.EMP\" AS \"E\" JOIN \"HR.DEPT\"%'", "1\n");
    // u.t everywhere: queries, joins, t.col and u.t.col, DML, sequences.
    try c.expectRows("SELECT emp.name, hr.emp.id FROM hr.emp ORDER BY 1", "ann|1\nbob|2\n");
    try c.expectRows("SELECT e.name, m.name FROM hr.emp e JOIN emp m ON m.id = e.id", "ann|main\n");
    try c.expectRows("SELECT * FROM hr.v", "ann|sales\n");
    try c.exec("UPDATE hr.emp SET dept = 10 WHERE name = 'bob'; DELETE FROM hr.emp WHERE id = 1");
    try c.expectRows("SELECT hr.s.NEXTVAL, hr.s.CURRVAL FROM dual", "5|5\n");
    try c.exec("MERGE INTO hr.emp t USING (SELECT 'cy' AS n FROM dual) s ON (t.name = s.n) WHEN NOT MATCHED THEN INSERT (name) VALUES (s.n)");
    try c.expectRows("SELECT name FROM hr.emp ORDER BY 1", "bob\ncy\n");
    try c.expectError("SELECT * FROM nobody.t", "ORA-00942: table or view \"NOBODY\".\"T\" does not exist");
    try c.expectError("CREATE TABLE nobody.t (a NUMBER)", "ORA-01918: user 'NOBODY' does not exist");
    try c.expectError("SELECT hr.nosuch.NEXTVAL FROM dual", "ORA-02289: sequence does not exist");
    try c.exec("DROP TABLE IF EXISTS nobody.t");
    // The data dictionary: OWNER per user, USER_* the connected user's.
    try c.expectRows("SELECT owner, table_name FROM all_tables ORDER BY 1, 2", "HR|DEPT\nHR|EMP\nMAIN|EMP\n");
    try c.expectRows("SELECT table_name FROM user_tables", "EMP\n");
    try c.expectRows("SELECT owner, index_name, table_owner, table_name, uniqueness FROM all_indexes WHERE index_name = 'EMP_NAME'", "HR|EMP_NAME|HR|EMP|NONUNIQUE\n");
    try c.expectRows("SELECT sequence_owner, sequence_name FROM all_sequences ORDER BY 2", "HR|ISEQ$$_EMP_ID\nHR|S\n");
    try c.expectRows("SELECT count(*) FROM user_sequences", "0\n");
    try c.expectRows("SELECT owner, view_name FROM all_views", "HR|V\n");
    try c.expectRows("SELECT column_name FROM all_tab_columns WHERE owner = 'HR' AND table_name = 'EMP' ORDER BY column_id", "ID\nNAME\nDEPT\n");
    try c.expectRows("SELECT username FROM all_users ORDER BY username", "HR\nMAIN\n");
    try c.expectRows("SELECT username, account_status FROM user_users", "MAIN|OPEN\n");
    // ALTER SESSION SET CURRENT_SCHEMA: unqualified names resolve in HR.
    try c.expectRows("SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'), SYS_CONTEXT('userenv', 'session_user'), USER FROM dual", "MAIN|MAIN|MAIN\n");
    var stmt: ?*vi.Vdbe = null;
    try testing.expectEqual(RC.OK, prepare.prepareV2(c.db, "SELECT count(*) FROM emp", &stmt, null));
    defer _ = api.finalize(stmt.?);
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqual(@as(i64, 1), api.columnInt64(stmt.?, 0));
    _ = api.reset(stmt.?);
    try c.exec("ALTER SESSION SET CURRENT_SCHEMA = hr");
    // The prepared statement is compiled again.
    try testing.expectEqual(RC.ROW, api.step(stmt.?));
    try testing.expectEqual(@as(i64, 2), api.columnInt64(stmt.?, 0));
    _ = api.reset(stmt.?);
    try c.expectRows("SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'), USER FROM dual", "HR|MAIN\n");
    try c.expectRows("SELECT s.NEXTVAL FROM dual", "6\n");
    try c.exec("CREATE TABLE loc (a NUMBER); INSERT INTO loc VALUES (1); CREATE INDEX loc_a ON loc (a)");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE name LIKE '%LOC%' ORDER BY name", "HR.LOC\nHR.LOC_A\n");
    try c.expectRows("WITH emp AS (SELECT 7 AS x FROM dual) SELECT x FROM emp", "7\n");
    try c.expectRows("SELECT count(*) FROM dual", "1\n");
    try c.expectRows("SELECT table_name FROM user_tables", "EMP\n");
    try c.exec("RENAME loc TO loc2; ALTER TABLE loc2 RENAME TO loc3; DROP INDEX loc_a; DROP TABLE loc3");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name LIKE '%LOC%'", "0\n");
    try c.expectError("ALTER SESSION SET CURRENT_SCHEMA = nobody", "ORA-01435: user does not exist");
    try c.exec("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY' CURRENT_SCHEMA = main");
    try c.expectRows("SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM dual", "MAIN\n");
    try c.expectError("SELECT SYS_CONTEXT('USERENV', 'NOSUCH') FROM dual", "ORA-02003: invalid USERENV parameter");
    // CREATE SCHEMA AUTHORIZATION: the connected user's tables and views
    // in one statement.
    try c.exec("CREATE SCHEMA AUTHORIZATION main CREATE TABLE cs (a NUMBER) CREATE VIEW csv AS SELECT a FROM cs GRANT SELECT ON cs TO hr");
    try c.expectRows("SELECT count(*) FROM csv", "0\n");
    try c.expectError("CREATE SCHEMA AUTHORIZATION hr CREATE TABLE x (a NUMBER)", "ORA-02421: missing or invalid schema authorization identifier");
    // DROP USER: CASCADE drops the user's objects.
    try c.expectError("DROP USER hr", "ORA-01922: CASCADE must be specified to drop 'HR'");
    try c.expectError("DROP USER nobody", "ORA-01918: user 'NOBODY' does not exist");
    try c.exec("DROP USER IF EXISTS nobody; DROP USER hr CASCADE");
    try c.expectRows("SELECT count(*) FROM sqlite_schema WHERE name LIKE 'HR.%'", "0\n");
    try c.expectRows("SELECT count(*) FROM xq_sequence WHERE name LIKE 'HR.%'", "0\n");
    try c.expectRows("SELECT username FROM all_users", "MAIN\n");
    try c.expectError("SELECT * FROM hr.emp", "ORA-00942: table or view \"HR\".\"EMP\" does not exist");
    try c.expectRows("SELECT name FROM emp", "main\n");
}
