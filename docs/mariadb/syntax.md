# 지원 문법

[MariaDB 호환](README.md)의 일부입니다.

## 토큰

- 백틱 식별자: `` `a``b` ``
- 문자열 `'...'`/`"..."`와 백슬래시 이스케이프. `\%`, `\_`는 LIKE용으로 그대로 둡니다.
- 주석: `#`, `-- `, `/* */`
- 실행 주석: `/*! */`, `/*!50100 */`, `/*M!100100 */`. 버전이 11.8 이하면 코드입니다.
- 16진·2진 상수: `X'..'`/`0x..`, `b'..'`/`0b..`
- 문자 집합 접두: `N'..'`, `_utf8mb4'..'`
- 인접 문자열 연결
- 매개변수 `?`, 사용자 변수 `@var`, 시스템 변수 `@@[session.]var`

## 식과 연산자

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

## 함수

| 분류 | 함수 |
| --- | --- |
| 조건 | `IFNULL`, `IF` |
| 문자열 | `CONCAT`(NULL이면 NULL), `CONCAT_WS`, `LENGTH`(바이트), `CHAR_LENGTH`, `SUBSTRING(... FROM ... FOR ...)`, `TRIM(LEADING ... FROM ...)`, `LOCATE`, `POSITION`, `LPAD`, `RPAD`, `LEFT`, `RIGHT`, `REPEAT`, `REVERSE`, `HEX`, `FORMAT`, `FIND_IN_SET`, `FIELD`, `ELT` |
| 집계 | `GROUP_CONCAT([DISTINCT] ... ORDER BY ... SEPARATOR ...)`, `STDDEV`, `VARIANCE` |
| 수 | `FLOOR`, `CEIL`, `ROUND`, `TRUNCATE`, `POW`, `SQRT`, `LOG` ... |
| 날짜 | `NOW()`/`CURDATE()`/`CURTIME()`(UTC), `DATE_ADD`, `DATE_SUB`, `DATEDIFF`, `TIMESTAMPDIFF`, `DATE_FORMAT`, `STR_TO_DATE`, `YEAR`/`MONTH`/`DAY`/`HOUR`/`DAYOFWEEK`/`DAYNAME` ..., `EXTRACT` |
| JSON | 아래 [JSON](#json)을 보세요. |
| 그 밖 | `LAST_INSERT_ID()`, `UUID()`, `RAND()` |

## JSON

MariaDB 11의 JSON 함수를 MariaDB가 계산하고 출력하는 대로 구현합니다(`json.zig`). `JSON` 열은 `longtext` + `CHECK(json_valid(...))`이고 `JSON_VALID`는 SQLite의 `json_valid()`입니다. 둘은 결과가 같고 sqlite3도 이 CHECK를 계산합니다.

| 분류 | 함수 |
| --- | --- |
| 꺼내기 | `JSON_EXTRACT`, `JSON_VALUE`, `JSON_QUERY`, `JSON_UNQUOTE`, `JSON_KEYS`, `JSON_SEARCH` |
| 만들기 | `JSON_OBJECT`, `JSON_ARRAY`, `JSON_QUOTE`, `JSON_ARRAYAGG([DISTINCT] ... [ORDER BY ...] [LIMIT n])`, `JSON_OBJECTAGG` |
| 검사 | `JSON_CONTAINS`, `JSON_CONTAINS_PATH`, `JSON_EXISTS`, `JSON_OVERLAPS`, `JSON_EQUALS`, `JSON_VALID`, `JSON_LENGTH`, `JSON_DEPTH`, `JSON_TYPE` |
| 고치기 | `JSON_SET`, `JSON_INSERT`, `JSON_REPLACE`, `JSON_REMOVE`, `JSON_ARRAY_APPEND`, `JSON_ARRAY_INSERT`, `JSON_MERGE`(`_PRESERVE`), `JSON_MERGE_PATCH` |
| 형식 | `JSON_COMPACT`, `JSON_LOOSE`, `JSON_DETAILED`/`JSON_PRETTY`, `JSON_NORMALIZE` |
| 테이블 | `JSON_TABLE(doc, path COLUMNS (... FOR ORDINALITY, ... [EXISTS] PATH ..., NESTED [PATH] ... COLUMNS (...)))`, `NULL`/`ERROR`/`DEFAULT v` `ON EMPTY`/`ON ERROR` |

- 경로: `$`, `.key`, `."key"`, `.*`, `[n]`, `[*]`, `[last]`, `[last-n]`, `[-n]`, `[n to m]`, `**`, 앞의 `lax`/`strict`. 배열이 아닌 값은 `[0]`과 `[last]`에서 원소 하나인 배열입니다. 잘못된 문서나 경로는 NULL입니다(MariaDB의 경고는 기록하지 않습니다).
- 출력 형식은 MariaDB와 같습니다.
  - `JSON_EXTRACT`, `JSON_SET`, `JSON_OBJECT`, `JSON_ARRAY`, `JSON_LOOSE`, `JSON_MERGE` ...: `{"a": 1, "b": [1, 2]}`
  - `JSON_COMPACT`, `JSON_NORMALIZE`: 공백 없음. `JSON_ARRAYAGG`는 `[1,2]`, `JSON_OBJECTAGG`는 `{"a":1, "b":2}`
  - `JSON_DETAILED`: 한 줄에 값 하나, 멤버 값인 배열·객체는 키 다음 줄
  - 수와 문자열은 쓴 그대로(`1.50`, `"\u00e9"`), `JSON_QUERY`와 JSON 인자는 원문 그대로
- 여러 경로나 와일드카드의 `JSON_EXTRACT`는 찾은 값을 문서 순서로 배열에 담습니다.
- 비교(`=`, `<` ..., `IN`)에서 `JSON_EXTRACT`의 값은 MariaDB처럼 SQL 값입니다(`JSON_EXTRACT('{"a":"b"}', '$.a') = 'b'`는 참). 엔진 함수 `xq_maria_json_cmp()`로 감쌉니다.
- MySQL의 `col->'$.path'`, `col->>'$.path'`도 받습니다(`JSON_EXTRACT`, `JSON_UNQUOTE(JSON_EXTRACT(...))`). MariaDB에는 없는 확장입니다.

### 어떤 값이 JSON인가

`JSON_OBJECT`, `JSON_ARRAY`, `JSON_SET` 같은 함수는 JSON 값을 문자열로 감싸지 않고 그대로 넣습니다. MariaDB가 JSON으로 보는 값을 xqlite는 이렇게 압니다.

| 값 | 방법 |
| --- | --- |
| JSON을 돌려주는 함수의 결과 | SQLite의 JSON subtype(`'J'`, `json_object()`와 같음) |
| `JSON` 열 | SELECT 끝에서 FROM 테이블의 열 중 `CHECK (json_valid(col))`가 있는 열을 엔진 함수 `xq_maria_json_col()`로 감쌉니다. |
| 참/거짓 식(`1 > 2`, `TRUE`, `IS NULL`, `IN` ...) | `xq_maria_json_bool()`이 `true`/`false`로 바꿉니다. |
| `JSON_COMPACT(x)` 같은 형식 함수 | MariaDB처럼 형식을 입히지 않은 `x` 그대로입니다. |
| JSON 함수 하나를 고르는 스칼라 서브쿼리 | `xq_maria_json_col()`로 감쌉니다. |

- subtype은 테이블, 구체화되는 서브쿼리·CTE, 정렬을 지나면 사라집니다. 거기서 나온 값은 문자열입니다.
- SELECT 밖(`UPDATE ... SET`, CHECK, 생성 열)의 `JSON` 열은 표시하지 않으므로 `JSON_OBJECT('a', j)`의 `j`가 문자열이 됩니다. `JSON_SET(j, ...)`처럼 문서를 받는 인자는 언제나 JSON으로 읽으므로 상관없습니다.

### JSON_TABLE

- `JSON_TABLE(doc, path COLUMNS (...)) AS jt`는 FROM 항목 `xq_maria_json_table(doc, 'spec') AS jt`입니다.
  - 엔진 테이블 값 함수(이포니머스 가상 테이블, `Hooks.engine_modules`)입니다. 문장이 처음 이 이름을 쓸 때 연결에 등록합니다.
  - `spec`은 COLUMNS 절을 JSON으로 적은 것입니다.
  - 행마다 열 `xq_row`에 열 값의 JSON 배열이 있습니다. 값은 MariaDB처럼 열 타입으로 이미 바꿨습니다(`TINYINT` 범위 자르기, `2.5` → `3`, `'12abc'` → `12`, `VARCHAR(n)` 자르기, 잘못된 날짜 → `0000-00-00` ...).
- 테이블 값 함수라 앞 테이블을 인자로 쓸 수 있습니다(`FROM t, JSON_TABLE(t.j, ...)`, `LEFT JOIN JSON_TABLE(...) ON 1`).
- SELECT 끝에서 `jt.a`나 `a`는 `jt.xq_row ->> k`(k는 열 위치)로, `*`과 `jt.*`는 열 목록으로 바꿉니다. 뷰에는 이렇게 바꾼 식이 저장됩니다.
- 별칭이 없으면 MariaDB처럼 `Every table function must have an alias.` 오류입니다.
- `NESTED PATH` 형제는 MariaDB처럼 한 번에 하나씩 행을 만들고 나머지 열은 NULL입니다.

### MariaDB와 다른 점

| 항목 | xqlite |
| --- | --- |
| `DECIMAL` 값 | `REAL`이므로 `JSON_ARRAY(2.50)`은 `[2.5]`, `JSON_ARRAY(1/3)`은 `[0.3333333333333333]`입니다. |
| `UNION`의 열 타입 | 따지지 않습니다. MariaDB는 `UNION`으로 합친 수를 `JSON_ARRAYAGG`에서 문자열로 넣기도 합니다. |
| `JSON_ARRAYAGG(DISTINCT ... LIMIT n)` | SQLite의 `DISTINCT` 집계는 인자가 하나여야 해서 안 됩니다. |
| `JSON_SEARCH`의 대소문자 | ASCII와 Latin-1 글자만 무시합니다. |
| 경고 | 잘못된 JSON·경로는 NULL이지만 `SHOW WARNINGS`에 남지 않습니다. |
| sqlite3 | `xq_mariadb_json_*()`, `xq_maria_json_*()`를 쓰는 CHECK·생성 열·뷰는 평범한 sqlite3에서 계산할 수 없고, [확장](../extension.md)을 올리면 계산합니다. `xq_maria_json_table`(`JSON_TABLE`)은 엔진의 테이블 값 함수라 확장에도 없습니다. `JSON` 열의 `CHECK(json_valid(...))`는 확장 없이도 계산합니다. |

## SELECT

- `DISTINCT`
- 조인. `STRAIGHT_JOIN`은 순서를 고정합니다.
- `LIMIT n`, `LIMIT off, n`, `LIMIT n OFFSET m`, `OFFSET ... FETCH`
- `GROUP BY`(ASC/DESC는 무시), `HAVING`, `WINDOW`
- `UNION [ALL|DISTINCT]`, `EXCEPT`, `INTERSECT`와 괄호 친 항
- 서브쿼리, `WITH [RECURSIVE]`
- `FROM DUAL`
- 테이블 값 함수
- 인덱스 힌트, `FOR UPDATE`, `LOCK IN SHARE MODE`, `SQL_NO_CACHE` 등은 무시합니다.

## DML

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

## DDL

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

## 세션, SHOW, 그 밖

- 트랜잭션: `START TRANSACTION`, `BEGIN [WORK]`, `COMMIT`, `ROLLBACK [TO SAVEPOINT]`, `SAVEPOINT`, `RELEASE SAVEPOINT`
- `SET`: 시스템 변수, `@사용자 변수`, `NAMES`, `CHARACTER SET`, `TRANSACTION`
- 외래 키는 InnoDB처럼 강제합니다. 이 방언의 첫 문장에서 연결의 `PRAGMA foreign_keys`를 켜고, `SET foreign_key_checks`는 `PRAGMA foreign_keys`입니다. 열 정의 안의 `REFERENCES`는 MariaDB처럼 무시합니다.
- 64비트를 넘는 정수 결과는 `BIGINT value is out of range`(1690)입니다. MariaDB는 메시지 끝에 식을 붙이지만(`... in '(a + b)'`) 이 방언은 붙이지 않습니다.
- `SHOW [FULL] TABLES [{FROM | IN} db] [LIKE]`
- `SHOW COLUMNS/FIELDS`, `DESCRIBE`/`DESC`
- `SHOW INDEX`
- `SHOW CREATE TABLE`, `SHOW CREATE VIEW`
- `SHOW WARNINGS`, `SHOW ERRORS`, `SHOW COUNT(*) WARNINGS`
- `SHOW VARIABLES [LIKE]`
- `SHOW DATABASES`, `SHOW CREATE DATABASE`
- `EXPLAIN`은 `EXPLAIN QUERY PLAN`입니다.
- `CREATE/DROP DATABASE`, `USE db`: [데이터베이스](databases.md)를 보세요.
- `LOCK TABLES`, `UNLOCK TABLES`는 무시합니다.
- `CONNECTION_ID()`는 와이어 서버가 준 연결 id이고(`KILL`에 씀), 서버 밖의 연결에서는 1입니다. `KILL`은 방언이 아니라 MySQL 프로토콜이 실행합니다([KILL](../server.md#kill)).
- `ANALYZE [NO_WRITE_TO_BINLOG | LOCAL] TABLE t [, ...] [PERSISTENT FOR ...]`는 테이블마다 SQLite의 `ANALYZE`를 실행하고 MariaDB와 같은 결과 행(`Table`, `Op`, `Msg_type`, `Msg_text`)을 돌려줍니다. 없는 테이블과 뷰는 MariaDB처럼 `Error` 행을 냅니다.
- `information_schema.TABLES`, `COLUMNS`, `SCHEMATA`, `VIEWS`, `STATISTICS`
- mysqldump 출력을 그대로 불러올 수 있습니다.

## 이름

- 쓴 대소문자를 그대로 저장하고 대소문자 없이 비교합니다.
- MariaDB `lower_case_table_names=2`와 같은 동작이라 `@@lower_case_table_names`는 2입니다.
- 데이터베이스는 `main`, `ATTACH`로 붙인 데이터베이스, `CREATE DATABASE`의 데이터베이스입니다([데이터베이스](databases.md)). 붙인 데이터베이스의 `CREATE TABLE db.t`는 카탈로그 키를 그 데이터베이스의 `xq_catalog`에 기록합니다.
