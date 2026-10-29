//! End-to-end tests of the MariaDB dialect, against MariaDB's documented
//! behaviour (no MariaDB server is involved).

const std = @import("std");
const testing = std.testing;
const int = @import("../../sql/sqlite_int.zig");
const main_mod = @import("../../sql/main.zig");
const Conn = @import("../../sql/sql_test.zig").Conn;

fn open(c: *Conn) !void {
    try c.open();
    main_mod.setDialect(c.db, .mariadb);
}

test "mariadb: expressions and operators" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT 1 + 1, 'a' 'b', 7 / 2, 7 DIV 2, -7 DIV 2, 7 % 3, 7 MOD 3", "2|ab|3.5|3|-3|1|1\n");
    try c.expectRows("SELECT 1 || 0, 0 || 0, 1 && 0, !0, NOT 1, 1 XOR 1, 1 XOR 0, NULL XOR 1", "1|0|0|1|0|0|1|NULL\n");
    try c.expectRows("SELECT NULL <=> NULL, 1 <=> NULL, 1 = NULL, 5 ^ 3, 1 << 3, 6 & 3, 6 | 1, ~0 = -1", "1|0|NULL|6|8|2|7|1\n");
    // NOT is below comparison, ! above.
    try c.expectRows("SELECT NOT 1 = 2, !1 = 2", "1|0\n");
    try c.expectRows("SELECT 'abc' = 'ABC', 'abc' LIKE 'A%', BINARY 'abc' = 'ABC', 'a' = 'A' COLLATE utf8mb4_bin", "1|1|0|0\n");
    try c.expectRows("SELECT 2 BETWEEN 1 AND 3, 5 NOT BETWEEN 1 AND 3, 2 IN (1,2), 2 NOT IN (1,3), NULL IS NULL, 1 IS TRUE, 0 IS NOT FALSE", "1|1|1|1|1|1|0\n");
    try c.expectRows("SELECT CASE WHEN 1 THEN 'y' ELSE 'n' END, CASE 2 WHEN 1 THEN 'a' WHEN 2 THEN 'b' END", "y|b\n");
    try c.expectRows("SELECT TRUE, FALSE, X'41', 0x41 = X'41', b'101', 0b11", "1|0|A|1|5|3\n");
}

test "mariadb: tokenizer quirks" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE `my table` (`a``b` INT, `select` INT)");
    try c.exec("INSERT INTO `my table` VALUES (1, 2)");
    try c.expectRows("SELECT `a``b`, `select` FROM `my table`", "1|2\n");
    try c.expectColumns("SELECT `a``b` AS 'x y' FROM `my table`", "x y");
    // Strings with escapes; double quotes are strings.
    try c.expectRows("SELECT 'it\\'s', \"say \\\"hi\\\"\", 'a\\tb', 'c''d', LENGTH('\\\\')", "it's|say \"hi\"|a\tb|c'd|1\n");
    // Comments: #, -- (with a space), /* */; --1 is not a comment.
    try c.expectRows("SELECT 1 # comment\n + 1 -- another\n, 3--1 /* c */", "2|4\n");
    // Executable comments are code; version-gated ones above ours not.
    try c.expectRows("SELECT 1 /*! + 1 */ /*!999999 + 100 */ /*M!100100 + 10 */", "12\n");
    // \% and \_ stay for LIKE, whose escape character is \.
    try c.expectRows("SELECT 'a%' LIKE 'a\\%', 'ab' LIKE 'a\\%', 'a_b' LIKE 'a\\_b', 'axb' LIKE 'a\\_b'", "1|0|1|0\n");
    try c.expectRows("SELECT ? IS NULL", "1\n");
}

test "mariadb: sql_mode switches" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT @@sql_mode", "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION\n");
    try c.expectColumns("SELECT @@sql_mode", "@@sql_mode");
    // ANSI_QUOTES: "x" is an identifier.
    try c.exec("CREATE TABLE t (a INT)");
    try c.exec("INSERT INTO t VALUES (5)");
    try c.expectRows("SELECT \"a\" FROM t", "a\n");
    try c.exec("SET sql_mode = 'ANSI_QUOTES'");
    try c.expectRows("SELECT \"a\" FROM t", "5\n");
    try c.expectError("SELECT \"nope\" FROM t", "no such column: nope");
    // PIPES_AS_CONCAT.
    try c.expectRows("SELECT 'a' || 'b'", "0\n");
    try c.exec("SET SESSION sql_mode = 'PIPES_AS_CONCAT'");
    try c.expectRows("SELECT 'a' || 'b', 'a' || NULL", "ab|NULL\n");
    // NO_BACKSLASH_ESCAPES.
    try c.exec("SET @@session.sql_mode = 'NO_BACKSLASH_ESCAPES'");
    try c.expectRows("SELECT 'a\\nb', LENGTH('\\\\')", "a\\nb|2\n");
    // ANSI is a combination; DEFAULT restores the default.
    try c.exec("SET sql_mode = 'ansi'");
    try c.expectRows("SELECT @@sql_mode", "REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,ANSI\n");
    try c.exec("SET sql_mode = DEFAULT");
    try c.expectRows("SELECT @@SESSION.sql_mode LIKE 'STRICT_TRANS_TABLES%'", "1\n");
    try c.expectError("SET sql_mode = 'NOPE'", "Variable 'sql_mode' can't be set to the value of 'NOPE'");
    try c.exec("SET sql_mode = CONCAT(@@sql_mode, ',PIPES_AS_CONCAT')");
    try c.expectRows("SELECT 'x' || 'y'", "xy\n");
    try c.expectError("SELECT @@nope", "Unknown system variable 'nope'");
    try c.exec("SET NAMES utf8mb4; SET NAMES 'utf8' COLLATE 'utf8_general_ci'; SET CHARACTER SET utf8");
}

test "mariadb: strict and lenient INSERT" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (i TINYINT, u INT UNSIGNED, s VARCHAR(5), d DECIMAL(5,2), e ENUM('a','b'), dt DATE)");
    // Strict (the default): errors.
    try c.expectError("INSERT INTO t (i) VALUES (200)", "Out of range value for column 'i' at row 1");
    try c.expectError("INSERT INTO t (u) VALUES (-1)", "Out of range value for column 'u' at row 1");
    try c.expectError("INSERT INTO t (s) VALUES ('toolong')", "Data too long for column 's' at row 1");
    try c.expectError("INSERT INTO t (i) VALUES (1), ('x')", "Incorrect integer value: 'x' for column `main`.`t`.`i` at row 2");
    try c.expectError("INSERT INTO t (e) VALUES ('c')", "Data truncated for column 'e' at row 1");
    try c.expectError("INSERT INTO t (dt) VALUES ('2024-02-30')", "Incorrect date value: '2024-02-30' for column `main`.`t`.`dt` at row 1");
    try c.expectError("INSERT INTO t (d) VALUES (1000)", "Out of range value for column 'd' at row 1");
    try c.expectRows("SELECT count(*) FROM t", "0\n");
    // Conversions that fit.
    try c.exec("INSERT INTO t VALUES ('12', '7', 'ab   ', 1.235, 'B', '20240105')");
    try c.expectRows("SELECT i, u, s, d, e, dt, typeof(i) FROM t", "12|7|ab   |1.24|b|2024-01-05|integer\n");
    // Lenient: clipped with warnings.
    try c.exec("DELETE FROM t");
    try c.exec("SET sql_mode = ''");
    try c.exec("INSERT INTO t VALUES (200, -1, 'toolong', 1000, 'c', 'garbage')");
    try c.expectRows("SHOW WARNINGS", "Warning|1264|Out of range value for column 'i' at row 1\n" ++
        "Warning|1264|Out of range value for column 'u' at row 1\n" ++
        "Warning|1265|Data truncated for column 's' at row 1\n" ++
        "Warning|1264|Out of range value for column 'd' at row 1\n" ++
        "Warning|1265|Data truncated for column 'e' at row 1\n" ++
        "Warning|1265|Data truncated for column 'dt' at row 1\n");
    try c.expectRows("SELECT @@warning_count", "6\n");
    try c.expectRows("SHOW COUNT(*) WARNINGS", "6\n");
    try c.expectRows("SELECT i, u, s, d, e, dt FROM t", "127|0|toolo|999.99||0000-00-00\n");
    try c.expectRows("SHOW WARNINGS", "");
    // INSERT IGNORE is lenient in strict mode too.
    try c.exec("SET sql_mode = DEFAULT");
    try c.exec("DELETE FROM t");
    try c.exec("INSERT IGNORE INTO t (i, s) VALUES (-500, 'abcdefg')");
    try c.expectRows("SELECT i, s FROM t", "-128|abcde\n");
    // NULL into NOT NULL, and a NOT NULL column without a default left
    // out.
    try c.exec("CREATE TABLE nn (a INT NOT NULL, b INT NOT NULL DEFAULT 5, c VARCHAR(3))");
    try c.expectError("INSERT INTO nn (a) VALUES (NULL)", "Column 'a' cannot be null");
    try c.expectError("INSERT INTO nn (c) VALUES ('x')", "Field 'a' doesn't have a default value");
    try c.exec("INSERT IGNORE INTO nn (a) VALUES (NULL)");
    try c.expectRows("SHOW WARNINGS", "Warning|1048|Column 'a' cannot be null\n");
    try c.exec("SET sql_mode = ''");
    try c.exec("INSERT INTO nn (c) VALUES ('y')");
    try c.expectRows("SHOW WARNINGS", "Warning|1364|Field 'a' doesn't have a default value\n");
    try c.expectError("INSERT INTO nn (a) VALUES (NULL)", "Column 'a' cannot be null");
    try c.exec("INSERT INTO nn (a) VALUES (1), (NULL)");
    try c.expectRows("SELECT a, b, c FROM nn", "0|5|NULL\n0|5|y\n1|5|NULL\n0|5|NULL\n");
    try c.exec("SET sql_mode = DEFAULT");
    // UPDATE converts too.
    try c.expectError("UPDATE t SET i = 1000", "Out of range value for column 'i' at row 1");
    try c.exec("UPDATE IGNORE t SET i = 1000");
    try c.expectRows("SELECT i FROM t", "127\n");
}

test "mariadb: AUTO_INCREMENT" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (id INT NOT NULL AUTO_INCREMENT, v VARCHAR(10), PRIMARY KEY (id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
    try c.exec("INSERT INTO t (v) VALUES ('a'), ('b')");
    try c.expectRows("SELECT LAST_INSERT_ID()", "2\n");
    try c.exec("INSERT INTO t VALUES (NULL, 'c'), (0, 'd')");
    try c.exec("INSERT INTO t VALUES (10, 'e')");
    try c.exec("INSERT INTO t (v) VALUES ('f')");
    try c.expectRows("SELECT id, v FROM t ORDER BY id", "1|a\n2|b\n3|c\n4|d\n10|e\n11|f\n");
    // Deleted values are not reused.
    try c.exec("DELETE FROM t WHERE id = 11");
    try c.exec("INSERT INTO t (v) VALUES ('g')");
    try c.expectRows("SELECT max(id) FROM t", "12\n");
    // NO_AUTO_VALUE_ON_ZERO: 0 is stored.
    try c.exec("SET sql_mode = 'NO_AUTO_VALUE_ON_ZERO'");
    try c.exec("INSERT INTO t VALUES (0, 'zero')");
    try c.expectRows("SELECT v FROM t WHERE id = 0", "zero\n");
    // AUTO_INCREMENT=n.
    try c.exec("CREATE TABLE u (id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY, x INT) AUTO_INCREMENT=100");
    try c.exec("INSERT INTO u (x) VALUES (1)");
    try c.expectRows("SELECT id FROM u", "100\n");
    // TRUNCATE starts again.
    try c.exec("TRUNCATE TABLE u");
    try c.exec("INSERT INTO u (x) VALUES (1)");
    try c.expectRows("SELECT id FROM u", "1\n");
    try c.expectError("CREATE TABLE bad (id INT AUTO_INCREMENT, k INT, PRIMARY KEY (k))", "xqlite: an AUTO_INCREMENT column must be the PRIMARY KEY (or the only UNIQUE key of a table without one)");
    // SERIAL.
    try c.exec("CREATE TABLE s (id SERIAL, v INT)");
    try c.exec("INSERT INTO s (v) VALUES (1), (2)");
    try c.expectRows("SELECT id FROM s", "1\n2\n");
}

test "mariadb: ON DUPLICATE KEY UPDATE, REPLACE, INSERT IGNORE" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (id INT PRIMARY KEY, email VARCHAR(50) UNIQUE, n INT DEFAULT 0)");
    try c.exec("INSERT INTO t VALUES (1, 'a@x', 1)");
    try c.exec("INSERT INTO t VALUES (1, 'b@x', 5) ON DUPLICATE KEY UPDATE n = n + VALUES(n)");
    try c.expectRows("SELECT id, email, n FROM t", "1|a@x|6\n");
    // On the other unique key, case-insensitively.
    try c.exec("INSERT INTO t VALUES (2, 'A@X', 1) ON DUPLICATE KEY UPDATE n = 100");
    try c.expectRows("SELECT id, email, n FROM t", "1|a@x|100\n");
    try c.exec("REPLACE INTO t VALUES (1, 'c@x', 7)");
    try c.expectRows("SELECT id, email, n FROM t", "1|c@x|7\n");
    try c.exec("INSERT IGNORE INTO t VALUES (1, 'd@x', 8), (3, 'e@x', 9)");
    try c.expectRows("SELECT id, email, n FROM t ORDER BY id", "1|c@x|7\n3|e@x|9\n");
    try c.expectError("INSERT INTO t VALUES (4, 'C@X', 1)", "UNIQUE constraint failed: t.email");
    // INSERT ... SET, DEFAULT, RETURNING.
    try c.exec("INSERT INTO t SET id = 5, email = 'f@x'");
    try c.expectRows("INSERT INTO t VALUES (6, 'g@x', DEFAULT) RETURNING id, n", "6|0\n");
    try c.expectRows("SELECT n FROM t WHERE id = 5", "0\n");
    try c.expectError("INSERT INTO t VALUES (7)", "Column count doesn't match value count at row 1");
    try c.expectRows("DELETE FROM t WHERE id >= 5 RETURNING id", "5\n6\n");
    // INSERT ... SELECT converts.
    try c.exec("CREATE TABLE small (b TINYINT)");
    try c.expectError("INSERT INTO small SELECT n * 100 FROM t", "Out of range value for column 'b' at row 1");
    try c.exec("INSERT INTO small SELECT n FROM t WHERE id = 1");
    try c.expectRows("SELECT b FROM small", "7\n");
}

test "mariadb: SELECT forms" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a INT, b VARCHAR(10)); INSERT INTO t VALUES (1,'x'),(2,'y'),(3,'x'),(4,'z')");
    try c.expectRows("SELECT a FROM t ORDER BY a LIMIT 2", "1\n2\n");
    try c.expectRows("SELECT a FROM t ORDER BY a LIMIT 1, 2", "2\n3\n");
    try c.expectRows("SELECT a FROM t ORDER BY a LIMIT 2 OFFSET 2", "3\n4\n");
    try c.expectRows("SELECT a FROM t ORDER BY a DESC OFFSET 1 ROWS FETCH FIRST 1 ROWS ONLY", "3\n");
    try c.expectRows("SELECT b, count(*) AS n FROM t GROUP BY b HAVING n > 1", "x|2\n");
    try c.expectRows("SELECT DISTINCT b FROM t ORDER BY b", "x\ny\nz\n");
    try c.expectRows("SELECT a FROM t WHERE a < 2 UNION SELECT a FROM t WHERE a > 3 ORDER BY a DESC", "4\n1\n");
    try c.expectRows("SELECT b FROM t WHERE a = 1 UNION ALL SELECT b FROM t WHERE a = 3", "x\nx\n");
    try c.expectRows("SELECT b FROM t WHERE a = 1 UNION DISTINCT SELECT b FROM t WHERE a = 3", "x\n");
    try c.expectRows("(SELECT a FROM t ORDER BY a LIMIT 1) UNION ALL (SELECT a FROM t ORDER BY a DESC LIMIT 1)", "1\n4\n");
    try c.expectRows("SELECT x.a, y.a FROM t x JOIN t y ON y.a = x.a + 1 WHERE x.a = 1", "1|2\n");
    try c.expectRows("SELECT x.a, y.a FROM t x STRAIGHT_JOIN t y ON y.a = x.a + 1 WHERE x.a = 2", "2|3\n");
    try c.expectRows("SELECT x.a, y.a FROM t x LEFT OUTER JOIN t y ON y.a = x.a + 10 WHERE x.a = 1", "1|NULL\n");
    try c.expectRows("SELECT count(*) FROM t x, t y", "16\n");
    try c.expectRows("SELECT a FROM t WHERE a IN (SELECT a FROM t WHERE b = 'x') ORDER BY 1", "1\n3\n");
    try c.expectRows("SELECT (SELECT max(a) FROM t), EXISTS(SELECT 1 FROM t WHERE a = 9)", "4|0\n");
    try c.expectRows("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT GROUP_CONCAT(n ORDER BY n DESC SEPARATOR '-') FROM r", "3-2-1\n");
    try c.expectRows("SELECT GROUP_CONCAT(DISTINCT b ORDER BY b) FROM t", "x,y,z\n");
    try c.expectRows("SELECT GROUP_CONCAT(a, b ORDER BY a) FROM t", "1x,2y,3x,4z\n");
    try c.expectRows("SELECT a, row_number() OVER (PARTITION BY b ORDER BY a) FROM t ORDER BY a", "1|1\n2|1\n3|2\n4|1\n");
    try c.expectRows("SELECT sum(a) OVER w FROM t WINDOW w AS (ORDER BY a ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) ORDER BY a", "1\n3\n5\n7\n");
    try c.expectRows("SELECT 1 FROM DUAL", "1\n");
    try c.expectRows("SELECT SQL_NO_CACHE a FROM t WHERE a = 1 FOR UPDATE", "1\n");
    try c.expectRows("SELECT * FROM (SELECT a FROM t) AS s WHERE s.a = 2", "2\n");
    try c.expectRows("SELECT a FROM t FORCE INDEX (PRIMARY) WHERE a = 3", "3\n");
}

test "mariadb: functions" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectRows("SELECT IFNULL(NULL, 2), IF(1 > 2, 'y', 'n'), CONCAT('a', 1, 'b'), CONCAT('a', NULL), CONCAT_WS('-', 'a', NULL, 'b')", "2|n|a1b|NULL|a-b\n");
    try c.expectRows("SELECT CAST('12abc' AS SIGNED), CAST(1.5 AS CHAR), CAST('3.456' AS DECIMAL(5,2)), CAST('2024-01-02 10:00:00' AS DATE)", "12|1.5|3.46|2024-01-02\n");
    try c.expectRows("SELECT LENGTH('é'), CHAR_LENGTH('é'), UCASE('a'), LCASE('B'), SUBSTRING('hello', 2, 3), SUBSTRING('hello' FROM 2), MID('hello', 2, 1)", "2|1|A|b|ell|ello|e\n");
    try c.expectRows("SELECT TRIM('  x  '), TRIM(LEADING 'x' FROM 'xxaxx'), TRIM(TRAILING FROM 'a  '), LOCATE('l', 'hello'), LOCATE('l', 'hello', 4), POSITION('l' IN 'hello')", "x|axx|a|3|4|3\n");
    try c.expectRows("SELECT LPAD('5', 3, '0'), RPAD('ab', 4, '.'), LEFT('hello', 2), RIGHT('hello', 3), REPEAT('ab', 2), REVERSE('abc'), HEX(255), HEX('A')", "005|ab..|he|llo|abab|cba|FF|41\n");
    try c.expectRows("SELECT FLOOR(1.5), CEIL(1.2), POW(2, 10), ROUND(2.5), TRUNCATE(1.29, 1), ABS(-3), GREATEST(1, 5, 3), LEAST(4, 2), MOD(10, 3)", "1|2|1024.0|3|1.2|3|5|2|1\n");
    try c.expectRows("SELECT FORMAT(1234567.891, 2), FIND_IN_SET('b', 'a,b,c'), FIELD('b', 'a', 'b'), ELT(2, 'a', 'b')", "1,234,567.89|2|2|b\n");
    try c.expectRows("SELECT DATE_ADD('2024-01-31', INTERVAL 1 MONTH), '2024-01-01' + INTERVAL 1 DAY, DATE_SUB('2024-03-01 00:00:00', INTERVAL 1 SECOND)", "2024-02-29|2024-01-02|2024-02-29 23:59:59\n");
    try c.expectRows("SELECT YEAR('2024-05-06'), MONTH('2024-05-06'), DAY('2024-05-06'), DAYOFWEEK('2024-05-06'), DATEDIFF('2024-03-01', '2024-02-01'), LAST_DAY('2023-02-10')", "2024|5|6|2|29|2023-02-28\n");
    try c.expectRows("SELECT DATE_FORMAT('2024-05-06 13:04:05', '%Y/%m/%d %H:%i:%s %W %M %D'), EXTRACT(YEAR FROM '2024-05-06')", "2024/05/06 13:04:05 Monday May 6th|2024\n");
    try c.expectRows("SELECT TIMESTAMPDIFF(MONTH, '2024-01-15', '2024-03-14'), TIMESTAMPDIFF(DAY, '2024-01-01', '2024-01-31')", "1|30\n");
    try c.expectRows("SELECT NOW() = CURRENT_TIMESTAMP, LENGTH(NOW()), LENGTH(CURDATE()), DATABASE(), VERSION() LIKE '%MariaDB%'", "1|19|10|main|1\n");
    try c.expectRows("SELECT ISNULL(NULL), COALESCE(NULL, 1), NULLIF(1, 1)", "1|1|NULL\n");
    try c.expectRows("SELECT ROUND(2.5), ROUND(2.567, 2), ROUND(-2.5), ROUND(15, -1), CAST('2024-02-30' AS DATE)", "3|2.57|-3|20|NULL\n");
    try c.expectRows("SELECT ASCII('A'), DAYNAME('2024-05-06'), MONTHNAME('2024-05-06'), TIME('2024-01-01 10:20:30'), STR_TO_DATE('01/02/2024', '%m/%d/%Y')", "65|Monday|May|10:20:30|2024-01-02\n");
    // IN compares with the default collation too.
    try c.expectRows("SELECT 'a' IN ('A', 'b'), 'a' IN ('A'), 'a' IN (SELECT 'A')", "1|1|1\n");
}

test "mariadb: collation and case-insensitive keys" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE u (name VARCHAR(20) NOT NULL, code VARCHAR(10) COLLATE utf8mb4_bin, UNIQUE KEY uk_name (name), KEY (code))");
    try c.exec("INSERT INTO u VALUES ('Alice', 'A'), ('bob', 'a')");
    try c.expectError("INSERT INTO u VALUES ('ALICE', 'x')", "UNIQUE constraint failed: u.name");
    try c.expectRows("SELECT name FROM u WHERE name = 'BOB'", "bob\n");
    try c.expectRows("SELECT count(*) FROM u WHERE code = 'a'", "1\n");
    try c.expectRows("SELECT name FROM u ORDER BY name", "Alice\nbob\n");
    try c.expectRows("SELECT sql FROM sqlite_schema WHERE name = 'u'", "CREATE TABLE \"u\"(\"name\" TEXT NOT NULL COLLATE NOCASE, \"code\" TEXT COLLATE BINARY) STRICT\n");
    try c.expectRows("SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name", "u$code\nu$uk_name\n");
}

test "mariadb: DDL, catalog, SHOW and DESCRIBE" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE IF NOT EXISTS `users` (
        \\  `id` int(11) unsigned NOT NULL AUTO_INCREMENT COMMENT 'pk',
        \\  `email` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
        \\  `status` enum('active','banned') NOT NULL DEFAULT 'active',
        \\  `score` decimal(10,2) DEFAULT NULL,
        \\  `meta` json DEFAULT NULL,
        \\  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
        \\  `updated_at` datetime DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
        \\  PRIMARY KEY (`id`),
        \\  UNIQUE KEY `email` (`email`),
        \\  KEY `idx_status` (`status`, `created_at`)
        \\) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci COMMENT='Users';
    );
    try c.expectRows("SHOW TABLES", "users\n");
    try c.expectColumns("SHOW TABLES", "Tables_in_main");
    try c.expectRows("DESCRIBE users",
        \\id|int(11) unsigned|NO|PRI|NULL|auto_increment
        \\email|varchar(255)|NO|UNI|NULL|
        \\status|enum('active','banned')|NO|MUL|active|
        \\score|decimal(10,2)|YES||NULL|
        \\meta|longtext|YES||NULL|
        \\created_at|timestamp|NO||current_timestamp()|
        \\updated_at|datetime|YES||NULL|on update current_timestamp()
        \\
    );
    try c.expectColumns("SHOW COLUMNS FROM users", "Field|Type|Null|Key|Default|Extra");
    try c.exec("INSERT INTO users (email, meta) VALUES ('x@y', '{\"a\":1}')");
    try c.expectRows("SELECT id, status, length(created_at), updated_at FROM users", "5|active|19|NULL\n");
    try c.expectError("INSERT INTO users (email, meta) VALUES ('z@y', 'not json')", "CHECK constraint failed: meta");
    try c.exec("UPDATE users SET score = 1.5");
    try c.expectRows("SELECT score, updated_at IS NOT NULL FROM users", "1.5|1\n");
    try c.expectRows("SHOW INDEX FROM users", "users|0|PRIMARY|1|id|A|NULL|NULL|NULL||BTREE|||NO\n" ++
        "users|0|email|1|email|A|NULL|NULL|NULL||BTREE|||NO\n" ++
        "users|1|idx_status|1|status|A|NULL|NULL|NULL||BTREE|||NO\n" ++
        "users|1|idx_status|2|created_at|A|NULL|NULL|NULL||BTREE|||NO\n");
    // The second CREATE IF NOT EXISTS does nothing.
    try c.exec("CREATE TABLE IF NOT EXISTS users (x INT)");
    try c.expectRows("SHOW WARNINGS", "Note|1050|Table 'users' already exists\n");
    // Indexes, views, ALTER, DROP.
    try c.exec("CREATE INDEX idx_score ON users (score)");
    try c.exec("DROP INDEX idx_score ON users");
    try c.exec("CREATE VIEW v AS SELECT id, IF(status = 'active', 1, 0) AS on_ FROM users WHERE email <> \"\"");
    try c.expectRows("SELECT * FROM v", "5|1\n");
    try c.exec("CREATE OR REPLACE VIEW v AS SELECT id FROM users");
    try c.expectRows("SELECT * FROM v", "5\n");
    try c.exec("ALTER TABLE users ADD COLUMN nick VARCHAR(3) DEFAULT 'abc'");
    try c.expectError("UPDATE users SET nick = 'abcd'", "Data too long for column 'nick' at row 1");
    try c.exec("ALTER TABLE users RENAME TO people");
    try c.expectRows("SELECT nick FROM people", "abc\n");
    try c.exec("DROP VIEW v; DROP TABLE people; DROP TABLE IF EXISTS people");
    try c.expectError("DROP TABLE people", "Unknown table 'main.people'");
    try c.expectRows("SELECT count(*) FROM xq_catalog", "0\n");
}

test "mariadb: transactions, USE, user variables, LIMIT on DML" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (a INT)");
    try c.exec("START TRANSACTION; INSERT INTO t VALUES (1); SAVEPOINT s1; INSERT INTO t VALUES (2); ROLLBACK TO SAVEPOINT s1; COMMIT");
    try c.expectRows("SELECT a FROM t", "1\n");
    try c.exec("BEGIN; INSERT INTO t VALUES (9); ROLLBACK WORK");
    try c.expectRows("SELECT count(*) FROM t", "1\n");
    try c.exec("USE main");
    try c.expectError("USE nope", "Unknown database 'nope'");
    try c.exec("SET @x = 5, @y := 'a'");
    try c.expectRows("SELECT @x + 1, @y, @z, @w := 3, @w", "6|a|NULL|3|3\n");
    try c.exec("INSERT INTO t VALUES (2), (3), (4), (5)");
    try c.exec("DELETE FROM t ORDER BY a DESC LIMIT 2");
    try c.expectRows("SELECT a FROM t ORDER BY a", "1\n2\n3\n");
    try c.exec("UPDATE t SET a = a * 10 ORDER BY a LIMIT 1");
    try c.expectRows("SELECT a FROM t ORDER BY a", "2\n3\n10\n");
    try c.exec("LOCK TABLES t WRITE; UNLOCK TABLES");
    try c.exec("SET foreign_key_checks = 0; SET autocommit = 1; SET time_zone = '+00:00'");
    // Back to SQLite.
    try c.exec("PRAGMA xq_dialect = 'sqlite'");
    try c.expectRows("SELECT 'a' || 'b', 'a' IN ('A', 'b'), 'a' IN ('A')", "ab|0|0\n");
}

test "mariadb: errors" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.expectError("SELEC 1", "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near 'SELEC 1' at line 1");
    try c.expectError("SELECT 1 FROM", "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near '' at line 1");
    try c.expectError("SELECT * FROM nope", "no such table: nope");
    try c.exec("  -- just a comment\n ");
    try c.exec(";;");
}

test "mariadb: CHECK, generated columns, foreign keys, DEFAULT" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec(
        \\CREATE TABLE p (
        \\  id INT PRIMARY KEY,
        \\  start INT, `end` INT,
        \\  price DECIMAL(6,2) NOT NULL DEFAULT 1.50 CHECK (price >= 0),
        \\  label VARCHAR(10) DEFAULT 'it\'s',
        \\  span INT AS (`end` - start) VIRTUAL,
        \\  CONSTRAINT chk_order CHECK (start <= `end` && start >= 0)
        \\)
    );
    try c.exec("INSERT INTO p (id, start, end) VALUES (1, 2, 5)");
    try c.expectRows("SELECT price, label, span, end FROM p", "1.5|it's|3|5\n");
    try c.expectError("INSERT INTO p (id, start, end) VALUES (2, 5, 1)", "CHECK constraint failed: chk_order");
    try c.expectError("INSERT INTO p (id, price) VALUES (3, -1)", "CHECK constraint failed: price");
    try c.exec("UPDATE p SET price = 9, label = DEFAULT");
    try c.expectRows("SELECT price, label FROM p", "9.0|it's\n");
    try c.exec("CREATE TABLE ch (id INT AUTO_INCREMENT PRIMARY KEY, pid INT, FOREIGN KEY (pid) REFERENCES p (id) ON DELETE CASCADE)");
    try c.exec("SET foreign_key_checks = 1");
    try c.expectRows("SELECT @@foreign_key_checks", "1\n");
    try c.exec("INSERT INTO ch (pid) VALUES (1), (1)");
    try c.expectError("INSERT INTO ch (pid) VALUES (42)", "FOREIGN KEY constraint failed");
    try c.exec("DELETE FROM p");
    try c.expectRows("SELECT count(*) FROM ch", "0\n");
}

test "mariadb: information_schema" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(20) NOT NULL DEFAULT 'x'); CREATE VIEW v AS SELECT id FROM t");
    try c.expectRows("SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES ORDER BY TABLE_NAME", "main|t|BASE TABLE\nmain|v|VIEW\n");
    try c.expectRows("SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA FROM information_schema.columns WHERE table_name = 'T' AND table_schema = 'main' ORDER BY ORDINAL_POSITION",
        \\id|int|int(11)|NO|NULL|PRI|auto_increment
        \\name|varchar|varchar(20)|NO|x||
        \\
    );
    try c.expectRows("SELECT count(*) FROM information_schema.tables t JOIN information_schema.columns c ON c.table_name = t.table_name WHERE t.table_type = 'VIEW'", "1\n");
    try c.expectRows("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA", "main\n");
    try c.expectError("SELECT * FROM information_schema.nope", "Unknown table 'nope' in information_schema");
}

test "mariadb: names, parameters and the file seen from SQLite" {
    var c: Conn = undefined;
    try open(&c);
    defer c.close();
    try c.exec("CREATE TABLE Items (Id INT PRIMARY KEY, Label CHAR(5))");
    try c.exec("INSERT INTO items (ID, label) VALUES (1, 'ab  ')");
    try c.expectRows("SELECT ITEMS.LABEL, length(label) FROM ITEMS", "ab|2\n");
    try c.expectRows("SHOW TABLES LIKE 'it%'", "Items\n");
    try c.expectRows("SHOW CREATE TABLE items",
        \\Items|CREATE TABLE `Items` (
        \\  `Id` int(11) NOT NULL,
        \\  `Label` char(5) DEFAULT NULL,
        \\  PRIMARY KEY (`Id`)
        \\) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
        \\
    );
    try c.expectError("INSERT INTO items (id) VALUES (NULL)", "Column 'Id' cannot be null");
    // A parameter is converted like a literal.
    const api = @import("../../vdbe/api.zig");
    var stmt: ?*@import("../../vdbe/vdbe_int.zig").Vdbe = null;
    try testing.expectEqual(int.RC.OK, @import("../../sql/prepare.zig").prepareV2(c.db, "INSERT INTO items VALUES (?, ?)", &stmt, null));
    _ = api.bindInt64(stmt.?, 1, 2);
    _ = api.bindText(stmt.?, 2, "toolong");
    try testing.expectEqual(int.RC.ERROR, api.step(stmt.?));
    _ = api.finalize(stmt.?);
    try c.expectRows("SELECT count(*) FROM items", "1\n");
    // The file is SQLite's: the SQLite dialect reads it, and the STRICT
    // types hold there too.
    try c.reopen();
    try c.expectRows("SELECT typeof(Id), Label FROM Items", "integer|ab\n");
    try c.expectError("INSERT INTO Items VALUES (3, x'00')", "cannot store BLOB value in TEXT column Items.Label");
    try c.expectRows("PRAGMA integrity_check", "ok\n");
}
