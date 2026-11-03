# 지원 범위: 문장과 스키마

[PostgreSQL 호환](README.md)의 일부입니다.

## 어휘

- 따옴표 없는 식별자는 소문자로 접고, `"Quoted"`는 그대로 둡니다.
- 문자열: `'...'`(`''`로 따옴표, 줄바꿈이 든 공백 사이 이어 붙이기: 사이에 주석이 있으면 이어지지 않아 문법 오류), `E'...'` 이스케이프(`\uXXXX`·`\UXXXXXXXX`, UTF-16 서로게이트 쌍은 한 문자로: `E'\uD83D\uDE00'`), `U&'...'`와 `U&"..."`(`\XXXX`, `\+XXXXXX`, `\\`; `UESCAPE '!'`로 이스케이프 문자를 바꿈), `$$...$$`/`$tag$...$tag$`. `SET standard_conforming_strings = off`이면 그 뒤 문장의 `'...'`와 `N'...'`도 `E'...'`처럼 백슬래시 이스케이프를 읽고(`'it\'s'`), `U&'...'`는 `unsafe use of string constant with Unicode escapes`(0A000, DETAIL과 함께)입니다(기본은 `on`). `escape_string_warning`의 경고는 내지 않습니다. 유니코드 이스케이프의 오류는 PostgreSQL의 문구와 위치(`invalid Unicode escape`, `invalid Unicode surrogate pair`, `invalid Unicode escape value`, `UESCAPE must be followed by a simple string literal`, `invalid Unicode escape character`)입니다. `HINT`는 없습니다.
- 매개변수 `$1`은 `?1`이 됩니다.
- 주석: `--`, 중첩 `/* */`.
- 연산자: `::`. `a<-1`은 PostgreSQL처럼 `a < -1`입니다.
- 숫자: 16진(`0x1F`)·8진(`0o17`)·2진(`0b101`), `1_000`(지수에도: `1_0e1_0`). bigint를 넘는 16진·8진·2진 정수는 10진 정수처럼 `numeric`입니다. 오류도 PostgreSQL의 스캐너와 같습니다: `0x`, `0x_`는 `invalid hexadecimal integer`, `0x1g`, `0b102`, `1__0`, `100_`은 `trailing junk after numeric literal`.
- 백틱과 `[x]`는 식별자가 아닙니다.

## SELECT

| 영역 | 지원 |
| --- | --- |
| 기본 | `DISTINCT`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW` |
| FROM | 테이블, 서브쿼리, `VALUES`, `generate_series()`, JSON 집합 반환 함수(아래 [JSON](json.md)), `unnest()`·`generate_subscripts()`(아래 [배열](arrays.md)); 서브쿼리 별칭의 열 이름 `AS t(a, b)`; 함수 앞의 `LATERAL` |
| JOIN | `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL`, `ON`/`USING`, 괄호 조인 |
| 정렬 | `ORDER BY ... [ASC\|DESC] [NULLS FIRST\|LAST]` |
| 행 수 제한 | `LIMIT`/`OFFSET`/`LIMIT ALL`, `OFFSET n ROWS FETCH FIRST n ROWS ONLY` |
| 집합 연산 | `UNION`/`INTERSECT`/`EXCEPT`(INTERSECT가 먼저 묶임) |
| CTE | `WITH [RECURSIVE]`, `[NOT] MATERIALIZED` |
| 그 밖 | 단독 `VALUES`, `TABLE t`, `FOR UPDATE/SHARE`(무시), `SELECT ... INTO [TEMP] [TABLE] t`(`CREATE TABLE t AS`) |

## DML

- **INSERT**
  - 열 목록, 여러 행 `VALUES`와 `DEFAULT`, 열보다 적은 값
  - `INSERT ... SELECT`, `DEFAULT VALUES`
  - `OVERRIDING SYSTEM VALUE`
  - `ON CONFLICT (cols) [WHERE] DO NOTHING | DO UPDATE SET ... EXCLUDED.x [WHERE]`
- **UPDATE**: `SET a = ...`, `SET (a, b) = (...)`, `= DEFAULT`, `FROM`, 배열 원소 `SET a[i] = ...`
- **DELETE**: `USING`
- **공통**: `RETURNING`(대상의 별칭으로 한정한 열 포함), 앞에 붙는 `WITH`
- **TRUNCATE** `[RESTART IDENTITY]`

## 트랜잭션

- `BEGIN`/`START TRANSACTION`(격리 수준 등은 파싱만 함)
- `COMMIT`/`END`, `ROLLBACK`/`ABORT`
- `SAVEPOINT`, `RELEASE [SAVEPOINT]`, `ROLLBACK TO [SAVEPOINT]`
- `EXPLAIN`(= SQLite의 `EXPLAIN QUERY PLAN`)

## DDL

- **CREATE TABLE** `[TEMP] [IF NOT EXISTS]`, `CREATE TABLE ... AS`
  - 열 제약: `NOT NULL`, `DEFAULT`, `PRIMARY KEY`, `UNIQUE`, `CHECK`, `REFERENCES ... ON DELETE/UPDATE`, `COLLATE "C"`
  - 생성 열: `GENERATED ALWAYS AS (...) STORED`
  - identity: `GENERATED {ALWAYS|BY DEFAULT} AS IDENTITY [(옵션)]`, `serial` 계열
  - 테이블 제약
- **CREATE INDEX**: `[UNIQUE] [CONCURRENTLY] [IF NOT EXISTS] [name] ON t [USING btree] (열·식 [DESC]) [WHERE]`. 이름이 없으면 PostgreSQL처럼 `t_col_idx`입니다.
- **CREATE VIEW**: `[OR REPLACE] [TEMP]`
- **CREATE SEQUENCE**: `[IF NOT EXISTS] ... START/INCREMENT/MINVALUE/MAXVALUE/[NO] CYCLE`
- **ALTER TABLE**: `RENAME TO`, `RENAME COLUMN`, `ADD COLUMN [IF NOT EXISTS]`, `DROP COLUMN [IF EXISTS]`
- **DROP**: `TABLE/VIEW/INDEX/SEQUENCE [IF EXISTS] [CASCADE]`
- **CREATE SCHEMA** `[IF NOT EXISTS] name [AUTHORIZATION role]`, `CREATE SCHEMA AUTHORIZATION role`
- **DROP SCHEMA** `[IF EXISTS] a [, b ...] [CASCADE | RESTRICT]`
- **COMMENT ON** `TABLE | VIEW | COLUMN name IS 'text' | NULL`: `xq_catalog`의 `pg.comment` 키. `pg_description`, `obj_description()`, `col_description()`이 읽음
- 모든 DDL은 `s.t`처럼 스키마로 한정한 이름을 받습니다(아래 [스키마](#스키마)).

## 스키마

`CREATE SCHEMA`로 만든 스키마는 SQLite 데이터베이스가 아니라 main 데이터베이스 안의 이름 공간입니다. 공용 구현은 `src/catalog/schema.zig`([방언 아키텍처](../architecture.md#스키마네임스페이스))입니다.

| PostgreSQL | SQLite |
| --- | --- |
| `public.t`, 한정하지 않은 `t` | `main.t` |
| `pg_temp.t`, `CREATE TEMP TABLE t` | `temp.t` |
| `aux.t`(`ATTACH ... AS aux`) | `aux.t` |
| `sales.orders`(`CREATE SCHEMA sales`) | main의 `"sales.orders"` |

- 스키마의 개체(테이블, 뷰, 인덱스, 시퀀스, `serial`의 시퀀스)는 `<스키마>.<이름>`이라는 main의 개체입니다. 파일 하나, 트랜잭션 하나이고, sqlite3에서는 `"sales.orders"`로 읽고 씁니다(`.tables`에 `sales.orders`로 나옴).
- 스키마 목록은 `xq_catalog`의 행(`tbl = ''`, `col` = 스키마, `key = 'schema'`, `value` = 소유자)입니다.
- 인덱스와 `serial`·identity 시퀀스는 테이블의 스키마에 있습니다(`sales.orders_id_seq`). `ALTER TABLE sales.orders RENAME TO x`는 `sales.x`가 됩니다.
- 질의와 DML, 조인, 서브쿼리, 뷰에서 `s.t`를 씁니다. 별칭이 없으면 테이블의 이름 `t`가 별칭이 되므로 `t.col`과 `s.t.col` 모두 됩니다(`ON CONFLICT ... DO UPDATE SET v = t.v`, `RETURNING t.col`도).
- 뷰는 SQLite 텍스트로 저장될 때 `"sales.orders"`를 이름으로 씁니다(데이터베이스 이름 없이). 그래서 sqlite3에서도 그 뷰를 읽습니다. 뷰 안의 한정하지 않은 이름은 PostgreSQL처럼 만들 때의 `search_path`로 정해집니다.
- `nextval('s.seq')`, `currval`, `setval`의 상수 이름은 PostgreSQL의 regclass처럼 읽습니다(`[schema.]name`, 따옴표 없는 부분은 소문자로 접고, 스키마가 없으면 `search_path`).
- `DROP SCHEMA ... CASCADE`는 뷰, 테이블(인덱스와 함께), 시퀀스, 카탈로그 항목과 목록의 행을 한 문장으로 지웁니다. `RESTRICT`(기본값)는 개체가 있으면 `cannot drop schema s because other objects depend on it`으로 실패합니다.
- 오류는 PostgreSQL 18과 같은 문구입니다: `schema "s" already exists`, `schema "s" does not exist`(DDL), `relation "s.t" does not exist`(질의), `unacceptable schema name "pg_x"`, `role "x" does not exist`, `no schema has been selected to create in`, `cannot create temporary relation in non-temporary schema`.
- `ATTACH`로 붙인 데이터베이스 안에서도 `CREATE`/`DROP`/`ALTER TABLE`, `CREATE INDEX`, `CREATE VIEW`를 씁니다(카탈로그 항목은 그 데이터베이스의 `xq_catalog`, identity 시퀀스는 main의 `xq_sequence`).

### search_path

- `SET search_path TO a, b`, `SET search_path = DEFAULT`, `SET SCHEMA 'a'`, `RESET search_path`, `SHOW search_path`, `set_config('search_path', ..., false)`, `current_setting('search_path')`. 기본값은 `"$user", public`이고 `$user`는 `postgres`입니다.
- 한정하지 않은 이름은 `pg_temp`(임시 개체), 그다음 `search_path`의 스키마 순서로 찾습니다. 경로에 없으면 `relation "t" does not exist`입니다. `WITH` 질의의 이름은 찾지 않습니다.
- DDL은 경로에서 처음으로 있는 스키마(`current_schema()`)에 만듭니다. 그런 스키마가 없으면 `no schema has been selected to create in`입니다.
- `current_schema()`(`current_schema`), `current_schemas(bool)`(`{pg_catalog,public}` 같은 텍스트)는 경로에서 있는 스키마를 보여 줍니다.
- 이름은 문장을 컴파일할 때 정해집니다. `search_path`를 바꾸면 준비된 문장이 만료되어, 다음 실행 때 새 경로로 다시 컴파일됩니다.
- `SET`은 이 밖에 드라이버가 연결할 때 쓰는 매개변수(`application_name`, `client_encoding`, `client_min_messages`, `DateStyle`, `IntervalStyle`, `TimeZone`, `extra_float_digits`, `standard_conforming_strings`(어휘를 바꿈: 위 [어휘](#어휘)), `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, `bytea_output`, `default_transaction_isolation`, `transaction_isolation`, `transaction_read_only`, `lc_messages` ... 40여 개)를 받아 `SHOW`가 그 값을 보여 줍니다(`IntervalStyle`·`standard_conforming_strings` 말고는 동작을 바꾸지 않음). `IntervalStyle`은 `postgres`, `postgres_verbose`, `sql_standard`, `iso_8601`만 받고(대소문자 무관, `SHOW`는 소문자) 다른 값은 `invalid value for parameter "IntervalStyle": "x"`(22023)와 그 `HINT`입니다([interval](interval.md)). `client_min_messages`도 같은 식으로 `debug5` ... `debug1`, `log`, `notice`, `warning`, `error`(숨은 `debug`는 `debug2`, `info`)만 받고, `standard_conforming_strings`는 불리언(`on`, `off`, `true`, `no`, `1` ...: `SHOW`는 `on`/`off`)이 아니면 `parameter "standard_conforming_strings" requires a Boolean value`(22023)입니다. 시작 패킷의 값(서버의 `options`)도 같은 검사를 거칩니다. `SET TIME ZONE 'UTC' | LOCAL | INTERVAL '+00:00' HOUR TO MINUTE`도 됩니다. 모르는 이름은 `unrecognized configuration parameter "x"`입니다. `RESET ALL`, `SET TRANSACTION ...`(무시)도 됩니다.
- 읽기 전용: `server_version`(`18.6 (xqlite)`), `server_version_num`(`180006`), `server_encoding`, `integer_datetimes`, `is_superuser`, `in_hot_standby`, `max_identifier_length`, `block_size`, `lc_collate`, `lc_ctype` .... `SET`하면 `parameter "server_version" cannot be changed`(55P02)입니다. `version()`은 `PostgreSQL 18.6 (xqlite 3.54.1)`입니다.
- `SHOW`의 열 이름은 PostgreSQL의 철자(`DateStyle`, `TimeZone`)이고, `SHOW TRANSACTION ISOLATION LEVEL`(`read committed`), `SHOW SESSION AUTHORIZATION`, `SHOW ALL`(`pg_settings`의 이름·값·설명)도 됩니다. `transaction_isolation`은 PostgreSQL의 기본값 `read committed`를 보여 줍니다(실제로는 SQLite의 직렬화).
- 와이어 서버가 시작 패킷의 값(`application_name`, `options`)을 정하면 `RESET`은 기본값이 아니라 그 값으로 돌아갑니다(`xq_pg_startup_setting()`). `current_database()`는 클라이언트가 준 데이터베이스 이름이고 서버 밖에서는 `postgres`입니다.
