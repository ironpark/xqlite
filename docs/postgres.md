# PostgreSQL 호환

xqlite의 PostgreSQL 방언이 지원하는 문법과 의미, 그리고 PostgreSQL과 다른 점입니다. 방언 구조와 프론트엔드 계약은 [방언 아키텍처](architecture.md)를 보세요.

## 목차

- [켜는 법](#켜는-법)
- [구조](#구조)
- [지원 범위](#지원-범위)
- [타입 매핑](#타입-매핑)
- [PostgreSQL과 다른 점](#postgresql과-다른-점)
- [아직 하지 않은 것](#아직-하지-않은-것)
- [검증](#검증)

## 켜는 법

| 어디서 | 방법 |
| --- | --- |
| SQL | `PRAGMA xq_dialect = 'postgres'` |
| 셸 | `.dialect postgres` |
| Zig API | `.dialect = .postgres` |

```sql
PRAGMA xq_dialect = 'postgres';
CREATE TABLE app_user (
  id         bigserial PRIMARY KEY,
  email      varchar(100) NOT NULL UNIQUE,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);
INSERT INTO app_user (email) VALUES ($1) RETURNING id;
INSERT INTO app_user (email) VALUES ('a@x') ON CONFLICT (email) DO UPDATE SET active = EXCLUDED.active;
SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'app_user';
PRAGMA xq_dialect = 'sqlite';   -- PRAGMA는 SQLite 문법 그대로 통과
```

## 구조

프론트엔드는 `src/dialect/postgres/`에 있습니다. 문장을 구문 트리 IR(`src/ir/tree.zig`)로 파싱하고, 내림·렌더링·카탈로그 기록은 공용 `src/ir/lower.zig`와 `render.zig`가 합니다.

| 파일 | 내용 |
| --- | --- |
| `frontend.zig` | 진입점. 한 문장을 파싱해 IR로 내림. `PRAGMA`·`ATTACH`·`DETACH`·`VACUUM`·`REINDEX`는 SQLite 문법으로, `ANALYZE [VERBOSE] [[schema.]name]`는 같은 인자로 SQLite에 넘김(`public`은 `main`, `CREATE SCHEMA`의 스키마는 `main."s.t"`, `VERBOSE`는 무시; `VACUUM`은 [SQLite 호환](sqlite.md#vacuum과-백업-api)의 VACUUM) |
| `lexer.zig` | PostgreSQL 어휘(아래 [어휘](#어휘)) |
| `parser.zig` | 재귀 하강 파서. IR을 만들면서 PostgreSQL 의미를 해석함(캐스트, LIKE/ILIKE, 함수 이름과 특수 문법, 결과 열 이름, NULL 정렬, 스키마 이름과 `search_path` 해석, 카탈로그 뷰, 짧은 INSERT VALUES, DDL의 타입·검사·identity) |
| `ddl.zig` | DDL의 PostgreSQL 문구 검사, 이름 없는 인덱스의 이름 |
| `types.zig` | 타입 → STRICT 저장 타입·검사·`format_type()` 철자·캐스트 |
| `funcs.zig` | 방언 함수와 엔진 함수(`xq_like`, 정규식 연산자의 `xq_pg_regex` 등) |
| `regex.zig` | 정규식(jsonpath `like_regex`와 `~` 연산자) |
| `json.zig` | json/jsonb 값: PostgreSQL 규칙의 파싱, jsonb 정규화와 출력, 비교·포함 |
| `jsonpath.zig` | jsonpath의 부분집합 |
| `jfuncs.zig` | JSON 연산자·함수·집계·집합 반환 함수의 구현 |
| `typing.zig` | 식 타입의 규칙(`Hooks.typing`, [아키텍처](architecture.md)의 코어의 타입): 리터럴·연산자·함수의 결과 타입 |
| `operators.zig` | 연산자 표(`pg_operator`처럼 연산자, 피연산자 타입, 결과 타입, 구현)와 PostgreSQL 규칙의 연산자 해석(아래 [연산자 해석](#연산자-해석)) |
| `datetime.zig` | `date`/`time`/`timestamp[tz]`/`interval` 값의 PostgreSQL 입력·출력, 그 연산자의 엔진 함수(`xq_pg_date_pli()` ...)와 캐스트(`xq_pg_date()` ...), collation `xq_pg_interval` |
| `overload.zig` | 피연산자 타입에 따른 선택(`Rules.overload`): 산술·비트 연산자를 연산자 표로, `jsonb`의 `\|\|`·비교·`ORDER BY`, interval의 비교·`ORDER BY`, `->`·`#>`의 json/jsonb 함수, JSON을 만드는 함수의 인자. 이름을 해석한 코어가 부름 |
| `jtype.zig` | 파싱 뒤, 타입이 아니라 이름과 FROM 구조로 정하는 JSON: 값으로 쓴 FROM 항목(행), FROM의 JSON 집합 반환 함수 열과 그 옆의 `*`, json/jsonb 열에 저장하는 값의 정규화 |
| `ddltype.zig` | 스키마가 텍스트로 남기는 문장(뷰, CHECK, 생성 열, 식 인덱스)에 코어의 선택을 되돌려 씀: 식을 내리고 해석만 하는 probe |
| `session.zig` | `CREATE SCHEMA`/`DROP SCHEMA`, `SET`/`RESET`/`SHOW`, `COMMENT ON`, `set_config()`/`current_setting()`/`current_schema()`/`current_schemas()` |
| `state.zig` | 연결별 세션 상태(`search_path`와 그 밖의 매개변수, 시작 값, 카탈로그 스냅숏), 따르는 릴리스(16.15) |
| `catalog_views.zig` | `information_schema`/`pg_catalog` 뷰 |
| `pgcatalog.zig` | 시스템 카탈로그: 메모리의 스키마에서 만든 스냅숏, OID, 엔진 테이블 값 함수 `xq_pg_class` ... |
| `catalog_funcs.zig` | 카탈로그 함수(`pg_get_indexdef()`, `pg_table_is_visible()` ...)와 reg* 타입의 입출력 |
| `test.zig` | 종단 테스트 |

## 지원 범위

### 어휘

- 따옴표 없는 식별자는 소문자로 접고, `"Quoted"`는 그대로 둡니다.
- 문자열: `'...'`(`''`로 따옴표, 줄바꿈 사이 이어 붙이기), `E'...'` 이스케이프, `$$...$$`/`$tag$...$tag$`.
- 매개변수 `$1`은 `?1`이 됩니다.
- 주석: `--`, 중첩 `/* */`.
- 연산자: `::`. `a<-1`은 PostgreSQL처럼 `a < -1`입니다.
- 숫자: 16진(`0x1F`)·8진(`0o17`)·2진(`0b101`), `1_000`.
- 백틱과 `[x]`는 식별자가 아닙니다.

### SELECT

| 영역 | 지원 |
| --- | --- |
| 기본 | `DISTINCT`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW` |
| FROM | 테이블, 서브쿼리, `VALUES`, `generate_series()`, JSON 집합 반환 함수(아래 [JSON](#json)); 서브쿼리 별칭의 열 이름 `AS t(a, b)`; 함수 앞의 `LATERAL` |
| JOIN | `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL`, `ON`/`USING`, 괄호 조인 |
| 정렬 | `ORDER BY ... [ASC\|DESC] [NULLS FIRST\|LAST]` |
| 행 수 제한 | `LIMIT`/`OFFSET`/`LIMIT ALL`, `OFFSET n ROWS FETCH FIRST n ROWS ONLY` |
| 집합 연산 | `UNION`/`INTERSECT`/`EXCEPT`(INTERSECT가 먼저 묶임) |
| CTE | `WITH [RECURSIVE]`, `[NOT] MATERIALIZED` |
| 그 밖 | 단독 `VALUES`, `TABLE t`, `FOR UPDATE/SHARE`(무시) |

### DML

- **INSERT**
  - 열 목록, 여러 행 `VALUES`와 `DEFAULT`, 열보다 적은 값
  - `INSERT ... SELECT`, `DEFAULT VALUES`
  - `OVERRIDING SYSTEM VALUE`
  - `ON CONFLICT (cols) [WHERE] DO NOTHING | DO UPDATE SET ... EXCLUDED.x [WHERE]`
- **UPDATE**: `SET a = ...`, `SET (a, b) = (...)`, `= DEFAULT`, `FROM`
- **DELETE**: `USING`
- **공통**: `RETURNING`(대상의 별칭으로 한정한 열 포함), 앞에 붙는 `WITH`
- **TRUNCATE** `[RESTART IDENTITY]`

### 트랜잭션

- `BEGIN`/`START TRANSACTION`(격리 수준 등은 파싱만 함)
- `COMMIT`/`END`, `ROLLBACK`/`ABORT`
- `SAVEPOINT`, `RELEASE [SAVEPOINT]`, `ROLLBACK TO [SAVEPOINT]`
- `EXPLAIN`(= SQLite의 `EXPLAIN QUERY PLAN`)

### DDL

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

### 스키마

`CREATE SCHEMA`로 만든 스키마는 SQLite 데이터베이스가 아니라 main 데이터베이스 안의 이름 공간입니다. 공용 구현은 `src/catalog/schema.zig`([방언 아키텍처](architecture.md#스키마네임스페이스))입니다.

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
- 오류는 PostgreSQL 16과 같은 문구입니다: `schema "s" already exists`, `schema "s" does not exist`(DDL), `relation "s.t" does not exist`(질의), `unacceptable schema name "pg_x"`, `role "x" does not exist`, `no schema has been selected to create in`, `cannot create temporary relation in non-temporary schema`.
- `ATTACH`로 붙인 데이터베이스 안에서도 `CREATE`/`DROP`/`ALTER TABLE`, `CREATE INDEX`, `CREATE VIEW`를 씁니다(카탈로그 항목은 그 데이터베이스의 `xq_catalog`, identity 시퀀스는 main의 `xq_sequence`).

#### search_path

- `SET search_path TO a, b`, `SET search_path = DEFAULT`, `SET SCHEMA 'a'`, `RESET search_path`, `SHOW search_path`, `set_config('search_path', ..., false)`, `current_setting('search_path')`. 기본값은 `"$user", public`이고 `$user`는 `postgres`입니다.
- 한정하지 않은 이름은 `pg_temp`(임시 개체), 그다음 `search_path`의 스키마 순서로 찾습니다. 경로에 없으면 `relation "t" does not exist`입니다. `WITH` 질의의 이름은 찾지 않습니다.
- DDL은 경로에서 처음으로 있는 스키마(`current_schema()`)에 만듭니다. 그런 스키마가 없으면 `no schema has been selected to create in`입니다.
- `current_schema()`(`current_schema`), `current_schemas(bool)`(`{pg_catalog,public}` 같은 텍스트)는 경로에서 있는 스키마를 보여 줍니다.
- 이름은 문장을 컴파일할 때 정해집니다. `search_path`를 바꾸면 준비된 문장이 만료되어, 다음 실행 때 새 경로로 다시 컴파일됩니다.
- `SET`은 이 밖에 드라이버가 연결할 때 쓰는 매개변수(`application_name`, `client_encoding`, `client_min_messages`, `DateStyle`, `IntervalStyle`, `TimeZone`, `extra_float_digits`, `standard_conforming_strings`, `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, `bytea_output`, `default_transaction_isolation`, `transaction_isolation`, `transaction_read_only`, `lc_messages` ... 40여 개)를 받아 `SHOW`가 그 값을 보여 줍니다(동작은 바꾸지 않음). `SET TIME ZONE 'UTC' | LOCAL | INTERVAL '+00:00' HOUR TO MINUTE`도 됩니다. 모르는 이름은 `unrecognized configuration parameter "x"`입니다. `RESET ALL`, `SET TRANSACTION ...`(무시)도 됩니다.
- 읽기 전용: `server_version`(`16.15 (xqlite)`), `server_version_num`(`160015`), `server_encoding`, `integer_datetimes`, `is_superuser`, `in_hot_standby`, `max_identifier_length`, `block_size`, `lc_collate`, `lc_ctype` .... `SET`하면 `parameter "server_version" cannot be changed`(55P02)입니다. `version()`은 `PostgreSQL 16.15 (xqlite 3.54.1)`입니다.
- `SHOW`의 열 이름은 PostgreSQL의 철자(`DateStyle`, `TimeZone`)이고, `SHOW TRANSACTION ISOLATION LEVEL`(`read committed`), `SHOW SESSION AUTHORIZATION`, `SHOW ALL`(`pg_settings`의 이름·값·설명)도 됩니다. `transaction_isolation`은 PostgreSQL의 기본값 `read committed`를 보여 줍니다(실제로는 SQLite의 직렬화).
- 와이어 서버가 시작 패킷의 값(`application_name`, `options`)을 정하면 `RESET`은 기본값이 아니라 그 값으로 돌아갑니다(`xq_pg_startup_setting()`). `current_database()`는 클라이언트가 준 데이터베이스 이름이고 서버 밖에서는 `postgres`입니다.

### 식과 연산자

| 영역 | 지원 |
| --- | --- |
| 캐스트 | `::type`, `CAST`, 타입 리터럴(`DATE '2024-01-01'`) |
| NULL·진리값 | `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN` |
| 술어 | `BETWEEN`, `IN (목록\|서브쿼리)`, `= ANY (서브쿼리)`/`<> ALL (서브쿼리)`, `EXISTS` |
| 패턴 | `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE`, 정규식 `~`/`~*`/`!~`/`!~*`(`xq_pg_regex()`, `regex.zig`의 POSIX 확장 정규식 부분집합: 어디서든 맞으면 참) |
| 날짜·시각 | `date ± integer`, `date - date`, `date ± interval`, `date + time`, `timestamp[tz] ± interval`, `timestamp[tz] - timestamp[tz]`, `time ± interval`, `time - time`, `interval ± interval`, `-interval`, `interval * 수`, `interval / 수`(아래 [연산자 해석](#연산자-해석)) |
| JSON | `->`, `->>`, `#>`, `#>>`, `@>`, `<@`, `?`, `?\|`, `?&`, jsonb의 `\|\|`, `-`, `#-`, `@?`, `@@`, `IS [NOT] JSON` (아래 [JSON](#json)) |
| 그 밖 | `CASE`, 행 값, `ARRAY[...]`(텍스트 리터럴, 아래), `\|\|`(피연산자가 NULL이면 NULL) |
| 집계 | `count(*)`, 집계의 `DISTINCT`/`ORDER BY`/`FILTER` |
| 윈도우 | `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS ... EXCLUDE ...)`, `OVER name` |

연산자 우선순위는 PostgreSQL의 것입니다(낮은 것부터).

`OR` < `AND` < `NOT` < `IS` < 비교 < `BETWEEN`/`IN`/`LIKE` < 기타 연산자(`||`, `->`, `~`) < `+ -` < `* / %` < `^` < 단항 < `::`

#### 연산자 해석

산술·비트 연산자(`+ - * / %`, 단항 `-`, `& | << >>`)는 피연산자의 타입으로 연산자 표(`operators.zig`)의 행을 고릅니다. PostgreSQL의 연산자 해석과 같은 순서입니다.

1. 타입이 정확히 같은 행. 문자열 상수(PostgreSQL의 unknown)는 먼저 다른 피연산자의 타입으로 봅니다(`date '2024-01-02' - '2024-01-01'`은 `date - date`, `1`).
2. 없으면 피연산자가 암시적으로 캐스트되는 행들: 정수는 더 넓은 정수·`numeric`·실수로, `numeric`은 실수로, `date`는 `timestamp[tz]`로, `timestamp`는 `timestamptz`로, `time`은 `interval`로, 문자열끼리. 문자열 상수는 어느 타입과도 맞습니다.
3. 그중 정확히 맞는 자리가 가장 많은 행, 그다음 캐스트하는 자리에 선호 타입(`double precision`, `text`, `timestamptz`, `interval`)이 가장 많은 행. 문자열 상수의 자리는 남은 행들의 타입 범주가 하나여야 합니다(문자열 범주가 있으면 그것).
4. 한 행이면 그 연산자, 없으면 `operator does not exist: date + text`(42883), 여럿이면 `operator is not unique: date + unknown`(42725).

| 행 | 구현 |
| --- | --- |
| 정수(`smallint`/`integer`/`bigint`의 모든 쌍, 넓은 쪽), `numeric`, `real`, `double precision`의 `+ - * /`; 같은 타입의 `%`(실수의 `%`는 없음); 단항 `-`; 정수의 `& \|`와 `<< >>`(오른쪽 `integer`) | 엔진의 연산 코드(SQLite의 바이트코드). 문자열 상수는 그 정수 타입으로 읽음(`xq_pg_int4('a')`: `'a' + 1`은 `invalid input syntax for type integer: "a"`) |
| `date ± integer` → `date`, `date - date` → `integer`, `date ± interval`·`date + time` → `timestamp`, `timestamp[tz] ± interval` → 같은 타입, `timestamp[tz] - timestamp[tz]` → `interval`, `time ± interval` → `time`, `time - time`, `interval ± interval`, `-interval`, `interval * double precision`, `interval / double precision` → `interval`(교환한 행 포함) | `datetime.zig`의 엔진 함수 `xq_pg_<PostgreSQL 구현 이름>`(`xq_pg_date_pli`, `xq_pg_timestamp_pl_interval`, `xq_pg_interval_mul` ...) |
| `jsonb - text`, `jsonb - integer`, `jsonb - text[]` | `xq_pg_jsonb_delete()`, `xq_pg_jsonb_delete_keys()` |

- 달 더하기는 PostgreSQL처럼 달, 날, 시간 순서이고 달의 마지막 날로 맞춥니다(`date '2024-01-31' + interval '1 month'`은 `2024-02-29 00:00:00`). 타임스탬프의 차는 날과 시간의 interval입니다(`justify_hours()`: `1 day 02:00:00`, `-1 days -02:00:00`). `interval * 수`·`/ 수`는 달의 나머지를 30일로, 날의 나머지를 시간으로 내립니다(`interval '1 month' / 2`는 `15 days`).
- interval은 PostgreSQL의 기본 출력 형식(`IntervalStyle` postgres)입니다: `1 day`, `1 day 02:00:00`, `-1 mons`, `3 years 2 mons`, `-1 days +01:00:00`.
- 피연산자 하나라도 타입을 모르면(SQLite 테이블의 열, 규칙이 없는 함수) 표를 보지 않고 SQLite의 연산입니다(오류 없음). 매개변수와 NULL은 문자열 상수처럼 어느 타입과도 맞지만 문장을 실패시키지 않고, 행이 정해지면 매개변수는 그 행의 타입을 받습니다(`ts + $1`의 `$1`은 `interval`). 문자열 상수끼리(`'1' + '2'`)도 SQLite의 연산입니다.
- `||`는 표에 없습니다(PostgreSQL의 `text || anynonarray`는 어느 타입이나 받으므로). jsonb의 `||`와 비교는 `overload.zig`의 따로 된 선택이고, jsonb `-`의 오른쪽이 표가 모르는 타입(SQLite 열, `int[]`)일 때도 그쪽이 고릅니다.
- 뷰, CHECK, 생성 열, 식 인덱스의 텍스트에는 고른 함수가 남습니다(`xq_pg_date_pli("d", 1)`). 어느 방언의 연결에서 읽어도 같은 뜻입니다.

### 함수

SQLite 내장 함수에 더해 다음을 지원합니다. 같은 이름의 SQLite 내장(`random()`, `floor()` 등)은 이 방언에서 가려집니다.

| 분류 | 함수 |
| --- | --- |
| 날짜·시각 | `now()`, `current_timestamp`, `localtimestamp`, `current_date`, `extract(field FROM x)`/`date_part`; 연산자는 위 [연산자 해석](#연산자-해석) |
| 문자열 특수 문법 | `substring(x FROM a FOR b)`, `position(a IN b)`, `trim([BOTH\|LEADING\|TRAILING] [c] FROM x)` |
| 문자열 | `strpos`, `left`/`right`, `concat`/`concat_ws`, `lpad`/`rpad`, `repeat`, `reverse`, `split_part`, `starts_with`, `btrim`, `char_length`, `ascii`/`chr` |
| 집계 | `string_agg`, `bool_and`/`bool_or`/`every` |
| 비교 | `greatest`/`least`(NULL은 건너뜀) |
| 수학 | `floor`, `ceil`, `sqrt`, `power`, `exp`, `ln`, `log`, `mod`, `trunc`, `sign`, `pi` |
| 난수·UUID | `random()`(0 이상 1 미만 실수), `gen_random_uuid()` |
| 시스템 | `version()`, `current_user`, `current_database()`, `current_schema`, `current_schemas(bool)`, `current_setting(name [, missing_ok])`, `set_config(name, value, false)`, `format_type(oid, typmod)`(와이어 서버가 알리는 타입 OID의 이름, psql의 `\gdesc`), `pg_backend_pid()`, `pg_is_in_recovery()`, `quote_ident`/`quote_literal`/`quote_nullable` |
| 카탈로그 | 아래 [카탈로그](#카탈로그)의 함수 |
| 시퀀스 | 시퀀스 함수(`nextval()` 등) |
| JSON | 아래 [JSON](#json) |

### JSON

`json`과 `jsonb`는 PostgreSQL 16과 같은 값을 냅니다. 둘 다 TEXT로 저장합니다.

| 타입 | 저장하는 텍스트 | 예 |
| --- | --- | --- |
| `json` | 입력 그대로(공백, 중복 키, 키 순서) | `'{"b":1,  "a":2}'::json` → `{"b":1,  "a":2}` |
| `jsonb` | 정규화한 텍스트: 키는 길이, 그다음 바이트 순서, 중복 키는 마지막 값, 수는 `numeric_out()` 철자(`1e2`는 `100`, `1.50`은 `1.50`), PostgreSQL의 공백 | `'{"b":1, "a":[1,2], "a":3}'::jsonb` → `{"a": 3, "b": 1}` |

- `::json`은 검사만 하고(`xq_pg_json()`), `::jsonb`는 정규화합니다(`xq_pg_jsonb()`). 입력 규칙은 PostgreSQL의 것입니다(RFC 8259, `jsonb`의 `\u0000`은 `unsupported Unicode escape sequence`). 잘못된 값은 `invalid input syntax for type json`입니다.
- `json`/`jsonb` 열은 CHECK `json_valid()`를 그대로 두고, INSERT·UPDATE·`ON CONFLICT DO UPDATE`가 넣는 값을 `jsonb` 열이면 정규화, `json` 열이면 검사합니다. 상수 DEFAULT는 CREATE TABLE 때 정규화해 SQLite 텍스트로 저장합니다. 선언 타입은 `xq_catalog`의 `type` 키에 `json`/`jsonb`로 남습니다.
- 피연산자 타입으로 정하는 것(`overload.zig`): `jsonb`의 `||`·`-`, `jsonb`의 `->`·`#>`(결과도 jsonb), `jsonb` 비교와 `ORDER BY`(아래), JSON을 만드는 함수의 인자(`json`/`jsonb`는 JSON으로, 불리언은 `true`/`false`로, 배열은 JSON 배열로, `double precision`·`real`·`numeric`은 PostgreSQL 철자의 수로: [PostgreSQL과 다른 점](#postgresql과-다른-점)의 JSON 수). 이름을 해석한 뒤 코어의 타입(`Expr.xq_type`)으로 고르므로 테이블 열, 서브쿼리·CTE·뷰의 열, 캐스트, 함수 결과 어디서 온 `jsonb`든 같습니다(`SELECT s.d || '{"b":2}' FROM (SELECT d FROM t) s`, 뷰의 jsonb 열 `||`). 타입을 모르는 쪽(문자열 상수, NULL, 타입 모르는 매개변수)은 다른 쪽 타입으로 읽습니다.
- 이름과 FROM 구조로 정하는 것(`jtype.zig`, 내리기 전): 값으로 쓴 FROM 항목은 그 행(`xq_pg_row_json('a', t.a, ...)`, 값의 JSON 변환은 위처럼 코어가), JSON 집합 반환 함수의 열 참조와 그 옆의 `*`, json/jsonb 열에 넣는 값(`xq_pg_jsonb()`/`xq_pg_json()`로 감쌈; 값이 이미 그 타입의 함수 결과면 코어가 감싼 것을 뺌).
- 스키마가 남기는 텍스트(뷰, CHECK, 생성 열, 식 인덱스, CTE 안 포함)에는 그 선택이 함수로 적힙니다(`ddltype.zig`가 같은 식을 해석만 해 보고 트리에 되돌림): `xq_pg_jsonb_concat(...)`, `COLLATE xq_pg_jsonb` ... 그래서 SQLite 방언이나 다른 방언에서 읽어도 같은 뜻이고, 이 방언에서 읽을 때 코어는 뷰·트리거의 텍스트에서 다시 고르지 않습니다(SQLite 방언으로 만든 뷰의 `||`는 이 방언에서도 텍스트 연결).

#### 연산자

| 연산자 | 뜻 | 엔진 함수 |
| --- | --- | --- |
| `->`, `->>` | 키(텍스트) 또는 인덱스(정수, 음수는 끝에서) | `xq_pg_json[b]_get[_text]` |
| `#>`, `#>>` | text[] 경로(`'{a,b,0}'`) | `xq_pg_json[b]_path[_text]` |
| `@>`, `<@` | 포함(최상위 배열은 스칼라 원소를 포함) | `xq_pg_jsonb_contains` |
| `?`, `?\|`, `?&` | 최상위 키 또는 문자열 원소의 존재 | `xq_pg_jsonb_exists[_any\|_all]` |
| `\|\|` | 객체 병합, 배열 연결(스칼라는 한 원소 배열) | `xq_pg_jsonb_concat` |
| `-` | 키(배열이면 같은 문자열 원소), 정수 인덱스, text[] 키 목록 | `xq_pg_jsonb_delete[_keys]` |
| `#-` | 경로 삭제 | `xq_pg_jsonb_delete_path` |
| `@?`, `@@` | jsonpath의 결과 존재, 술어(오류는 NULL/false) | `xq_pg_jsonb_path_exists_op`, `_match_op` |

- `json`의 `->`는 입력 텍스트의 그 부분을, `jsonb`의 `->`는 정규화한 텍스트를 돌려줍니다. `->>`는 문자열을 풀고 JSON `null`은 SQL NULL입니다.
- `jsonb`의 `=`/`<`/`>`와 `ORDER BY`, 집계 안의 `ORDER BY`는 collation `xq_pg_jsonb`로 PostgreSQL의 순서를 씁니다: Object > Array > Boolean > Number > String > Null, 원소·쌍이 많은 컨테이너가 크고, 같으면 차례로 비교. `'1.0'::jsonb = '1'`은 참입니다. 반대쪽의 문자열 상수는 jsonb로 읽습니다.
- `json`끼리의 `||`와 `=`는 PostgreSQL처럼 `operator does not exist: json || json`입니다.
- text[] 인자는 리터럴 `'{a,b}'`, `'{a,b}'::text[]`, `ARRAY['a','b']`입니다. `ARRAY[...]`와 `::text[]`(int[] 등도)는 배열의 텍스트 리터럴(`{a,b}`)입니다. 배열 타입 열은 여전히 없습니다.

#### 함수

| 분류 | 함수 |
| --- | --- |
| 만들기 | `to_json`, `to_jsonb`, `row_to_json(행 [, pretty])`, `array_to_json(배열 [, pretty])`, `json_build_object`, `jsonb_build_object`, `json_build_array`, `jsonb_build_array`, `json_object(text[] [, text[]])`, `jsonb_object` |
| 집계 | `json_agg`, `jsonb_agg`, `json_object_agg`, `jsonb_object_agg`(`DISTINCT`, `ORDER BY`, `FILTER`) |
| 처리 | `json[b]_typeof`, `json[b]_array_length`, `json[b]_extract_path[_text]`, `json[b]_strip_nulls`, `jsonb_set`, `jsonb_set_lax`, `jsonb_insert`, `jsonb_pretty` |
| jsonpath | `jsonb_path_exists`, `jsonb_path_match`, `jsonb_path_query`(집합), `jsonb_path_query_array`, `jsonb_path_query_first`(`vars`, `silent` 인자) |
| 집합 반환 | `json[b]_each[_text]`, `json[b]_array_elements[_text]`, `json[b]_object_keys`, `jsonb_path_query`, `json[b]_to_record[set](...) AS x(a int, ...)`, `json[b]_populate_record[set](NULL::table, ...)` |
| SQL/JSON | `IS [NOT] JSON [VALUE\|ARRAY\|OBJECT\|SCALAR] [WITH\|WITHOUT UNIQUE [KEYS]]`, `JSON_OBJECT(k : v \| k VALUE v ...)`, `JSON_ARRAY(v, ... \| query)`, `JSON_OBJECTAGG(k : v)`, `JSON_ARRAYAGG(v [ORDER BY])`; `NULL\|ABSENT ON NULL`, `WITH UNIQUE KEYS`, `RETURNING json\|jsonb`, `FORMAT JSON` |

- 출력 철자는 PostgreSQL의 것입니다: `json_build_object`·`JSON_OBJECT`는 `{"a" : 1, "b" : 2}`, `json_object_agg`는 `{ "a" : 1 }`, `row_to_json`은 `{"a":1,"b":"x"}`, 행이나 배열의 `json_agg`는 원소 사이에 줄바꿈, `jsonb_pretty`는 네 칸 들여쓰기.
- 행 값: FROM 항목의 이름(`row_to_json(t)`, `to_jsonb(t)`, `json_agg(t)`)은 그 열들로 펼친 `xq_pg_row_json('a', t.a, ...)`입니다.
- 집합 반환 함수는 FROM에서(별칭의 열 이름, `WITH ORDINALITY`, 앞 항목의 열을 인자로: `FROM t, jsonb_each(t.j)`, `CROSS JOIN LATERAL ...`) 그리고 select 목록에서(`SELECT id, jsonb_array_elements(j) FROM t`, 여러 개면 PostgreSQL처럼 나란히, 짧은 쪽은 NULL) 씁니다. 구현은 `xq_pg_rows_*()`가 만든 행 배열을 SQLite의 `json_each()`가 읽는 것이고, 열 참조는 `jtype.zig`가 그 식으로 바꿉니다.
- 레코드 열의 값은 문자열이면 푼 텍스트, 그 밖은 JSON 텍스트를 그 열의 타입으로 캐스트한 것입니다.

#### jsonpath

`lax`(기본)/`strict`, `$`, `@`, `$var`(`vars`), `.key`, `."key"`, `.*`, `[*]`, `[n]`, `[n to m]`, `[last]`, `[last - 1]`, 여러 첨자, `.**`, 필터 `? (...)`(`==`, `!=`/`<>`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `exists`, `starts with`, `like_regex`(플래그 `i`, `q`; `.`, `[...]`, `\d`, `^`, `$`, `|`, `*`, `+`, `?`, `{n,m}`), `is unknown`), 산술 `+ - * / %`(numeric처럼: `10 / 3`은 `3.3333333333333333`), 메서드 `type()`, `size()`, `double()`, `abs()`, `floor()`, `ceiling()`. 오류 문구는 PostgreSQL의 것입니다(`JSON object does not contain key "b"`, `jsonpath array subscript is out of bounds`, `syntax error at end of jsonpath input` ...).

#### GIN 인덱스

`CREATE INDEX ... USING gin (doc [jsonb_path_ops])`(그리고 `USING hash`)는 같은 열의 B-tree 인덱스로 만듭니다. 이름은 PostgreSQL과 같고(`g_doc_idx`) `pg_indexes`에 나옵니다. 인덱스가 이 열의 검색을 빠르게 하지는 않습니다: `@>`·`?`는 테이블을 훑고, jsonb의 `=`는 collation `xq_pg_jsonb`라 BINARY 인덱스를 쓰지 않습니다. `((doc ->> 'name'))` 같은 식 인덱스는 그 식에 쓰입니다. 단 식 인덱스·CHECK·생성 열·뷰의 JSON 연산자와 함수는 스키마에 `xq_pg_*`/`xq_postgres_*` 함수로 남으므로, sqlite3에서는 그런 인덱스가 있는 테이블에 쓰거나 그 뷰를 읽을 수 없습니다(열 자체와 `gin` 인덱스는 문제없음).

### 카탈로그

| 스키마 | 관계 |
| --- | --- |
| `information_schema` | `tables`, `columns`(`xq_catalog`의 PostgreSQL 선언 타입, identity 여부, 정수 열은 `integer`), `views`, `schemata`, `sequences`, `table_constraints`, `key_column_usage`, `referential_constraints`, `check_constraints` |
| `pg_catalog`(스키마 없이도 보임) | 스키마에서 만드는 것: `pg_namespace`, `pg_class`, `pg_attribute`, `pg_type`, `pg_index`, `pg_constraint`, `pg_attrdef`, `pg_sequence`, `pg_depend`(identity·serial 시퀀스의 소유), `pg_description`, `pg_proc`(내장 타입의 입출력 함수). 그 위의 뷰: `pg_tables`, `pg_views`, `pg_indexes`, `pg_sequences`. 상수: `pg_database`, `pg_roles`, `pg_authid`, `pg_user`, `pg_am`, `pg_tablespace`, `pg_collation`, `pg_language`, `pg_settings`(세션의 값). 빈 것: `pg_trigger`, `pg_policy`, `pg_inherits`, `pg_rewrite`, `pg_statistic_ext`, `pg_publication*`, `pg_extension`, `pg_enum`, `pg_range`, `pg_shdescription`, `pg_auth_members`, `pg_partitioned_table`, `pg_foreign_table`, `pg_matviews`, `pg_event_trigger` |

psql의 `\d`, `\dt`, `\di`, `\dv`, `\ds`, `\dn`, `\df`, `\dT`, `\l`, `\du`와 `\d 테이블`(열, 기본값, identity, 인덱스, CHECK, 외래 키, Referenced by), `\d 인덱스`, `\d 시퀀스`가 와이어 서버로 PostgreSQL 16과 같은 출력을 냅니다([서버](server.md#xqlite-serve)).

**만드는 법.** 스키마에서 만드는 관계는 엔진 테이블 값 함수(이름 있는 가상 테이블, `Hooks.engine_modules`의 `xq_pg_class` ...)이고, 뷰 텍스트가 열마다 PostgreSQL 타입으로 캐스트합니다(`relhasindex::boolean`이라 클라이언트에 `t`/`f`). 행은 스냅숏(`pgcatalog.zig`)에서 옵니다. 스냅숏은 각 데이터베이스의 메모리 스키마(`Table`, `Index`, 외래 키), 메모리의 카탈로그(선언 타입, identity, 제약 이름, 주석), `xq_sequence`, `sqlite_schema`의 SQL 텍스트(CHECK, 인덱스 식, 뷰)에서 한 번에 읽어 자기 아레나에 복사합니다. 연결은 마지막 스냅숏을 두고, 어느 데이터베이스의 스키마(쿠키·세대)도, 바뀐 행 수(`n_total_change`)도 그대로이면 다시 씁니다. 그래서 행마다 부르는 함수(`pg_table_is_visible()`, reg* 캐스트)도 문장마다 한 번 읽습니다. 뷰 텍스트를 키우는 대신 이렇게 한 이유: `pg_attribute`·`pg_constraint`·`pg_index`는 SQLite의 pragma로는 CHECK 텍스트, 제약 이름, INTEGER PRIMARY KEY의 인덱스, 식 인덱스, 정의 텍스트(`pg_get_constraintdef()`)를 모두 얻지 못하고, psql의 질의마다 여러 번 조인되는 관계를 pragma 질의의 합집합으로 만들면 느립니다. 파일에는 아무것도 쓰지 않으므로 DB는 SQLite 그대로이고, sqlite3와 SQLite 방언에는 `pg_class` 같은 이름이 없습니다(엔진 함수 `xq_pg_*`만 보임).

- 데이터베이스와 스키마: main은 `public`, `CREATE SCHEMA`의 스키마(`"sales.orders"`)는 `sales`, temp의 개체는 `pg_temp_1`, `ATTACH`한 데이터베이스는 그 이름의 스키마입니다. xqlite 자신의 테이블(`sqlite_*`, `xq_*`)은 없습니다.
- INTEGER PRIMARY KEY에도 PostgreSQL처럼 `<table>_pkey` 인덱스와 PRIMARY KEY 제약이 있습니다. UNIQUE·PRIMARY KEY의 자동 인덱스는 제약 이름(`t_b_c_key`, 사용자가 준 이름)입니다. 타입 검사용 CHECK(`integer out of range` ...)는 제약에 나오지 않습니다.
- `pg_attribute`의 타입은 선언 타입의 OID와 typmod(와이어 서버의 RowDescription과 같은 표)이고, SQLite가 만든 테이블은 `information_schema`처럼 `INTEGER`가 `bigint`입니다. 뷰의 열은 그 뷰를 이 방언으로 컴파일한 결과 열의 타입입니다.
- 기본값(`pg_attrdef.adbin`, `pg_get_expr()`)은 저장된 SQLite 텍스트를 PostgreSQL처럼 씁니다: `'x'::text`, `now()`, `false`, `nextval('t_id_seq'::regclass)`. CHECK·인덱스 식·뷰도 따옴표가 필요 없는 이름은 따옴표 없이(`CHECK ((length(b) > 1))`, `lower(b)`).
- 함수: `pg_get_userbyid()`, `pg_table_is_visible()`·`pg_type_is_visible()`(`search_path`대로), `pg_function_is_visible()` 등(참), `pg_get_expr()`, `pg_get_indexdef(oid [, n, pretty])`, `pg_get_constraintdef()`, `pg_get_viewdef()`, `pg_get_serial_sequence()`, `obj_description()`, `col_description()`, `shobj_description()`(NULL), `has_table_privilege()`·`has_schema_privilege()` ... ·`pg_has_role()`(참: 역할은 슈퍼유저 하나), `to_regclass()`·`to_regtype()`·`to_regnamespace()`·`to_regrole()`, `pg_encoding_to_char()`, `pg_size_pretty()`, `pg_table_size()` 등(0), `pg_typeof()`(값의 저장 형식으로: `integer`, `bigint`, `numeric`, `text` ...), `array_to_string()`(배열 리터럴), psql이 빈 관계에 부르는 `pg_get_triggerdef()`·`pg_partition_ancestors()` 등.
- `'t'::regclass`, `::regtype`, `::regnamespace`, `::regrole`은 이름(또는 숫자)을 `search_path`를 따라 OID로 읽습니다(`relation "x" does not exist`). 값은 OID라 `attrelid = 't'::regclass`처럼 비교하고, 질의의 결과 열이거나 `::text`로 캐스트하면 이름입니다(경로에서 찾을 수 없으면 `sales.orders`처럼 스키마를 붙임). `::regproc`은 함수 이름 텍스트입니다.
- psql의 철자: `OPERATOR(pg_catalog.=)`은 그 연산자, `COLLATE pg_catalog.default`, 세 부분 열 이름(`pg_catalog.pg_class.relname`).

**OID.** 내장 개체는 PostgreSQL의 OID입니다(`int4` 23, `text` 25, `pg_catalog` 11, `public` 2200, `pg_class` 1259 ...). 데이터베이스의 개체는 그것을 가리키는 이름(데이터베이스와 SQLite 이름, 제약은 테이블과 이름 ...)의 해시를 [16384, 2^31)에 놓은 수입니다. `xq_catalog`에 번호를 적는 방식 대신 이것을 고른 이유: 누가 만들었든(sqlite3, 다른 방언) 쓰기 없이 번호가 있고, 연결·재시작·VACUUM(`sqlite_schema`의 rowid를 다시 매김)·다른 개체의 생성과 삭제에도 바뀌지 않습니다(이름 순서 번호는 밀림). 한 카탈로그 안에서 해시가 겹치면 키 순서로 다음 빈 번호를 줍니다. 그래서 번호는 개체 집합의 함수이고, 겹친 개체가 생기거나 없어질 때만 다른 개체의 번호가 바뀝니다. 이름을 바꾸면 번호가 바뀝니다(PostgreSQL은 유지).

## 타입 매핑## 타입 매핑

| PostgreSQL | STRICT 저장 | 검사(이름이 PostgreSQL 메시지인 CHECK) |
| --- | --- | --- |
| `smallint`(`smallserial`) | `INTEGER` | 범위 → `smallint out of range` |
| `integer`(`serial`) | `INTEGER` | 범위 → `integer out of range` |
| `bigint`, `bigserial`, `oid` | `INTEGER` | |
| `real`, `double precision`, `float(p)` | `REAL` | |
| `numeric(p,s)`, `decimal` | `ANY` | 숫자만(`invalid input syntax for type numeric`). 문자열은 그 수로 읽어 넣음(아래) |
| `boolean` | `INTEGER` | 0/1만(`invalid input syntax for type boolean`). 문자열은 불리언 철자로 읽어 넣음(아래) |
| `text` | `TEXT` | |
| `varchar(n)`, `char(n)` | `TEXT` | `length() <= n`(`value too long for type character varying(n)`, `character(n)`) |
| `bytea` | `BLOB` | |
| `date`, `time`, `timestamp[tz]`, `interval` | `TEXT` | 넣는 문자열은 PostgreSQL이 읽고 쓰는 텍스트로(아래) |
| `uuid` | `TEXT` | |
| `json`, `jsonb` | `TEXT` | `json_valid()`; 넣는 값은 `json`이면 검사, `jsonb`이면 정규화([JSON](#json)) |

- 선언 타입은 `xq_catalog`의 `type` 키에 `format_type()` 철자(`character varying(20)`, `timestamp with time zone`)로 남습니다.
- 다른 타입의 값을 넣으면 SQLite STRICT 오류(`cannot store TEXT value in INTEGER column t.a`)가 납니다.
- `boolean`과 `numeric` 열에 넣는 문자열(상수, 텍스트로 바인딩한 매개변수, `INSERT ... SELECT`의 값)은 PostgreSQL이 그 타입의 입력을 읽듯 읽습니다: `'t'`, `'true'`, `'yes'`, `'on'`, `'1'`(그 접두어 `'tr'`, `'of'` ..., 대소문자·앞뒤 공백 무시)은 1/0, `' 1.50 '`은 수 1.5, `'3'`은 3. 아니면 `invalid input syntax for type boolean: "x"`/`invalid input syntax for type numeric: "x"`(22P02). `INSERT`와 `UPDATE`(`ON CONFLICT DO UPDATE` 포함)가 저장 직전에 바꿉니다([타입을 읽는 코드 생성](architecture.md#타입을-읽는-코드-생성)).
- `date`, `time`, `timestamp`, `timestamptz`, `interval` 열에 넣는 문자열도 그 타입의 입력으로 읽어 PostgreSQL의 출력 텍스트로 넣습니다: `'2024-1-5'`는 `2024-01-05`, `'2 hours'`는 `02:00:00`, `timestamptz`의 `'2024-01-01 10:00:00+02'`는 UTC의 `2024-01-01 08:00:00`. 읽지 못하면 `invalid input syntax for type date: "x"`(22007), 범위 밖의 필드는 `date/time field value out of range: "2024-02-30"`(22008). 텍스트는 그대로 sqlite3의 날짜 함수가 읽습니다.
- 배열과 모르는 타입은 `type "x" does not exist` 같은 오류입니다.

### 캐스트

| 캐스트 | xqlite | PostgreSQL과 다른 점 |
| --- | --- | --- |
| `::date`/`::time`/`::timestamp`/`::timestamptz`/`::interval` | `xq_pg_date()`/`xq_pg_time()`/`xq_pg_timestamp()`/`xq_pg_timestamptz()`/`xq_pg_interval()`: PostgreSQL의 입력(ISO 날짜, `T`나 공백 뒤의 시각, 오프셋, `BC`; interval의 단위·시각·`ago`·ISO 8601 `P1DT2H`; `now`, `today`, `tomorrow`, `yesterday`, `epoch`)을 읽어 그 출력으로(초의 소수는 끝의 0 없이: `03:04:05.5`). 읽지 못하면 오류 | `infinity`, 시간대 이름(`Asia/Seoul`), `DateStyle`이 바꾸는 입력·출력은 없음. `timestamptz`는 UTC. `::timetz`는 `time()` |
| `::smallint`/`::int`/`::bigint` | `xq_pg_int2/4/8()`: 실수는 0에서 먼 쪽으로 반올림, 문자열은 정수로 읽음(`'2.5'::int`는 `invalid input syntax for type integer`), 범위 밖은 `integer out of range` | |
| `::varchar(n)` | 자름 | |
| `::numeric(p,s)` | 반올림 | |
| `::boolean` | `'t'`/`'yes'`/`'on'` 같은 철자를 읽음 | |
| `::json`/`::jsonb` | `xq_pg_json()`/`xq_pg_jsonb()` | |
| `::text[]`(`int[]` 등) | `xq_pg_text_array()`: 검사한 배열 리터럴 텍스트 | 배열 값이 아니라 텍스트 |

## PostgreSQL과 다른 점

| 주제 | PostgreSQL | xqlite | 이유 |
| --- | --- | --- | --- |
| 불리언 | `true`/`false` | 정수 0/1. `SELECT true`는 `1`(SQLITE_INTEGER). 셸과 서버는 `boolean` 열과 불리언 식(`a = b`, `true`, `x IS NULL`)을 psql처럼 `t`/`f`로 보여 줌([값 표시](architecture.md#값-표시)). 뷰의 불리언 식 열은 1/0. 열에 넣는 문자열은 불리언 철자로 읽음(`'yes'`, `' off '`). PostgreSQL은 타입이 `text`인 식(텍스트 열, `'a' \|\| 'b'`)을 넣으면 오류이지만 xqlite는 그것도 읽음 | sqlite3 API로 돌아오는 결과의 타입을 바꿀 수 없음. 저장 값은 값의 타입이 아니라 실행 중 값이 문자열인지로 바꿈 |
| `numeric` | 고정 소수점 | SQLite 수(정수 또는 실수). API로는 `1.50`이 `1.5`. 셸과 서버는 `numeric(p,s)` 열, 캐스트(`x::numeric(6,2)`), 스케일을 아는 식(`1.50`, `n + 1`, `n * n`, `sum(n)`, `round(x, 2)`)을 그 자리수로 보여 줌(`1.50`, `0.1 + 0.2`는 `0.3`). PostgreSQL이 값마다 스케일을 정하는 나눗셈과 `avg()`는 `1.5`, `1.0`(PostgreSQL은 `1.5000000000000000`) | 저장 타입이 `ANY`. 넣는 문자열(상수, 텍스트로 바인딩한 값)은 수로 읽음(`'1.50'`은 1.5). `numeric(p,s)`에 넣는 값을 스케일 s로 반올림하지 않고, `'NaN'`·`'Infinity'`는 거부(SQLite에 NaN이 없음) |
| 식의 타입 | 연산자·함수 해석이 정함 | 같은 규칙으로 매김: `integer + integer`는 `integer`, `integer + bigint`는 `bigint`, `1`은 `integer`, `1.50`은 `numeric`, `'a'`는 `text`, `count()`·`sum(int)`은 `bigint`, `avg()`는 `numeric`, `now()`은 `timestamp with time zone`, `date + 1`은 `date`([코어의 타입](architecture.md#코어의-타입)). 결과 열의 선언 타입(`sqlite3_column_decltype()`, psql `\gdesc`의 철자), 값 표시, 매개변수의 타입, 정수 산술의 범위 검사(아래 정수 오버플로), 저장 시 변환(`boolean`, `numeric`, 날짜·시각)에 씀. 산술·비트 연산자는 연산자 표로 고르고([연산자 해석](#연산자-해석)), 그 밖에 피연산자 타입으로 고르는 것은 `jsonb` 연산자·비교·`ORDER BY`, interval의 비교·`ORDER BY`, JSON을 만드는 함수의 인자(`overload.zig`) | 함수 해석은 이름으로(인자 타입으로 오버로드를 고르지 않음) |
| NULL 정렬 | NULL이 가장 큰 값 | 같음(ASC면 마지막, DESC면 처음) | SQLite는 반대라 방언이 맞춤. NULL일 수 없는 열(NOT NULL, INTEGER PRIMARY KEY, 외부 조인의 NULL 쪽이 아닌 것)에는 붙이지 않아 인덱스 순서를 그대로 씀(그때 바이트코드는 SQLite와 같음) |
| `LIKE` | 대소문자 구분, 기본 이스케이프 `\` | 같음(엔진 함수 `xq_like()`). `ILIKE`는 ASCII 대소문자만 무시(`xq_ilike()`) | SQLite의 LIKE는 대소문자를 무시하고 기본 이스케이프가 없음 |
| identity·serial | 시퀀스 | 시퀀스 `<table>_<col>_seq`. 아래 [identity](#identity와-serial) | SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않음 |
| `now()`, `current_timestamp` | 시간대가 있는 타임스탬프 | 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음). 셸과 서버는 `timestamptz` 열에 `+00`을 붙여 보여 줌 | SQLite 날짜 함수가 그대로 읽음 |
| 날짜·시각 연산 | 세션 시간대로 계산 | 같은 결과(위 [연산자 해석](#연산자-해석)). `timestamptz`는 늘 UTC로 계산(`SET TIME ZONE`은 보여 주기만 함). 날짜와 타임스탬프의 비교는 ISO 텍스트의 비교(같은 타입끼리와 문자열 상수는 PostgreSQL과 같음; `timestamp = date`는 시각 `00:00:00`이 없는 텍스트라 다름). interval의 비교와 `ORDER BY`는 collation `xq_pg_interval`(한 달은 30일: `'1 mon' = '30 days'`). 그 collation은 jsonb의 것처럼 방언의 것이라, interval을 비교하는 뷰는 SQLite 방언에서 읽을 수 없음 | 저장은 sqlite3가 읽는 TEXT |
| 이름의 대소문자 | `"Foo"`와 `foo`는 다른 이름 | 접기는 하지만 같은 이름 | SQLite의 이름 비교는 대소문자를 구분하지 않음 |
| 오류 문구 | PostgreSQL 문구 | 싼 곳에서만 PostgreSQL 문구(아래 [오류](#오류)). 실행 중 제약 위반도 PostgreSQL 문구(첫 줄만, `DETAIL`은 없음) | |
| 0으로 나누기 | 오류 | 같음(`/`, `%`가 `division by zero`, 22012). 이 방언으로 컴파일한 문장에서만이고, sqlite3나 SQLite 방언에서 같은 뷰·CHECK를 계산하면 NULL | 엔진의 산술 정책(`Hooks.arith`) |
| 정수 오버플로 | int4·int2 연산도 오류 | 같음: 타입이 `integer`인 연산(`integer + integer`, 32비트 리터럴끼리의 `SELECT 2147483647 + 1`, 단항 `-`, `(-2147483647 - 1) / -1`)은 `integer out of range`, `smallint`끼리는 `smallint out of range`, `bigint`는 64비트를 넘으면 `bigint out of range`(모두 22003). 이 방언으로 컴파일한 문장에서만이고(뷰와 트리거 본문 포함), CHECK·생성 열의 식과 sqlite3·SQLite 방언에서는 64비트로 계산. 매개변수는 추론한 타입(`a + $1`의 `integer`)이라 클라이언트가 `int8`로 지정해도 `integer`로 검사 | 코드 생성이 연산의 P5에 폭을 적음([타입을 읽는 코드 생성](architecture.md#타입을-읽는-코드-생성)) |
| 복합 질의의 타입 | 항들의 타입을 맞추거나 실패(`UNION types boolean and integer cannot be matched`) | 공통 타입이 있으면 그 타입, 없으면 실패하지 않고 타입을 모름(값은 저장된 대로 보임) | |
| 외래 키 | 늘 강제 | 같음. 이 방언의 첫 문장에서 연결의 `PRAGMA foreign_keys`를 켬. 응용이 끈 것은 그대로 둠 | sqlite3는 여전히 끈 채로 씀 |
| 격리 수준 | 여러 수준 | 파싱만 함 | SQLite는 늘 직렬화 |
| JSON | `jsonb`는 이진 형식 | 정규화한 TEXT. `json`은 입력 텍스트 | sqlite3가 그대로 읽고 `json_extract()` 등을 씀. sqlite3가 넣은 값은 정규화되지 않은 채 남고(연산자·함수는 읽을 때 정규화), CHECK `json_valid()`는 SQLite의 규칙 |
| jsonb 비교 | jsonb의 순서 | 같음(collation `xq_pg_jsonb`). 인덱스는 BINARY라 `=`에 쓰이지 않음 | |
| JSON 수 | numeric과 float8 | 같음: 타입을 아는 인자는 JSON을 만드는 함수가 PostgreSQL 철자로 씀. `double precision`/`real`은 `float8out()`처럼 되읽히는 가장 짧은 자릿수, 지수가 -4~14면 고정 소수점, 아니면 두 자리 이상의 지수(`to_json(100.0::float8)`은 `100`, `1e20::float8`은 `1e+20`, `1e-5::float8`은 `1e-05`; `xq_pg_float_json()`), 스케일을 아는 `numeric`은 그 자릿수(`to_json(1.50)`은 `1.50`, `numeric(5,2)` 열의 2는 `2.00`; `xq_pg_numeric_json()`). `row_to_json`·`json_agg`의 열도 | 스케일을 모르는 numeric(`avg()`, 나눗셈)과 타입을 모르는 값은 SQLite 철자(`2.5`, `1.0e+20`) |
| 저장되는 식 | | IR이 SQLite 텍스트로 렌더링. PostgreSQL 함수는 `xq_postgres_greatest(...)`, LIKE는 `xq_like(...)`처럼 저장 | SQLite 방언이나 다른 방언의 연결에서 읽어도 같은 뜻. 단 sqlite3에서는 그런 식을 계산할 수 없음 |

저장되는 식은 CHECK, DEFAULT, 생성 열, 인덱스 식, 뷰입니다.

### identity와 serial

- `serial`과 `GENERATED ... AS IDENTITY`는 시퀀스 `<table>_<col>_seq`로 번호를 매깁니다(PostgreSQL과 같은 이름).
- 열은 `INTEGER NOT NULL DEFAULT (nextval('seq'))`이고, 키이면 SQLite의 INTEGER PRIMARY KEY(rowid)가 됩니다.
- `xq_catalog`에 `identity`/`identity_kind` 키가 남습니다.
- INSERT가 빠뜨린 identity 열(그리고 `DEFAULT`)은 공용 내림(`src/ir/lower.zig`)이 catalog의 `identity` 키를 보고 `nextval()`로 채웁니다. DEFAULT 텍스트에 기대지 않는 이유는 둘입니다.
  - SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않습니다.
  - `trusted_schema`가 꺼져 있으면 스키마의 `nextval()`은 unsafe use입니다.
- `GENERATED ALWAYS`는 명시한 값을 거부합니다(`cannot insert a non-DEFAULT value into column "id"`). `OVERRIDING SYSTEM VALUE`로 허용합니다.
- 테이블을 지우면 시퀀스도 지웁니다. `TRUNCATE ... RESTART IDENTITY`는 시퀀스를 다시 시작합니다.
- sqlite3에서 이 테이블에 키 없이 넣으면 rowid가 번호를 매깁니다.

### 결과 열 이름

PostgreSQL 규칙을 따릅니다: `?column?`, 함수 이름, 상수 캐스트면 `int4` 같은 타입 이름, `case`, `exists`.

### 오류

PostgreSQL 문구를 쓰는 오류입니다.

- `syntax error at or near "x"`, `syntax error at end of input`
- `relation "t" does not exist`, `column "c" does not exist`
- `column reference "a" is ambiguous`
- `relation "t" already exists`
- 스키마의 오류([스키마](#스키마))
- `cannot insert a non-DEFAULT value into column "id"`

실행 중 제약 위반도 PostgreSQL 문구와 SQLSTATE입니다. psql이 보여 주는 첫 줄(`ERROR:`)과 같고, 그 아래 `DETAIL` 줄(`Key (a)=(1) already exists.`)은 없습니다.

| 위반 | 메시지 | SQLSTATE |
| --- | --- | --- |
| UNIQUE, PRIMARY KEY, 유일 인덱스 | `duplicate key value violates unique constraint "t_a_key"` | 23505 |
| `CREATE UNIQUE INDEX`가 중복을 찾음 | `could not create unique index "i"` | 23505 |
| NOT NULL | `null value in column "a" of relation "t" violates not-null constraint` | 23502 |
| CHECK | `new row for relation "t" violates check constraint "t_a_check"` | 23514 |
| 타입 검사(위 [타입 매핑](#타입-매핑)) | `integer out of range` ... | 22003, 22001, 22P02 |
| 외래 키(자식 행) | `insert or update on table "t" violates foreign key constraint "t_b_fkey"` | 23503 |
| 외래 키(부모 행) | `update or delete on table "p" violates foreign key constraint "t_b_fkey" on table "t"` | 23503 |

- 제약 이름은 사용자가 준 이름(`CONSTRAINT x`, 인덱스 이름)이고, 없으면 PostgreSQL이 붙이는 이름입니다: `<table>_pkey`, `<table>_<columns>_key`, `<table>_<columns>_fkey`, `<table>_<column>_check`, `<table>_check`. 같은 이름이 겹칠 때 PostgreSQL이 붙이는 번호(`t_a_key1`)는 붙이지 않습니다.
- SQLite가 남기지 않는 UNIQUE, PRIMARY KEY, FOREIGN KEY의 이름은 CREATE TABLE이 `xq_catalog`에 적어 둡니다(키 `constraint:<종류>:<열>`). 그 뒤 RENAME COLUMN으로 열 이름이 바뀌면 기본 이름으로 돌아갑니다.
- 문장이 끝날 때 찾는 외래 키 위반(여러 행, 부모 행 지우기)은 마지막으로 센 위반의 제약을 말합니다. COMMIT에서 찾는 지연 제약(`DEFERRABLE INITIALLY DEFERRED`)은 어느 제약인지 모르므로 `insert or update violates foreign key constraint`입니다.
- 이 방언으로 컴파일한 문장에서만입니다. sqlite3나 SQLite 방언의 문장은 SQLite 문구(`UNIQUE constraint failed: t.a`)입니다.

## 아직 하지 않은 것

| 영역 | 항목 |
| --- | --- |
| 쿼리 | `DISTINCT ON`, `LATERAL` 서브쿼리, `GROUPING SETS`/`ROLLUP`/`CUBE`, `EXCEPT ALL`/`INTERSECT ALL`, `FETCH ... WITH TIES`, 테이블·함수 별칭의 열 이름 |
| DML | 데이터를 바꾸는 CTE, `ON CONFLICT ON CONSTRAINT`, `COPY` |
| 타입 | 배열 타입 열과 배열 연산(`ARRAY[...]`·`::text[]`은 텍스트 리터럴뿐), `ENUM`·`CREATE TYPE`·도메인, 시퀀스의 데이터 타입(언제나 `bigint`) |
| JSON | jsonpath `like_regex`의 POSIX 문자 클래스·역참조·플래그 `m`/`x`, `.**{n to m}`, `keyvalue()`, `datetime()`과 문자열 메서드; 복합 타입 인자의 `json_populate_record`(`NULL::table`만), `IS JSON`의 비텍스트 인자 오류, select 목록의 레코드 반환 함수(`json_each`), `WITH ORDINALITY`의 select 목록, `jsonb` 부분 쓰기 연산자(`j['a']`), GIN의 `@>`·`?` 인덱스 검색, sqlite3가 넣은 jsonb의 정규화, PostgreSQL 17의 `JSON_TABLE`/`JSON_VALUE`/`JSON_QUERY`/`JSON_EXISTS` |
| 식과 함수 | `SIMILAR TO`, 정규식의 역참조·POSIX 문자 클래스·`regexp_*` 함수, `AT TIME ZONE`, `to_char`/`date_trunc`/`age`/`justify_*`, `extract`의 interval, `U&'...'` |
| 날짜·시각 | `infinity`/`-infinity`, 세션 시간대(`timestamptz`는 UTC로만), `timetz`의 연산(표에 없어 SQLite의 연산), `sum()`/`avg()`의 interval(타입은 `interval`이지만 SQLite의 수 계산), `GROUP BY`/`DISTINCT`의 interval(텍스트로 같은 것끼리: 넣는 값은 정규화되므로 `'2 hours'`와 `'120 minutes'`는 같음, `'1 mon'`과 `'30 days'`는 다름), `timestamp`와 `date`의 비교, `interval '1' day`처럼 필드를 붙인 interval 리터럴(필드를 무시하고 `'1'`은 1초), 타임스탬프의 범위 294247년부터(PostgreSQL은 294276년까지), 타입을 아는 값(`now()`)을 `date` 열에 넣을 때의 변환(문자열만 읽음) |
| 연산자 해석 | `numeric`·실수와 만난 문자열 상수를 그 타입의 입력으로 읽기(정수만 읽음), `OPERATOR(schema.op)` 문법, 사용자 정의 연산자 |
| DDL | `ALTER TABLE`의 `ALTER COLUMN`·`ADD/DROP CONSTRAINT`·identity 열 추가, 한 문장으로 여러 개체 `DROP`(`DROP SCHEMA a, b`만 됨), 임시 테이블의 시퀀스(`main`에 남음), 붙인 데이터베이스 안의 `CREATE SEQUENCE` |
| 스키마 | 스키마 요소가 있는 `CREATE SCHEMA s CREATE TABLE ...`, `ALTER SCHEMA`, `ALTER TABLE ... SET SCHEMA`, `DROP SCHEMA public`, 이름에 `.`이 있는 스키마, 대소문자만 다른 두 스키마(SQLite의 이름 비교처럼 같은 이름), 다른 스키마의 뷰·외래 키가 기대는 것을 `CASCADE`가 따라 지우는 것, 여러 테이블을 지우는 `DROP SCHEMA ... CASCADE`의 auto_vacuum 데이터베이스(거부함), 상수가 아닌 `nextval(x)`의 `search_path`(이름 그대로 main에서 찾음), `public`에 이름이 `s.t`인 개체(스키마 `s`의 `t`와 겹침) |
| 절차·서버 | PL/pgSQL·`CREATE FUNCTION`·트리거, `LISTEN`/`NOTIFY`, `SET LOCAL`, `SET`의 트랜잭션 의미(롤백해도 남음), 격리 수준 |
| 오류 | 제약 위반·산술·저장 변환 밖의 실행 중 엔진 오류(SQLite 내장 함수가 내는 것 등)의 PostgreSQL 문구, 제약 위반의 `DETAIL` |
| 카탈로그 | 붙인 데이터베이스의 `information_schema`(`pg_catalog`에는 나옴), `pg_catalog`의 시스템 관계 자신(`pg_class`에 `pg_class`가 없음; `'pg_class'::regclass`는 1259), 시스템 열(`attnum < 0`), 시퀀스의 타입(`seqtypid` 언제나 `bigint`), 인덱스 방식(`USING gin`도 `btree`), `\d+ 테이블`(`unnest()`), 정규식 연산자·배열 문법이 들어가기 전의 `\d 이름`(psql이 `OPERATOR(pg_catalog.~)`, `array(...)`, `= any(...)`, 배열 첨자를 보냄), 드라이버의 배열 질의(SQLAlchemy의 `unnest(conkey)`, pgjdbc의 `_pg_expandarray`), `pg_get_viewdef()`의 줄 바꿈, `pg_typeof()`의 식 타입(값으로 정함), 크기 함수(0), `COMMENT ON`의 인덱스·시퀀스·스키마·함수 |
| 셸 | dollar-quote 문장 분할(셸은 SQLite 규칙으로 문장을 나눔) |

## 검증

| 도구 | 하는 일 |
| --- | --- |
| `src/dialect/postgres/test.zig` | 종단 테스트 |
| `xqt dialect-diff pg` + `tools/dialect/pg-cases.txt` | 실제 PostgreSQL과 차등 비교. 77개 케이스(JSON 33개, 시스템 카탈로그 1개)가 PostgreSQL 16과 같은 행·열 이름·오류를 냄(불리언 `t`/`f`는 1/0으로 맞춰 비교). 오류를 내는 문장은 따로 모은 케이스에 있음(psql의 stderr와 stdout이 podman을 거치며 섞이는 순서가 일정하지 않음) |
| `xqt wire-diff pg` + `tools/dialect/pg-wire-cases.txt`, `pg-client-cases.txt` | 와이어 서버(`xqlite serve --pg`)를 psql로 실제 PostgreSQL 16과 차등 비교. psql 출력 전체(메타 명령 `\d` 계열, `\gdesc`, `\bind`, 명령 태그, 오류와 NOTICE)를 비교하고, 다른 케이스를 result(조용히 다른 답)·error(거부)·format(표기만 다름)으로 나눔. `pg-client-cases.txt`는 node-postgres·knex·Sequelize·SQLAlchemy·Django·pgjdbc·asyncpg·Prisma가 실제로 보낸 카탈로그 질의(서버 로그에서 모음). 처음 잰 값은 129개 중 22개가 같음(result 11, error 89, format 7): psql의 `\d` 계열과 ORM의 카탈로그 질의는 거의 모두 `pg_am`·`pg_type`·`pg_attribute`·`pg_index`가 없거나 `OPERATOR(pg_catalog.~)`·`!~`·`= ANY($1)`·`schema.table.column` 참조를 못 읽어 거부됨 |
| `xqt wire-diff pg --regress` + `tools/dialect/pg-regress` | PostgreSQL 회귀 테스트 8개(`boolean`, `int2`, `int4`, `int8`, `text`, `varchar`, `case`, `strings`)를 와이어 서버에서 돌려 문장별 통과율을 잼. 처음 잰 값은 951개 중 431개(45.3%) |
| `xqt interop pg` | sqlite3 교차 검증. 이 방언으로 쓴 데이터베이스(`CREATE SCHEMA`의 테이블·뷰 포함)가 sqlite3 무결성 검사를 통과하고, sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 함. sqlite3의 `.tables`에 `sales.orders`가 나오고, sqlite3가 넣은 행을 이 방언이 `sales.orders`로 읽음. `jsonb` 열은 sqlite3의 `json_extract()`로 읽히고, sqlite3가 넣은 JSON을 이 방언의 연산자가 읽으며, sqlite3도 잘못된 JSON을 거부함 |

차등 비교는 PostgreSQL 컨테이너를 띄운 뒤 실행합니다(`$PG_PSQL`, 기본값 `podman exec -i xq-pg psql -U postgres`). 경우들은 병렬로 돌고, 작업자마다 자기 데이터베이스(`xqt_dialect_N`)에서 `public` 스키마를 지우고 다시 만들고, 앞 경우가 만든 스키마를 지운 뒤 시작합니다. 서버에 닿지 않으면 바로 실패하며 `zig build check`에는 들어 있지 않습니다. 둘 다 먼저 `zig build tools`가 필요합니다.

```sh
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
zig-out/bin/xqt dialect-diff pg
zig-out/bin/xqt wire-diff pg            # 와이어 서버 + psql ([테스트](testing.md#와이어-차등-테스트-postgresql))
zig-out/bin/xqt wire-diff pg --regress  # PostgreSQL 회귀 테스트 일부
zig-out/bin/xqt interop pg
```
