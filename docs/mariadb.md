# MariaDB 호환

xqlite의 MariaDB(MySQL) 방언이 지원하는 문법과 의미, 그리고 MariaDB와 다른 점입니다. 방언 구조와 프론트엔드 계약은 [방언 아키텍처](architecture.md)를 보세요.

## 목차

- [켜는 법](#켜는-법)
- [구조](#구조)
- [저장 방식](#저장-방식)
- [sql_mode](#sql_mode)
- [지원 문법](#지원-문법)
- [MariaDB와 다른 점](#mariadb와-다른-점)
- [아직 하지 않은 것](#아직-하지-않은-것)
- [검증](#검증)

## 켜는 법

| 어디서 | 어떻게 |
| --- | --- |
| SQL | `PRAGMA xq_dialect = 'mariadb'`(또는 `'mysql'`) |
| 셸 | `.dialect mariadb` |
| Zig API | `db.setDialect(.mariadb)` |

- SQLite로 돌아갈 때도 `PRAGMA xq_dialect = 'sqlite'`를 그대로 씁니다.
- `PRAGMA`, `ATTACH`, `DETACH`, `VACUUM`, `REINDEX`는 MariaDB 방언에서도 SQLite 문장으로 넘깁니다. `VACUUM`과 `VACUUM INTO`는 SQLite와 같이 동작합니다([SQLite 호환](sqlite.md#vacuum과-백업-api)).

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

`src/dialect/mariadb/`의 파일입니다.

| 파일 | 하는 일 |
| --- | --- |
| `frontend.zig` | 방언 진입점: 프론트엔드와 훅(방언 함수, 엔진 함수, 대소문자 무시 기본 collation) |
| `lexer.zig` | 토크나이저: 백틱, MariaDB 문자열과 이스케이프, 주석, 실행 주석, `X'..'`·`0x..`·`b'..'`, `@변수` |
| `parser.zig` | 재귀 하강 파서의 핵심, 식, SELECT |
| `functions.zig` | 함수 호출과 특수 문법(`CAST`, `TRIM`, `SUBSTRING ... FROM`, `GROUP_CONCAT ... SEPARATOR` ...) |
| `dml.zig` | INSERT, REPLACE, UPDATE, DELETE, TRUNCATE |
| `ddl.zig` | CREATE/DROP/ALTER, 인덱스, `xq_catalog` 키 |
| `session.zig` | SET, 트랜잭션, USE, SHOW, DESCRIBE, EXPLAIN, LOCK TABLES, ANALYZE TABLE |
| `infoschema.zig` | `information_schema.TABLES`, `COLUMNS`, `SCHEMATA` |
| `types.zig` | MariaDB 열 타입, 저장 타입, INSERT/UPDATE의 값 변환(`xq_coerce()`) |
| `runtime.zig` | 방언 함수 테이블: SQLite에 없거나 뜻이 다른 연산·함수 |
| `state.zig` | 연결 상태 `ConnState.mariadb`: `sql_mode`, 경고, 사용자 변수 |
| `test.zig` | MariaDB 문서의 동작에 맞춘 끝에서 끝까지 테스트 |

### IR 트리, lower, render

- 파서는 문장을 구문 트리 IR(`ir.tree`)로 만듭니다.
- 실행할 문장은 `ir.lower`가 그 트리에서 만듭니다.
- 스키마에 저장되는 것(CREATE TABLE의 CHECK·DEFAULT·생성 열, CREATE VIEW, 인덱스)은 `ir.render`가 같은 트리에서 만듭니다.
- 그래서 같은 식은 질의, CHECK, DEFAULT, 생성 열, 뷰에서 같은 뜻입니다. `/`는 어디서나 `CAST(l AS REAL) / r`이고, `DIV`는 `xq_div()`이며, 바뀐 함수 이름도 같습니다.
- `SHOW`·`DESCRIBE`·`information_schema`는 스키마·pragma 함수·`xq_catalog`를 읽는 SQLite 질의를 만들어 내립니다.
- `information_schema` 뷰의 MariaDB 텍스트는 같은 파서로 트리를 만듭니다.
- `SET`의 값은 트리로 만들어 `ir.lower`로 내립니다.
- MariaDB 의미가 SQLite와 다른 연산·함수는 엔진 함수와 방언 함수 테이블(`runtime.zig`)로 구현합니다.

파서가 트리에 남기는 MariaDB 의미는 다음과 같습니다.

| MariaDB | 트리 / SQLite |
| --- | --- |
| `/` | `div{real}` |
| `DIV` | `div{int}` |
| `XOR`, `^` | 엔진 함수 `xq_xor()`, `xq_bitxor()` |
| `<=>` | `IS` |
| `\|\|` | `OR`(`PIPES_AS_CONCAT`이면 `concat{propagate}`) |
| 두 인자 이상의 `CONCAT()` | `concat{propagate}` |
| `LIKE` | SQLite `LIKE ... ESCAPE '\'`(ASCII 대소문자 무시) |
| 이름이 다른 함수 | SQLite 내장 함수나 엔진 함수(`UCASE` → `upper`, `CHAR_LENGTH` → `length`, `GREATEST` → `max`, `STDDEV` → `xq_stddev_pop` ...) |
| 방언 함수 테이블의 함수 | `Func.dialect = .mariadb`, 스키마에는 `xq_mariadb_left(...)`처럼 한정 이름 |
| INSERT/UPDATE가 열에 저장하는 값 | `coerce` 노드(`xq_coerce()`) |
| `AUTO_INCREMENT` 열의 0 | `nullif(v, 0)`(`NO_AUTO_VALUE_ON_ZERO`가 아니면) |
| VALUES/SET의 `DEFAULT` | IR 공통 의미: 그 열의 DEFAULT, 없으면 NULL(`AUTO_INCREMENT`는 다음 rowid) |

결과 열 이름은 MariaDB처럼 쓴 식의 텍스트입니다. 문자열 상수는 그 값입니다.

## 저장 방식

DDL은 SQLite 텍스트로 렌더링해 `ir.stmt.lowerSqliteText()`로 내립니다. 그래서 sqlite3가 그대로 열고 `PRAGMA integrity_check`를 통과합니다.

### 테이블과 카탈로그

- 테이블은 `STRICT`입니다.
- 열은 저장 타입(`INTEGER`/`REAL`/`TEXT`/`BLOB`)으로 만듭니다.
- MariaDB 선언 타입(`int(10) unsigned`, `varchar(20)`, `enum('a','b')` ...), 기본값, `AUTO_INCREMENT`, `ON UPDATE CURRENT_TIMESTAMP`는 같은 문장 안에서 `xq_catalog`에 기록합니다.
- `SHOW COLUMNS`, `DESCRIBE`, `SHOW CREATE TABLE`, `information_schema`가 `xq_catalog`를 읽습니다.

### 타입 대응

| MariaDB 타입 | 저장 타입 |
| --- | --- |
| `TINYINT`, `SMALLINT`, `MEDIUMINT`, `INT`, `BIGINT`, `BIT`, `YEAR` | `INTEGER` |
| `DECIMAL(p,0)`, p ≤ 18(`DECIMAL`만 쓰면 `DECIMAL(10,0)`) | `INTEGER` |
| 그 밖의 `DECIMAL`, `FLOAT`, `DOUBLE` | `REAL` |
| `BINARY`, `VARBINARY`, `TINYBLOB`, `BLOB`, `MEDIUMBLOB`, `LONGBLOB` | `BLOB` |
| `CHAR`, `VARCHAR`, `*TEXT`, `ENUM`, `SET`, `DATE`, `DATETIME`, `TIMESTAMP`, `TIME` | `TEXT` |

| 별칭 | 뜻 |
| --- | --- |
| `JSON` | `longtext` + `CHECK(json_valid(...))` |
| `BOOL`, `BOOLEAN` | `tinyint(1)` |
| `SERIAL` | `bigint unsigned NOT NULL AUTO_INCREMENT UNIQUE` |
| `INTEGER`, `INT1`~`INT8`, `DEC`, `NUMERIC`, `FIXED`, `REAL`, `NCHAR`, `NVARCHAR`, `LONG`, `CLOB` ... | MariaDB와 같은 기본 타입 |

### Collation

- 문자열 열에는 언제나 명시적 `COLLATE`를 적습니다.
- 기본·`*_ci` collation은 `NOCASE`입니다.
- `*_bin`·`binary`·`*_cs`는 `BINARY`입니다.
- 날짜·JSON 열은 `BINARY`입니다.
- 그래서 `UNIQUE` 키도 MariaDB처럼 대소문자를 구분하지 않습니다.
- `NOCASE`는 ASCII만 접습니다(`'é' = 'É'`는 거짓).

### `AUTO_INCREMENT`

- SQLite의 `INTEGER PRIMARY KEY AUTOINCREMENT`(sqlite_sequence)입니다.
- 열은 PRIMARY KEY여야 합니다. PRIMARY KEY 없는 테이블이면 그 테이블의 유일한 UNIQUE 키여도 됩니다.
- NULL과 0(`NO_AUTO_VALUE_ON_ZERO`가 아니면)은 다음 값을 만듭니다.
- 더 큰 값을 직접 넣으면 카운터가 따라갑니다.
- 지운 값은 다시 쓰지 않습니다.
- `AUTO_INCREMENT=n`은 sqlite_sequence를 미리 채우고, `TRUNCATE`는 되돌립니다.
- `LAST_INSERT_ID()`는 `last_insert_rowid()`입니다.

### 인덱스 이름

- MariaDB 인덱스 이름은 테이블마다, SQLite 인덱스 이름은 스키마마다 유일합니다.
- 그래서 테이블 `t`의 인덱스 `i`는 SQLite 인덱스 `"t$i"`입니다.
- `KEY`/`INDEX`/`UNIQUE` 정의는 테이블을 만든 직후 같은 문장 안에서(`OP_SqlExec`) 만듭니다.
- `RENAME TABLE t TO u`(와 `ALTER TABLE ... RENAME`)는 인덱스 이름도 `"u$i"`로 바꿉니다.
- 이름을 바꿀 때는 SQLite의 ALTER TABLE처럼 같은 문장 안에서 `sqlite_schema`의 인덱스 행(이름과 CREATE INDEX 텍스트)을 고쳐 쓰고 스키마를 다시 읽습니다. b-tree는 그대로입니다.
- 바뀐 뒤에는 `SHOW INDEX`, `SHOW CREATE TABLE`, `DROP INDEX i ON u`가 새 이름으로 찾습니다.

### CHECK 이름

- 열의 `CHECK`는 열 이름을 붙입니다.
- 이름 없는 테이블 `CHECK`는 `CONSTRAINT_<n>`입니다.
- 둘 다 MariaDB와 같은 이름이고, 오류는 `CHECK constraint failed: price`처럼 나옵니다.

## `sql_mode`

- 연결 단위입니다.
- 기본값은 MariaDB 10.2+의 `STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION`입니다.
- `SET [SESSION] sql_mode = ...`, `SET @@sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')`, `SET sql_mode = DEFAULT`로 바꿉니다.
- `SELECT @@sql_mode`로 읽습니다. 조합 모드(`ANSI`, `TRADITIONAL`, `POSTGRESQL` ...)는 MariaDB처럼 펼쳐 보입니다.
- `SET`은 문장이 실행될 때 적용됩니다. 문법에 영향을 주는 모드는 그 뒤에 컴파일되는 문장부터 적용됩니다.
- 데이터 모드는 실행 시점의 모드를 읽으므로 준비된 문장도 현재 모드를 따릅니다.

| 모드 | 효과 |
| --- | --- |
| `ANSI_QUOTES` | `"x"`가 식별자입니다(아니면 문자열). |
| `PIPES_AS_CONCAT` | `\|\|`가 연결입니다(아니면 `OR`). |
| `NO_BACKSLASH_ESCAPES` | 문자열의 `\`가 보통 문자입니다. |
| `EMPTY_STRING_IS_NULL` | `''`가 NULL입니다. |
| `NO_AUTO_VALUE_ON_ZERO` | `AUTO_INCREMENT` 열의 0이 다음 값을 만들지 않습니다. |
| `STRICT_TRANS_TABLES`, `STRICT_ALL_TABLES` | 엄격 모드입니다. 모든 테이블이 트랜잭션 테이블이라 둘은 같은 뜻입니다. |
| `NO_ZERO_DATE`, `NO_ZERO_IN_DATE`, `ALLOW_INVALID_DATES` | 날짜 변환에 반영합니다. |

### 엄격 모드와 값 변환

- INSERT/UPDATE가 저장하는 값마다 `xq_coerce(value, type, ...)`를 거칩니다.
- 엄격 모드에서는 범위 밖·너무 긴 값·잘못된 날짜가 MariaDB 메시지로 문장을 실패시킵니다(`Out of range value for column 'i' at row 1`, `Data too long ...`, `Incorrect date value ...`).
- 엄격 모드가 아니거나 `INSERT/UPDATE IGNORE`이면 잘라 저장하고 경고를 남깁니다(`SHOW WARNINGS`, `@@warning_count`).
- `NOT NULL` 열의 NULL은 MariaDB와 같이 처리합니다.
- 기본값 없는 `NOT NULL` 열을 생략하면 MariaDB와 같이 `Field 'c' doesn't have a default value`입니다.

### 받아들이지만 효과가 없는 모드

- `ONLY_FULL_GROUP_BY`
- `ERROR_FOR_DIVISION_BY_ZERO`: 0으로 나누기는 언제나 NULL입니다.
- `HIGH_NOT_PRECEDENCE`
- `PAD_CHAR_TO_FULL_LENGTH`
- `IGNORE_SPACE`
- `REAL_AS_FLOAT`

## 지원 문법

### 토큰

- 백틱 식별자: `` `a``b` ``
- 문자열 `'...'`/`"..."`와 백슬래시 이스케이프. `\%`, `\_`는 LIKE용으로 그대로 둡니다.
- 주석: `#`, `-- `, `/* */`
- 실행 주석: `/*! */`, `/*!50100 */`, `/*M!100100 */`. 버전이 11.8 이하면 코드입니다.
- 16진·2진 상수: `X'..'`/`0x..`, `b'..'`/`0b..`
- 문자 집합 접두: `N'..'`, `_utf8mb4'..'`
- 인접 문자열 연결
- 매개변수 `?`, 사용자 변수 `@var`, 시스템 변수 `@@[session.]var`

### 식과 연산자

- MariaDB 우선순위를 따릅니다.
- 연산자: `||`, `&&`, `!`, `XOR`, `<=>`, `DIV`, `MOD`, `^`, `<<`, `>>`
- `/`는 실수 나눗셈입니다(7/2 = 3.5).
- `LIKE`는 기본 escape가 `\`이고 대소문자를 무시합니다.
- `IN`, `BETWEEN`, `IS [NOT] TRUE/FALSE/NULL/UNKNOWN`, `CASE`
- `CAST/CONVERT(... AS SIGNED/UNSIGNED/CHAR(n)/DECIMAL(p,s)/DATE/DATETIME/TIME/BINARY)`
- `BINARY x`, `COLLATE`
- `x + INTERVAL n DAY`
- `NEXT VALUE FOR s`
- 윈도우 함수

### 함수

| 분류 | 함수 |
| --- | --- |
| 조건 | `IFNULL`, `IF` |
| 문자열 | `CONCAT`(NULL이면 NULL), `CONCAT_WS`, `LENGTH`(바이트), `CHAR_LENGTH`, `SUBSTRING(... FROM ... FOR ...)`, `TRIM(LEADING ... FROM ...)`, `LOCATE`, `POSITION`, `LPAD`, `RPAD`, `LEFT`, `RIGHT`, `REPEAT`, `REVERSE`, `HEX`, `FORMAT`, `FIND_IN_SET`, `FIELD`, `ELT` |
| 집계 | `GROUP_CONCAT([DISTINCT] ... ORDER BY ... SEPARATOR ...)`, `STDDEV`, `VARIANCE` |
| 수 | `FLOOR`, `CEIL`, `ROUND`, `TRUNCATE`, `POW`, `SQRT`, `LOG` ... |
| 날짜 | `NOW()`/`CURDATE()`/`CURTIME()`(UTC), `DATE_ADD`, `DATE_SUB`, `DATEDIFF`, `TIMESTAMPDIFF`, `DATE_FORMAT`, `STR_TO_DATE`, `YEAR`/`MONTH`/`DAY`/`HOUR`/`DAYOFWEEK`/`DAYNAME` ..., `EXTRACT` |
| JSON | `JSON_UNQUOTE`. 그 밖의 `JSON_*`는 SQLite의 json 함수입니다. |
| 그 밖 | `LAST_INSERT_ID()`, `UUID()`, `RAND()` |

### SELECT

- `DISTINCT`
- 조인. `STRAIGHT_JOIN`은 순서를 고정합니다.
- `LIMIT n`, `LIMIT off, n`, `LIMIT n OFFSET m`, `OFFSET ... FETCH`
- `GROUP BY`(ASC/DESC는 무시), `HAVING`, `WINDOW`
- `UNION [ALL|DISTINCT]`, `EXCEPT`, `INTERSECT`와 괄호 친 항
- 서브쿼리, `WITH [RECURSIVE]`
- `FROM DUAL`
- 테이블 값 함수
- 인덱스 힌트, `FOR UPDATE`, `LOCK IN SHARE MODE`, `SQL_NO_CACHE` 등은 무시합니다.

### DML

- `INSERT [IGNORE]`
  - `VALUES`/`VALUE` 여러 행
  - `SET a=1`
  - `SELECT`
  - `DEFAULT`
  - `ON DUPLICATE KEY UPDATE col = VALUES(col)`
  - `RETURNING`
- `REPLACE`
- `UPDATE [IGNORE] ... [ORDER BY] [LIMIT n]`
- `DELETE ... [ORDER BY] [LIMIT n] [RETURNING]`
- `TRUNCATE`

### DDL

- `CREATE [TEMPORARY] TABLE [IF NOT EXISTS]`
  - 열: 타입, `NOT NULL`/`NULL`, `DEFAULT`, `AUTO_INCREMENT`, `COMMENT`, `CHARACTER SET`, `COLLATE`
  - 키: `PRIMARY KEY`, `UNIQUE [KEY]`, `KEY`/`INDEX`(접두 길이는 무시)
  - 제약: `CHECK`, `FOREIGN KEY ... ON DELETE/UPDATE`
  - 생성 열: `AS (...) VIRTUAL/STORED`
  - 테이블 옵션: `ENGINE=`, `DEFAULT CHARSET=`, `COLLATE=`, `AUTO_INCREMENT=n` ...
- `CREATE TABLE ... AS SELECT`
- `DROP TABLE [IF EXISTS]`
- `CREATE [UNIQUE] INDEX`, `DROP INDEX i ON t`
- `CREATE [OR REPLACE] VIEW`, `DROP VIEW`
- `CREATE SEQUENCE`, `DROP SEQUENCE`
- `ALTER TABLE`는 한 번에 한 가지 변경만 합니다.
  - `ADD [COLUMN]`, `DROP [COLUMN]`, `RENAME COLUMN`, `RENAME TO`, `ADD/DROP INDEX`
  - `DISABLE/ENABLE KEYS`와 테이블 옵션은 무시합니다.
- `RENAME TABLE`

### 세션, SHOW, 그 밖

- 트랜잭션: `START TRANSACTION`, `BEGIN [WORK]`, `COMMIT`, `ROLLBACK [TO SAVEPOINT]`, `SAVEPOINT`, `RELEASE SAVEPOINT`
- `SET`: 시스템 변수, `@사용자 변수`, `NAMES`, `CHARACTER SET`, `TRANSACTION`
- `SET foreign_key_checks`는 `PRAGMA foreign_keys`입니다.
- `SHOW [FULL] TABLES [LIKE]`
- `SHOW COLUMNS/FIELDS`, `DESCRIBE`/`DESC`
- `SHOW INDEX`
- `SHOW CREATE TABLE`, `SHOW CREATE VIEW`
- `SHOW WARNINGS`, `SHOW ERRORS`, `SHOW COUNT(*) WARNINGS`
- `SHOW VARIABLES [LIKE]`
- `SHOW DATABASES`
- `EXPLAIN`은 `EXPLAIN QUERY PLAN`입니다.
- `USE db`는 존재만 확인합니다. 기본 스키마는 `main`입니다.
- `LOCK TABLES`, `UNLOCK TABLES`는 무시합니다.
- `ANALYZE [NO_WRITE_TO_BINLOG | LOCAL] TABLE t [, ...] [PERSISTENT FOR ...]`는 테이블마다 SQLite의 `ANALYZE`를 실행하고 MariaDB와 같은 결과 행(`Table`, `Op`, `Msg_type`, `Msg_text`)을 돌려줍니다. 없는 테이블과 뷰는 MariaDB처럼 `Error` 행을 냅니다.
- `information_schema.TABLES`, `COLUMNS`, `SCHEMATA`
- mysqldump 출력을 그대로 불러올 수 있습니다.

### 이름

- 쓴 대소문자를 그대로 저장하고 대소문자 없이 비교합니다.
- MariaDB `lower_case_table_names=2`와 같은 동작이라 `@@lower_case_table_names`는 2입니다.
- 데이터베이스는 SQLite 스키마(`main`, `temp`, `ATTACH`로 붙인 데이터베이스)입니다. 붙인 데이터베이스도 `db.t`로 읽고 쓰고, `CREATE TABLE db.t`의 카탈로그 키는 그 데이터베이스의 `xq_catalog`에 기록합니다. `SHOW DATABASES`, `SHOW TABLES FROM db`, `information_schema`에도 나옵니다.

## MariaDB와 다른 점

### 타입과 값

| 항목 | xqlite |
| --- | --- |
| `DECIMAL` | `REAL`로 저장합니다(scale 0이고 정밀도 18 이하면 `INTEGER`). 반올림은 되지만 정확한 십진 연산이 아니고 `220.00`이 `220.0`으로 보입니다. |
| 정수 값의 실수 | `POW(2,10)`이 `1024.0`처럼 SQLite 형식으로 보입니다. |
| `BIGINT UNSIGNED`, `CAST(... AS UNSIGNED)` | 부호 있는 64비트 범위입니다. |
| `TIMESTAMP` | 시간대 변환이 없고 범위도 `DATETIME`과 같습니다. 시간대는 UTC입니다. |
| PAD SPACE | 비교에 없으므로 `'x' = 'x  '`는 거짓입니다. |

### 문장의 동작

| 항목 | xqlite |
| --- | --- |
| UPDATE의 대입 | 모두 이전 행 값을 봅니다(`SIMULTANEOUS_ASSIGNMENT`와 같음). |
| `LAST_INSERT_ID()` | 여러 행 INSERT에서는 마지막 행의 id입니다. 직접 넣은 id에도 바뀝니다. |
| `ON DUPLICATE KEY UPDATE` | affected rows는 SQLite 방식(행마다 1)입니다. 한 행이 두 UNIQUE 키에서 서로 다른 두 행과 충돌하면 첫 행만 고칩니다. |
| `SHOW WARNINGS` | 문장을 컴파일할 때(보통 직전 문장 실행 직후) 기록된 경고를 보여 줍니다. 경고는 다음 문장을 컴파일할 때 지워집니다. 최대 8개를 저장하고 개수는 전부 셉니다. |
| 엔진 오류 | `no such table`, `UNIQUE constraint failed` ...는 SQLite 메시지 그대로입니다. |
| `INSERT ... SELECT` | 변환 오류 메시지의 행 번호가 언제나 1입니다. |

### 스키마에 저장되는 식

- `DEFAULT (...)`, `CHECK`, 생성 열, 뷰에는 MariaDB처럼 변수와 매개변수를 쓸 수 없습니다.
  - `Function or expression '@x' cannot be used in the CHECK clause of ...`
  - `View's SELECT contains a variable or parameter`
- 엔진 함수(`xq_div` ...)나 방언 함수(`xq_mariadb_*`)를 부르는 스키마는 xqlite에서는 어느 방언으로든 같은 결과를 냅니다.
- sqlite3는 그런 식을 계산할 수 없습니다.
- `/`, `UCASE`, `GREATEST`, `IF`, `CONCAT`, `LIKE` 같은 식은 sqlite3에서도 같습니다(`tools/interop-mariadb.sh`).
- 저장된 식의 비교는 열 collation이 없으면 읽는 연결의 기본 collation을 씁니다.

| 읽는 쪽 | 기본 collation |
| --- | --- |
| MariaDB 방언 | `NOCASE` |
| SQLite 방언, sqlite3 | `BINARY` |

- 문자열 열에는 언제나 collation을 적으므로 열과의 비교는 어디서나 같습니다.
- 열이 아닌 값끼리 비교할 때(`'a' = 'A'`, `UPPER(x) = 'a'`)만 다릅니다.

### 아직 쓸 수 없는 스키마 식

| 항목 | 이유 |
| --- | --- |
| `DEFAULT (NEXT VALUE FOR s)` | `nextval()`이 unsafe라 스키마에서 부를 수 없습니다. |
| `ALTER TABLE ... ADD COLUMN`의 DEFAULT | SQLite처럼 상수여야 합니다. |
| `information_schema`를 읽는 뷰 | pragma 테이블 값 함수가 스키마에서 unsafe입니다. |

## 아직 하지 않은 것

- 프로그램
  - 저장 프로시저·함수
  - MySQL 문법의 트리거·이벤트
- DML
  - 다중 테이블 `UPDATE`/`DELETE`
  - `SELECT ... INTO`
  - `LOAD DATA`
- SELECT와 식
  - `WITH ROLLUP`
  - `REGEXP`: SQLite처럼 `regexp()` 함수가 있어야 합니다.
  - `MATCH ... AGAINST`
- DDL
  - `ALTER TABLE`의 `CHANGE`/`MODIFY`와 여러 변경
  - `PARTITION`
  - `FULLTEXT`: 보통 인덱스로 만듭니다.
  - `CREATE TABLE ... LIKE`
  - `CREATE OR REPLACE TABLE`
  - `INVISIBLE` 열
- 그 밖
  - utf8 밖의 문자 집합
  - `ONLY_FULL_GROUP_BY` 검사
  - 셸의 문장 분할: SQLite 규칙이라 `'it\'s'` 같은 문자열이 있으면 파일 끝까지 한 덩어리로 실행됩니다.

## 검증

### MariaDB 서버와 비교

`tools/dialect/maria-diff.sh`는 `tools/dialect/maria-cases.txt`의 각 경우를 MariaDB 서버와 `xqlite sql`(`.dialect mariadb`)에서 실행해 결과 행, 열 이름, `ERROR:` 줄을 비교합니다.

```sh
zig build
podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
tools/dialect/maria-diff.sh [cases-file]
```

- 서버는 `$MARIA_CLIENT`로 연결합니다. 기본값은 `podman exec -i xq-maria mariadb -uroot`입니다.
- 각 경우는 빈 데이터베이스 `main`(collation `utf8mb4_general_ci`)에서 시작합니다.
- 소수 부분이 있는 수는 끝의 0을 떼고 비교합니다(MariaDB `DECIMAL`은 `3.5000`, 방언의 `REAL`은 `3.5`).

### sqlite3와 교차 검사

`tools/interop-mariadb.sh`는 MariaDB 방언으로 쓴 데이터베이스를 sqlite3로 확인합니다.

- sqlite3의 무결성 검사를 통과해야 합니다.
- sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 합니다.
- 다루는 것: STRICT 테이블, 이름 붙은 CHECK, DEFAULT·생성 열 식, `AUTO_INCREMENT`, 테이블과 함께 이름이 바뀌는 `"t$i"` 인덱스, 뷰, `xq_catalog`.
- 엔진 함수(`xq_*`)를 쓰는 식은 sqlite3에 없으므로 `src/dialect/mariadb/test.zig`에서 확인합니다.
- `sqlite3`(또는 `$SQLITE3`)와 먼저 `zig build`가 필요합니다.
