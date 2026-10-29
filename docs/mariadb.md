# MariaDB 호환

xqlite의 MariaDB(MySQL) 방언이 지원하는 문법과 의미, 그리고 MariaDB와 다른 점입니다. 방언 구조와 프론트엔드 계약은 [README의 방언 아키텍처](../README.md#방언-아키텍처)를 보세요.

`PRAGMA xq_dialect = 'mariadb'`(또는 `'mysql'`), 셸의 `.dialect mariadb`, Zig API의 `db.setDialect(.mariadb)`로 켭니다. SQLite로 돌아갈 때는 MariaDB 방언에서도 `PRAGMA xq_dialect = 'sqlite'`를 그대로 씁니다(`PRAGMA`, `ATTACH`, `DETACH`, `VACUUM`, `REINDEX`는 SQLite 문장으로 넘김).

```sql
PRAGMA xq_dialect = 'mariadb';
CREATE TABLE `users` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `email` varchar(190) NOT NULL,
  `status` enum('active','banned') NOT NULL DEFAULT 'active',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_email` (`email`)
) ENGINE=InnoDB AUTO_INCREMENT=100 DEFAULT CHARSET=utf8mb4;
INSERT INTO users (email) VALUES ('a@x.org'), ('b@x.org');
INSERT INTO users (email) VALUES ('A@X.ORG') ON DUPLICATE KEY UPDATE status = 'banned';
SELECT id, email, status FROM users ORDER BY id LIMIT 0, 10;   -- 100, 101
SET sql_mode = '';                                -- 엄격 모드 끄기
INSERT INTO users (email, status) VALUES ('c@x.org', 'nope');  -- '' + 경고
SHOW WARNINGS;
```

## 구조

`src/dialect/mariadb/`의 토크나이저(`lexer.zig`)와 재귀 하강 파서(`parser.zig`, `functions.zig`, `dml.zig`, `ddl.zig`, `session.zig`)가 문장을 구문 트리 IR(`ir.tree`)로 만들고, 실행할 문장은 `ir.lower`가, 스키마에 저장되는 것(CREATE TABLE의 CHECK·DEFAULT·생성 열, CREATE VIEW, 인덱스)은 `ir.render`가 같은 트리에서 만듭니다. 그래서 질의, CHECK, DEFAULT, 생성 열, 뷰에서 같은 식은 같은 뜻입니다(`/`는 어디서나 `CAST(l AS REAL) / r`, `DIV`는 `xq_div()`, 바뀐 함수 이름도 같음). 파서가 트리에 남기는 MariaDB 의미는 다음과 같습니다.


- `/`는 `div{real}`, `DIV`는 `div{int}`, `XOR`·`^`는 엔진 함수 `xq_xor()`·`xq_bitxor()`, `<=>`는 `IS`, `||`는 `OR`(`PIPES_AS_CONCAT`이면 `concat{propagate}`), 두 인자 이상의 `CONCAT()`도 `concat{propagate}`, `LIKE`는 SQLite `LIKE ... ESCAPE '\'`(ASCII 대소문자 무시).
- 이름이 다른 함수는 SQLite 내장 함수나 엔진 함수로 바꾸고(`UCASE` → `upper`, `CHAR_LENGTH` → `length`, `GREATEST` → `max`, `STDDEV` → `xq_stddev_pop` ...), 방언 함수 테이블(`runtime.zig`)의 함수는 `Func.dialect = .mariadb`로 표시해 스키마에는 `xq_mariadb_left(...)`처럼 한정 이름으로 씁니다.
- INSERT/UPDATE가 열에 저장하는 값은 `coerce` 노드(`xq_coerce()`), `AUTO_INCREMENT` 열의 0은 `nullif(v, 0)`(`NO_AUTO_VALUE_ON_ZERO`가 아니면), VALUES/SET의 `DEFAULT`는 IR 공통 의미(그 열의 DEFAULT, 없으면 NULL이라 `AUTO_INCREMENT`는 다음 rowid)로 내립니다.
- 결과 열 이름은 MariaDB처럼 쓴 식의 텍스트(문자열 상수는 그 값)입니다.

`SHOW`·`DESCRIBE`·`information_schema`는 스키마·pragma 함수·`xq_catalog`를 읽는 SQLite 질의를 만들어 내리고(`information_schema` 뷰는 MariaDB 텍스트를 같은 파서로 트리로 만듦), `SET`의 값은 트리로 만들어 `ir.lower`로 내립니다. 세션 상태(`sql_mode`, 경고, 사용자 변수)는 연결의 `ConnState.mariadb`(`state.zig`)에 있고, MariaDB 의미가 SQLite와 다른 연산·함수는 엔진 함수와 방언 함수 테이블(`runtime.zig`)로 구현합니다.

## 저장 방식

DDL은 SQLite 텍스트로 렌더링해 `ir.stmt.lowerSqliteText()`로 내리므로 sqlite3가 그대로 열고 `PRAGMA integrity_check`를 통과합니다.


- 테이블은 `STRICT`이고 열은 저장 타입(`INTEGER`/`REAL`/`TEXT`/`BLOB`)으로, MariaDB 선언 타입(`int(10) unsigned`, `varchar(20)`, `enum('a','b')` ...)·기본값·`AUTO_INCREMENT`·`ON UPDATE CURRENT_TIMESTAMP`는 같은 문장 안에서 `xq_catalog`에 기록합니다(`SHOW COLUMNS`, `DESCRIBE`, `SHOW CREATE TABLE`, `information_schema`가 읽음).
- 문자열 열에는 언제나 명시적 `COLLATE`를 적습니다. 기본·`*_ci` collation은 `NOCASE`, `*_bin`·`binary`·`*_cs`는 `BINARY`이고, 날짜·JSON 열은 `BINARY`입니다. 그래서 `UNIQUE` 키도 MariaDB처럼 대소문자를 구분하지 않습니다. `NOCASE`는 ASCII만 접습니다(`'é' = 'É'`는 거짓).
- `AUTO_INCREMENT`는 SQLite의 `INTEGER PRIMARY KEY AUTOINCREMENT`(sqlite_sequence)입니다. NULL과 0(`NO_AUTO_VALUE_ON_ZERO`가 아니면)은 다음 값을 만들고, 더 큰 값을 직접 넣으면 카운터가 따라가며, 지운 값은 다시 쓰지 않습니다. `AUTO_INCREMENT=n`은 sqlite_sequence를 미리 채우고 `TRUNCATE`는 되돌립니다. 열은 PRIMARY KEY(또는 PRIMARY KEY 없는 테이블의 유일한 UNIQUE 키)여야 합니다. `LAST_INSERT_ID()`는 `last_insert_rowid()`입니다.
- MariaDB 인덱스 이름은 테이블마다, SQLite는 스키마마다 유일하므로 테이블 `t`의 인덱스 `i`는 SQLite 인덱스 `"t$i"`입니다. `KEY`/`INDEX`/`UNIQUE` 정의는 테이블을 만든 직후 같은 문장 안에서(`OP_SqlExec`) 만듭니다. `RENAME TABLE t TO u`(와 `ALTER TABLE ... RENAME`)는 인덱스 이름도 `"u$i"`로 바꿉니다. SQLite의 ALTER TABLE처럼 같은 문장 안에서 `sqlite_schema`의 인덱스 행(이름과 CREATE INDEX 텍스트)을 고쳐 쓰고 스키마를 다시 읽으므로 b-tree는 그대로이고, `SHOW INDEX`, `SHOW CREATE TABLE`, `DROP INDEX i ON u`가 새 이름으로 찾습니다.
- 열의 `CHECK`는 열 이름, 이름 없는 테이블 `CHECK`는 `CONSTRAINT_<n>`으로 MariaDB처럼 이름을 붙입니다(오류는 `CHECK constraint failed: price`).
- `JSON`은 `longtext` + `CHECK(json_valid(...))`, `BOOL`은 `tinyint(1)`, `SERIAL`은 `bigint unsigned NOT NULL AUTO_INCREMENT UNIQUE`입니다.

## `sql_mode`

연결 단위이고 기본값은 MariaDB 10.2+의 `STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION`입니다. `SET [SESSION] sql_mode = ...`, `SET @@sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')`, `SET sql_mode = DEFAULT`로 바꾸고 `SELECT @@sql_mode`로 읽습니다(조합 모드 `ANSI`, `TRADITIONAL`, `POSTGRESQL` ... 는 MariaDB처럼 펼쳐 보임). `SET`은 문장이 실행될 때 적용되고, 문법에 영향을 주는 모드는 그 뒤에 컴파일되는 문장부터 적용됩니다.


- `ANSI_QUOTES`: `"x"`가 식별자(아니면 문자열). `PIPES_AS_CONCAT`: `||`가 연결(아니면 `OR`). `NO_BACKSLASH_ESCAPES`: 문자열의 `\`가 보통 문자. `EMPTY_STRING_IS_NULL`, `NO_AUTO_VALUE_ON_ZERO`도 지원합니다.
- 엄격 모드(`STRICT_TRANS_TABLES`/`STRICT_ALL_TABLES`, 모든 테이블이 트랜잭션 테이블이라 같은 뜻): INSERT/UPDATE가 저장하는 값마다 `xq_coerce(value, type, ...)`를 거칩니다. 엄격 모드에서는 범위 밖·너무 긴 값·잘못된 날짜가 MariaDB 메시지(`Out of range value for column 'i' at row 1`, `Data too long ...`, `Incorrect date value ...`)로 문장을 실패시키고, 아니면(또는 `INSERT/UPDATE IGNORE`) 잘라 저장하고 경고를 남깁니다(`SHOW WARNINGS`, `@@warning_count`). `NOT NULL` 열의 NULL, 기본값 없는 `NOT NULL` 열 생략(`Field 'c' doesn't have a default value`)도 MariaDB와 같습니다. `NO_ZERO_DATE`, `NO_ZERO_IN_DATE`, `ALLOW_INVALID_DATES`는 날짜 변환에 반영합니다. 실행 시점의 모드를 읽으므로 준비된 문장도 현재 모드를 따릅니다.
- `ONLY_FULL_GROUP_BY`, `ERROR_FOR_DIVISION_BY_ZERO`(0으로 나누기는 언제나 NULL), `HIGH_NOT_PRECEDENCE`, `PAD_CHAR_TO_FULL_LENGTH`, `IGNORE_SPACE`, `REAL_AS_FLOAT`는 받아들이지만 효과가 없습니다.

## 지원 문법


- 토큰: `` `a``b` ``, `'...'`/`"..."`와 백슬래시 이스케이프(`\%`, `\_`는 LIKE용으로 유지), `#`·`-- `·`/* */` 주석, 실행 주석 `/*! */`·`/*!50100 */`·`/*M!100100 */`(버전이 11.8 이하면 코드), `X'..'`/`0x..`, `b'..'`/`0b..`, `N'..'`, `_utf8mb4'..'`, 인접 문자열 연결, `?`, `@var`, `@@[session.]var`.
- 식: MariaDB 우선순위, `||`/`&&`/`!`/`XOR`/`<=>`/`DIV`/`MOD`/`^`/`<<`/`>>`, `/`는 실수 나눗셈(7/2 = 3.5), `LIKE`(기본 escape `\`, 대소문자 무시), `IN`, `BETWEEN`, `IS [NOT] TRUE/FALSE/NULL/UNKNOWN`, `CASE`, `CAST/CONVERT(... AS SIGNED/UNSIGNED/CHAR(n)/DECIMAL(p,s)/DATE/DATETIME/TIME/BINARY)`, `BINARY x`, `COLLATE`, `x + INTERVAL n DAY`, `NEXT VALUE FOR s`, 윈도우 함수. 함수: `IFNULL`, `IF`, `CONCAT`(NULL이면 NULL), `CONCAT_WS`, `GROUP_CONCAT([DISTINCT] ... ORDER BY ... SEPARATOR ...)`, `NOW()`/`CURDATE()`/`CURTIME()`(UTC), `LAST_INSERT_ID()`, `LENGTH`(바이트)/`CHAR_LENGTH`, `SUBSTRING(... FROM ... FOR ...)`, `TRIM(LEADING ... FROM ...)`, `LOCATE`, `POSITION`, `LPAD`/`RPAD`, `LEFT`/`RIGHT`, `REPEAT`, `REVERSE`, `HEX`, `FORMAT`, `FIND_IN_SET`, `FIELD`, `ELT`, `FLOOR`/`CEIL`/`ROUND`/`TRUNCATE`/`POW`/`SQRT`/`LOG` ..., `DATE_ADD`/`DATE_SUB`, `DATEDIFF`, `TIMESTAMPDIFF`, `DATE_FORMAT`, `STR_TO_DATE`, `YEAR`/`MONTH`/`DAY`/`HOUR`/`DAYOFWEEK`/`DAYNAME` ..., `EXTRACT`, `UUID()`, `RAND()`, `STDDEV`/`VARIANCE`, `JSON_UNQUOTE`(그 밖의 `JSON_*`는 SQLite의 json 함수).
- `SELECT`: `DISTINCT`, 조인(`STRAIGHT_JOIN`은 순서 고정), `LIMIT n` / `LIMIT off, n` / `LIMIT n OFFSET m` / `OFFSET ... FETCH`, `GROUP BY`(ASC/DESC 무시), `HAVING`, `WINDOW`, `UNION [ALL|DISTINCT]`/`EXCEPT`/`INTERSECT`와 괄호 친 항, 서브쿼리, `WITH [RECURSIVE]`, `FROM DUAL`, 인덱스 힌트·`FOR UPDATE`·`LOCK IN SHARE MODE`·`SQL_NO_CACHE` 등은 무시, 테이블 값 함수.
- DML: `INSERT [IGNORE]`(`VALUES`/`VALUE` 여러 행, `SET a=1`, `SELECT`, `DEFAULT`, `ON DUPLICATE KEY UPDATE col = VALUES(col)`, `RETURNING`), `REPLACE`, `UPDATE [IGNORE] ... [ORDER BY] [LIMIT n]`, `DELETE ... [ORDER BY] [LIMIT n] [RETURNING]`, `TRUNCATE`.
- DDL: `CREATE [TEMPORARY] TABLE [IF NOT EXISTS]`(타입, `NOT NULL`/`NULL`, `DEFAULT`, `AUTO_INCREMENT`, `PRIMARY KEY`, `UNIQUE [KEY]`, `KEY`/`INDEX`(접두 길이 무시), `CHECK`, `FOREIGN KEY ... ON DELETE/UPDATE`, 생성 열 `AS (...) VIRTUAL/STORED`, `COMMENT`·`CHARACTER SET`·`COLLATE`, 테이블 옵션 `ENGINE=`·`DEFAULT CHARSET=`·`COLLATE=`·`AUTO_INCREMENT=n` ...), `CREATE TABLE ... AS SELECT`, `DROP TABLE [IF EXISTS]`, `CREATE [UNIQUE] INDEX`, `DROP INDEX i ON t`, `CREATE [OR REPLACE] VIEW`, `DROP VIEW`, `CREATE/DROP SEQUENCE`, `ALTER TABLE` 한 가지 변경(`ADD [COLUMN]`, `DROP [COLUMN]`, `RENAME COLUMN`, `RENAME TO`, `ADD/DROP INDEX`, `DISABLE/ENABLE KEYS`·테이블 옵션은 무시), `RENAME TABLE`.
- 그 밖: `START TRANSACTION`/`BEGIN [WORK]`/`COMMIT`/`ROLLBACK [TO SAVEPOINT]`/`SAVEPOINT`/`RELEASE SAVEPOINT`, `SET`(시스템 변수, `@사용자 변수`, `NAMES`, `CHARACTER SET`, `TRANSACTION`, `foreign_key_checks`는 `PRAGMA foreign_keys`), `SHOW [FULL] TABLES [LIKE]`, `SHOW COLUMNS/FIELDS`, `DESCRIBE`/`DESC`, `SHOW INDEX`, `SHOW CREATE TABLE`, `SHOW WARNINGS/ERRORS/COUNT(*) WARNINGS`, `SHOW VARIABLES [LIKE]`, `SHOW DATABASES`, `EXPLAIN`(= `EXPLAIN QUERY PLAN`), `USE db`(존재 확인만, 기본 스키마는 `main`), `LOCK/UNLOCK TABLES`(무시), `information_schema.TABLES/COLUMNS/SCHEMATA`. mysqldump 출력을 그대로 불러올 수 있습니다.
- 이름: 쓴 대소문자를 그대로 저장하고 대소문자 없이 비교합니다(MariaDB `lower_case_table_names=2`와 같은 동작이라 `@@lower_case_table_names`는 2). 데이터베이스는 SQLite 스키마(`main`, `ATTACH`한 이름)입니다.

## MariaDB와 다른 점 / 하지 않은 것

저장 프로시저·함수, MySQL 문법의 트리거·이벤트, 다중 테이블 `UPDATE`/`DELETE`, `ALTER TABLE`의 `CHANGE`/`MODIFY`와 여러 변경, `PARTITION`, `FULLTEXT`(보통 인덱스로 만듦)·`MATCH ... AGAINST`, `REGEXP`(SQLite처럼 `regexp()` 함수가 있어야 함), `WITH ROLLUP`, `SELECT ... INTO`, `LOAD DATA`, `CREATE TABLE ... LIKE`, `CREATE OR REPLACE TABLE`, `INVISIBLE` 열, utf8 밖의 문자 집합, `ONLY_FULL_GROUP_BY` 검사, 셸의 문장 분할(SQLite 규칙이라 `'it\'s'` 같은 문자열이 있으면 파일 끝까지 한 덩어리로 실행됨). 또한:

- `DECIMAL`은 `REAL`(scale 0이면 `INTEGER`)로 저장되어 반올림은 되지만 정확한 십진 연산이 아니고 `220.00`이 `220.0`으로 보입니다. 정수형 실수(`POW(2,10)`)도 `1024.0`처럼 SQLite 형식으로 보입니다.
- `BIGINT UNSIGNED`와 `CAST(... AS UNSIGNED)`는 부호 있는 64비트 범위입니다. `TIMESTAMP`는 시간대 변환이 없고 범위도 `DATETIME`과 같습니다(시간대는 UTC).
- PAD SPACE 비교가 없어 `'x' = 'x  '`는 거짓입니다. UPDATE의 대입은 모두 이전 행 값을 봅니다(`SIMULTANEOUS_ASSIGNMENT`와 같음). `LAST_INSERT_ID()`는 여러 행 INSERT에서 마지막 행 id이고 직접 넣은 id에도 바뀝니다. `ON DUPLICATE KEY UPDATE`의 affected rows는 SQLite 방식(행마다 1)입니다.
- `SHOW WARNINGS`는 문장을 컴파일할 때(보통 직전 문장 실행 직후) 기록된 경고를 보여 주고, 경고는 다음 문장을 컴파일할 때 지워집니다(최대 8개 저장, 개수는 전부 셈). 엔진 오류(`no such table`, `UNIQUE constraint failed` ...)는 SQLite 메시지 그대로입니다.
- 저장되는 식(`DEFAULT (...)`, `CHECK`, 생성 열, 뷰)에는 MariaDB처럼 변수와 매개변수를 쓸 수 없습니다(`Function or expression '@x' cannot be used in the CHECK clause of ...`, `View's SELECT contains a variable or parameter`). 엔진 함수(`xq_div` ...)·방언 함수(`xq_mariadb_*`)를 부르는 스키마는 xqlite에서는 어느 방언으로든 같은 결과를 내지만 sqlite3에서는 그 식을 계산할 수 없습니다(`/`, `UCASE`, `GREATEST`, `IF`, `CONCAT`, `LIKE` 같은 식은 sqlite3에서도 같음, `tools/interop-mariadb.sh`).
- 저장된 식의 비교는 열 collation이 없으면 읽는 연결의 기본 collation을 씁니다(MariaDB 방언은 `NOCASE`, SQLite 방언과 sqlite3는 `BINARY`). 문자열 열에는 언제나 collation을 적으므로 열과의 비교는 어디서나 같고, 열이 아닌 값끼리(`'a' = 'A'`, `UPPER(x) = 'a'`) 비교할 때만 다릅니다.
- `DEFAULT (NEXT VALUE FOR s)`는 아직 쓸 수 없습니다(`nextval()`이 unsafe라 스키마에서 부를 수 없음). `ALTER TABLE ... ADD COLUMN`의 DEFAULT는 SQLite처럼 상수여야 합니다. `INSERT ... SELECT`의 변환 오류 메시지의 행 번호는 언제나 1이고, `information_schema`를 읽는 뷰는 pragma 테이블 값 함수가 스키마에서 unsafe라 쓸 수 없습니다.
