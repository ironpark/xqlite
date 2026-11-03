# 데이터베이스

[MariaDB 호환](README.md)의 일부입니다.

MariaDB의 데이터베이스는 세 가지입니다.

| 데이터베이스 | xqlite |
| --- | --- |
| `main` | 파일의 main 데이터베이스. 새 연결의 현재 데이터베이스이고 `DATABASE()`가 `main`입니다. |
| `ATTACH`로 붙인 데이터베이스 | 그 SQLite 데이터베이스(`temp`는 임시 테이블의 자리) |
| `CREATE DATABASE`/`CREATE SCHEMA`로 만든 데이터베이스 | main 안의 이름 붙은 스키마([공용 설계](../architecture.md#스키마네임스페이스), `src/catalog/schema.zig`) |

`main`이라는 이름은 `xqt dialect-diff mariadb`가 서버에서 쓰는 데이터베이스 이름과 같습니다. 그래서 `Table 'main.t' doesn't exist` 같은 메시지와 `information_schema`의 `TABLE_SCHEMA`가 서버와 같습니다.

## 저장

`CREATE DATABASE sales`의 개체는 main의 개체이고 이름이 `"sales.<이름>"`입니다.

| 개체 | SQLite 이름 |
| --- | --- |
| 테이블·뷰 `sales.orders` | `"sales.orders"` |
| 인덱스 `ix` | `"sales.orders$ix"` |
| `AUTO_INCREMENT` 카운터 | `sqlite_sequence`의 행 `sales.orders` |
| 시퀀스 `sales.s` | `xq_sequence`의 행 `sales.s` |
| 카탈로그 항목 | `main.xq_catalog`의 `tbl = 'sales.orders'` |
| 데이터베이스 자체 | `main.xq_catalog`의 `('', 'sales', 'schema', 'root')`, `('', 'sales', 'dialect', 'mariadb')`, `('', 'sales', 'collation', <collation>)` |

- 파일 하나, 트랜잭션 하나입니다. sqlite3는 `"sales.orders"`로 읽고 씁니다(`xqt interop mariadb`).
- 데이터베이스 이름에는 `.`, `/`, `\`를 쓸 수 없습니다(`Incorrect database name 'a.b'`).

## 문장

- `CREATE {DATABASE | SCHEMA} [IF NOT EXISTS] db [[DEFAULT] CHARACTER SET [=] cs] [[DEFAULT] COLLATE [=] c] [COMMENT [=] '...']`
  - 문자 집합과 collation은 기록만 합니다(`SHOW CREATE DATABASE`, `information_schema.SCHEMATA`). 테이블의 열은 언제나 방언의 기본(`NOCASE`)입니다.
  - 아무것도 쓰지 않으면 MariaDB 11.8 서버의 기본 `utf8mb4_uca1400_ai_ci`, `CHARACTER SET cs`만 쓰면 그 문자 집합의 기본 collation(`latin1_swedish_ci` ...)입니다.
  - `CREATE OR REPLACE DATABASE`는 있던 데이터베이스를 지우고 다시 만듭니다.
- `DROP {DATABASE | SCHEMA} [IF EXISTS] db`는 MariaDB처럼 안의 테이블, 뷰, 인덱스, 시퀀스를 모두 지웁니다.
  - `main`과 붙인 데이터베이스는 지울 수 없습니다(붙인 것은 `DETACH`).
  - `auto_vacuum` 데이터베이스에서는 테이블이 둘 이상인 데이터베이스를 한 문장으로 지울 수 없습니다(공용 `schema.codeDrop()`의 제한). 테이블을 먼저 지우세요.
  - 현재 데이터베이스를 지우면 MariaDB처럼 선택된 데이터베이스가 없어집니다. `DATABASE()`는 NULL이고 한정하지 않은 이름은 `No database selected`입니다.
- `USE db`는 현재 데이터베이스를 바꿉니다. 문장이 실행될 때 적용하고(`xq_maria_use()`), 준비된 문장을 만료시켜 다음 실행 때 새 데이터베이스에서 다시 컴파일되게 합니다.

## 이름 해석

이름은 문장을 컴파일할 때 정합니다(`Parser.relation()`).

- `db.t`는 그 데이터베이스의 `t`입니다. SQLite 데이터베이스 이름(`main`, `temp`, 붙인 이름)이 먼저이고, 그다음이 `CREATE DATABASE`의 데이터베이스입니다.
- 한정하지 않은 `t`는 `WITH` 질의, 임시 테이블, 현재 데이터베이스 순서로 찾습니다.
  - 현재 데이터베이스가 `main`이면 이름을 그대로 둡니다. SQLite의 규칙(`temp`, `main`, 붙인 데이터베이스 순서)대로 찾으므로 이전과 같습니다.
  - 붙인 데이터베이스 `aux`이면 `aux.t`, `CREATE DATABASE`의 `sales`이면 `"sales.t"`입니다.
- `"sales.t"`는 데이터베이스 이름 없이 쓰고 원래 이름 `t`를 별칭으로 붙입니다(FROM 항목, INSERT/UPDATE/DELETE 대상). 그래서 `t.col`과 `sales.t.col`이 그대로 됩니다. 뷰에 저장되는 텍스트도 `"sales.t" AS "t"`라서 main이 다른 이름으로 붙어도 됩니다.
- 대상: SELECT, 조인, 서브쿼리, INSERT/REPLACE/UPDATE/DELETE/TRUNCATE, `CREATE TABLE db.t`(`AS SELECT` 포함), `CREATE VIEW db.v`, `CREATE INDEX ... ON db.t`, `DROP INDEX ... ON db.t`, `ALTER TABLE db.t`, `DROP TABLE/VIEW db.t`, `NEXT VALUE FOR db.s`, `NEXTVAL(db.s)`, `CREATE/DROP SEQUENCE db.s`, `SHOW COLUMNS/INDEX/CREATE TABLE`, `DESCRIBE`, `ANALYZE TABLE`.
- `REFERENCES t`는 만드는 테이블의 SQLite 데이터베이스 안이어야 합니다. main과 `CREATE DATABASE`의 데이터베이스끼리는 됩니다.
- `RENAME TABLE a TO b`와 `ALTER TABLE a RENAME TO b`에서 한정하지 않은 `b`는 MariaDB처럼 현재 데이터베이스입니다. 테이블은 main과 `CREATE DATABASE`의 데이터베이스 사이에서 옮길 수 있고(인덱스 이름, `AUTO_INCREMENT` 카운터, 카탈로그 항목이 따라갑니다), 다른 SQLite 데이터베이스로는 옮길 수 없습니다.

## SHOW와 information_schema

- `SHOW {DATABASES | SCHEMAS} [LIKE]`: `information_schema`, `main`, 붙인 데이터베이스, `CREATE DATABASE`의 데이터베이스(이름순). 열 이름은 MariaDB처럼 `Database (pattern)`입니다.
- `SHOW [FULL] TABLES [{FROM | IN} db] [LIKE]`: 기본은 현재 데이터베이스입니다. `main`의 목록에는 다른 데이터베이스의 `"db.t"`가 나오지 않습니다. 열 이름은 `Tables_in_db (pattern)`입니다.
- `SHOW CREATE {DATABASE | SCHEMA} db`: ``CREATE DATABASE `db` /*!40100 DEFAULT CHARACTER SET cs COLLATE c */``. `main`과 붙인 데이터베이스는 `utf8mb4_general_ci`입니다.
- `information_schema`의 `TABLES`, `COLUMNS`, `VIEWS`, `STATISTICS`는 `"db.t"`를 `TABLE_SCHEMA = 'db'`, `TABLE_NAME = 't'`로 보여 주고 `main`에서는 감춥니다. `SCHEMATA`는 데이터베이스마다 한 행입니다. 이름 열은 MariaDB처럼 대소문자를 무시하고 비교합니다.
- `DATABASE()`, `SCHEMA()`는 컴파일할 때의 현재 데이터베이스입니다(`USE`가 준비된 문장을 만료시킵니다).

## 오류

| 경우 | 메시지(MariaDB와 같음) |
| --- | --- |
| 이미 있는 데이터베이스(1007) | `Can't create database 'd'; database exists`(`IF NOT EXISTS`면 같은 문구의 Note) |
| 없는 데이터베이스 지우기(1008) | `Can't drop database 'd'; database doesn't exist`(`IF EXISTS`면 Note) |
| 없는 데이터베이스(1049) | `Unknown database 'd'`(`USE`, `CREATE TABLE d.t`, `SHOW TABLES FROM d`, `SHOW CREATE DATABASE`) |
| 없는 테이블(1146) | `Table 'db.t' doesn't exist`(SQLite의 `no such table`도 이 문구로 바꿉니다) |
| 없는 테이블 지우기(1051) | `Unknown table 'db.t'` |
| 있는 테이블(1050) | `Table 't' already exists` |
| 선택된 데이터베이스 없음(1046) | `No database selected` |

## 제약 위반

이 방언으로 컴파일한 문장의 제약 위반은 MariaDB의 문구와 번호입니다. SQLSTATE는 다른 오류처럼 PostgreSQL의 코드 공간입니다(MariaDB 자신은 모두 23000).

| 위반 | 메시지 | 번호 | SQLSTATE |
| --- | --- | --- | --- |
| PRIMARY KEY, UNIQUE 키 | `Duplicate entry '1' for key 'PRIMARY'`, `Duplicate entry 'a-1' for key 'uk'` | 1062 | 23505 |
| NOT NULL | `Column 'a' cannot be null` | 1048 | 23502 |
| CHECK | ``CONSTRAINT `c` failed for `db`.`t` `` | 4025 | 23514 |
| 외래 키(자식 행) | ``Cannot add or update a child row: a foreign key constraint fails (`db`.`t`, CONSTRAINT `t_ibfk_1` FOREIGN KEY (`b`) REFERENCES `p` (`id`))`` | 1452 | 23503 |
| 외래 키(부모 행) | ``Cannot delete or update a parent row: a foreign key constraint fails (...)`` | 1451 | 23503 |

- 키 이름은 MariaDB와 같습니다: 기본 키는 `PRIMARY`, 그 밖에는 인덱스 이름(`t$uk`의 `uk`), 이름 없는 키는 첫 열 이름입니다. 여러 열 키의 값은 `-`로 잇습니다.
- 이름 없는 외래 키는 `<table>_ibfk_<n>`(CREATE TABLE에서의 순서)입니다. 이름을 준 외래 키의 이름은 CREATE TABLE이 `xq_catalog`에 적어 둡니다(키 `constraint:foreign_key:<열>`). 외래 키 문구의 끝에 붙는 `ON DELETE CASCADE` 같은 동작은 쓰지 않습니다.
- `CREATE UNIQUE INDEX`가 중복을 찾으면 값이 없는 `Duplicate entry for key 'i'`입니다.
- 문장이 끝날 때 찾는 외래 키 위반은 마지막으로 센 위반의 제약을 말합니다. COMMIT에서 찾는 지연 제약은 제약을 모르므로 `Cannot add or update a child row: a foreign key constraint fails`입니다.
- 값 변환이 내는 `Column 'a' cannot be null`(1048)은 SQL 함수의 오류라 결과 코드가 SQLITE_ERROR입니다. 엔진의 NOT NULL 검사가 내는 것은 SQLITE_CONSTRAINT_NOTNULL입니다.
