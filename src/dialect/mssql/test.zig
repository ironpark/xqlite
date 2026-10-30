//! End-to-end tests of the T-SQL dialect, against SQL Server's documented
//! behaviour (tools/dialect/mssql-cases.txt compares with a server).

const std = @import("std");
const testing = std.testing;
const main_mod = @import("../../sql/main.zig");
const Conn = @import("../../sql/sql_test.zig").Conn;

fn open(c: *Conn) !void {
    try c.open();
    main_mod.setDialect(c.db, .mssql);
}

test "mssql: expressions and operators" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT 1 + 1, 'a' + 'b', 7 / 2, -7 / 2, 7 % 3, 7.0 / 2", "2|ab|3|-3|1|3.5\n");
    try c.expectRows("SELECT 6 & 3, 6 | 1, 5 ^ 3, ~0, 'a' + NULL, '1' + 1", "2|7|6|-1|NULL|2\n");
    try c.expectColumns("SELECT 1 + 1, 2 AS x, y = 3", "|x|y");
    try c.expectRows("SELECT CASE WHEN 'abc' = 'ABC' THEN 1 ELSE 0 END, CASE WHEN 1 !< 2 THEN 1 ELSE 0 END", "1|0\n");
    try c.expectRows("SELECT IIF(2 > 1, 'y', 'n'), ISNULL(NULL, 3), CHOOSE(2, 'a', 'b')", "y|3|b\n");
}

test "mssql: tokens and GO" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT 'it''s', N'n', [a b] = 1, \"q\" = 2, 0x41 /* a /* nested */ comment */", "it's|n|1|2|A\n");
    // No semicolons needed; GO ends a statement.
    try c.exec("CREATE TABLE g (x INT)\nGO\nINSERT INTO g VALUES (1) INSERT INTO g VALUES (2)\nGO");
    try c.expectRows("SELECT COUNT(*) FROM g", "2\n");
    try c.expectError("SELECT 1 +", "Incorrect syntax near '+'.");
}

test "mssql: LIKE patterns" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT CASE WHEN 'ABC' LIKE 'a%' THEN 1 ELSE 0 END, CASE WHEN 'a_c' LIKE 'a[_]c' THEN 1 ELSE 0 END, CASE WHEN 'abc' LIKE 'a[_]c' THEN 1 ELSE 0 END", "1|1|0\n");
    try c.expectRows("SELECT CASE WHEN 'b' LIKE '[a-c]' THEN 1 ELSE 0 END, CASE WHEN 'd' LIKE '[^a-c]' THEN 1 ELSE 0 END, CASE WHEN '5%' LIKE '5!%' ESCAPE '!' THEN 1 ELSE 0 END", "1|1|1\n");
}

test "mssql: functions" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT LEN('ab  '), CHARINDEX('B', 'abcb', 3), REPLACE('Hello', 'L', 'x'), LEFT('hello', 2), RIGHT('hello', 3)", "2|4|Hexxo|he|llo\n");
    try c.expectRows("SELECT CONCAT('a', NULL, 1), CONCAT_WS('-', 'a', NULL, 'b'), STUFF('abcdef', 2, 3, 'XY'), QUOTENAME('a]b')", "a1|a-b|aXYef|[a]]b]\n");
    try c.expectRows("SELECT POWER(2, 10), ROUND(2.567, 2), ROUND(125, -1), CEILING(2.1), FLOOR(-2.5)", "1024|2.57|130|3|-3\n");
    try c.expectRows("SELECT CAST('12' AS INT), CAST(1.7 AS INT), CAST(3.14159 AS DECIMAL(10,2)), CAST(5 AS BIT), CAST('abcdef' AS VARCHAR(3))", "12|1|3.14|1|abc\n");
    try c.expectRows("SELECT TRY_CAST('x' AS INT), TRY_CONVERT(DATE, 'nope'), CONVERT(VARCHAR(10), CAST('2024-03-05' AS DATE), 112)", "NULL|NULL|20240305\n");
    try c.expectError("SELECT CAST('abc' AS INT)", "Conversion failed when converting the varchar value 'abc' to data type int.");
    try c.expectError("SELECT CAST(300 AS TINYINT)", "Arithmetic overflow error for data type tinyint, value = 300.");
}

test "mssql: dates" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT DATEADD(month, 1, '2024-01-31'), DATEADD(dd, 1, CAST('2024-12-31' AS DATE))", "2024-02-29 00:00:00.000|2025-01-01\n");
    try c.expectRows("SELECT DATEDIFF(year, '2023-12-31', '2024-01-01'), DATEDIFF(week, '2024-01-06', '2024-01-07'), DATEDIFF(hour, '2024-01-01 10:59', '2024-01-01 11:00')", "1|1|1\n");
    try c.expectRows("SELECT DATEPART(weekday, '2024-03-05'), DATENAME(month, '2024-03-05'), EOMONTH('2024-02-10'), DATEFROMPARTS(2024, 2, 29)", "3|March|2024-02-29|2024-02-29\n");
    try c.expectRows("SELECT CAST('2024-01-01 00:00:00.002' AS DATETIME), CAST('2024-01-01 10:00:00.1234567' AS DATETIME2(3))", "2024-01-01 00:00:00.003|2024-01-01 10:00:00.123\n");
    try c.expectRows("SELECT LEN(CONVERT(VARCHAR(30), GETDATE(), 121)), LEN(SYSDATETIME())", "23|27\n");
}

test "mssql: tables, types and identity" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (id INT IDENTITY(1,1) PRIMARY KEY, name NVARCHAR(5) NOT NULL, price DECIMAL(10,2), flag BIT, d DATE)");
    try c.exec("INSERT INTO t VALUES ('a', 1.005, 7, '20240102')");
    try c.exec("INSERT INTO t (name) VALUES ('B')");
    try c.expectRows("SELECT id, name, price, flag, d FROM t ORDER BY id", "1|a|1.01|1|2024-01-02\n2|B|NULL|NULL|NULL\n");
    try c.expectRows("SELECT SCOPE_IDENTITY(), @@IDENTITY, IDENT_CURRENT('dbo.t')", "2|2|2\n");
    try c.expectRows("SELECT name FROM t WHERE name = 'b'", "B\n");
    try c.expectError("INSERT INTO t (name) VALUES ('toolong')", "String or binary data would be truncated in table 'main.dbo.t', column 'name'. Truncated value: 'toolo'.");
    try c.expectError("INSERT INTO t (id, name) VALUES (9, 'x')", "Cannot insert explicit value for identity column in table 't' when IDENTITY_INSERT is set to OFF.");
    try c.exec("SET IDENTITY_INSERT t ON; INSERT INTO t (id, name) VALUES (9, 'x'); SET IDENTITY_INSERT t OFF; INSERT INTO t (name) VALUES ('y')");
    try c.expectRows("SELECT id FROM t WHERE name = 'y'", "10\n");
    try c.expectError("UPDATE t SET id = 1", "Cannot update identity column 'id'.");
    try c.exec("TRUNCATE TABLE t; INSERT INTO t (name) VALUES ('z')");
    try c.expectRows("SELECT id FROM t", "1\n");
    // The catalog records the declared types.
    try c.expectRows("SELECT DATA_TYPE, CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 't' AND COLUMN_NAME = 'name'", "nvarchar|5\n");
    try c.expectRows("SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('t')", "5\n");
}

test "mssql: computed columns and + by column types" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE cc (a INT, b INT, s VARCHAR(10), total AS (a + b), label AS (s + ':' + s) PERSISTED)");
    try c.exec("INSERT INTO cc (a, b, s) VALUES (1, 2, 'x')");
    try c.expectRows("SELECT total, label, a + b, s + s FROM cc", "3|x:x|3|xx\n");
    // The schema keeps SQLite's + and ||, which sqlite3 reads.
    try c.expectRows("SELECT instr(sql, 'xq_') FROM sqlite_schema WHERE name = 'cc'", "0\n");
}

test "mssql: select clauses" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE s (n INT); INSERT INTO s VALUES (1), (2), (3), (4), (5), (6)");
    try c.expectRows("SELECT TOP 2 n FROM s ORDER BY n DESC", "6\n5\n");
    try c.expectRows("SELECT TOP 50 PERCENT n FROM s ORDER BY n", "1\n2\n3\n");
    try c.expectRows("SELECT n FROM s ORDER BY n OFFSET 2 ROWS FETCH NEXT 2 ROWS ONLY", "3\n4\n");
    try c.expectRows("SELECT AVG(n), AVG(CAST(n AS FLOAT)) FROM s", "3|3.5\n");
    try c.expectRows("WITH c (k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM c WHERE k < 4) SELECT SUM(k) FROM c", "10\n");
    try c.expectRows("SELECT STRING_AGG(n, '-') WITHIN GROUP (ORDER BY n DESC) FROM s WHERE n < 4", "3-2-1\n");
    try c.expectError("SELECT 1 FROM s CROSS APPLY s AS x", "xqlite: CROSS APPLY is supported only with OPENJSON and table-valued functions");
}

test "mssql: DML forms" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE p (id INT PRIMARY KEY, cat INT, price INT); CREATE TABLE r (id INT PRIMARY KEY, rate INT)");
    try c.exec("INSERT INTO p VALUES (1, 1, 10), (2, 1, 20), (3, 2, 30); INSERT INTO r VALUES (1, 2), (2, 3)");
    try c.expectRows("UPDATE p SET price += 1 OUTPUT INSERTED.id, INSERTED.price WHERE id = 1", "1|11\n");
    try c.exec("UPDATE x SET x.price = x.price * r.rate FROM p AS x JOIN r ON r.id = x.cat");
    try c.expectRows("SELECT price FROM p ORDER BY id", "22\n40\n90\n");
    try c.expectRows("DELETE FROM p OUTPUT DELETED.id WHERE id = 3", "3\n");
    try c.exec("DELETE p FROM p JOIN r ON r.id = p.cat WHERE r.rate = 2 AND p.id = 1");
    try c.exec("UPDATE TOP (1) p SET price = 0");
    try c.expectRows("SELECT id, price FROM p", "2|0\n");
}

test "mssql: MERGE" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (id INT PRIMARY KEY, v VARCHAR(10), n INT); INSERT INTO t VALUES (1, 'a', 1), (2, 'b', 2), (3, 'c', 3)");
    try c.exec(
        \\MERGE INTO t USING (VALUES (2, 'B'), (3, 'del'), (4, 'D')) AS s (id, v) ON t.id = s.id
        \\WHEN MATCHED AND s.v = 'del' THEN DELETE
        \\WHEN MATCHED THEN UPDATE SET v = s.v, n = t.n + 10
        \\WHEN NOT MATCHED THEN INSERT (id, v, n) VALUES (s.id, s.v, 0)
        \\WHEN NOT MATCHED BY SOURCE THEN UPDATE SET v = 'gone';
    );
    try c.expectRows("SELECT id, v, n FROM t ORDER BY id", "1|gone|1\n2|B|12\n4|D|0\n");
    // A matched DELETE and an INSERT: the deleted row's source is not
    // inserted again; the inserted row is not deleted.
    try c.exec("MERGE t USING (VALUES (4), (5)) AS s (id) ON t.id = s.id WHEN MATCHED THEN DELETE WHEN NOT MATCHED THEN INSERT (id, v, n) VALUES (s.id, 'new', 5);");
    try c.expectRows("SELECT id, v FROM t ORDER BY id", "1|gone\n2|B\n5|new\n");
    try c.expectError("MERGE t USING (VALUES (1)) AS s (id) ON t.id = s.id WHEN MATCHED THEN DELETE", "A MERGE statement must be terminated by a semi-colon (;).");
}

test "mssql: variables and transactions" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("DECLARE @i INT = 5, @s VARCHAR(3) = 'abcdef'");
    try c.expectRows("SELECT @i + 1, @s + 'x'", "6|abcx\n");
    try c.exec("SET @i += 10; CREATE TABLE v (x INT); INSERT INTO v VALUES (3), (1), (2)");
    try c.expectRows("SELECT @i", "15\n");
    try c.expectRows("SELECT @i = x FROM v ORDER BY x", "");
    try c.expectRows("SELECT @i", "3\n");
    try c.expectError("SELECT @nope", "Must declare the scalar variable \"@nope\".");
    try c.exec("BEGIN TRAN; INSERT INTO v VALUES (4); BEGIN TRANSACTION");
    try c.expectRows("SELECT @@TRANCOUNT", "2\n");
    try c.exec("COMMIT; ROLLBACK");
    try c.expectRows("SELECT @@TRANCOUNT, COUNT(*) FROM v", "0|3\n");
    try c.exec("BEGIN TRAN t1; INSERT INTO v VALUES (5); SAVE TRAN s1; INSERT INTO v VALUES (6); ROLLBACK TRAN s1; COMMIT TRAN t1");
    try c.expectRows("SELECT MAX(x) FROM v", "5\n");
    try c.expectError("COMMIT", "The COMMIT TRANSACTION request has no corresponding BEGIN TRANSACTION.");
    try c.exec("SET NOCOUNT ON; SET ANSI_NULLS ON; SET TRANSACTION ISOLATION LEVEL READ COMMITTED");
}

test "mssql: DDL" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE dbo.parent (id INT CONSTRAINT pk_parent PRIMARY KEY CLUSTERED, code VARCHAR(5) COLLATE Latin1_General_CS_AS UNIQUE)");
    try c.exec("CREATE TABLE child (id INT PRIMARY KEY, pid INT REFERENCES parent (id) ON DELETE CASCADE, INDEX ix_pid (pid))");
    try c.exec("INSERT INTO parent VALUES (1, 'A'), (2, 'a'); INSERT INTO child VALUES (1, 1), (2, 2)");
    // Foreign keys are enforced.
    try c.exec("DELETE FROM parent WHERE id = 1");
    try c.expectRows("SELECT id FROM child", "2\n");
    try c.expectError("INSERT INTO child VALUES (3, 99)", "FOREIGN KEY constraint failed");
    try c.exec("CREATE NONCLUSTERED INDEX ix_code ON parent (code DESC); DROP INDEX ix_code ON parent; DROP INDEX child.ix_pid");
    try c.exec("ALTER TABLE child ADD note VARCHAR(10) DEFAULT 'n'; ALTER TABLE child DROP COLUMN note");
    try c.exec("CREATE VIEW v AS SELECT id FROM parent");
    try c.expectError("CREATE VIEW w AS SELECT 1", "Create View or Function failed because no column name was specified for column 1.");
    try c.exec("CREATE OR ALTER VIEW v AS SELECT code FROM parent");
    try c.expectRows("SELECT code FROM v", "a\n");
    try c.exec("EXEC sp_rename 'child', 'kid'; EXEC sp_rename 'kid.pid', 'parent_id', 'COLUMN'");
    try c.expectRows("SELECT parent_id FROM kid", "2\n");
    try c.exec("CREATE TABLE #tmp (id INT IDENTITY, v INT); INSERT INTO #tmp (v) VALUES (7)");
    try c.expectRows("SELECT id, v FROM #tmp", "1|7\n");
    try c.exec("DROP TABLE IF EXISTS #tmp, nothere; DROP VIEW v; DROP TABLE kid; DROP TABLE parent");
    try c.expectError("CREATE TABLE a1 (x INT); CREATE TABLE a2 (x INT); DROP TABLE a1, a2", "xqlite: DROP of several existing objects in one statement is not supported (drop them one at a time)");
    try c.expectError("DROP TABLE nothere", "Cannot drop the table 'nothere', because it does not exist or you do not have permission.");
    try c.expectError("SELECT * FROM nothere", "Invalid object name 'nothere'.");
    try c.expectError("SELECT nocol FROM (SELECT 1 AS a) AS q", "Invalid column name 'nocol'.");
}

test "mssql: JSON functions" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT ISJSON('{\"a\":1}'), ISJSON('1'), ISJSON('[01]'), ISJSON(NULL), ISJSON('1', SCALAR), ISJSON('[1]', OBJECT)", "1|0|0|NULL|1|0\n");
    try c.expectRows("SELECT JSON_VALUE('{\"a\":{\"b\":[1,\"x\"]},\"t\":true,\"n\":1.50}', '$.a.b[1]'), JSON_VALUE('{\"t\":true}', '$.t'), JSON_VALUE('{\"n\":1.50}', '$.n'), JSON_VALUE('{\"a\":[1]}', '$.a')", "x|true|1.50|NULL\n");
    // Read only as far as the value.
    try c.expectRows("SELECT JSON_VALUE('{\"a\":1', '$.a'), JSON_VALUE('[1, 2', '$.zz')", "1|NULL\n");
    try c.expectError("SELECT JSON_VALUE('{\"a\":1} x', '$.zz')", "JSON text is not properly formatted. Unexpected character 'x' is found at position 8.");
    try c.expectError("SELECT JSON_VALUE('{\"a\":1}', 'strict $.b')", "Property cannot be found on the specified JSON path.");
    try c.expectError("SELECT JSON_VALUE('{\"a\":1}', '$.a-b')", "JSON path is not properly formatted. Unexpected character '-' is found at position 3.");
    try c.expectError("SELECT JSON_VALUE(N'{\"\u{e9}\":x}', '$.c')", "JSON text is not properly formatted. Unexpected character 'x' is found at position 5.");
    try c.expectRows("SELECT JSON_QUERY('{\"a\": [1, 2]}', '$.a'), JSON_QUERY('{\"s\":\"x\"}', '$.s'), JSON_QUERY(' [1] ')", "[1, 2]|NULL|[1]\n");
    try c.expectRows("SELECT JSON_MODIFY('{\"a\": 1, \"b\": 2}', '$.a', NULL), JSON_MODIFY('{\"a\":1}', '$.c', 'x/y'), JSON_MODIFY('{\"a\":[1]}', 'append $.a', 2)", "{ \"b\": 2}|{\"a\":1,\"c\":\"x\\/y\"}|{\"a\":[1,2]}\n");
    try c.expectRows("SELECT JSON_MODIFY('{}', '$.j', JSON_QUERY('[1]')), JSON_MODIFY('{}', '$.s', '[1]'), JSON_MODIFY('{}', '$.b', CAST(1 AS BIT)), JSON_MODIFY('{}', '$.f', CAST(1.5 AS FLOAT))", "{\"j\":[1]}|{\"s\":\"[1]\"}|{\"b\":true}|{\"f\":1.500000000000000e+000}\n");
    try c.expectError("SELECT JSON_MODIFY('[1]', '$', 1)", "Unsupported JSON path found in argument 2 of JSON_MODIFY.");
    try c.expectError("SELECT JSON_MODIFY('{}', '$.a', CAST('2024-01-02' AS DATE))", "Argument data type date is invalid for argument 3 of json_modify function.");
    try c.expectRows("SELECT STRING_ESCAPE('a/\"' + CHAR(10) + CHAR(1), 'json')", "a\\/\\\"\\n\\u0001\n");
    // SQL Server 2022's constructors.
    try c.expectRows("SELECT JSON_OBJECT('a': 1, 'b': 'x', 'c': NULL), JSON_OBJECT('a': NULL ABSENT ON NULL), JSON_ARRAY(1, NULL, JSON_ARRAY()), JSON_ARRAY(NULL NULL ON NULL)", "{\"a\":1,\"b\":\"x\",\"c\":null}|{}|[1,[]]|[null]\n");
    try c.expectRows("SELECT JSON_PATH_EXISTS('{\"a\":[1]}', '$.a[0]'), JSON_PATH_EXISTS('{\"a\":[1]}', '$.b')", "1|0\n");
    // Column types decide how JSON_MODIFY writes a value.
    try c.exec("CREATE TABLE jd (id INT, j NVARCHAR(MAX), flag BIT, f FLOAT)");
    try c.exec("INSERT INTO jd VALUES (1, '{}', 1, 2.5)");
    try c.exec("UPDATE jd SET j = JSON_MODIFY(JSON_MODIFY(j, '$.flag', flag), '$.f', f)");
    try c.expectRows("SELECT j, JSON_MODIFY(j, '$.id', id) FROM jd", "{\"flag\":true,\"f\":2.500000000000000e+000}|{\"flag\":true,\"f\":2.500000000000000e+000,\"id\":1}\n");
}

test "mssql: OPENJSON" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT [key], value, type FROM OPENJSON('{\"s\":\"x\",\"n\":1.50,\"t\":true,\"z\":null,\"a\":[1, 2],\"o\":{}}')", "s|x|1\nn|1.50|2\nt|true|3\nz|NULL|0\na|[1, 2]|4\no|{}|5\n");
    try c.expectRows("SELECT [key], value FROM OPENJSON('{\"a\":{\"b\":[7,8]}}', '$.a.b')", "0|7\n1|8\n");
    try c.expectRows("SELECT COUNT(*) FROM OPENJSON('{\"a\":1}', '$.a')", "0\n");
    // key is case-sensitive (SQL Server's BIN2).
    try c.expectRows("SELECT COUNT(*) FROM OPENJSON('{\"a\":1}') WHERE [key] = 'A'", "0\n");
    try c.expectError("SELECT * FROM OPENJSON('{\"a\":1}', 'strict $.a')", "Value referenced by JSON path is not an array or object and cannot be opened with OPENJSON.");
    try c.expectRows("SELECT * FROM OPENJSON('[{\"id\":1,\"x\":{\"y\":2}},{\"id\":\"2\"}]') WITH (id INT, x NVARCHAR(MAX) AS JSON, y INT '$.x.y')", "1|{\"y\":2}|2\n2|NULL|NULL\n");
    try c.expectColumns("SELECT * FROM OPENJSON('[]') WITH ([a b] INT, c VARCHAR(3))", "a b|c");
    try c.expectError("SELECT * FROM OPENJSON('[{\"id\":\"abc\"}]') WITH (id INT)", "Conversion failed when converting the nvarchar value 'abc' to data type int.");
    try c.expectError("SELECT * FROM OPENJSON('[]') WITH (j INT AS JSON)", "AS JSON option can be specified only for column of nvarchar(max) type in WITH clause.");
    try c.exec("CREATE TABLE od (id INT, lines NVARCHAR(MAX))");
    try c.exec("INSERT INTO od VALUES (1, '[{\"sku\":\"a\",\"qty\":2},{\"sku\":\"b\",\"qty\":1}]'), (2, NULL)");
    try c.expectRows("SELECT od.id, l.sku, l.qty FROM od CROSS APPLY OPENJSON(od.lines) WITH (sku VARCHAR(5), qty INT) AS l ORDER BY l.sku", "1|a|2\n1|b|1\n");
    try c.expectRows("SELECT od.id, j.[key] FROM od OUTER APPLY OPENJSON(od.lines) AS j ORDER BY od.id, j.[key]", "1|0\n1|1\n2|NULL\n");
    try c.expectError("SELECT * FROM od CROSS APPLY (SELECT 1 AS x) AS q", "xqlite: CROSS APPLY is supported only with OPENJSON and table-valued functions");
    // A view keeps the spec in the function's name; it is SQLite text.
    try c.exec("CREATE VIEW ov AS SELECT od.id, l.sku FROM od CROSS APPLY OPENJSON(od.lines) WITH (sku VARCHAR(5) '$.sku') AS l");
    try c.expectRows("SELECT sku FROM ov ORDER BY sku", "a\nb\n");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT sku FROM ov ORDER BY sku", "a\nb\n");
}

test "mssql: FOR JSON" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectColumns("SELECT 1 AS a FOR JSON PATH", "JSON_F52E2B61-18A1-11d1-B105-00805F49916B");
    try c.expectRows("SELECT 1 AS [x.a], 2 AS [x.b], NULL AS c, 'q/' AS d FOR JSON PATH", "[{\"x\":{\"a\":1,\"b\":2},\"d\":\"q\\/\"}]\n");
    try c.expectRows("SELECT NULL AS c FOR JSON PATH, INCLUDE_NULL_VALUES, ROOT('r')", "{\"r\":[{\"c\":null}]}\n");
    try c.expectRows("SELECT 1 AS a WHERE 1 = 0 FOR JSON PATH", "");
    try c.expectError("SELECT 1 AS [x.a], 3 AS c, 2 AS [x.b] FOR JSON PATH", "Property 'x.b' cannot be generated in JSON output due to a conflict with another column name or alias. Use different names and aliases for each column in SELECT list.");
    try c.expectError("SELECT 1 FOR JSON PATH", "Column expressions and data sources without names or aliases cannot be formatted as JSON text using FOR JSON clause. Add alias to the unnamed column or table.");
    try c.exec("CREATE TABLE fo (id INT, name VARCHAR(10), ok BIT, at DATETIME)");
    try c.exec("CREATE TABLE fi (oid INT, sku VARCHAR(10))");
    try c.exec("INSERT INTO fo VALUES (1, 'a', 1, '2024-01-02 03:04:05'), (2, 'b', 0, NULL); INSERT INTO fi VALUES (1, 'x'), (1, 'y'), (2, 'z')");
    try c.expectRows("SELECT * FROM fo ORDER BY id FOR JSON PATH", "[{\"id\":1,\"name\":\"a\",\"ok\":true,\"at\":\"2024-01-02T03:04:05.000\"},{\"id\":2,\"name\":\"b\",\"ok\":false}]\n");
    try c.expectRows("SELECT fo.id, fi.sku FROM fo JOIN fi ON fi.oid = fo.id ORDER BY fo.id, fi.sku FOR JSON AUTO", "[{\"id\":1,\"fi\":[{\"sku\":\"x\"},{\"sku\":\"y\"}]},{\"id\":2,\"fi\":[{\"sku\":\"z\"}]}]\n");
    // A nested FOR JSON is JSON, not a string.
    try c.expectRows("SELECT id, (SELECT sku FROM fi WHERE fi.oid = fo.id ORDER BY sku FOR JSON PATH) AS s FROM fo ORDER BY id FOR JSON PATH", "[{\"id\":1,\"s\":[{\"sku\":\"x\"},{\"sku\":\"y\"}]},{\"id\":2,\"s\":[{\"sku\":\"z\"}]}]\n");
    try c.expectRows("SELECT id AS k FROM fo ORDER BY k DESC FOR JSON PATH, WITHOUT_ARRAY_WRAPPER", "{\"k\":2},{\"k\":1}\n");
    try c.expectError("SELECT 1 AS a FOR JSON AUTO", "FOR JSON AUTO requires at least one table for generating JSON objects. Use FOR JSON PATH or add a FROM clause with a table name.");
}

test "mssql: JSON in the schema" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    // ISJSON is SQLite's json_valid(): sqlite3 can check the constraint.
    try c.exec("CREATE TABLE jc (doc NVARCHAR(MAX) CONSTRAINT ck_doc CHECK (ISJSON(doc) = 1))");
    try c.expectError("INSERT INTO jc VALUES ('1')", "CHECK constraint failed: ck_doc");
    try c.expectRows("SELECT instr(sql, 'xq_') FROM sqlite_schema WHERE name = 'jc'", "0\n");
    try c.exec("CREATE TABLE js (id INT, doc NVARCHAR(MAX), a AS JSON_VALUE(doc, '$.a'))");
    try c.exec("INSERT INTO js (id, doc) VALUES (1, '{\"a\":\"x\"}')");
    try c.expectRows("SELECT a FROM js", "x\n");
    try c.expectRows("SELECT instr(sql, 'xq_tsql_json_value') > 0 FROM sqlite_schema WHERE name = 'js'", "1\n");
    try c.exec("CREATE VIEW jv AS SELECT id, doc FROM js FOR JSON PATH");
    main_mod.setDialect(c.db, .sqlite);
    try c.expectRows("SELECT * FROM jv", "[{\"id\":1,\"doc\":\"{\\\"a\\\":\\\"x\\\"}\"}]\n");
}
