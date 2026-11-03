# MariaDB (MySQL) 호환: 지원 기능

xqlite MariaDB 방언이 지원하는 데이터 타입, SQL 구문(DDL/DML), `sql_mode`, 데이터베이스 네임스페이스 및 내장 함수의 상세 명세입니다.

---

## 1. 어휘 및 데이터 타입

### 1.1 어휘 및 토큰
- **식별자 인용**: 백틱(`` `col` ``) 인용 지원. 이중 인용부호(`"col"`)는 `ANSI_QUOTES` 활성화 시 식별자로 인식.
- **문자열 리터럴**: 단일 따옴표(`'...'`) 및 이중 따옴표(`"..."`). 백슬래시 이스케이프(`\0`, `\'`, `\"`, `\b`, `\n`, `\r`, `\t`, `\\`) 지원.
- **상수 접두사**: 16진 상수(`0x..`, `X'..'`), 2진 비트 상수(`0b..`, `b'..'`), 문자 집합(`_utf8mb4'..'`).
- **주석**: `#`, `-- `(공백 필수), `/* */`, MariaDB/MySQL 실행 주석(`/*!50100 code */`, `/*M!100100 code */`).
- **변수**: 사용자 정의 세션 변수(`@var`), 시스템 변수(`@@[session.]sql_mode`).

### 1.2 데이터 타입 매핑
테이블은 `STRICT` 모드로 생성되며, MariaDB의 타입 제약을 검사합니다.

| MariaDB 타입 | 저장 타입 | 설명 및 제약 |
| --- | --- | --- |
| `TINYINT`, `SMALLINT`, `MEDIUMINT`, `INT`/`INTEGER`, `BIGINT` | `INTEGER` | 부호 유무(`[UN]SIGNED`) 및 비트 범위 검사. 오버플로우 시 에러. |
| `FLOAT`, `DOUBLE [PRECISION]` | `REAL` | 부동소수점 수. |
| `DECIMAL(p,s)`, `NUMERIC(p,s)` | `REAL` | 지정된 정밀도와 스케일을 인식하여 출력 및 반올림. |
| `CHAR(n)`, `VARCHAR(n)` | `TEXT` | 최대 길이 n 검사. 기본 정렬 규칙은 대소문자를 구분하지 않는 `utf8mb4_general_ci`. |
| `TINYTEXT`, `TEXT`, `MEDIUMTEXT`, `LONGTEXT` | `TEXT` | 긴 텍스트 저장. |
| `BINARY(n)`, `VARBINARY(n)`, `BLOB` | `BLOB` | 바이트 단위 바이너리 데이터. |
| `DATE`, `DATETIME[(fsp)]`, `TIMESTAMP` | `TEXT` | ISO-8601 형식(`YYYY-MM-DD HH:MM:SS`) 문자열. |
| `TIME`, `YEAR` | `TEXT` / `INTEGER` | 시간 및 연도. |
| `ENUM('val1', 'val2', ...)` | `TEXT` | 정의된 열거형 목록에 포함되는 값만 저장 허용. |
| `SET('val1', 'val2', ...)` | `TEXT` | 쉼표로 구분된 세트 원소 저장. |
| `JSON` | `TEXT` | 유효한 JSON 텍스트 검증 (`json_valid`). |

---

## 2. 지원 SQL 문장

### 2.1 데이터 정의어 (DDL)
- **`CREATE DATABASE [IF NOT EXISTS] db_name`** / **`DROP DATABASE [IF EXISTS] db_name`**
- **`USE db_name`**: 현재 세션의 기본 데이터베이스를 변경합니다.
- **`CREATE TABLE [IF NOT EXISTS] tbl`**
  - 열 속성: `AUTO_INCREMENT`, `NOT NULL`, `DEFAULT expr`, `COMMENT '...'`
  - 테이블 옵션: `ENGINE=InnoDB`, `AUTO_INCREMENT=n`, `DEFAULT CHARSET=utf8mb4`, `COLLATE=...` (파싱 후 호환 처리)
  - 인덱스/키: `PRIMARY KEY (col)`, `KEY / INDEX (col)`, `UNIQUE KEY (col)`, `FOREIGN KEY`
- **`ALTER TABLE`**: `ADD COLUMN`, `DROP COLUMN`, `RENAME TABLE`
- **`DROP TABLE [IF EXISTS] tbl [, ...]`**
- **`TRUNCATE [TABLE] tbl`**

### 2.2 데이터 조작어 (DML)
- **`SELECT`**
  - `FROM tbl` 및 조인(`JOIN`, `LEFT JOIN`, `RIGHT JOIN`, `CROSS JOIN`, `STRAIGHT_JOIN`)
  - 쉼표 조인(`FROM a, b WHERE a.id = b.id`)
  - 정렬 및 페이징: `LIMIT count` 또는 MySQL 전용 `LIMIT offset, count`
  - 집계 및 그룹화: `GROUP BY`, `HAVING`
- **`INSERT`**
  - `INSERT INTO tbl VALUES (...)`
  - `INSERT IGNORE INTO tbl`: 키 충돌 시 오류 대신 행을 건너뛰고 경고 생성.
  - `REPLACE INTO tbl`: 충돌 시 기존 행을 삭제하고 신규 삽입.
  - `INSERT ... ON DUPLICATE KEY UPDATE col = expr, ...`: 충돌 시 지정된 열만 갱신 (`VALUES(col)` 지원).
- **`UPDATE`** & **`DELETE`**: `WHERE` 조건 및 `LIMIT` 절 지원.

### 2.3 세션 및 관리 문장
- **`SET`**: `SET @var = expr`, `SET sql_mode = '...'`
- **`SHOW` 문장**:
  - `SHOW DATABASES`, `SHOW SCHEMAS`
  - `SHOW TABLES [FROM db] [LIKE '...']`
  - `SHOW COLUMNS FROM tbl`, `DESCRIBE tbl`
  - `SHOW CREATE TABLE tbl`
  - `SHOW CREATE DATABASE db`
  - `SHOW WARNINGS`, `SHOW ERRORS`
- **트랜잭션**: `START TRANSACTION`, `BEGIN`, `COMMIT`, `ROLLBACK`

---

## 3. `sql_mode` 동작 제어

`SET sql_mode = '...'`를 통해 세션 수준에서 런타임 제약 조건을 조정할 수 있습니다.

| 모드 플래그 | 효과 |
| --- | --- |
| `STRICT_TRANS_TABLES` / `STRICT_ALL_TABLES` | 유효하지 않은 값 삽입 시 경고 대신 오류를 발생시키고 트랜잭션을 중단합니다. |
| `NO_ZERO_DATE` / `NO_ZERO_IN_DATE` | `'0000-00-00'` 날짜 삽입을 금지합니다. |
| `ANSI_QUOTES` | 쌍따옴표(`"`)를 문자열 리터럴이 아닌 식별자 인용부호로 취급합니다. |
| `PIPES_AS_CONCAT` | `\|\|` 연산자를 논리 OR가 아닌 문자열 연결 연산자로 취급합니다. |
| `IGNORE_SPACE` | 내장 함수 이름 뒤의 공백을 허용합니다. |

---

## 4. 내장 함수 및 연산자

- **연산자**: `||` (논리 OR / PIPES_AS_CONCAT), `&&` (논리 AND), `!` (NOT), `XOR`, `<=>` (NULL 안전 동등 비교), `DIV` (정수 나눗셈), `MOD`, `^`, `<<`, `>>`
- **제어 흐름**: `IF(cond, then, else)`, `IFNULL(expr1, expr2)`, `NULLIF(expr1, expr2)`, `COALESCE(...)`, `CASE ... END`
- **문자열 함수**: `CONCAT`, `CONCAT_WS`, `LENGTH`, `CHAR_LENGTH`, `LOWER`, `UPPER`, `SUBSTRING` / `SUBSTR`, `LEFT`, `RIGHT`, `TRIM`, `LTRIM`, `RTRIM`, `LPAD`, `RPAD`, `REPEAT`, `REVERSE`, `REPLACE`, `INSTR`, `LOCATE`, `GROUP_CONCAT`
- **수학 함수**: `ABS`, `CEILING` / `CEIL`, `FLOOR`, `ROUND`, `TRUNCATE`, `POW` / `POWER`, `SQRT`, `MOD`, `RAND`
- **날짜 및 시간 함수**: `NOW()`, `CURRENT_TIMESTAMP`, `CURDATE()`, `CURTIME()`, `DATE_ADD()`, `DATE_SUB()`, `DATEDIFF()`, `DATE_FORMAT()`, `YEAR()`, `MONTH()`, `DAY()`, `HOUR()`, `MINUTE()`, `SECOND()`, `UNIX_TIMESTAMP()`, `FROM_UNIXTIME()`
- **JSON 함수**: `JSON_EXTRACT`, `JSON_UNQUOTE`, `->`, `->>`, `JSON_ARRAY`, `JSON_OBJECT`, `JSON_SET`, `JSON_INSERT`, `JSON_REPLACE`, `JSON_REMOVE`, `JSON_CONTAINS`, `JSON_VALID`
- **시스템 및 기타**: `DATABASE()`, `VERSION()`, `LAST_INSERT_ID()`, `CONNECTION_ID()`, `FOUND_ROWS()`, `ROW_COUNT()`
