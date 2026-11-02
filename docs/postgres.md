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
| `json.zig` | json/jsonb 값: PostgreSQL 규칙의 파싱, jsonb 정규화와 출력, 비교·포함, jsonb의 정준 JSONB(`toBlob()`, `fromBlob()`)와 정렬 키(`appendKey()`). JSONB 노드 읽기·검사·텍스트는 방언 밖의 `dialect/jsonb.zig`(값 표시도 씀) |
| `jsonpath.zig` | jsonpath의 부분집합 |
| `jfuncs.zig` | JSON 연산자·함수·집계·집합 반환 함수의 구현 |
| `array.zig` | 배열 값(PostgreSQL의 텍스트: `{1,2,NULL}`)의 읽기·쓰기, 원소 타입의 입력·출력, 배열의 엔진 함수(캐스트와 저장, `ARRAY[...]`, `ANY`/`ALL`, 첨자, `unnest()`의 행 ...)와 방언 함수(`array_length()` ...), collation `xq_pg_array`/`xq_pg_array_num` |
| `typing.zig` | 식 타입의 규칙(`Hooks.typing`, [아키텍처](architecture.md)의 코어의 타입): 리터럴·연산자·함수의 결과 타입 |
| `operators.zig` | 연산자 표(`pg_operator`처럼 연산자, 피연산자 타입, 결과 타입, 구현)와 PostgreSQL 규칙의 연산자 해석(아래 [연산자 해석](#연산자-해석)) |
| `datetime.zig` | `date`/`time`/`timestamp[tz]`/`interval` 값의 PostgreSQL 입력·출력, 그 연산자의 엔진 함수(`xq_pg_date_pli()`, `xq_pg_iv_interval_pl()` ...)와 캐스트(`xq_pg_date()`, `xq_pg_iv()` ...), interval BLOB의 함수(`xq_pg_iv_key()`, `xq_pg_iv_sum()`, `justify_*()` ...), 예전 텍스트 interval의 함수와 collation `xq_pg_interval`. interval 값 자체(필드, 연산, BLOB 인코딩)는 방언 밖의 `src/dialect/interval.zig` |
| `overload.zig` | 피연산자 타입에 따른 선택(`Rules.overload`): 산술·비트 연산자를 연산자 표로, `jsonb`의 `\|\|`·비교·`ORDER BY`, interval의 비교·`ORDER BY`, `->`·`#>`의 json/jsonb 함수, JSON을 만드는 함수의 인자, 배열의 `\|\|`·비교·`ORDER BY`와 원소 타입을 알아야 하는 배열 함수(아래 [배열](#배열)). 이름을 해석한 코어가 부름 |
| `jtype.zig` | 파싱 뒤, 타입이 아니라 이름과 FROM 구조로 정하는 JSON: 값으로 쓴 FROM 항목(행), FROM의 JSON 집합 반환 함수 열과 그 옆의 `*`, json/jsonb 열에 저장하는 값의 정규화 |
| `ddltype.zig` | 스키마가 텍스트로 남기는 문장(뷰, CHECK, 생성 열, 식 인덱스)에 코어의 선택을 되돌려 씀: 식을 내리고 해석만 하는 probe |
| `session.zig` | `CREATE SCHEMA`/`DROP SCHEMA`, `SET`/`RESET`/`SHOW`, `COMMENT ON`, `set_config()`/`current_setting()`/`current_schema()`/`current_schemas()` |
| `state.zig` | 연결별 세션 상태(`search_path`와 그 밖의 매개변수, 시작 값, 카탈로그 스냅숏), 따르는 릴리스(18.6) |
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
| FROM | 테이블, 서브쿼리, `VALUES`, `generate_series()`, JSON 집합 반환 함수(아래 [JSON](#json)), `unnest()`·`generate_subscripts()`(아래 [배열](#배열)); 서브쿼리 별칭의 열 이름 `AS t(a, b)`; 함수 앞의 `LATERAL` |
| JOIN | `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL`, `ON`/`USING`, 괄호 조인 |
| 정렬 | `ORDER BY ... [ASC\|DESC] [NULLS FIRST\|LAST]` |
| 행 수 제한 | `LIMIT`/`OFFSET`/`LIMIT ALL`, `OFFSET n ROWS FETCH FIRST n ROWS ONLY` |
| 집합 연산 | `UNION`/`INTERSECT`/`EXCEPT`(INTERSECT가 먼저 묶임) |
| CTE | `WITH [RECURSIVE]`, `[NOT] MATERIALIZED` |
| 그 밖 | 단독 `VALUES`, `TABLE t`, `FOR UPDATE/SHARE`(무시), `SELECT ... INTO [TEMP] [TABLE] t`(`CREATE TABLE t AS`) |

### DML

- **INSERT**
  - 열 목록, 여러 행 `VALUES`와 `DEFAULT`, 열보다 적은 값
  - `INSERT ... SELECT`, `DEFAULT VALUES`
  - `OVERRIDING SYSTEM VALUE`
  - `ON CONFLICT (cols) [WHERE] DO NOTHING | DO UPDATE SET ... EXCLUDED.x [WHERE]`
- **UPDATE**: `SET a = ...`, `SET (a, b) = (...)`, `= DEFAULT`, `FROM`, 배열 원소 `SET a[i] = ...`
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
- 오류는 PostgreSQL 18과 같은 문구입니다: `schema "s" already exists`, `schema "s" does not exist`(DDL), `relation "s.t" does not exist`(질의), `unacceptable schema name "pg_x"`, `role "x" does not exist`, `no schema has been selected to create in`, `cannot create temporary relation in non-temporary schema`.
- `ATTACH`로 붙인 데이터베이스 안에서도 `CREATE`/`DROP`/`ALTER TABLE`, `CREATE INDEX`, `CREATE VIEW`를 씁니다(카탈로그 항목은 그 데이터베이스의 `xq_catalog`, identity 시퀀스는 main의 `xq_sequence`).

#### search_path

- `SET search_path TO a, b`, `SET search_path = DEFAULT`, `SET SCHEMA 'a'`, `RESET search_path`, `SHOW search_path`, `set_config('search_path', ..., false)`, `current_setting('search_path')`. 기본값은 `"$user", public`이고 `$user`는 `postgres`입니다.
- 한정하지 않은 이름은 `pg_temp`(임시 개체), 그다음 `search_path`의 스키마 순서로 찾습니다. 경로에 없으면 `relation "t" does not exist`입니다. `WITH` 질의의 이름은 찾지 않습니다.
- DDL은 경로에서 처음으로 있는 스키마(`current_schema()`)에 만듭니다. 그런 스키마가 없으면 `no schema has been selected to create in`입니다.
- `current_schema()`(`current_schema`), `current_schemas(bool)`(`{pg_catalog,public}` 같은 텍스트)는 경로에서 있는 스키마를 보여 줍니다.
- 이름은 문장을 컴파일할 때 정해집니다. `search_path`를 바꾸면 준비된 문장이 만료되어, 다음 실행 때 새 경로로 다시 컴파일됩니다.
- `SET`은 이 밖에 드라이버가 연결할 때 쓰는 매개변수(`application_name`, `client_encoding`, `client_min_messages`, `DateStyle`, `IntervalStyle`, `TimeZone`, `extra_float_digits`, `standard_conforming_strings`, `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, `bytea_output`, `default_transaction_isolation`, `transaction_isolation`, `transaction_read_only`, `lc_messages` ... 40여 개)를 받아 `SHOW`가 그 값을 보여 줍니다(동작은 바꾸지 않음). `SET TIME ZONE 'UTC' | LOCAL | INTERVAL '+00:00' HOUR TO MINUTE`도 됩니다. 모르는 이름은 `unrecognized configuration parameter "x"`입니다. `RESET ALL`, `SET TRANSACTION ...`(무시)도 됩니다.
- 읽기 전용: `server_version`(`18.6 (xqlite)`), `server_version_num`(`180006`), `server_encoding`, `integer_datetimes`, `is_superuser`, `in_hot_standby`, `max_identifier_length`, `block_size`, `lc_collate`, `lc_ctype` .... `SET`하면 `parameter "server_version" cannot be changed`(55P02)입니다. `version()`은 `PostgreSQL 18.6 (xqlite 3.54.1)`입니다.
- `SHOW`의 열 이름은 PostgreSQL의 철자(`DateStyle`, `TimeZone`)이고, `SHOW TRANSACTION ISOLATION LEVEL`(`read committed`), `SHOW SESSION AUTHORIZATION`, `SHOW ALL`(`pg_settings`의 이름·값·설명)도 됩니다. `transaction_isolation`은 PostgreSQL의 기본값 `read committed`를 보여 줍니다(실제로는 SQLite의 직렬화).
- 와이어 서버가 시작 패킷의 값(`application_name`, `options`)을 정하면 `RESET`은 기본값이 아니라 그 값으로 돌아갑니다(`xq_pg_startup_setting()`). `current_database()`는 클라이언트가 준 데이터베이스 이름이고 서버 밖에서는 `postgres`입니다.

### 식과 연산자

| 영역 | 지원 |
| --- | --- |
| 캐스트 | `::type`, `CAST`, 타입 리터럴(`DATE '2024-01-01'`) |
| NULL·진리값 | `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN` |
| 술어 | `BETWEEN`, `IN (목록\|서브쿼리)`, `x op ANY\|SOME\|ALL (배열\|서브쿼리)`(`= <> < <= > >=`, `[NOT] LIKE`, `[NOT] ILIKE`), `EXISTS` |
| 패턴 | `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE`, 정규식 `~`/`~*`/`!~`/`!~*`(`xq_pg_regex()`, `regex.zig`의 POSIX 확장 정규식 부분집합: 어디서든 맞으면 참) |
| 날짜·시각 | `date ± integer`, `date - date`, `date ± interval`, `date + time`, `timestamp[tz] ± interval`, `timestamp[tz] - timestamp[tz]`, `time ± interval`, `time - time`, `interval ± interval`, `-interval`, `interval * 수`, `interval / 수`(아래 [연산자 해석](#연산자-해석)) |
| JSON | `->`, `->>`, `#>`, `#>>`, `@>`, `<@`, `?`, `?\|`, `?&`, jsonb의 `\|\|`, `-`, `#-`, `@?`, `@@`, `IS [NOT] JSON` (아래 [JSON](#json)) |
| 배열 | `ARRAY[...]`, `ARRAY(서브쿼리)`, `a[i]`, `a[i][j]`, `a[lo:hi]`, `\|\|`, `@>`, `<@`, `&&`, 비교와 `ORDER BY`(아래 [배열](#배열)) |
| 그 밖 | `CASE`, 행 값, `(레코드).필드`(`_pg_expandarray()`의 `x`, `n`), `\|\|`(피연산자가 NULL이면 NULL) |
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
| 정수(`smallint`/`integer`/`bigint`의 모든 쌍, 넓은 쪽), `real`, `double precision`의 `+ - * /`; 같은 타입의 `%`(실수의 `%`는 없음); 단항 `-`; 정수의 `& \|`와 `<< >>`(오른쪽 `integer`) | 엔진의 연산 코드(SQLite의 바이트코드). 문자열 상수는 그 정수 타입으로 읽음(`xq_pg_int4('a')`: `'a' + 1`은 `invalid input syntax for type integer: "a"`) |
| `numeric`의 `+ - * / %`, 단항 `-` | `xq_dec_add()` ... `xq_dec_neg()`: 정확한 키([numeric](#numeric)) |
| `date ± integer` → `date`, `date - date` → `integer`, `date ± interval`·`date + time` → `timestamp`, `timestamp[tz] ± interval` → 같은 타입, `timestamp[tz] - timestamp[tz]` → `interval`, `time ± interval` → `time`, `time - time`, `interval ± interval`, `-interval`, `interval * double precision`, `interval / double precision` → `interval`(교환한 행 포함) | `datetime.zig`의 엔진 함수 `xq_pg_<PostgreSQL 구현 이름>`(`xq_pg_date_pli`, `xq_pg_timestamp_pl_interval`, `xq_pg_interval_mul` ...) |
| `jsonb - text`, `jsonb - integer`, `jsonb - text[]` | `xq_pg_jsonb_delete()`, `xq_pg_jsonb_delete_keys()` |

- 달 더하기는 PostgreSQL처럼 달, 날, 시간 순서이고 달의 마지막 날로 맞춥니다(`date '2024-01-31' + interval '1 month'`은 `2024-02-29 00:00:00`). 타임스탬프의 차는 날과 시간의 interval입니다(`justify_hours()`: `1 day 02:00:00`, `-1 days -02:00:00`). `interval * 수`·`/ 수`는 달의 나머지를 30일로, 날의 나머지를 시간으로 내립니다(`interval '1 month' / 2`는 `15 days`).
- interval은 PostgreSQL의 기본 출력 형식(`IntervalStyle` postgres)입니다: `1 day`, `1 day 02:00:00`, `-1 mons`, `3 years 2 mons`, `-1 days +01:00:00`, `infinity`/`-infinity`.
- interval 연산은 PostgreSQL 18의 것입니다: 무한의 규칙(`infinity + 1 day`는 `infinity`, `infinity - infinity`와 `infinity * 0`은 `interval out of range`, `time + infinity`는 `cannot add infinite interval to time`), 필드가 넘치면 `interval out of range`, 곱셈·나눗셈의 반올림은 `rint()`(짝수 쪽).
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
| 집계 | `string_agg`, `bool_and`/`bool_or`/`every`, `array_agg`(윈도우 함수로도) |
| 배열 | 아래 [배열](#배열) |
| 비교 | `greatest`/`least`(NULL은 건너뜀) |
| 수학 | `floor`, `ceil`, `sqrt`, `power`, `exp`, `ln`, `log`, `mod`, `trunc`, `sign`, `pi` |
| 난수·UUID | `random()`(0 이상 1 미만 실수), `gen_random_uuid()`, `uuidv4()`, `uuidv7([shift interval])`, `uuid_extract_version()`, `uuid_extract_timestamp()`(아래 [uuid](#uuid)) |
| 시스템 | `version()`, `current_user`, `current_database()`, `current_schema`, `current_schemas(bool)`, `current_setting(name [, missing_ok])`, `set_config(name, value, false)`, `format_type(oid, typmod)`(와이어 서버가 알리는 타입 OID의 이름, psql의 `\gdesc`), `pg_backend_pid()`, `pg_is_in_recovery()`, `quote_ident`/`quote_literal`/`quote_nullable` |
| 카탈로그 | 아래 [카탈로그](#카탈로그)의 함수 |
| 시퀀스 | 시퀀스 함수(`nextval()` 등) |
| JSON | 아래 [JSON](#json) |

### uuid

`uuid`는 16바이트 BLOB으로 저장합니다(`src/dialect/postgres/uuid.zig`). PostgreSQL의 uuid 순서(`uuid_cmp()`)는 바이트 순서이므로 SQLite의 BLOB 비교(memcmp)가 곧 PostgreSQL의 순서입니다. 그래서 인덱스, 범위 검색, `ORDER BY`, `PRIMARY KEY`/`UNIQUE`/외래 키가 값 그대로 동작하고, `uuidv7()` 키는 시간 순서라 인덱스에 거의 끝에만 붙습니다.

- 입력은 PostgreSQL의 `uuid_in()`과 같습니다: 16진수 32자리(대소문자 무관), 네 자리마다(마지막 뒤 말고) 하이픈 하나를 둘 수 있음, 전체를 `{}`로 감쌀 수 있음, 공백은 없음. 아니면 `invalid input syntax for type uuid: "x"`(22P02). 출력은 소문자의 `8-4-4-4-12`입니다.
- 열에 넣는 값(상수, 텍스트·이진으로 바인딩한 매개변수, `INSERT ... SELECT`의 값)은 저장 함수 `xq_pg_uuid()`가 16바이트로 바꿉니다. 열의 CHECK `length(u) = 16`(이름 `invalid input syntax for type uuid`)은 다른 BLOB을 막습니다. `DEFAULT '...'`은 CREATE TABLE에서 읽어 `X'..'`로 남고, `DEFAULT gen_random_uuid()`는 `xq_postgres_uuidv4()`입니다.
- 캐스트: `'...'::uuid`는 `xq_pg_uuid('...')`(상수라 한 번 계산), `u::text`와 `u || 'x'`, `concat()`·`format()`의 인자, JSON을 만드는 함수의 인자(`to_json(u)`는 `"a0eebc99-..."`), 배열의 원소(`ARRAY[u]`, `array_agg(u)`, `u = ANY(arr)`)는 그 텍스트(`xq_pg_uuid_text()`)입니다. `uuid[]`는 다른 배열처럼 원소의 텍스트로 저장합니다.
- 비교(`=`, `<` ..., `IN`, `BETWEEN`)는 문자열 상수와 매개변수를 열의 형태로 바꿉니다(`u = xq_pg_uuid('...')`, `u = xq_pg_uuid($1)`). 열은 그대로 두므로 인덱스를 씁니다. 뷰·CHECK·식 인덱스의 텍스트에도 그 함수가 남습니다.
- 셸과 와이어 서버는 텍스트로 보여 줍니다([값 표시](architecture.md#값-표시)). 와이어의 열 OID는 2950, 이진 형식은 16바이트(결과와 매개변수), API로 돌아오는 값은 16바이트 BLOB입니다.
- **예전 테이블**: uuid를 TEXT로 저장하던 때에 만든 테이블의 열(선언 타입 `uuid`, 저장 `TEXT`)은 그 표현을 유지합니다. 열마다 저장 타입으로 정합니다: 넣는 값은 `xq_pg_uuid_text()`가 정규 텍스트로 바꾸고(`Rules.store_text`), 비교는 상수를 텍스트로 바꿔(`u = xq_pg_uuid_text('...')`) 그 열의 인덱스를 씁니다. 텍스트 열과 BLOB 열의 비교(`old.u = new.u`)는 BLOB 쪽을 텍스트로 바꿔 맞습니다. 새 테이블(`ALTER TABLE ADD COLUMN` 포함)은 BLOB입니다.
- PostgreSQL 18의 함수:
  - `gen_random_uuid()`와 `uuidv4()`: 무작위 버전 4. 파서가 `gen_random_uuid()`를 `uuidv4()`로 부릅니다. 예전 스키마의 `xq_postgres_gen_random_uuid()`는 뜻 그대로(36자 텍스트) 남습니다.
  - `uuidv7([shift interval])`: 앞 48비트가 Unix 밀리초, 다음 12비트가 밀리초 안의 1/4096(RFC 9562의 방법 3), 나머지가 무작위인 버전 7. PostgreSQL처럼 연결(세션)마다 시계가 호출마다 적어도 1/4096밀리초 앞으로 가므로(`get_real_time_ns_ascending()`) 한 연결이 만든 값은 순서대로입니다. `shift`는 `timestamptz + interval`처럼 더하고, 1970년 전이나 48비트 밖이면 `timestamp out of range for UUID version 7`(22008). 확장을 올린 sqlite3도 연결마다 그 시계를 둡니다.
  - `uuid_extract_version(u)`: 버전(`smallint`), RFC 9562 변형이 아니면 NULL.
  - `uuid_extract_timestamp(u)`: 버전 1과 7의 시각(`timestamptz`), 그 밖은 NULL.
  - `gen_random_uuid()`와 `uuidv7()`은 결정적이지 않으므로 인덱스·CHECK에는 쓸 수 없고 DEFAULT에는 씁니다.

### JSON

`json`과 `jsonb`는 PostgreSQL 18과 같은 값을 냅니다. `json`은 TEXT로, `jsonb`는 SQLite 고유의 JSONB(SQLite 3.45+의 이진 JSON, `jsonb()`가 만드는 것)로 저장합니다.

| 타입 | 저장하는 것 | 예 |
| --- | --- | --- |
| `json` | 입력 그대로의 TEXT(공백, 중복 키, 키 순서) | `'{"b":1,  "a":2}'::json` → `{"b":1,  "a":2}` |
| `jsonb` | 정규화한 값의 JSONB BLOB: 키는 길이, 그다음 바이트 순서, 중복 키는 마지막 값, 수는 `numeric_out()` 철자(`1e2`는 `100`, `1.50`은 `1.50`). 보이는 것은 PostgreSQL의 텍스트(공백 포함) | `'{"b":1, "a":[1,2], "a":3}'::jsonb` → `{"a": 3, "b": 1}` |

- `::json`은 검사만 하고(`xq_pg_json()`), `::jsonb`는 정규화합니다(`xq_pg_jsonb()`). 입력 규칙은 PostgreSQL의 것입니다(RFC 8259, `jsonb`의 `\u0000`은 `unsupported Unicode escape sequence`). 잘못된 값은 `invalid input syntax for type json`입니다.
- `json` 열은 TEXT와 CHECK `json_valid()`, `jsonb` 열은 BLOB과 CHECK `json_valid(j, 8)`(JSONB인 BLOB)입니다. INSERT·UPDATE·`ON CONFLICT DO UPDATE`가 넣는 값은 `json` 열이면 검사하고(`jtype.zig`), `jsonb` 열이면 저장 변환(`Rules.store`)이 열의 저장 타입대로 바꿉니다: BLOB 열은 정준 JSONB(`xq_pg_jsonb_bin()`), 이 저장 방식 전에 만든 데이터베이스의 TEXT 열은 지금처럼 정규화한 텍스트(`xq_pg_jsonb_text()`). 상수 DEFAULT는 CREATE TABLE 때 JSONB BLOB 리터럴(`X'...'`)로, 상수가 아닌 DEFAULT와 생성 열은 `xq_pg_jsonb_bin(...)`으로 적습니다. 선언 타입은 `xq_catalog`의 `type` 키에 `json`/`jsonb`로 남습니다.
- 정준 JSONB: 값 하나에 바이트열 하나라서 같은 값은 같은 바이트(UNIQUE, `GROUP BY`, `DISTINCT`가 memcmp로 맞음). 노드마다 가장 작은 헤더, null/true/false, 수는 소수점이 없으면 INT 있으면 FLOAT(지수 없이 `numeric_out()`의 자릿수), 문자열은 이스케이프할 것이 없으면 TEXT 있으면 TEXTRAW(문자 그대로), 객체는 jsonb의 키 순서(`json.zig`의 `toBlob()`). sqlite3 자신의 함수(`jsonb()`, `json_set()` ...)가 쓴 JSONB는 정준이 아닐 수 있습니다(TEXTJ·TEXT5 문자열, JSON5 수, 쓴 순서의 키, 중복 키, 큰 헤더). 연산자와 함수는 그런 값을 읽을 때 정규화하고(`fromBlob()`), 결과는 정준 JSONB입니다. 표시는 저장된 그대로(키 순서, 수의 철자)이고, 그런 값과 정준 값은 바이트가 달라 UNIQUE·`GROUP BY`·`DISTINCT`에서 다른 값입니다(비교 연산자는 같음). `UPDATE t SET j = j`로 정준이 됩니다.
- 표현: jsonb 값이 들어 있는 곳에 따라 BLOB(열에서 온 값과 그 연산자·함수의 결과)이거나 TEXT(상수의 캐스트 `'...'::jsonb`, `to_jsonb()`·`jsonb_build_object()`·`jsonb_agg()` 같은 만드는 함수의 결과, `jsonb[]`의 원소, 예전 TEXT 열)입니다. 엔진 함수는 둘 다 받고, jsonb 인자 중 하나가 JSONB BLOB이면 jsonb 결과도 BLOB입니다(그래서 예전 스키마의 식은 같은 텍스트를 냄). 셸, 와이어 서버(텍스트 형식, 이진 형식은 버전 바이트 1과 텍스트), `jsonb::text`(`xq_pg_jsonb_text()`), `concat()`·`format()`, `jsonb || text`, 배열의 원소는 BLOB의 텍스트를 씁니다(`api/display.zig`의 `textAlloc()`).
- 피연산자 타입으로 정하는 것(`overload.zig`): `jsonb`의 `||`·`-`, `jsonb`의 `->`·`#>`(결과도 jsonb), `jsonb` 비교와 `ORDER BY`(아래), 첨자 `j['a'][0]`(`#>`의 경로, 읽기만), JSON을 만드는 함수의 인자(`json`/`jsonb`는 JSON으로, 불리언은 `true`/`false`로, 배열은 JSON 배열로, `double precision`·`real`·`numeric`은 PostgreSQL 철자의 수로: [PostgreSQL과 다른 점](#postgresql과-다른-점)의 JSON 수). 이름을 해석한 뒤 코어의 타입(`Expr.xq_type`)으로 고르므로 테이블 열, 서브쿼리·CTE·뷰의 열, 캐스트, 함수 결과 어디서 온 `jsonb`든 같습니다(`SELECT s.d || '{"b":2}' FROM (SELECT d FROM t) s`, 뷰의 jsonb 열 `||`). 타입을 모르는 쪽(문자열 상수, NULL, 타입 모르는 매개변수)은 다른 쪽 타입으로 읽습니다.
- 이름과 FROM 구조로 정하는 것(`jtype.zig`, 내리기 전): 값으로 쓴 FROM 항목은 그 행(`xq_pg_row_json('a', t.a, ...)`, 값의 JSON 변환은 위처럼 코어가), JSON 집합 반환 함수의 열 참조와 그 옆의 `*`, json 열에 넣는 값(`xq_pg_json()`로 감쌈; 값이 이미 json인 함수 결과면 코어가 감싼 것을 뺌).
- 스키마가 남기는 텍스트(뷰, CHECK, 생성 열, 식 인덱스, CTE 안 포함)에는 그 선택이 함수로 적힙니다(`ddltype.zig`가 같은 식을 해석만 해 보고 트리에 되돌림): `xq_pg_jsonb_concat(...)`, `xq_pg_jsonb_key(j) = xq_pg_jsonb_key(...)`, `CAST(xq_pg_jsonb_text(j) AS TEXT)` ... 그래서 SQLite 방언이나 다른 방언에서 읽어도 같은 뜻이고, 이 방언에서 읽을 때 코어는 뷰·트리거의 텍스트에서 다시 고르지 않습니다(SQLite 방언으로 만든 뷰의 `||`는 이 방언에서도 텍스트 연결).

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

- `json`의 `->`는 입력 텍스트의 그 부분을, `jsonb`의 `->`는 정규화한 값을 돌려줍니다(JSONB 값이면 그 노드의 바이트를 그대로: 키만 읽어 찾고 정준이면 복사만 함). `->>`는 문자열을 풀고 JSON `null`은 SQL NULL입니다.
- `jsonb`의 `=`/`<>`/`<`/`>`, `IN`, `BETWEEN`, `ORDER BY`(집계·윈도우 안 포함)는 PostgreSQL의 순서인 정렬 키를 비교합니다(`xq_pg_jsonb_key()`, `Rules.order_key`): Object > Array > Boolean > Number > String > Null, 원소·쌍이 많은 컨테이너가 크고, 같으면 차례로 비교, 맨 위의 빈 배열은 어느 값보다 작음. 키는 BLOB이고 그 바이트 순서(memcmp)가 jsonb의 순서라 SQLite의 비교와 정렬이 그대로 씁니다(collation은 TEXT에만 걸리므로 JSONB BLOB에 쓸 수 없음). 수는 값으로 같아서 `'1.0'::jsonb = '1'`은 참입니다. 반대쪽의 문자열 상수는 jsonb로 읽습니다. 키 인코딩은 파일 형식의 일부라 바뀌지 않습니다(`json.zig`의 `appendKey()`). 복합 질의(`UNION` ...)의 `ORDER BY`는 항이 열이어야 해서 키 함수를 씌울 수 없으므로 collation `xq_pg_jsonb`를 씁니다: TEXT 값은 jsonb의 순서, JSONB BLOB은 바이트 순서(밖에서 `SELECT ... FROM (복합) s ORDER BY x`로 감싸면 jsonb의 순서). 예전 스키마의 collation `xq_pg_jsonb`(TEXT의 jsonb 순서)는 그대로 등록되어 있습니다.
- `json`끼리의 `||`와 `=`는 PostgreSQL처럼 `operator does not exist: json || json`입니다.
- text[] 인자는 리터럴 `'{a,b}'`, `'{a,b}'::text[]`, `ARRAY['a','b']`, text[] 열입니다(아래 [배열](#배열)). `array_to_json()`과 JSON을 만드는 함수는 타입을 아는 배열의 원소를 그 타입대로 씁니다(`int[]`는 수, `boolean[]`은 `true`/`false`).

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

`CREATE INDEX ... USING gin (doc [jsonb_path_ops])`(그리고 `USING hash`)는 같은 열의 B-tree 인덱스로 만듭니다. 이름은 PostgreSQL과 같고(`g_doc_idx`) `pg_indexes`에 나옵니다. 인덱스가 이 열의 검색을 빠르게 하지는 않습니다: `@>`·`?`는 테이블을 훑고, jsonb의 `=`는 정렬 키(`xq_pg_jsonb_key()`)의 비교라 열의 인덱스를 쓰지 않습니다(`((xq_pg_jsonb_key(doc)))`의 식 인덱스는 쓸 수 있음). 열 자체는 평범한 sqlite3가 `json()`, `json_extract()`, `->>`로 읽습니다. `((doc ->> 'name'))` 같은 식 인덱스는 그 식에 쓰입니다. 단 식 인덱스·CHECK·생성 열·뷰의 JSON 연산자와 함수는 스키마에 `xq_pg_*`/`xq_postgres_*` 함수로 남으므로, 평범한 sqlite3에서는 그런 인덱스가 있는 테이블에 쓰거나 그 뷰를 읽을 수 없습니다(열 자체와 `gin` 인덱스는 문제없음). [확장](extension.md)을 올린 sqlite3는 같은 결과로 계산합니다.

### 배열

배열 값은 PostgreSQL이 그 배열을 쓰는 텍스트(`array_out()`)입니다: `{1,2,NULL}`, `{"a b",c}`, `{{1,2},{3,4}}`, 하한이 1이 아니면 앞에 범위(`[0:1]={1,2}`). 원소 타입은 코어의 타입입니다(`Expr.xq_type`의 `Type`: `logical = .array`와 `Type.element`, [아키텍처](architecture.md#코어의-타입)). 카탈로그의 `int2vector`·`oidvector`도 PostgreSQL의 텍스트(`1 2`, 하한 0)입니다.

- 이 표현을 고른 이유: 와이어 프로토콜의 텍스트 형식, psql, 값 표시, 카탈로그가 이미 이 텍스트이고, sqlite3에서도 그대로 텍스트로 읽히며, `array_to_json()`으로 JSON이 됩니다. 원소 타입은 값에 없고 식의 타입에 있으므로, 원소 타입을 알아야 하는 엔진 함수(첨자, `ANY`, `unnest()`)에는 `overload.zig`가 원소 타입을 정수 인자(`array.Code`)로 덧붙입니다.
- 타입의 배열 입력(캐스트 `'{ 1, 01}'::int[]`, 배열 열에 넣는 값)은 원소마다 그 타입의 입력으로 읽고 출력으로 씁니다: `{1,1}`, `'{yes}'::bool[]`은 `{t}`, `'{1.50,1e2}'::numeric[]`은 `{1.50,100}`, `'{1.0,1e20}'::float8[]`은 `{1,1e+20}`, 날짜·시각·interval·uuid·jsonb도 그 타입의 정규 텍스트. 그래서 같은 타입의 두 배열은 텍스트가 같으면 같은 값입니다. 읽지 못하면 PostgreSQL의 오류: `malformed array literal: "{1,2"`(22P02), `invalid input syntax for type integer: "a"`, `value "70000" is out of range for type smallint`, `date/time field value out of range: "2024-02-30"`.
- 원소 타입을 모르는 곳(뷰의 텍스트 안에서 원소 타입을 덧붙이지 않은 호출, 타입 모르는 매개변수)에서는 원소를 적힌 대로 두고 값으로 비교합니다(수와 수, 텍스트와 텍스트, `t`/`f`와 불리언 1/0).

| 영역 | 지원 |
| --- | --- |
| 타입 | `int[]`, `integer[]`, `text[]`, `varchar(n)[]`, `int[3]`, `int ARRAY`, `int[][]`(차원 수는 PostgreSQL처럼 타입에 없음), 그 밖의 타입의 배열, `name[]`·`oid[]`·`"char"[]`·`aclitem[]`·`regtype[]`, `int2vector`·`oidvector` |
| 열 | STRICT `TEXT`, CHECK `xq_pg_array_valid()`(이름 `malformed array literal`), 선언 타입 `integer[]`(`format_type()`, `pg_attribute.atttypid` 1007, `information_schema.columns`의 `ARRAY`/`_int4`). 넣는 값은 그 타입의 배열 입력(`Rules.store`: `xq_pg_array_int4()` ...)을 지나 정규 텍스트로 저장 |
| 만들기 | `ARRAY[1,2]`(값들의 공통 타입의 배열: `ARRAY[1,2.5]`는 `numeric[]`, `ARRAY[true]`는 `{t}`, `ARRAY[1.50, 2]`는 `{1.50,2}`), `ARRAY[[1,2],[3,4]]`, `ARRAY[ARRAY[1],ARRAY[2]]`, `ARRAY[]::int[]`(캐스트 없는 `ARRAY[]`는 `cannot determine type of empty array`), `ARRAY(서브쿼리)`(그 순서대로, 행이 없으면 `{}`), `array_agg(x [ORDER BY ...])`(배열의 `array_agg`는 차원이 하나 많은 배열), `string_to_array(s, sep [, null])` |
| `ANY`/`ALL` | `x op ANY (배열)`, `ALL`, `SOME`의 `= <> < <= > >=`, `LIKE`/`ILIKE`/`NOT LIKE`/`NOT ILIKE`(`xq_pg_any()`). 배열은 열, 캐스트, `ARRAY[...]`, 함수 결과(`current_schemas(true)`), 매개변수, 문자열 상수(`'a' = ANY('{a,b}')`), 서브쿼리(`id > ANY (SELECT ...)`; `= ANY`·`<> ALL`의 서브쿼리는 전처럼 `IN`). NULL은 PostgreSQL처럼: 참인 원소가 없고 NULL이 있으면 NULL, 빈 배열의 `ANY`는 거짓·`ALL`은 참, 배열이 NULL이면 NULL. 배열이 아닌 수·불리언은 `op ANY/ALL (array) requires array on right side`(42809). 타입 모르는 매개변수는 반대쪽의 타입을 받음(`id = ANY($1)`의 `$1`은 `integer[]`, `x`가 `name`이면 `text[]`) |
| 첨자 | `a[i]`, `a[i][j]`, `(식)[i]`, 슬라이스 `a[lo:hi]`, `a[:hi]`, `a[lo:]`(슬라이스가 있으면 첨자 `i`는 `1:i`). 범위 밖, 차원보다 적은 첨자, NULL 첨자는 NULL. 원소는 그 타입의 값(`int[]`의 원소는 정수라 `attnum = conkey[1]`이 됨; 타입을 모르면 정수로 읽히는 텍스트는 정수). 결과 열 이름은 바탕 식의 것(`a`, `array`, `int4`). `int2vector`는 0부터 |
| 쓰기 | `UPDATE t SET a[i] = v`, `a[i][j] = v`(`xq_pg_array_set()`): 1차원 배열(NULL, 빈 배열 포함)은 사이를 NULL로 채우며 늘어남(`[0:3]={...}`처럼 하한도), 다차원은 범위 안만(`array subscript out of range`) |
| 연산자 | `\|\|`(배열과 배열 `array_cat()`, 배열과 원소 `array_append()`/`array_prepend()`, 문자열 상수와 NULL은 배열로), `@>`, `<@`, `&&`, `=`·`<>`·`<`·`>` ...(collation `xq_pg_array_num`/`xq_pg_array`: 원소마다, 수는 값으로, NULL은 모든 값 뒤, 같으면 짧은 쪽이 먼저; 반대쪽 문자열 상수는 그 배열 타입으로 읽음), `ORDER BY`·`DISTINCT`(같은 collation) |
| 함수 | `array_length`, `array_lower`, `array_upper`, `array_dims`, `array_ndims`, `cardinality`, `array_position(a, x [, start])`, `array_positions`, `array_append`, `array_prepend`, `array_cat`, `array_remove`, `array_replace`, `array_to_string(a, sep [, null])`(모든 차원) |
| 집합 반환 | FROM의 `unnest(a [, b ...])`(여러 배열은 나란히, 짧은 쪽은 NULL), `WITH ORDINALITY`, 별칭 `AS u(x, n)`, 앞 항목의 열(`FROM t, unnest(t.tags) tag`, `CROSS JOIN LATERAL`), `generate_subscripts(a, dim [, reverse])`, `information_schema._pg_expandarray(a)`(열 `x`, `n`). select 목록의 `unnest(a)`, `generate_subscripts()`, `_pg_expandarray()`와 그 필드 `(…).x`·`(…).n`(여러 개면 나란히). JSON 집합 반환 함수처럼 `xq_pg_rows_unnest()` ... 가 만든 행을 `json_each()`가 읽음 |
| 카탈로그 | `pg_constraint.conkey`·`confkey`(`smallint[]`), `pg_index.indkey`·`indoption`(`int2vector`, `1 2`)·`indclass`·`indcollation`(`oidvector`), `pg_proc.proargtypes`(`oidvector`)·`proargnames`(`text[]`)·`proargmodes`(`"char"[]`), `pg_class.relacl`·`reloptions`, `pg_attribute.attoptions` ... 이 그 배열 타입. SQLAlchemy의 `unnest(conkey)`·`generate_subscripts(indkey, 1)`, pgjdbc의 `_pg_expandarray(i.indkey)`·`conkey[pos.n]`, Django의 `array(SELECT ... FROM unnest(c.conkey) WITH ORDINALITY ...)`, psql `\d+`의 `unnest(tc.reloptions)`를 읽음 |
| 와이어 | `RowDescription`·`ParameterDescription`의 배열 OID(`int4[]` 1007, `text[]` 1009, `bool[]` 1000 ...), 텍스트 형식 그대로, 배열의 이진 형식(매개변수와 결과, 원소가 이진 형식이 되는 타입: [서버](server.md#값과-타입)) |

- 뷰, CHECK, 식 인덱스의 텍스트에는 고른 함수가 남습니다(`xq_pg_subscript_k("a", 1, 3)`, `xq_pg_any(2, "a", 0, 0, 3)`, `xq_pg_array_append("s", ...)`, `COLLATE xq_pg_array_num`). 배열 비교의 collation은 jsonb의 것처럼 방언의 것이라, 배열을 비교하는 뷰는 SQLite 방언에서 읽을 수 없습니다(첨자·`ANY`·`||` 같은 함수는 엔진 함수라 어느 방언에서나 읽힘).

### interval

interval은 정렬 키와 필드를 붙인 32바이트 BLOB입니다(`src/dialect/interval.zig`). 앞 16바이트는 PostgreSQL의 `interval_cmp_value()`(한 달 = 30일, 하루 = 24시간인 마이크로초, 128비트, 부호 비트를 뒤집은 big-endian)이고, 뒤 16바이트는 필드(달 `i32`, 날 `i32`, 마이크로초 `i64`, 같은 방식)입니다. 그래서 `memcmp`의 순서가 PostgreSQL의 순서입니다. `'1 mon'`과 `'30 days'`는 길이가 같지만 다른 값이라(`date + '1 mon'`과 `date + '30 days'`는 다름) 필드를 남깁니다. 이 인코딩은 파일 형식이라 바뀌지 않습니다.

| 쓰는 곳 | xqlite |
| --- | --- |
| 정렬, 인덱스, `min`/`max` | BLOB 그대로(SQLite의 BINARY). BLOB 열의 인덱스가 `ORDER BY`와 범위 검색을 맡음 |
| `=`, `<>`, `IS [NOT] DISTINCT FROM`, `IN (...)`, `BETWEEN` | 키(`xq_pg_iv_key()`)끼리: `'1 mon' = '30 days'` |
| BLOB 열과 `<`, `<=`, `>`, `>=` | 열은 그대로, 상대는 그 길이의 경계(`< xq_pg_iv_key(x)`, `<= xq_pg_iv_high(x)`): 인덱스 범위 검색 |
| `GROUP BY`, `DISTINCT`, 창의 `PARTITION BY`·`ORDER BY`, 여러 항의 `ORDER BY`의 마지막이 아닌 항 | 키로(같은 길이는 같은 그룹·동점). `DISTINCT`는 결과 열의 `GROUP BY`가 됨 |
| `::text`, `\|\|`, `concat()`, `format()`, JSON, 배열의 원소 | 텍스트(`xq_pg_iv_text()`) |
| `sum()`, `avg()` | `xq_pg_iv_sum()`/`xq_pg_iv_avg()`: PostgreSQL처럼 필드별 합, 평균은 `interval / 개수`, 무한은 같은 부호면 그 무한·다르면 `interval out of range`. 창 함수로도 |
| `justify_hours()`, `justify_days()`, `justify_interval()`, `isfinite()` | 방언 함수(BLOB을 돌려줌) |
| 셸, 서버 | 값 표시 계층이 BLOB을 텍스트로. 서버의 바이너리 형식은 PostgreSQL의 `interval_send`(마이크로초 `int64`, 날 `int32`, 달 `int32`), 매개변수도 |

- 뷰, CHECK, 식 인덱스의 텍스트에는 이 함수들이 남고(`xq_pg_iv_key("v") = xq_pg_iv_key('30 days')`, `GROUP BY xq_pg_iv_key("v")`), 모두 엔진 함수라 SQLite 방언과 [확장](extension.md)을 올린 sqlite3도 읽습니다. 연산자의 함수는 `xq_pg_iv_<연산>`(`xq_pg_iv_timestamp_pl_interval()` ...)입니다.
- UNIQUE와 PRIMARY KEY, `UNION`/`INTERSECT`/`EXCEPT`, `count(DISTINCT v)`, `IN (SELECT ...)`는 바이트로 비교하므로 `'1 mon'`과 `'30 days'`를 다르게 봅니다(PostgreSQL은 같음). 같은 길이의 `max()`/`min()`이 어느 철자를 돌려주는지도 다를 수 있습니다.
- 예전 데이터베이스(interval을 텍스트로 저장하던 xqlite)의 `TEXT` 열은 그대로입니다. 열마다 선언된 저장 타입으로 구분해, `TEXT` 열에 넣는 값은 텍스트로(무한은 `interval out of range`) 넣고, 정렬은 예전처럼 collation `xq_pg_interval`, 비교와 연산은 위의 함수(텍스트와 BLOB을 모두 읽음)입니다. 예전 스키마가 부르는 `xq_pg_interval()`, `xq_pg_interval_pl()` ...와 collation은 뜻이 그대로 남습니다. 옮기려면 테이블을 다시 만듭니다.

### numeric

`numeric`/`decimal`은 정확한 십진수입니다(`src/dialect/decimal.zig`, 엔진 함수 `src/dialect/decimal_sql.zig`). PostgreSQL처럼 계산하고(반올림은 0에서 먼 쪽, `NaN`과 `±Infinity`, 나눗셈의 스케일은 `select_div_scale()`, 오류와 SQLSTATE), 저장은 값 자체가 정렬 키인 `BLOB`입니다.

- **키**: 바이트 비교(memcmp, SQLite의 BINARY) 순서가 수의 순서이고 같은 수는 같은 바이트열입니다(`1.50`과 `1.5`는 한 키). 그래서 범위 검색, `ORDER BY`, `GROUP BY`, `DISTINCT`, `min`/`max`, PRIMARY KEY, UNIQUE, 외래 키가 SQLite 그대로 인덱스를 씁니다. 형식은 `decimal.zig` 머리말과 [확장](extension.md#numeric-키)에 있습니다. 확장 없는 sqlite3는 값을 바이트로만 보고 쓰지 못합니다(`xq_dec_valid` CHECK).
- **저장**: 열에 넣는 모든 값(수, 문자열, 매개변수, `INSERT ... SELECT`, `UPDATE`)은 `xq_dec_key(v, p, s)`를 지납니다: `numeric(p,s)`는 s자리로 반올림하고 p - s자리를 넘으면 `numeric field overflow`(22003), 무한대도 그 오류. 스케일 없는 `numeric`은 끝의 0을 버립니다(`'1.50'`은 `1.5`로 보임; 비교·유일성·그룹은 PostgreSQL과 같음). `DEFAULT` 상수는 키의 BLOB 상수(`X'40810364'`)로, 그 밖의 기본값과 생성 열은 `xq_dec_key(식, p, s)`로 스키마에 씁니다. 다른 타입(`integer`, `double precision`, `text` ...)의 열에 넣는 numeric은 그 타입으로 바꿉니다(PostgreSQL의 대입 캐스트: `1.5`를 `integer` 열에 넣으면 2).
- **이전 데이터베이스**: 이 변경 전에 만든 테이블의 `numeric` 열(STRICT 저장 `ANY`)은 지금처럼 수를 저장합니다(`xq_dec_number()`). 저장 방식은 열마다 선언된 SQLite 타입(`ANY`/`BLOB`)으로 정해 한 열에서 섞이지 않습니다. 옮기려면 테이블을 다시 만듭니다.
- **식**: `numeric` 연산자는 키의 함수입니다(`a + b` → `xq_dec_add(a, b)`; 리터럴은 `xq_dec('1.50')`로 자릿수와 스케일을 지킴). 비교는 키를 스케일 없이 비교합니다(`n = 1.5` → `n = xq_dec_key('1.5')`: 상수라 인덱스를 씀; 식 인덱스는 `xq_dec_key(식)`으로 저장해 같은 식의 비교가 그 인덱스를 씀). 실수와 만나면 실수로(`xq_dec_float8()`). `round`/`trunc`/`ceil`/`floor`/`abs`/`sign`/`mod`/`div`/`scale`/`min_scale`/`trim_scale`, `sum`/`avg`(윈도우 포함, `sum(bigint)`·`avg(integer)`도 numeric), 정수·실수·텍스트로의 캐스트, `||`·`concat()`·`format()`, JSON(`to_json` ...), 배열 원소(`ARRAY[n]`, `array_agg`)가 키를 읽습니다. 그 밖의 함수에는 수로(`xq_dec_number()`) 넘깁니다.
- **표시 스케일**: 계산한 값은 PostgreSQL의 표시 스케일(dscale)을 키 뒤에 붙여 들고 다닙니다(`10.0 / 4`는 `2.5000000000000000`, `avg()`도). 셸과 서버는 타입의 스케일(`numeric(10,2)` 열, `n + 1`), 없으면 키의 스케일로 보여 줍니다. 저장한 값(스케일 없음)에서 나온 값은 자기 자릿수입니다. 비교, `IN`, `GROUP BY`, `DISTINCT`는 스케일을 떼고 비교·그룹합니다(`xq_dec_key()`, `Rules.group_key`: `VALUES (1.5), (1.50)`은 한 그룹). `UNION`·`INTERSECT`·`EXCEPT`, `count(DISTINCT x)`는 바이트로 비교하므로 스케일만 다른 계산 값을 다른 값으로 봅니다.
- **입력**: `numeric_in()`의 문법(앞뒤 공백, `NaN`, `Infinity`/`inf`, `_` 자리 구분, `0x`/`0o`/`0b` 정수, 지수), 범위(소수점 앞 131072자리, 뒤 16383자리; 넘으면 `value overflows numeric format`). 실수는 15자리(`float8_numeric()`).
- **서버**: 텍스트 형식은 위 표시, 이진 형식은 PostgreSQL의 NBASE 10000 형식(결과와 매개변수).

### 카탈로그

| 스키마 | 관계 |
| --- | --- |
| `information_schema` | `tables`, `columns`(`xq_catalog`의 PostgreSQL 선언 타입, identity 여부, 정수 열은 `integer`), `views`, `schemata`, `sequences`, `table_constraints`, `key_column_usage`, `referential_constraints`, `check_constraints` |
| `pg_catalog`(스키마 없이도 보임) | 스키마에서 만드는 것: `pg_namespace`, `pg_class`, `pg_attribute`, `pg_type`, `pg_index`, `pg_constraint`, `pg_attrdef`, `pg_sequence`, `pg_depend`(identity·serial 시퀀스의 소유), `pg_description`, `pg_proc`(내장 타입의 입출력 함수). 그 위의 뷰: `pg_tables`, `pg_views`, `pg_indexes`, `pg_sequences`. 상수: `pg_database`, `pg_roles`, `pg_authid`, `pg_user`, `pg_am`, `pg_tablespace`, `pg_collation`, `pg_language`, `pg_settings`(세션의 값). 빈 것: `pg_trigger`, `pg_policy`, `pg_inherits`, `pg_rewrite`, `pg_statistic_ext`, `pg_publication*`, `pg_extension`, `pg_enum`, `pg_range`, `pg_shdescription`, `pg_auth_members`, `pg_partitioned_table`, `pg_foreign_table`, `pg_matviews`, `pg_event_trigger` |

psql의 `\d`, `\dt`, `\di`, `\dv`, `\ds`, `\dn`, `\df`, `\dT`, `\l`, `\du`와 `\d 테이블`(열, 기본값, identity, 인덱스, CHECK, 외래 키, Referenced by), `\d 인덱스`, `\d 시퀀스`가 와이어 서버로 PostgreSQL 16과 같은 출력을 냈습니다([서버](server.md#xqlite-serve)). psql 18의 질의가 읽는 PostgreSQL 17·18의 열(`pg_constraint.conenforced`·`conperiod`, `pg_class.relallfrozen`, `pg_database.datlocale`·`dathasloginevt`, `pg_collation.colllocale`, `pg_publication.pubgencols`)도 있습니다. 다만 psql 18도 `\d` 계열에 배열 문법(`array(...)`, `= any(...)`, 배열 첨자)을 함께 보내므로, 지금은 그것이 들어가기 전까지 오류입니다.

**만드는 법.** 스키마에서 만드는 관계는 엔진 테이블 값 함수(이름 있는 가상 테이블, `Hooks.engine_modules`의 `xq_pg_class` ...)이고, 뷰 텍스트가 열마다 PostgreSQL 타입으로 캐스트합니다(`relhasindex::boolean`이라 클라이언트에 `t`/`f`). 행은 스냅숏(`pgcatalog.zig`)에서 옵니다. 스냅숏은 각 데이터베이스의 메모리 스키마(`Table`, `Index`, 외래 키), 메모리의 카탈로그(선언 타입, identity, 제약 이름, 주석), `xq_sequence`, `sqlite_schema`의 SQL 텍스트(CHECK, 인덱스 식, 뷰)에서 한 번에 읽어 자기 아레나에 복사합니다. 연결은 마지막 스냅숏을 두고, 어느 데이터베이스의 스키마(쿠키·세대)도, 바뀐 행 수(`n_total_change`)도 그대로이면 다시 씁니다. 그래서 행마다 부르는 함수(`pg_table_is_visible()`, reg* 캐스트)도 문장마다 한 번 읽습니다. 뷰 텍스트를 키우는 대신 이렇게 한 이유: `pg_attribute`·`pg_constraint`·`pg_index`는 SQLite의 pragma로는 CHECK 텍스트, 제약 이름, INTEGER PRIMARY KEY의 인덱스, 식 인덱스, 정의 텍스트(`pg_get_constraintdef()`)를 모두 얻지 못하고, psql의 질의마다 여러 번 조인되는 관계를 pragma 질의의 합집합으로 만들면 느립니다. 파일에는 아무것도 쓰지 않으므로 DB는 SQLite 그대로이고, sqlite3와 SQLite 방언에는 `pg_class` 같은 이름이 없습니다(엔진 함수 `xq_pg_*`만 보임).

- 데이터베이스와 스키마: main은 `public`, `CREATE SCHEMA`의 스키마(`"sales.orders"`)는 `sales`, temp의 개체는 `pg_temp_1`, `ATTACH`한 데이터베이스는 그 이름의 스키마입니다. xqlite 자신의 테이블(`sqlite_*`, `xq_*`)은 없습니다.
- NOT NULL 열(PRIMARY KEY의 열 포함)마다 PostgreSQL 18처럼 NOT NULL 제약 `<table>_<column>_not_null`(`contype` `n`, `pg_get_constraintdef()`는 `NOT NULL a`)이 있고, `information_schema.table_constraints`에는 `CHECK`, `check_constraints`에는 `a IS NOT NULL`로 나옵니다.
- INTEGER PRIMARY KEY에도 PostgreSQL처럼 `<table>_pkey` 인덱스와 PRIMARY KEY 제약이 있습니다. UNIQUE·PRIMARY KEY의 자동 인덱스는 제약 이름(`t_b_c_key`, 사용자가 준 이름)입니다. 타입 검사용 CHECK(`integer out of range` ...)는 제약에 나오지 않습니다.
- `pg_attribute`의 타입은 선언 타입의 OID와 typmod(와이어 서버의 RowDescription과 같은 표)이고, SQLite가 만든 테이블은 `information_schema`처럼 `INTEGER`가 `bigint`입니다. 뷰의 열은 그 뷰를 이 방언으로 컴파일한 결과 열의 타입입니다.
- 기본값(`pg_attrdef.adbin`, `pg_get_expr()`)은 저장된 SQLite 텍스트를 PostgreSQL처럼 씁니다: `'x'::text`, `now()`, `false`, `nextval('t_id_seq'::regclass)`. CHECK·인덱스 식·뷰도 따옴표가 필요 없는 이름은 따옴표 없이(`CHECK ((length(b) > 1))`, `lower(b)`).
- 함수: `pg_get_userbyid()`, `pg_table_is_visible()`·`pg_type_is_visible()`(`search_path`대로), `pg_function_is_visible()` 등(참), `pg_get_expr()`, `pg_get_indexdef(oid [, n, pretty])`, `pg_get_constraintdef()`, `pg_get_viewdef()`, `pg_get_serial_sequence()`, `obj_description()`, `col_description()`, `shobj_description()`(NULL), `has_table_privilege()`·`has_schema_privilege()` ... ·`pg_has_role()`(참: 역할은 슈퍼유저 하나), `to_regclass()`·`to_regtype()`·`to_regnamespace()`·`to_regrole()`, `pg_encoding_to_char()`, `pg_size_pretty()`, `pg_table_size()` 등(0), `pg_typeof()`(값의 저장 형식으로: `integer`, `bigint`, `numeric`, `text` ...), `current_schemas()`(`name[]`), psql이 빈 관계에 부르는 `pg_get_triggerdef()`·`pg_partition_ancestors()` 등.
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
| `numeric(p,s)`, `decimal` | `BLOB` | 정렬 키만(`xq_dec_valid(n, p, s)` → `invalid input syntax for type numeric`). 넣는 모든 값을 `numeric(p,s)`의 키로 바꿈(아래 [numeric](#numeric)) |
| `boolean` | `INTEGER` | 0/1만(`invalid input syntax for type boolean`). 문자열은 불리언 철자로 읽어 넣음(아래) |
| `text` | `TEXT` | |
| `varchar(n)`, `char(n)` | `TEXT` | `length() <= n`(`value too long for type character varying(n)`, `character(n)`) |
| `bytea` | `BLOB` | |
| `date`, `time`, `timestamp[tz]` | `TEXT` | 넣는 문자열은 PostgreSQL이 읽고 쓰는 텍스트로(아래) |
| `interval` | `BLOB` | `xq_pg_iv_valid()`(`invalid input syntax for type interval`); 넣는 값은 interval의 BLOB으로([interval](#interval)). 예전 데이터베이스의 열은 `TEXT` |
| `uuid` | `BLOB` | 16바이트(`invalid input syntax for type uuid`). 넣는 문자열은 `uuid_in()`처럼 읽음([uuid](#uuid)). 예전 테이블의 `TEXT` 열은 텍스트 그대로 |
| `json` | `TEXT` | `json_valid()`; 넣는 값은 검사([JSON](#json)) |
| `jsonb` | `BLOB` | `json_valid(j, 8)`; 넣는 값은 정준 JSONB(이 방식 전에 만든 TEXT 열은 정규화한 텍스트, [JSON](#json)) |
| 배열(`integer[]`, `text[]`, `varchar(n)[]` ...) | `TEXT` | 배열 리터럴(`malformed array literal`); 넣는 값은 원소 타입으로 읽어 정규 텍스트로([배열](#배열)) |

- 선언 타입은 `xq_catalog`의 `type` 키에 `format_type()` 철자(`character varying(20)`, `timestamp with time zone`)로 남습니다.
- 다른 타입의 값을 넣으면 SQLite STRICT 오류(`cannot store TEXT value in INTEGER column t.a`)가 납니다.
- `boolean` 열에 넣는 문자열(상수, 텍스트로 바인딩한 매개변수, `INSERT ... SELECT`의 값)은 PostgreSQL이 그 타입의 입력을 읽듯 읽습니다: `'t'`, `'true'`, `'yes'`, `'on'`, `'1'`(그 접두어 `'tr'`, `'of'` ..., 대소문자·앞뒤 공백 무시)은 1/0. 아니면 `invalid input syntax for type boolean: "x"`(22P02). `numeric` 열에 넣는 값은 모두 `xq_dec_key(v, p, s)`를 지납니다(아래 [numeric](#numeric)). `INSERT`와 `UPDATE`(`ON CONFLICT DO UPDATE` 포함)가 저장 직전에 바꿉니다([타입을 읽는 코드 생성](architecture.md#타입을-읽는-코드-생성)).
- `date`, `time`, `timestamp`, `timestamptz`, `interval` 열에 넣는 문자열도 그 타입의 입력으로 읽어 PostgreSQL의 출력 텍스트로 넣습니다: `'2024-1-5'`는 `2024-01-05`, `'2 hours'`는 `02:00:00`, `timestamptz`의 `'2024-01-01 10:00:00+02'`는 UTC의 `2024-01-01 08:00:00`. 읽지 못하면 `invalid input syntax for type date: "x"`(22007), 범위 밖의 필드는 `date/time field value out of range: "2024-02-30"`(22008). 텍스트는 그대로 sqlite3의 날짜 함수가 읽습니다.
- `interval` 열에 넣는 값(문자열, 텍스트나 바이너리로 바인딩한 매개변수, interval 식)은 `xq_pg_iv()`로 BLOB이 됩니다. `DEFAULT '1 hour'`는 `DEFAULT (xq_pg_iv('1 hour'))`로 남습니다.
- 모르는 타입은 `type "x" does not exist`(배열이면 `type "x[]" does not exist`), `serial[]`은 `array of serial is not implemented`입니다.

### 캐스트

| 캐스트 | xqlite | PostgreSQL과 다른 점 |
| --- | --- | --- |
| `::date`/`::time`/`::timestamp`/`::timestamptz`/`::interval` | `xq_pg_date()`/`xq_pg_time()`/`xq_pg_timestamp()`/`xq_pg_timestamptz()`/`xq_pg_iv()`(interval의 BLOB; `::text`는 `xq_pg_iv_text()`): PostgreSQL의 입력(ISO 날짜, `T`나 공백 뒤의 시각, 오프셋, `BC`; interval의 단위·시각·`ago`·ISO 8601 `P1DT2H`; `now`, `today`, `tomorrow`, `yesterday`, `epoch`)을 읽어 그 출력으로(초의 소수는 끝의 0 없이: `03:04:05.5`). 읽지 못하면 오류 | `infinity`, 시간대 이름(`Asia/Seoul`), `DateStyle`이 바꾸는 입력·출력은 없음. `timestamptz`는 UTC. `::timetz`는 `time()` |
| `::smallint`/`::int`/`::bigint` | `xq_pg_int2/4/8()`: 실수는 0에서 먼 쪽으로 반올림, 문자열은 정수로 읽음(`'2.5'::int`는 `invalid input syntax for type integer`), 범위 밖은 `integer out of range` | |
| `::varchar(n)` | 자름 | |
| `::numeric`, `::numeric(p,s)` | `xq_dec(x [, p, s])`: 정확한 키, s로 반올림, p - s자리를 넘으면 `numeric field overflow`(22003) | |
| `::boolean` | `'t'`/`'yes'`/`'on'` 같은 철자를 읽음 | |
| `::json`/`::jsonb` | `xq_pg_json()`/`xq_pg_jsonb()` | |
| `::uuid`, uuid의 `::text` | `xq_pg_uuid()`(16바이트), `xq_pg_uuid_text()`([uuid](#uuid)) | `bytea`·정수에서의 캐스트는 실행 중 오류(PostgreSQL은 해석 중 `cannot cast type`) |
| `::int[]`(`text[]`, `numeric[]` ...) | `xq_pg_array_int4()` ...: 배열 입력, 원소마다 그 타입으로 읽어 정규 텍스트로(위 [배열](#배열)) | 원소 타입의 typmod(`numeric(10,2)[]`의 반올림, `varchar(3)[]`의 길이)는 적용하지 않음 |

## PostgreSQL과 다른 점

| 주제 | PostgreSQL | xqlite | 이유 |
| --- | --- | --- | --- |
| 불리언 | `true`/`false` | 정수 0/1. `SELECT true`는 `1`(SQLITE_INTEGER). 셸과 서버는 `boolean` 열과 불리언 식(`a = b`, `true`, `x IS NULL`)을 psql처럼 `t`/`f`로 보여 줌([값 표시](architecture.md#값-표시)). 뷰의 불리언 식 열은 1/0. 열에 넣는 문자열은 불리언 철자로 읽음(`'yes'`, `' off '`). PostgreSQL은 타입이 `text`인 식(텍스트 열, `'a' \|\| 'b'`)을 넣으면 오류이지만 xqlite는 그것도 읽음 | sqlite3 API로 돌아오는 결과의 타입을 바꿀 수 없음. 저장 값은 값의 타입이 아니라 실행 중 값이 문자열인지로 바꿈 |
| `numeric` | 정확한 십진수 | 정확함(정렬 키 BLOB, [numeric](#numeric)). API로는 값이 키(BLOB, `xqlite.decimal.keyText()`로 읽음). 스케일 없는 `numeric` 열은 끝의 0을 버리고 저장(`'1.50'`은 `1.5`로 보임). 이전에 만든 테이블의 `ANY` 열은 수 그대로 | `power`/`sqrt`/`exp`/`ln`/`log`/`^`는 실수로 계산(PostgreSQL은 높은 정밀도), `to_char`·`to_number`·`width_bucket`·`stddev`·`variance` 없음 |
| 식의 타입 | 연산자·함수 해석이 정함 | 같은 규칙으로 매김: `integer + integer`는 `integer`, `integer + bigint`는 `bigint`, `1`은 `integer`, `1.50`은 `numeric`, `'a'`는 `text`, `count()`·`sum(int)`은 `bigint`, `avg()`는 `numeric`, `now()`은 `timestamp with time zone`, `date + 1`은 `date`([코어의 타입](architecture.md#코어의-타입)). 결과 열의 선언 타입(`sqlite3_column_decltype()`, psql `\gdesc`의 철자), 값 표시, 매개변수의 타입, 정수 산술의 범위 검사(아래 정수 오버플로), 저장 시 변환(`boolean`, `numeric`, 날짜·시각)에 씀. 산술·비트 연산자는 연산자 표로 고르고([연산자 해석](#연산자-해석)), 그 밖에 피연산자 타입으로 고르는 것은 `jsonb` 연산자·비교·`ORDER BY`, interval의 비교·`ORDER BY`, JSON을 만드는 함수의 인자(`overload.zig`) | 함수 해석은 이름으로(인자 타입으로 오버로드를 고르지 않음) |
| NULL 정렬 | NULL이 가장 큰 값 | 같음(ASC면 마지막, DESC면 처음) | SQLite는 반대라 방언이 맞춤. NULL일 수 없는 열(NOT NULL, INTEGER PRIMARY KEY, 외부 조인의 NULL 쪽이 아닌 것)에는 붙이지 않아 인덱스 순서를 그대로 씀(그때 바이트코드는 SQLite와 같음) |
| `LIKE` | 대소문자 구분, 기본 이스케이프 `\` | 같음(엔진 함수 `xq_like()`). `ILIKE`는 ASCII 대소문자만 무시(`xq_ilike()`) | SQLite의 LIKE는 대소문자를 무시하고 기본 이스케이프가 없음 |
| identity·serial | 시퀀스 | 시퀀스 `<table>_<col>_seq`. 아래 [identity](#identity와-serial) | SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않음 |
| `now()`, `current_timestamp` | 시간대가 있는 타임스탬프 | 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음). 셸과 서버는 `timestamptz` 열에 `+00`을 붙여 보여 줌 | SQLite 날짜 함수가 그대로 읽음 |
| 날짜·시각 연산 | 세션 시간대로 계산 | 같은 결과(위 [연산자 해석](#연산자-해석)). `timestamptz`는 늘 UTC로 계산(`SET TIME ZONE`은 보여 주기만 함). 날짜와 타임스탬프의 비교는 ISO 텍스트의 비교(같은 타입끼리와 문자열 상수는 PostgreSQL과 같음; `timestamp = date`는 시각 `00:00:00`이 없는 텍스트라 다름). interval의 비교와 `ORDER BY`는 collation `xq_pg_interval`(한 달은 30일: `'1 mon' = '30 days'`). 그 collation은 jsonb의 것처럼 방언의 것이라, interval을 비교하는 뷰는 SQLite 방언과 평범한 sqlite3에서 읽을 수 없음. [확장](extension.md)을 올린 sqlite3는 collation과 interval 함수(`xq_pg_interval*`)를 가짐 | 저장은 sqlite3가 읽는 TEXT |
| 이름의 대소문자 | `"Foo"`와 `foo`는 다른 이름 | 접기는 하지만 같은 이름 | SQLite의 이름 비교는 대소문자를 구분하지 않음 |
| 오류 문구 | PostgreSQL 문구 | 싼 곳에서만 PostgreSQL 문구(아래 [오류](#오류)). 실행 중 제약 위반도 PostgreSQL 문구(첫 줄만, `DETAIL`은 없음) | |
| 0으로 나누기 | 오류 | 같음(`/`, `%`가 `division by zero`, 22012). 이 방언으로 컴파일한 문장에서만이고, sqlite3나 SQLite 방언에서 같은 뷰·CHECK를 계산하면 NULL | 엔진의 산술 정책(`Hooks.arith`) |
| 정수 오버플로 | int4·int2 연산도 오류 | 같음: 타입이 `integer`인 연산(`integer + integer`, 32비트 리터럴끼리의 `SELECT 2147483647 + 1`, 단항 `-`, `(-2147483647 - 1) / -1`)은 `integer out of range`, `smallint`끼리는 `smallint out of range`, `bigint`는 64비트를 넘으면 `bigint out of range`(모두 22003). 이 방언으로 컴파일한 문장에서만이고(뷰와 트리거 본문 포함), CHECK·생성 열의 식과 sqlite3·SQLite 방언에서는 64비트로 계산. 매개변수는 추론한 타입(`a + $1`의 `integer`)이라 클라이언트가 `int8`로 지정해도 `integer`로 검사 | 코드 생성이 연산의 P5에 폭을 적음([타입을 읽는 코드 생성](architecture.md#타입을-읽는-코드-생성)) |
| 복합 질의의 타입 | 항들의 타입을 맞추거나 실패(`UNION types boolean and integer cannot be matched`) | 공통 타입이 있으면 그 타입, 없으면 실패하지 않고 타입을 모름(값은 저장된 대로 보임) | |
| 외래 키 | 늘 강제 | 같음. 이 방언의 첫 문장에서 연결의 `PRAGMA foreign_keys`를 켬. 응용이 끈 것은 그대로 둠 | sqlite3는 여전히 끈 채로 씀 |
| 격리 수준 | 여러 수준 | 파싱만 함 | SQLite는 늘 직렬화 |
| JSON | `jsonb`는 이진 형식 | SQLite의 JSONB(정준 인코딩). `json`은 입력 텍스트. 이 방식 전에 만든 TEXT 열은 정규화한 TEXT | 확장 없는 sqlite3가 `json(j)`, `json_extract()`, `->>`로 읽음. sqlite3는 TEXT를 넣지 못하고(STRICT BLOB) `jsonb('...')`로 넣으며, 그 값은 정준이 아닐 수 있음(연산자·함수는 읽을 때 정규화; 확장을 올린 sqlite3는 `xq_pg_jsonb_bin(x)`로 정준 JSONB를 넣을 수 있음). CHECK `json_valid(j, 8)`(깊이 1000까지)는 SQLite의 규칙. 연산자(`->`, `@>`, `?` ...)의 식 인덱스·CHECK·뷰는 [확장](extension.md)을 올린 sqlite3가 같은 결과로 계산 |
| jsonb 비교 | jsonb의 순서 | 같음(정렬 키 `xq_pg_jsonb_key()`). 열의 인덱스는 `=`에 쓰이지 않음. UNIQUE·`GROUP BY`·`DISTINCT`는 정준 JSONB의 바이트라 수의 철자만 다른 같은 값(`1.0`과 `1`)은 다른 값(PostgreSQL은 같은 값; 예전 TEXT 저장도 그랬음). 복합 질의의 `ORDER BY`는 위 [JSON](#json) | |
| JSON 수 | numeric과 float8 | 같음: 타입을 아는 인자는 JSON을 만드는 함수가 PostgreSQL 철자로 씀. `double precision`/`real`은 `float8out()`처럼 되읽히는 가장 짧은 자릿수, 지수가 -4~14면 고정 소수점, 아니면 두 자리 이상의 지수(`to_json(100.0::float8)`은 `100`, `1e20::float8`은 `1e+20`, `1e-5::float8`은 `1e-05`; `xq_pg_float_json()`), `numeric`은 그 자릿수(`to_json(1.50)`은 `1.50`, `numeric(5,2)` 열의 2는 `2.00`, `avg()`는 `1.5000000000000000`; 키는 `xq_pg_dec_json()`, 리터럴은 `xq_pg_numeric_json()`), `NaN`·`Infinity`는 문자열. `row_to_json`·`json_agg`의 열도 | 타입을 모르는 값은 SQLite 철자(`2.5`, `1.0e+20`) |
| 배열 | 원소 타입이 있는 이진 값 | PostgreSQL의 배열 텍스트(`{1,2}`)를 TEXT로. 원소 타입은 식의 타입([배열](#배열)). API로도 텍스트. 원소 타입을 모르는 곳(타입 모르는 매개변수, `ANY`의 문자열 상수 밖)에서는 원소를 적힌 대로 값으로 비교. `name[]`은 원소 타입이 없어 와이어에서 `text[]`(1009, PostgreSQL은 1003) | sqlite3가 그대로 읽고, 와이어·psql·카탈로그가 이미 이 텍스트를 씀. 배열 열의 CHECK(`xq_pg_array_valid()`)와 첨자·연산자의 식, collation `xq_pg_array`·`xq_pg_array_num`의 정렬은 [확장](extension.md)을 올린 sqlite3가 계산 |
| 저장되는 식 | | IR이 SQLite 텍스트로 렌더링. PostgreSQL 함수는 `xq_postgres_greatest(...)`, LIKE는 `xq_like(...)`처럼 저장 | SQLite 방언이나 다른 방언의 연결에서 읽어도 같은 뜻. 평범한 sqlite3에서는 그런 식을 계산할 수 없고, [확장](extension.md)(`libxqlite_ext`)을 올린 sqlite3·Python·Datasette는 같은 결과로 계산(세션·카탈로그를 읽는 `current_setting()`, `pg_get_viewdef()` 같은 것만 빠짐). 그 함수들의 뜻은 파일 형식의 일부라 바뀌지 않음([ABI 규칙](extension.md#abi-규칙)) |

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
- 키가 아닌 identity 열은 DEFAULT의 `nextval()`이 번호를 매깁니다. [확장](extension.md)을 올린 sqlite3는 `PRAGMA trusted_schema=ON`에서 같은 시퀀스(`xq_sequence`)로 번호를 매기므로, 두 엔진이 번갈아 넣어도 겹치지 않습니다.

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
| 쿼리 | 결과 열이 없는 `SELECT;`, `DISTINCT ON`, `LATERAL` 서브쿼리, `GROUPING SETS`/`ROLLUP`/`CUBE`, `EXCEPT ALL`/`INTERSECT ALL`, `FETCH ... WITH TIES`, 테이블·함수 별칭의 열 이름 |
| DML | 데이터를 바꾸는 CTE, `ON CONFLICT ON CONSTRAINT`, `COPY` |
| 타입 | `char(n)`의 공백 채움(`'x'::char(3)`, 저장한 `'ab'`는 `'ab  '`로 보여야 함)과 n을 넘는 뒤 공백 자르기(`'abcd    '`를 `char(4)`·`varchar(4)`에 넣으면 오류), `ENUM`·`CREATE TYPE`·도메인, 시퀀스의 데이터 타입(언제나 `bigint`) |
| 배열 | 배열의 원소 typmod(`numeric(10,2)[]`의 반올림, `varchar(3)[]`의 길이 검사), 배열 슬라이스에 쓰기(`a[1:2] = ...`), `array_fill()`·`trim_array()`·`array_sample()`·`array_shuffle()`, 다차원 배열의 `array_to_json()`, 다른 배열 타입 사이의 캐스트의 원소 변환(`int[]::text[]`는 텍스트를 다시 읽음), `ARRAY[...]`의 원소에 쓰인 타입 모르는 매개변수, 레코드 일반(`_pg_expandarray()`의 `(x,n)`만), `name[]`의 OID 1003, 원소 타입이 다른 배열의 `\|\|`·비교에서의 오류(PostgreSQL은 `operator does not exist`) |
| JSON | jsonpath `like_regex`의 POSIX 문자 클래스·역참조·플래그 `m`/`x`, `.**{n to m}`, `keyvalue()`, `datetime()`과 문자열 메서드; 복합 타입 인자의 `json_populate_record`(`NULL::table`만), `IS JSON`의 비텍스트 인자 오류, select 목록의 레코드 반환 함수(`json_each`), `WITH ORDINALITY`의 select 목록, `jsonb` 첨자에 쓰기(`SET j['a'] = ...`), 맨 위 스칼라의 `->` 첨자 0·-1(TEXT 값, 곧 상수에서: PostgreSQL은 그 스칼라, 이 방언은 예전대로 NULL; JSONB 값은 같음), GIN의 `@>`·`?` 인덱스 검색, sqlite3가 넣은 jsonb의 정규화, PostgreSQL 17의 `JSON_TABLE`/`JSON_VALUE`/`JSON_QUERY`/`JSON_EXISTS` |
| 식과 함수 | `SIMILAR TO`, 정규식의 역참조·POSIX 문자 클래스·`regexp_*` 함수, `AT TIME ZONE`, `to_char`/`date_trunc`/`age`/`make_interval`, `extract`·`date_part`의 interval, `U&'...'` |
| 날짜·시각 | `date`·`timestamp`의 `infinity`/`-infinity`, `IntervalStyle`의 다른 형식(`sql_standard`, `iso_8601`, `postgres_verbose`)과 SQL의 연-월 리터럴(`'1-2'`), 세션 시간대(`timestamptz`는 UTC로만), `timetz`의 연산(표에 없어 SQLite의 연산), interval의 UNIQUE·`UNION`·`count(DISTINCT)`·`IN (SELECT ...)`(바이트로 같은 것끼리: `'1 mon'`과 `'30 days'`는 다름, [interval](#interval)), `timestamp`와 `date`의 비교, `interval '1' day`처럼 필드를 붙인 interval 리터럴(필드를 무시하고 `'1'`은 1초), 타임스탬프의 범위 294247년부터(PostgreSQL은 294276년까지), 타입을 아는 값(`now()`)을 `date` 열에 넣을 때의 변환(문자열만 읽음) |
| 연산자 해석 | `numeric`·실수와 만난 문자열 상수를 그 타입의 입력으로 읽기(정수만 읽음), `OPERATOR(schema.op)` 문법, 사용자 정의 연산자 |
| DDL | `ALTER TABLE`의 `ALTER COLUMN`·`ADD/DROP CONSTRAINT`·identity 열 추가, 한 문장으로 여러 개체 `DROP`(`DROP SCHEMA a, b`만 됨), 임시 테이블의 시퀀스(`main`에 남음), 붙인 데이터베이스 안의 `CREATE SEQUENCE`, `CREATE TABLE AS`·`SELECT ... INTO`의 명령 태그 `SELECT n`(와이어 서버는 `CREATE TABLE`, `SELECT 0`: SQLite의 CREATE TABLE AS는 넣은 행을 `changes()`에 세지 않음) |
| 스키마 | 스키마 요소가 있는 `CREATE SCHEMA s CREATE TABLE ...`, `ALTER SCHEMA`, `ALTER TABLE ... SET SCHEMA`, `DROP SCHEMA public`, 이름에 `.`이 있는 스키마, 대소문자만 다른 두 스키마(SQLite의 이름 비교처럼 같은 이름), 다른 스키마의 뷰·외래 키가 기대는 것을 `CASCADE`가 따라 지우는 것, 여러 테이블을 지우는 `DROP SCHEMA ... CASCADE`의 auto_vacuum 데이터베이스(거부함), 상수가 아닌 `nextval(x)`의 `search_path`(이름 그대로 main에서 찾음), `public`에 이름이 `s.t`인 개체(스키마 `s`의 `t`와 겹침) |
| 절차·서버 | PL/pgSQL·`CREATE FUNCTION`·트리거, `LISTEN`/`NOTIFY`, `SET LOCAL`, `SET`의 트랜잭션 의미(롤백해도 남음), 격리 수준 |
| 오류 | 제약 위반·산술·저장 변환 밖의 실행 중 엔진 오류(SQLite 내장 함수가 내는 것 등)의 PostgreSQL 문구, 제약 위반의 `DETAIL` |
| 카탈로그 | 붙인 데이터베이스의 `information_schema`(`pg_catalog`에는 나옴), `pg_catalog`의 시스템 관계 자신(`pg_class`에 `pg_class`가 없음; `'pg_class'::regclass`는 1259), 시스템 열(`attnum < 0`), 시퀀스의 타입(`seqtypid` 언제나 `bigint`), 인덱스 방식(`USING gin`도 `btree`), 외래 키의 `conindid`(언제나 0: pgjdbc의 `getImportedKeys`가 `pkic.oid = con.conindid`로 조인해 행이 없음), CHECK 제약의 `conkey`(빈 배열), `pg_get_viewdef()`의 줄 바꿈, `pg_typeof()`의 식 타입(값으로 정함), 크기 함수(0), `COMMENT ON`의 인덱스·시퀀스·스키마·함수 |
| 셸 | dollar-quote 문장 분할(셸은 SQLite 규칙으로 문장을 나눔) |

## 검증

| 도구 | 하는 일 |
| --- | --- |
| `src/dialect/postgres/test.zig` | 종단 테스트 |
| `xqt dialect-diff pg tools/dialect/pg-array-cases.txt` | 배열과 `ANY`/`ALL`의 차등 비교. 기록(`tools/dialect/pg-expected/pg-array-cases.out`, PostgreSQL 18.6)과 비교하고 `zig build check`에 들어 있음. 29개 케이스 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-uuid-cases.txt` | `uuid`의 차등 비교(입력 형식과 오류, 열의 저장·순서·비교, 캐스트, JSON·배열, DEFAULT와 키, `uuidv4`/`uuidv7`의 버전·변형·순서, `uuid_extract_*`). 무작위·시각 값은 버전, 길이, 순서, 개수로 봄. 기록(`pg-uuid-cases.out`, PostgreSQL 18.6)과 비교하고 `zig build check`에 들어 있음. 12개 케이스 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-jsonb-cases.txt` | jsonb 열(JSONB로 저장)의 값, 연산자, 수정 함수, 비교·`ORDER BY`·`IN`·`BETWEEN`·`DISTINCT`·`GROUP BY`·조인, 만드는 함수와 집계, 집합 반환 함수와 jsonpath, 뷰·CHECK·생성 열·인덱스, `jsonb[]`, 큰 값, 첨자, json 열의 차등 비교. 기록(`tools/dialect/pg-expected/pg-jsonb-cases.out`, PostgreSQL 18.6)과 비교하고 `zig build check`에 들어 있음. 12개 케이스 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-numeric-cases.txt` | `numeric`의 차등 비교(입력, 산술과 스케일, 함수, 캐스트, 열과 인덱스·UNIQUE·외래 키, 집계, CHECK·생성 열·뷰, JSON·배열, 카탈로그). 기록과 비교하고 `zig build check`에 들어 있음. 13개 케이스 모두 같음. 회귀 테스트 `numeric`은 138문장 중 92(이전 52) |
| `xqt dialect-diff pg` + `tools/dialect/pg-cases.txt` | PostgreSQL과 차등 비교. 기본은 저장소에 기록해 둔 PostgreSQL 18.6의 출력(`tools/dialect/pg-expected/pg-cases.out`)과 비교하므로 서버가 필요 없고 `zig build check`에 들어 있음. 82개 케이스 모두 PostgreSQL 18과 같은 행·열 이름·오류를 냄(불리언 `t`/`f`는 1/0으로 맞춰 비교; PostgreSQL 18로 옮길 때 81/82, NOT NULL 제약을 더해 82/82). 오류를 내는 문장은 따로 모은 케이스에 있음(psql의 stderr와 stdout이 podman을 거치며 섞이는 순서가 일정하지 않음) |
| `xqt wire-diff pg` + `tools/dialect/pg-wire-cases.txt`, `pg-client-cases.txt` | 와이어 서버(`xqlite serve --pg`)를 psql 18로 PostgreSQL 18과 차등 비교(기본은 기록 `tools/dialect/pg-expected/pg-wire-cases.out`, `pg-client-cases.out`과: psql만 필요). psql 출력 전체(메타 명령 `\d` 계열, `\gdesc`, `\bind`, 명령 태그, 오류와 NOTICE)를 비교하고, 다른 케이스를 result(조용히 다른 답)·error(거부)·format(표기만 다름)으로 나눔. `pg-client-cases.txt`는 node-postgres·knex·Sequelize·SQLAlchemy·Django·pgjdbc·asyncpg·Prisma가 실제로 보낸 카탈로그 질의(서버 로그에서 모음). 처음 잰 값은 129개 중 22개가 같음(result 11, error 89, format 7): psql의 `\d` 계열과 ORM의 카탈로그 질의는 거의 모두 `pg_am`·`pg_type`·`pg_attribute`·`pg_index`가 없거나 `OPERATOR(pg_catalog.~)`·`!~`·`= ANY($1)`·`schema.table.column` 참조를 못 읽어 거부됨. PostgreSQL 16으로 52개, 18로 옮길 때 51개(psql 18이 `conperiod`·`datlocale`을 읽고, 버전이 16이었음), 지금 52개(result 11, error 55, format 11). 남은 error는 대부분 배열 문법(`= ANY`, `ARRAY(...)`, 첨자, `unnest`) |
| `xqt wire-diff pg --regress` + `tools/dialect/pg-regress` | PostgreSQL 회귀 테스트 9개(`boolean`, `int2`, `int4`, `int8`, `text`, `varchar`, `case`, `strings`, `uuid`)를 와이어 서버에서 돌려 PostgreSQL이 함께 내놓는 기대 출력과 문장별 통과율을 잼(psql만 필요). 처음 잰 값은 REL_16_STABLE의 951개 중 431개(45.3%), 그 뒤 440개. REL_18_STABLE의 파일(문장 1005개: `to_bin`/`to_oct`, `crc32`, bytea와 정수 변환, `reverse(bytea)` ... 이 더해짐)로 448개(44.5%). `uuid`는 43개 중 24개(55.8%): 나머지는 오류의 `LINE`/`DETAIL`(저장 함수가 실행 중에 냄), `pg_input_is_valid()`, `EXPLAIN`의 계획, `infinity` interval, 10000년 이후 `timestamptz`의 순서(TEXT), 여러 테이블의 `DROP TABLE` |
| `xqt interop ext` | [확장](extension.md)을 올린 sqlite3로: jsonb·배열·interval·numeric·boolean 열과 엔진 함수의 CHECK·생성 열·식 인덱스·뷰·collation이 있는 데이터베이스의 무결성, 같은 결과, CHECK 위반의 같은 오류, sqlite3가 쓴 행을 xqlite가 검사하고 읽음, 엔진 함수의 기록된 결과(`tools/ext/abi-pg*.sql`) |
| `xqt interop pg` | sqlite3 교차 검증. 이 방언으로 쓴 데이터베이스(`CREATE SCHEMA`의 테이블·뷰 포함)가 sqlite3 무결성 검사를 통과하고, sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 함. sqlite3의 `.tables`에 `sales.orders`가 나오고, sqlite3가 넣은 행을 이 방언이 `sales.orders`로 읽음. `jsonb` 열은 sqlite3의 `json_extract()`로 읽히고, sqlite3가 넣은 JSON을 이 방언의 연산자가 읽으며, sqlite3도 잘못된 JSON을 거부함 |

기준은 PostgreSQL 18(`postgres:18-alpine`, 18.6)입니다. 차등 비교는 기본으로 저장소에 기록해 둔 PostgreSQL의 출력(`tools/dialect/pg-expected`, 케이스 파일마다 하나)과 비교하므로 서버가 없어도 됩니다. `dialect-diff`는 xqlite만 필요해 `zig build check`에 들어 있고, `wire-diff`는 psql 18(호스트에 없으면 `podman run --rm -i postgres:18-alpine`)이 필요해 들어 있지 않습니다. 기록에는 서버의 `version()`과 psql의 버전, 케이스마다 그 글의 해시가 있어서, 기록에 없는 케이스(`NOT RECORDED`)와 글이 바뀐 케이스(`STALE RECORDING`)는 따로 찍고 실패로 셉니다. 케이스를 고치면 서버를 띄우고 `--record`로 다시 기록하고, `--live`는 서버와 지금 비교합니다(`$PG_PSQL`, 기본값 `podman exec -i xq-pg psql -U postgres`). 서버 쪽 경우들은 병렬로 돌고, 작업자마다 자기 데이터베이스(`xqt_dialect_PID_N`, `xqt_wire_PID_N`: 프로세스 ID가 들어가 같은 서버를 쓰는 다른 실행과 겹치지 않음)에서 `public` 스키마를 지우고 다시 만들고, 앞 경우가 만든 스키마를 지운 뒤 시작합니다. 회귀 테스트(`--regress`)는 기록하지 않고 PostgreSQL이 내놓는 `expected/*.out`을 그대로 씁니다([테스트](testing.md#와이어-차등-테스트-postgresql)). 모두 먼저 `zig build tools`가 필요합니다.

```sh
zig-out/bin/xqt dialect-diff pg         # 기록과 (서버 없이)
zig-out/bin/xqt wire-diff pg            # 와이어 서버 + psql, 기록과 ([테스트](testing.md#와이어-차등-테스트-postgresql))
zig-out/bin/xqt wire-diff pg --regress  # PostgreSQL 회귀 테스트 일부, 기대 출력과
zig-out/bin/xqt interop pg
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18-alpine
zig-out/bin/xqt dialect-diff pg --live  # 서버와 지금
zig-out/bin/xqt dialect-diff pg --record && zig-out/bin/xqt wire-diff pg --record  # 기록을 다시 씀
```
