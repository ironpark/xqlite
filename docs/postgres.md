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
| `funcs.zig` | 방언 함수와 엔진 함수(`xq_like`, 예전 정규식 연산자의 `xq_pg_regex` 등), `boolean`·`numeric`·`varchar(n)`·`char(n)` 열의 저장 함수 |
| `integer.zig` | 정수(`smallint`/`integer`/`bigint`)의 입력 `parse()`(PostgreSQL의 `int2in()` ...: 앞뒤 공백, `0x`/`0o`/`0b`, `_`; 캐스트·열에 넣는 값·`pg_input_is_valid()`가 함께 씀), 캐스트 `xq_pg_cast_int2/4/8()`, 정수 열의 저장 함수, `#`의 `xq_pg_int_xor()` |
| `are.zig` | PostgreSQL의 정규식 엔진(ARE, 아래 [정규식](#정규식)): Pike VM으로 일치 범위를, PostgreSQL의 분해 규칙으로 부분식을 찾음 |
| `regexp.zig` | `~` 연산자(`xq_pg_re()`), `SIMILAR TO`(`xq_pg_similar_escape()`), `regexp_*()` 함수, `substring(x FROM 패턴)` |
| `regex.zig` | 예전의 작은 정규식 엔진: jsonpath `like_regex`와, 예전 데이터베이스의 스키마가 부르는 `xq_pg_regex()` |
| `json.zig` | json/jsonb 값: PostgreSQL 규칙의 파싱, jsonb 정규화와 출력, 비교·포함, jsonb의 정준 JSONB(`toBlob()`, `fromBlob()`)와 정렬 키(`appendKey()`). JSONB 노드 읽기·검사·텍스트는 방언 밖의 `dialect/jsonb.zig`(값 표시도 씀) |
| `jsonpath.zig` | jsonpath의 부분집합 |
| `jfuncs.zig` | JSON 연산자·함수·집계·집합 반환 함수의 구현 |
| `array.zig` | 배열 값(PostgreSQL의 텍스트: `{1,2,NULL}`)의 읽기·쓰기, 원소 타입의 입력·출력, 배열의 엔진 함수(캐스트와 저장, `ARRAY[...]`, `ANY`/`ALL`, 첨자, `unnest()`의 행 ...)와 방언 함수(`array_length()` ...), collation `xq_pg_array`/`xq_pg_array_num` |
| `typing.zig` | 식 타입의 규칙(`Hooks.typing`, [아키텍처](architecture.md)의 코어의 타입): 리터럴·연산자·함수의 결과 타입 |
| `operators.zig` | 연산자 표(`pg_operator`처럼 연산자, 피연산자 타입, 결과 타입, 구현)와 PostgreSQL 규칙의 연산자 해석(아래 [연산자 해석](#연산자-해석)) |
| `ivinput.zig` | PostgreSQL 18의 interval 입력(`interval_in()`: `ParseDateTime()`, `DecodeInterval()`, ISO 8601)과 타입 수식자(`interval day to second(3)`), `EXTRACT`/`date_part`의 interval, `make_interval()`; 엔진 함수 `xq_pg_iv_in()`, `xq_pg_iv_extract()`, `xq_pg_iv_date_part()` |
| `datetime.zig` | `date`/`time`/`timestamp[tz]`/`interval` 값의 PostgreSQL 입력·출력, 그 연산자의 엔진 함수(`xq_pg_date_pli()`, `xq_pg_iv_interval_pl()` ...)와 캐스트(`xq_pg_date()`, `xq_pg_iv()` ...), interval BLOB의 함수(`xq_pg_iv_key()`, `xq_pg_iv_sum()`, `justify_*()` ...), `IntervalStyle`의 네 출력 형식(`formatIntervalStyle()`, `xq_pg_iv_out()`), 예전 텍스트 interval의 함수와 collation `xq_pg_interval`. interval 값 자체(필드, 연산, BLOB 인코딩)는 방언 밖의 `src/dialect/interval.zig` |
| `formatting.zig` | `to_char()`·`to_number()`·`to_date()`·`to_timestamp()`(아래 [형식 함수](#형식-함수)). 수의 템플릿은 `numformat.zig`, 날짜·시각의 템플릿은 `dtformat.zig`(PostgreSQL `formatting.c`의 이식) |
| `builtins.zig`, `dtfuncs.zig`, `inputinfo.zig` | `gcd`/`lcm`, `float8()`/`float4()`, `booleq`/`boolne`, `interval_hash()`; `date_trunc`, `date_bin`, `timezone()`(`AT TIME ZONE`); `pg_input_is_valid()`, `pg_input_error_info()` |
| `overload.zig` | 피연산자 타입에 따른 선택(`Rules.overload`): 산술·비트 연산자를 연산자 표로, 값만으로는 모르는 인자 타입을 알려 주는 호출(표 `kind_calls`: `to_char(x, t)` → `xq_pg_to_char(x, t, 종류)`, `gcd`·`lcm` → `xq_pg_gcd(a, b, 비트)`, `timezone` → `xq_pg_timezone(z, x, 종류)`, `x AT TIME ZONE z` → `xq_pg_at_time_zone(z, x, 종류)`), `jsonb`의 `\|\|`·비교·`ORDER BY`, interval의 비교·`ORDER BY`, `->`·`#>`의 json/jsonb 함수, JSON을 만드는 함수의 인자, 배열의 `\|\|`·비교·`ORDER BY`와 원소 타입을 알아야 하는 배열 함수(아래 [배열](#배열)). 이름을 해석한 코어가 부름. 아래 네 타입의 선택은 그 타입의 모듈(`repr/*.zig`)을 부르고, `IN`/`BETWEEN`·캐스트·`GROUP BY`·`ORDER BY`는 기술자 표(`repr.zig`)에서 찾음 |
| `repr.zig` | 자기 형태의 BLOB으로 저장하는 타입(`numeric`, `interval`, `uuid`, `jsonb`; 예전 테이블에서는 텍스트나 수)마다 기술자 `TypeRepr`: 저장 함수(`store`, 다른 타입 열로의 `store_into`), `IN`/`BETWEEN`(`list`), 캐스트(`cast`), `GROUP BY` 키, `ORDER BY` 키·collation, JSON을 만드는 함수의 인자, 카탈로그의 기본값 텍스트(`default_text`, `default_bare`). `typing.zig`의 규칙(`store_column`, `store_forms`, `group_key`, `order_key`)과 `overload.zig`가 이 표를 씀. 타입마다의 구현은 `repr/numeric.zig`, `repr/interval.zig`, `repr/uuid.zig`, `repr/jsonb.zig` |
| `operand.zig` | `overload.zig`와 타입 모듈이 해석된 식에 묻는 것(타입, 자기 타입이 없는 피연산자, 부르는 함수 이름) |
| `jtype.zig` | 파싱 뒤, 타입이 아니라 이름과 FROM 구조로 정하는 JSON: 값으로 쓴 FROM 항목(행), FROM의 JSON 집합 반환 함수 열과 그 옆의 `*`, json/jsonb 열에 저장하는 값의 정규화 |
| `ddltype.zig` | 스키마가 텍스트로 남기는 문장(뷰, CHECK, 생성 열, 식 인덱스)에 코어의 선택을 되돌려 씀: 식을 내리고 해석만 하는 probe |
| `session.zig` | `CREATE SCHEMA`/`DROP SCHEMA`, `SET`/`RESET`/`SHOW`, `COMMENT ON`, `set_config()`/`current_setting()`/`current_schema()`/`current_schemas()` |
| `state.zig` | 연결별 세션 상태(`search_path`와 그 밖의 매개변수, 시작 값, 카탈로그 스냅숏), 따르는 릴리스(18.6) |
| `catalog_views.zig` | `information_schema`/`pg_catalog` 뷰 |
| `pgcatalog.zig` | 시스템 카탈로그: 메모리의 스키마에서 만든 스냅숏, OID, 엔진 테이블 값 함수 `xq_pg_class` ... |
| `syscatalog.zig` | 시스템 관계(`pg_class`, `information_schema.tables` ...)의 `pg_class`·`pg_attribute`·`pg_index`·`pg_constraint` 행. PostgreSQL 18에서 `tools/dialect/pg-syscatalog.sql`로 생성 |
| `catalog_funcs.zig` | 카탈로그 함수(`pg_get_indexdef()`, `pg_table_is_visible()` ...)와 reg* 타입의 입출력 |
| `test.zig` | 종단 테스트 |

## 지원 범위

### 어휘

- 따옴표 없는 식별자는 소문자로 접고, `"Quoted"`는 그대로 둡니다.
- 문자열: `'...'`(`''`로 따옴표, 줄바꿈이 든 공백 사이 이어 붙이기: 사이에 주석이 있으면 이어지지 않아 문법 오류), `E'...'` 이스케이프(`\uXXXX`·`\UXXXXXXXX`, UTF-16 서로게이트 쌍은 한 문자로: `E'\uD83D\uDE00'`), `U&'...'`와 `U&"..."`(`\XXXX`, `\+XXXXXX`, `\\`; `UESCAPE '!'`로 이스케이프 문자를 바꿈), `$$...$$`/`$tag$...$tag$`. `SET standard_conforming_strings = off`이면 그 뒤 문장의 `'...'`와 `N'...'`도 `E'...'`처럼 백슬래시 이스케이프를 읽고(`'it\'s'`), `U&'...'`는 `unsafe use of string constant with Unicode escapes`(0A000, DETAIL과 함께)입니다(기본은 `on`). `escape_string_warning`의 경고는 내지 않습니다. 유니코드 이스케이프의 오류는 PostgreSQL의 문구와 위치(`invalid Unicode escape`, `invalid Unicode surrogate pair`, `invalid Unicode escape value`, `UESCAPE must be followed by a simple string literal`, `invalid Unicode escape character`)입니다. `HINT`는 없습니다.
- 매개변수 `$1`은 `?1`이 됩니다.
- 주석: `--`, 중첩 `/* */`.
- 연산자: `::`. `a<-1`은 PostgreSQL처럼 `a < -1`입니다.
- 숫자: 16진(`0x1F`)·8진(`0o17`)·2진(`0b101`), `1_000`(지수에도: `1_0e1_0`). bigint를 넘는 16진·8진·2진 정수는 10진 정수처럼 `numeric`입니다. 오류도 PostgreSQL의 스캐너와 같습니다: `0x`, `0x_`는 `invalid hexadecimal integer`, `0x1g`, `0b102`, `1__0`, `100_`은 `trailing junk after numeric literal`.
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
- `SET`은 이 밖에 드라이버가 연결할 때 쓰는 매개변수(`application_name`, `client_encoding`, `client_min_messages`, `DateStyle`, `IntervalStyle`, `TimeZone`, `extra_float_digits`, `standard_conforming_strings`(어휘를 바꿈: 위 [어휘](#어휘)), `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, `bytea_output`, `default_transaction_isolation`, `transaction_isolation`, `transaction_read_only`, `lc_messages` ... 40여 개)를 받아 `SHOW`가 그 값을 보여 줍니다(`IntervalStyle`·`standard_conforming_strings` 말고는 동작을 바꾸지 않음). `IntervalStyle`은 `postgres`, `postgres_verbose`, `sql_standard`, `iso_8601`만 받고(대소문자 무관, `SHOW`는 소문자) 다른 값은 `invalid value for parameter "IntervalStyle": "x"`(22023)와 그 `HINT`입니다([interval](#interval)). `client_min_messages`도 같은 식으로 `debug5` ... `debug1`, `log`, `notice`, `warning`, `error`(숨은 `debug`는 `debug2`, `info`)만 받고, `standard_conforming_strings`는 불리언(`on`, `off`, `true`, `no`, `1` ...: `SHOW`는 `on`/`off`)이 아니면 `parameter "standard_conforming_strings" requires a Boolean value`(22023)입니다. 시작 패킷의 값(서버의 `options`)도 같은 검사를 거칩니다. `SET TIME ZONE 'UTC' | LOCAL | INTERVAL '+00:00' HOUR TO MINUTE`도 됩니다. 모르는 이름은 `unrecognized configuration parameter "x"`입니다. `RESET ALL`, `SET TRANSACTION ...`(무시)도 됩니다.
- 읽기 전용: `server_version`(`18.6 (xqlite)`), `server_version_num`(`180006`), `server_encoding`, `integer_datetimes`, `is_superuser`, `in_hot_standby`, `max_identifier_length`, `block_size`, `lc_collate`, `lc_ctype` .... `SET`하면 `parameter "server_version" cannot be changed`(55P02)입니다. `version()`은 `PostgreSQL 18.6 (xqlite 3.54.1)`입니다.
- `SHOW`의 열 이름은 PostgreSQL의 철자(`DateStyle`, `TimeZone`)이고, `SHOW TRANSACTION ISOLATION LEVEL`(`read committed`), `SHOW SESSION AUTHORIZATION`, `SHOW ALL`(`pg_settings`의 이름·값·설명)도 됩니다. `transaction_isolation`은 PostgreSQL의 기본값 `read committed`를 보여 줍니다(실제로는 SQLite의 직렬화).
- 와이어 서버가 시작 패킷의 값(`application_name`, `options`)을 정하면 `RESET`은 기본값이 아니라 그 값으로 돌아갑니다(`xq_pg_startup_setting()`). `current_database()`는 클라이언트가 준 데이터베이스 이름이고 서버 밖에서는 `postgres`입니다.

### 식과 연산자

| 영역 | 지원 |
| --- | --- |
| 캐스트 | `::type`, `CAST`, 타입 리터럴(`DATE '2024-01-01'`, `INTERVAL '1-2' YEAR TO MONTH`, `INTERVAL(2) '1.234 sec'`) |
| NULL·진리값 | `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN` |
| 술어 | `BETWEEN`, `IN (목록\|서브쿼리)`, `x op ANY\|SOME\|ALL (배열\|서브쿼리)`(`= <> < <= > >=`, `[NOT] LIKE`, `[NOT] ILIKE`), `EXISTS` |
| 패턴 | `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE`, 정규식 `~`/`~*`/`!~`/`!~*`(`xq_pg_re()`, 아래 [정규식](#정규식)), `[NOT] SIMILAR TO 패턴 [ESCAPE e]`(PostgreSQL처럼 `x ~ similar_to_escape(패턴, e)`) |
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
| 정수(`smallint`/`integer`/`bigint`의 모든 쌍, 넓은 쪽), `real`, `double precision`의 `+ - * /`; 같은 타입의 `%`(실수의 `%`는 없음); 단항 `-`; 정수의 `& \|`와 `<< >>`(오른쪽 `integer`) | 엔진의 연산 코드(SQLite의 바이트코드). 문자열 상수는 그 정수 타입으로 읽음(`xq_pg_cast_int4('a')`: `'a' + 1`은 `invalid input syntax for type integer: "a"`) |
| 같은 정수 타입의 `#`(배타적 논리합) | `integer.zig`의 엔진 함수 `xq_pg_int_xor()`(연산 코드가 없음; 파서가 호출로 만들고 `overload.zig`가 표로 타입을 검사: `text # integer`는 `operator does not exist`) |
| `numeric`의 `+ - * / %`, 단항 `-` | `xq_dec_add()` ... `xq_dec_neg()`: 정확한 키([numeric](#numeric)) |
| `date ± integer` → `date`, `date - date` → `integer`, `date ± interval`·`date + time` → `timestamp`, `timestamp[tz] ± interval` → 같은 타입, `timestamp[tz] - timestamp[tz]` → `interval`, `time ± interval` → `time`, `time - time`, `interval ± interval`, `-interval`, `interval * double precision`, `interval / double precision` → `interval`(교환한 행 포함) | `datetime.zig`의 엔진 함수 `xq_pg_<PostgreSQL 구현 이름>`(`xq_pg_date_pli`, `xq_pg_timestamp_pl_interval`, `xq_pg_interval_mul` ...) |
| `jsonb - text`, `jsonb - integer`, `jsonb - text[]` | `xq_pg_jsonb_delete()`, `xq_pg_jsonb_delete_keys()` |

- 달 더하기는 PostgreSQL처럼 달, 날, 시간 순서이고 달의 마지막 날로 맞춥니다(`date '2024-01-31' + interval '1 month'`은 `2024-02-29 00:00:00`). 타임스탬프의 차는 날과 시간의 interval입니다(`justify_hours()`: `1 day 02:00:00`, `-1 days -02:00:00`). `interval * 수`·`/ 수`는 달의 나머지를 30일로, 날의 나머지를 시간으로 내립니다(`interval '1 month' / 2`는 `15 days`).
- interval은 세션의 `IntervalStyle`로 보입니다. 기본(postgres)은 `1 day`, `1 day 02:00:00`, `-1 mons`, `3 years 2 mons`, `-1 days +01:00:00`, `infinity`/`-infinity`이고, 다른 형식은 아래 [interval](#interval)에 있습니다.
- interval 연산은 PostgreSQL 18의 것입니다: 무한의 규칙(`infinity + 1 day`는 `infinity`, `infinity - infinity`와 `infinity * 0`은 `interval out of range`, `time + infinity`는 `cannot add infinite interval to time`), 필드가 넘치면 `interval out of range`, 곱셈·나눗셈의 반올림은 `rint()`(짝수 쪽).
- 피연산자 하나라도 타입을 모르면(SQLite 테이블의 열, 규칙이 없는 함수) 표를 보지 않고 SQLite의 연산입니다(오류 없음). 매개변수와 NULL은 문자열 상수처럼 어느 타입과도 맞지만 문장을 실패시키지 않고, 행이 정해지면 매개변수는 그 행의 타입을 받습니다(`ts + $1`의 `$1`은 `interval`). 문자열 상수끼리(`'1' + '2'`)도 SQLite의 연산입니다.
- `||`는 표에 없습니다(PostgreSQL의 `text || anynonarray`는 어느 타입이나 받으므로). jsonb의 `||`와 비교는 `overload.zig`의 따로 된 선택이고, jsonb `-`의 오른쪽이 표가 모르는 타입(SQLite 열, `int[]`)일 때도 그쪽이 고릅니다.
- 뷰, CHECK, 생성 열, 식 인덱스의 텍스트에는 고른 함수가 남습니다(`xq_pg_date_pli("d", 1)`). 어느 방언의 연결에서 읽어도 같은 뜻입니다.

### 함수

SQLite 내장 함수에 더해 다음을 지원합니다. 같은 이름의 SQLite 내장(`random()`, `floor()` 등)은 이 방언에서 가려집니다.

| 분류 | 함수 |
| --- | --- |
| 날짜·시각 | `now()`, `current_timestamp`, `localtimestamp`, `current_date`, `extract(field FROM x)`/`date_part`(timestamp와 [interval](#interval)), `make_interval()`, `date_trunc(unit, x)`(timestamp·timestamptz·interval; date는 timestamptz로), `date_bin(stride, ts, origin)`, `timezone(zone, x)`과 `x AT TIME ZONE zone`·`AT LOCAL`(아래 [형식 함수](#형식-함수)); 연산자는 위 [연산자 해석](#연산자-해석) |
| 형식 | `to_char`, `to_number`, `to_date`, `to_timestamp(text, text)`, `to_timestamp(double)`(아래 [형식 함수](#형식-함수)) |
| 입력 검사 | `pg_input_is_valid(text, type)`, `pg_input_error_info(text, type)`(FROM에서; 아래 [형식 함수](#형식-함수)) |
| 인자 | 이름 붙은 인자 `f(name := v)`/`f(name => v)`(`make_interval`, `make_date`, `make_time`, `make_timestamp`의 매개변수 이름; 위치 인자 뒤에만, 주지 않은 것은 기본값), `VARIADIC`(아래) |
| 문자열 특수 문법 | `substring(x FROM a FOR b)`, `substring(x FROM 패턴)`·`substring(x SIMILAR 패턴 ESCAPE e)`(아래 [정규식](#정규식)), `position(a IN b)`, `trim([BOTH\|LEADING\|TRAILING] [c] FROM x)` |
| 정규식 | `regexp_match`, `regexp_matches`(집합 반환, `'g'`), `regexp_replace`, `regexp_split_to_table`/`regexp_split_to_array`, `regexp_count`, `regexp_instr`, `regexp_substr`, `regexp_like`, `similar_to_escape`(아래 [정규식](#정규식)) |
| 문자열 | `strpos`, `left`/`right`, `concat`/`concat_ws`, `lpad`/`rpad`, `repeat`, `reverse`, `split_part`, `starts_with`, `btrim`, `char_length`, `ascii`/`chr` |
| 집계 | `string_agg`, `bool_and`/`bool_or`/`every`, `array_agg`(윈도우 함수로도) |
| 배열 | 아래 [배열](#배열) |
| 비교 | `greatest`/`least`(NULL은 건너뜀) |
| 수학 | `floor`, `ceil`, `sqrt`, `power`, `exp`, `ln`, `log`, `log10`, `mod`, `trunc`, `sign`, `pi`, `factorial`, `width_bucket`, `gcd`/`lcm`(정수는 `integer out of range`·`bigint out of range`, numeric은 큰 쪽 스케일, NaN·무한은 NaN), `float8(x)`/`float4(x)` |
| 불리언·해시 | `booleq`/`boolne`, `interval_hash()`(같은 interval이면 같은 값; PostgreSQL의 수와는 다름) |
| 난수·UUID | `random()`(0 이상 1 미만 실수), `gen_random_uuid()`, `uuidv4()`, `uuidv7([shift interval])`, `uuid_extract_version()`, `uuid_extract_timestamp()`(아래 [uuid](#uuid)) |
| 시스템 | `version()`, `current_user`, `current_database()`, `current_schema`, `current_schemas(bool)`, `current_setting(name [, missing_ok])`, `set_config(name, value, false)`, `format_type(oid, typmod)`(와이어 서버가 알리는 타입 OID의 이름, psql의 `\gdesc`), `pg_backend_pid()`, `pg_is_in_recovery()`, `quote_ident`/`quote_literal`/`quote_nullable` |
| 카탈로그 | 아래 [카탈로그](#카탈로그)의 함수 |
| 시퀀스 | 시퀀스 함수(`nextval()` 등) |
| JSON | 아래 [JSON](#json) |

- 이름 붙은 인자는 파서가 매개변수 자리로 옮깁니다. 모르는 이름이나 이름 붙은 인자를 받지 않는 함수는 `function make_interval(foo => integer) does not exist`(42883, 인자 타입은 리터럴이 알려 주는 만큼), 이름 붙은 인자 뒤의 위치 인자는 `positional argument cannot follow named argument`, 같은 이름 둘은 `argument name "x" used more than once`입니다.
- `VARIADIC`은 마지막 인자에만 씁니다. `concat(VARIADIC a)`·`concat_ws(sep, VARIADIC a)`는 `array_to_string(a, sep)`(원소의 텍스트, NULL 원소는 건너뜀, 배열이 NULL이면 NULL), `format(fmt, VARIADIC ARRAY[...])`와 `json[b]_build_array/object(VARIADIC ARRAY[...])`는 원소를 그대로 인자로 펼칩니다(`VARIADIC NULL::t[]`은 인자 없음). 배열이 아닌 상수는 `VARIADIC argument must be an array`(42804), 그 밖의 함수는 `function f(integer[]) does not exist`입니다.

### 정규식

`~` 연산자, `SIMILAR TO`, `regexp_*()` 함수는 PostgreSQL의 고급 정규식(ARE)을 `are.zig`가 그대로 따릅니다.

- 문법: `.`, `[...]`/`[^...]`(범위, `[:alpha:]` 같은 POSIX 문자 클래스 `alnum alpha ascii blank cntrl digit graph lower print punct space upper word xdigit`, `[.c.]`, `[=c=]`), `\d \s \w \D \S \W`, 문자 이스케이프(`\n \t \uXXXX \UXXXXXXXX \xhh \0oo \cX` ...), 역참조 `\1` ... `\mnn`, 제약 `^ $ \A \Z \m \M \y \Y`, 전방·후방 탐색 `(?=...) (?!...) (?<=...) (?<!...)`, `(...)`·`(?:...)`·`(?#...)`, `|`, 수량자 `* + ? {m} {m,} {m,n}`(255까지)와 그 non-greedy 형(`*?` ...), `***=`(나머지는 글자 그대로)와 `***:`, 맨 앞의 포함 옵션 `(?inx...)`.
- 플래그(`regexp_*()`의 `flags`, 포함 옵션): `i`/`c`(대소문자), `n`/`m`, `p`, `w`, `s`(줄바꿈 민감), `x`(공백과 `#` 주석 무시), `t`, `q`(패턴이 글자 그대로), `e`(ERE: 백슬래시는 다음 글자 그대로, `(?`와 non-greedy 없음), `g`(모든 일치: `regexp_matches`, `regexp_replace`). 모르는 글자는 `invalid regular expression option: "z"`, `g`를 받지 않는 함수는 `regexp_match() does not support the "global" option`(`regexp_match`는 HINT와 함께)입니다.
- 일치는 PostgreSQL의 규칙입니다. 가장 왼쪽에서 시작하는 일치 중, 식 전체가 greedy면 가장 긴 것, 아니면 가장 짧은 것입니다(식의 greediness는 처음으로 greediness가 있는 수량자가 정하고, `|`는 greedy). 그 범위 안에서 부분식은 앞의 것부터 자기 greediness대로 나눕니다: `regexp_match('abc01234xyz', '(.*?)(\d+)(.*)')`는 `{abc,0,""}`, `regexp_match('abcd', '(a|ab)(c|bcd)(d*)')`는 `{ab,c,d}`. 반복된 그룹은 마지막 반복의 것이고, `x{m,n}`(m ≥ 1)은 PostgreSQL처럼 `x{m-1,n-1}` 뒤의 마지막 `x`로 나눕니다(`regexp_match('aaa', '(a*)+')`는 `{""}`, `'(a*)*'`는 `{aaa}`).
- 일치 범위는 Pike VM이 찾으므로(역추적 없음) `(a*)*b` 같은 패턴도 입력 길이에 비례합니다. 역참조가 있는 식만 역추적으로 맞춥니다. 후방 탐색은 거꾸로 읽는 프로그램으로 그 위치에서 뒤로 한 번 돌립니다. 그룹을 쓰지 않는 호출(`~`, `regexp_count`, `regexp_like`, `regexp_split_*`, `subexpr`가 0인 `regexp_instr`/`regexp_substr`, `\1`..`\9`가 없는 `regexp_replace`)은 부분식을 나누지 않습니다.
- 컴파일한 패턴은 상수면 문장에 두고, 행마다 바뀌는 패턴은 PostgreSQL의 `RE_compile_and_cache()`처럼 연결마다 최근 32개를 둡니다.
- 오류는 `invalid regular expression: parentheses () not balanced`, `... brackets [] not balanced`, `... braces {} not balanced`, `... invalid repetition count(s)`, `... quantifier operand invalid`, `... invalid escape \ sequence`, `... invalid backreference number`, `... invalid character class`, `... invalid character range`, `... invalid embedded option`(2201B)입니다.
- 함수: `regexp_match(s, p [, flags])`(그룹의 `text[]`, 그룹이 없으면 일치 전체, 없으면 NULL), `regexp_matches(s, p [, flags])`(행마다 `text[]`; FROM과 select 목록에서), `regexp_replace(s, p, r [, start [, N]] [, flags])`(`\1`..`\9`, `\&`, `\\`; 네 번째 인자가 수이면 start, 텍스트면 flags), `regexp_split_to_table`/`regexp_split_to_array(s, p [, flags])`, `regexp_count(s, p [, start [, flags]])`, `regexp_instr(s, p [, start [, N [, endoption [, flags [, subexpr]]]]])`, `regexp_substr(s, p [, start [, N [, flags [, subexpr]]]])`, `regexp_like(s, p [, flags])`. 위치는 문자 단위이고, 범위 밖의 `start`/`N`/`endoption`/`subexpr`는 `invalid value for parameter "start": 0`(22023)입니다.
- `substring(x FROM 패턴)`(`substring(x, 패턴)`도)은 첫 그룹이(없으면 일치 전체) 맞은 부분, `substring(x SIMILAR 패턴 ESCAPE e)`와 `substring(x FROM 패턴 FOR e)`는 SIMILAR 패턴의 두 `e"` 사이입니다. 패턴이 문자열 상수일 때 고르고(PostgreSQL의 `substring(text, text)`), 그 밖은 `substr()`입니다.
- `SIMILAR TO`는 PostgreSQL처럼 `similar_to_escape()`로 정규식을 만들어 `~`로 맞춥니다(`%`는 `.*`, `_`는 `.`, `(`는 갈무리하지 않는 그룹, 기본 이스케이프는 `\`, `ESCAPE ''`는 이스케이프 없음, `ESCAPE NULL`이면 NULL). 두 글자 이상의 이스케이프는 `invalid escape string`(HINT와 함께)입니다.
- 대소문자 무시(`i`, `~*`)와 문자 클래스는 ASCII에 더해 라틴 문자·그리스 문자·키릴 문자의 대소문자를 압니다. 그 밖의 ASCII 밖 문자는 글자(`[[:alpha:]]`)로 보고, 대소문자가 없는 것으로 봅니다.
- 예전 데이터베이스의 스키마(CHECK, 식 인덱스, 뷰)에 남은 `xq_pg_regex()`는 예전 엔진(`regex.zig`) 그대로 계산합니다. 새 스키마는 `xq_pg_re()`를 씁니다.

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

### 형식 함수

PostgreSQL의 `formatting.c`를 옮겼습니다. 로캘은 C입니다(`D` 소수점 `.`, `G` `,`, `L` 공백, 달·요일 이름은 영어, `TM`은 붙이지 않은 것과 같음).

- `to_char(수, 템플릿)`: `9`, `0`, `.`/`D`, `,`/`G`, `S`, `MI`, `PL`, `SG`, `PR`, `FM`, `TH`/`th`, `L`, `RN`/`rn`, `V`, `EEEE`, `"..."`와 `\` 이스케이프, 그 밖의 글자. 값보다 템플릿이 좁으면 `#`. 정수(`integer`·`smallint`는 `int4_to_char`, `bigint`는 `int8_to_char`: `V`의 넘침 오류가 타입마다), 실수(C의 `printf("%.*f")`처럼 이진 값을 반올림, 자릿수는 `DBL_DIG`·`FLT_DIG`까지), numeric(키를 그대로 읽어 반올림). 템플릿 오류(`multiple decimal points`, `"RN" is incompatible with other formats` ...)는 PostgreSQL의 문구와 SQLSTATE 42601, DETAIL이 있는 것(`"EEEE" may only be used together with digit and decimal point patterns.`)은 그 줄도 붙입니다.
- `to_char(timestamp|timestamptz|date|interval|time, 템플릿)`: `YYYY`, `MM`, `Mon`, `Month`, `DD`, `Day`, `Dy`, `DDD`, `IW`, `IYYY`, `J`, `Q`, `RM`, `HH`/`HH12`/`HH24`, `MI`, `SS`, `MS`, `US`, `FF1`-`FF6`, `SSSS`, `AM`/`PM`, `AD`/`BC`, `TZ`(timestamptz는 `UTC`, timestamp는 빈 문자열), `OF`(`+00`), 접미사 `FM`, `TH`, `FX`. 빈 템플릿과 무한 interval은 NULL.
- `to_number(text, 템플릿)`: numeric. `V`는 10^-n을 곱함(스케일 16 + n), `RN`은 로마 숫자를 읽음(`invalid Roman numeral`). 템플릿의 자릿수를 넘으면 `numeric field overflow`와 그 DETAIL.
- `to_date(text, 템플릿)`, `to_timestamp(text, 템플릿)`: PostgreSQL의 `DCH_from_char()`/`do_to_timestamp()`(구분자 건너뛰기, `FX`, 두 자리 연도의 2020 기준, ISO 주, `TZH:TZM`/`TZ` 약어의 오프셋, 범위·충돌 오류). 결과의 timestamptz는 UTC.
- 템플릿은 문장마다 한 번 읽어 둡니다(`sqlite3_set_auxdata()`). 상수 템플릿이면 행마다 다시 읽지 않습니다. `pg_input_is_valid()`/`pg_input_error_info()`의 타입 이름도 같습니다.
- 값만으로는 timestamp와 timestamptz와 date(모두 텍스트), integer와 bigint를 가릴 수 없으므로, 인자의 타입을 아는 호출은 `xq_pg_to_char(x, 템플릿, 종류)`가 됩니다(`overload.zig`의 표 `kind_calls`). 타입을 모르는 값(SQLite 열)은 저장 형식으로 읽습니다: 정수는 bigint, REAL은 double precision, numeric 키는 numeric, interval BLOB은 interval, 텍스트는 timestamp.
  - 스키마가 남기는 식(CHECK, 식 인덱스, 생성 열, 뷰)에도 종류가 적힙니다(`ddltype.zig`): `CHECK (to_char(z, 'TZ') <> '')`는 `xq_pg_to_char("z", 'TZ', 7)`, `CHECK (gcd(a, 0) > 0)`은 `xq_pg_gcd("a", 0, 32)`로 남아 질의와 같은 값을 읽습니다(integer의 `gcd(-2147483648, 0)`은 `integer out of range`). 종류와 비트의 수는 파일 형식의 일부입니다. `pg_get_constraintdef()`·`pg_get_viewdef()`는 원래 호출(`to_char(z, 'TZ'::text)`)로 보여 줍니다.
  - 그 전에 만든 스키마의 `xq_postgres_to_char("z", 'TZ')`, `xq_postgres_gcd("a", 0)`은 적힌 뜻(저장 형식으로 읽음) 그대로입니다. 다시 컴파일할 때 종류를 더하지 않습니다: 식 인덱스와 STORED 생성 열이 디스크에 남긴 결과, 확장을 올린 sqlite3의 계산과 같아야 하기 때문입니다. 같은 식을 다시 만들면(DROP 후 CREATE, `CREATE OR REPLACE VIEW`) 종류가 적힙니다.
- `pg_input_is_valid(text, type)`, `pg_input_error_info(text, type)`: 타입 이름을 캐스트처럼 읽고(`int4`, `numeric(7,4)`, `varchar(4)`), 그 타입으로의 캐스트가 부르는 함수(`xq_pg_int4()`, `xq_dec()`, `xq_pg_iv()`, `xq_pg_uuid()`, `xq_pg_bool()` ...)를 오류를 잡는 호출로 불러 그 문구와 SQLSTATE를 돌려줍니다. `numeric(p,s)`의 넘침에는 `apply_typmod()`의 DETAIL을 채웁니다. SQLite 캐스트를 쓰는 타입은 따로 읽습니다: `real`·`double precision`(`float8in()`), `bytea`(16진·이스케이프 형식), `varchar(n)`·`char(n)`(넘는 부분이 공백이면 통과), `int2vector`·`oidvector`. 다른 타입(`text` ...)은 무엇이든 통과. `pg_input_error_info()`는 FROM의 함수로만(열 `message`, `detail`, `hint`, `sql_error_code`; 유효하면 NULL 한 행).
- `timezone(zone, x)`/`x AT TIME ZONE zone`(`AT TIME ZONE`은 왼쪽 결합: `x AT TIME ZONE 'UTC' AT TIME ZONE 'EST'`는 `(x AT TIME ZONE 'UTC') AT TIME ZONE 'EST'`): timestamp는 그 시간대의 지역 시각으로 보고 timestamptz를, timestamptz(와 date)는 그 시간대의 지역 시각(timestamp)을 돌려줍니다. 시간대는 interval(UTC에서 동쪽으로의 고정 오프셋, 무한·달·날이 있으면 오류), PostgreSQL 기본 약어 집합의 약어(`UTC`, `Z`, `EST`, `PDT`, `CET`, `JST` ...: `to_timestamp()`의 `TZ`가 읽는 것과 같음), POSIX 오프셋(`'+05'`는 UTC 서쪽 5시간)입니다. tz 데이터베이스의 이름(`America/New_York`)은 `time zone "..." not recognized`, `time`·`timetz`의 `AT TIME ZONE`은 지원하지 않습니다.

### interval

interval은 정렬 키와 필드를 붙인 32바이트 BLOB입니다(`src/dialect/interval.zig`). 앞 16바이트는 PostgreSQL의 `interval_cmp_value()`(한 달 = 30일, 하루 = 24시간인 마이크로초, 128비트, 부호 비트를 뒤집은 big-endian)이고, 뒤 16바이트는 필드(달 `i32`, 날 `i32`, 마이크로초 `i64`, 같은 방식)입니다. 그래서 `memcmp`의 순서가 PostgreSQL의 순서입니다. `'1 mon'`과 `'30 days'`는 길이가 같지만 다른 값이라(`date + '1 mon'`과 `date + '30 days'`는 다름) 필드를 남깁니다. 이 인코딩은 파일 형식이라 바뀌지 않습니다.

| 쓰는 곳 | xqlite |
| --- | --- |
| 정렬, 인덱스, `min`/`max` | BLOB 그대로(SQLite의 BINARY). BLOB 열의 인덱스가 `ORDER BY`와 범위 검색을 맡음 |
| `=`, `<>`, `IS [NOT] DISTINCT FROM`, `IN (...)`, `BETWEEN` | 키(`xq_pg_iv_key()`)끼리: `'1 mon' = '30 days'` |
| BLOB 열과 `<`, `<=`, `>`, `>=` | 열은 그대로, 상대는 그 길이의 경계(`< xq_pg_iv_key(x)`, `<= xq_pg_iv_high(x)`): 인덱스 범위 검색 |
| `GROUP BY`, `DISTINCT`, 창의 `PARTITION BY`·`ORDER BY`, 여러 항의 `ORDER BY`의 마지막이 아닌 항 | 키로(같은 길이는 같은 그룹·동점). `DISTINCT`는 결과 열의 `GROUP BY`가 됨 |
| `::text`, `\|\|`, `concat()`, `format()`, JSON | 세션의 `IntervalStyle`로 쓴 텍스트(`xq_pg_iv_out()`, 결정적이지 않음) |
| 배열의 원소 | 기본 형식의 텍스트(`xq_pg_iv_text()`): 배열이 저장하는 형태. 보일 때 세션의 형식으로 |
| `sum()`, `avg()` | `xq_pg_iv_sum()`/`xq_pg_iv_avg()`: PostgreSQL처럼 필드별 합, 평균은 `interval / 개수`, 무한은 같은 부호면 그 무한·다르면 `interval out of range`. 창 함수로도 |
| 입력(캐스트, 리터럴, 열에 넣는 값, 연산자의 문자열 상수 피연산자) | `xq_pg_iv_in(x, typmod)`(`ivinput.zig`): PostgreSQL 18의 `interval_in()`. 연산자의 상수는 `xq_pg_iv_in('1 hour', -1)`. `IntervalStyle` sql_standard인 세션에서 컴파일한 캐스트·리터럴·`DEFAULT`는 `xq_pg_iv_in(x, typmod, 1)`(그 부호 규칙), 열에 넣는 값은 실행할 때의 세션으로 읽음. interval을 받는 함수(`uuidv7(interval)`, `to_char()`, `EXTRACT` ...)와 서버가 받는 매개변수도 같은 입력 |
| `EXTRACT(f FROM x)`, `date_part(f, x)` | `xq_pg_iv_extract()`(`numeric`), `xq_pg_iv_date_part()`(`double precision`) |
| `justify_hours()`, `justify_days()`, `justify_interval()`, `isfinite()`, `make_interval()` | 방언 함수(BLOB을 돌려줌) |
| 셸, 서버 | 값 표시 계층이 BLOB을 세션의 `IntervalStyle`로 쓴 텍스트로(`valuetext.Settings`). 서버의 바이너리 형식은 PostgreSQL의 `interval_send`(마이크로초 `int64`, 날 `int32`, 달 `int32`), 매개변수도 |

- `IntervalStyle`(`SET IntervalStyle = ...`)은 연결의 설정이고 출력할 때만 읽습니다. 저장된 값(BLOB, 배열의 텍스트)은 어느 형식에서나 같습니다. PostgreSQL 18의 `EncodeInterval()`과 같이 씁니다.
  - `postgres`(기본): `1 day 02:00:00`, `-1 days +02:03:04`
  - `postgres_verbose`: `@ 1 day 2 hours`, `@ 1 day ago`, `@ 1 day -1 sec`, `@ 0.5 secs ago`, `@ 0`
  - `sql_standard`: `1 2:00:00`, `-1-2`, `0`, 부호가 섞이면 모든 부호를 씀(`+1-2 -3 +4:05:06`)
  - `iso_8601`: `P1DT2H`, `P-1Y-2M3DT-4H-5M-6S`, `PT0S`
  - 무한은 어느 형식에서나 `infinity`/`-infinity`입니다.
  - 형식을 따르는 곳: 셸과 와이어 서버의 값(텍스트 형식, interval 배열의 원소, 예전 데이터베이스의 TEXT 열), `::text`·`||`·`concat()`·`format()`·JSON(`xq_pg_iv_out()`), 제약 위반의 `DETAIL`. 뷰의 `v::text`도 읽을 때의 세션을 따릅니다(PostgreSQL과 같음). 와이어 서버는 바뀐 값을 다음 `ReadyForQuery` 앞에 `ParameterStatus`로 알립니다.
  - `xq_pg_iv_out()`은 PostgreSQL의 `interval_out()`처럼 결정적이지 않아(stable), 식 인덱스와 생성 열에는 쓸 수 없습니다(`non-deterministic functions prohibited in index expressions`; PostgreSQL은 `functions in index expression must be marked IMMUTABLE`). CHECK에는 됩니다. 예전 스키마가 부르는 `xq_pg_iv_text()`는 늘 기본 형식입니다. [확장](extension.md)을 올린 sqlite3에는 세션이 없으므로 `xq_pg_iv_out()`도 기본 형식입니다.
  - 입력: `sql_standard`에서는 첫 필드가 `-`로 시작하고 다른 필드에 부호가 없으면 모든 필드가 음수입니다(`'-1 2:03:04'`는 `-1 days -02:03:04`, 다른 형식에서는 `-1 days +02:03:04`). 캐스트와 리터럴은 컴파일할 때의 세션으로 읽고(`sql_standard`로 바뀌거나 그것에서 바뀌는 `SET IntervalStyle`이 준비된 문장을 다시 컴파일함), 스키마의 `DEFAULT`도 만들 때 읽은 대로 남습니다(PostgreSQL이 상수를 그때 읽는 것과 같음). 열에 넣는 값은 실행할 때의 세션으로 읽습니다. ISO 8601(`P1Y2M3DT4H5M6S`, `P0001-02-03T04:05:06`)과 `@ ... ago`는 어느 형식에서나 읽습니다.
- 뷰, CHECK, 식 인덱스의 텍스트에는 이 함수들이 남고(`xq_pg_iv_key("v") = xq_pg_iv_key('30 days')`, `GROUP BY xq_pg_iv_key("v")`), 모두 엔진 함수라 SQLite 방언과 [확장](extension.md)을 올린 sqlite3도 읽습니다. 연산자의 함수는 `xq_pg_iv_<연산>`(`xq_pg_iv_timestamp_pl_interval()` ...)입니다.
- UNIQUE와 PRIMARY KEY, `UNION`/`INTERSECT`/`EXCEPT`, `count(DISTINCT v)`, `IN (SELECT ...)`는 바이트로 비교하므로 `'1 mon'`과 `'30 days'`를 다르게 봅니다(PostgreSQL은 같음). 같은 길이의 `max()`/`min()`이 어느 철자를 돌려주는지도 다를 수 있습니다.
- 입력은 PostgreSQL 18의 `interval_in()`입니다(`ivinput.zig`). 텍스트를 필드로 나눠 오른쪽부터 읽고(단위가 숫자 앞에 옴, 단위 없는 수는 앞 필드의 단위 그대로, 시간 뒤와 `hour` 뒤는 날), 아니면 ISO 8601(`P1Y2M`, `P0001-02-03T04:05:06`, `P00010203T040506`)로 읽습니다. SQL의 연-월(`'1-2'`, `'+1-2 -3 +4:05:06.789'`), `@ ... ago`, 단위의 앞 10글자(`millenniums`), 같은 단위 두 번의 오류(`'1 2 days'`)도 PostgreSQL의 것입니다. 필드 하나가 넘치면 `interval field value out of range: "..."`(22015), 합친 달이 넘치면 `interval out of range`(22008)입니다. 이 함수는 예전 `xq_pg_iv()`와 다른 이름이라, 예전 스키마가 부르는 `xq_pg_iv()`와 연산자의 함수(`xq_pg_iv_timestamp_pl_interval()` ...)가 텍스트 인자를 읽는 방식은 뜻이 그대로입니다.
- 필드와 정밀도(타입 수식자): `INTERVAL '1' YEAR`, `'1 2' DAY TO HOUR`, `'12:34.5678' MINUTE TO SECOND(2)`, `INTERVAL(2) '...'`, `'...'::interval day to minute`, 열 타입 `interval year to month`·`interval(0)`·`interval day to second(3)`. 수식자는 PostgreSQL의 `INTERVAL_TYPMOD()`이고(`format_type()`과 `atttypmod`에 보임), 단위 없는 수를 그 마지막 필드로 읽은 뒤(`interval '1' year to month`는 `1 mon`, `MINUTE TO SECOND`의 `'2:03'`은 2분 3초) 그 뒤의 필드를 버리고 초를 정밀도로 반올림합니다(`AdjustIntervalForTypmod()`). 열에 넣는 값(`INSERT`, `UPDATE`)과 `DEFAULT`도 열의 수식자를 지납니다. 정밀도는 6을 넘으면 6입니다(PostgreSQL은 경고를 냄).
- `EXTRACT`/`date_part`는 PostgreSQL 18의 `interval_part_common()`입니다: `microsecond`·`millisecond`·`second`(초 안의 값), `minute`, `hour`, `day`, `week`, `month`, `quarter`, `year`, `decade`, `century`, `millennium`, `epoch`(한 해 365.25일). `EXTRACT`는 `numeric`(`epoch`·`second`는 소수 6자리, `millisecond`는 3자리), `date_part`는 `double precision`이고, 무한 interval은 `hour`·`day`·`year`...·`epoch`가 `±Infinity`, 나머지는 NULL입니다. 모르는 단위는 `unit "x" not recognized for type interval`, `timezone`·`dow` 같은 것은 `unit "x" not supported for type interval`입니다. 파서는 `xq_pg_part(field, x, timestamp의 값, EXTRACT인지)`를 만들고 `overload.zig`가 `x`의 타입으로 interval의 함수나 timestamp의 식을 고릅니다(타입을 모르는 값은 실행 중에 값으로).
- `make_interval(years, months, weeks, days, hours, mins, secs)`: 주지 않은 인자는 0(파서가 채움), 넘치거나 무한·NaN인 초는 `interval out of range`, `secs * 1e6`이 넘치면 `value out of range: overflow`.
- 예전 데이터베이스(interval을 텍스트로 저장하던 xqlite)의 `TEXT` 열은 그대로입니다. 열마다 선언된 저장 타입으로 구분해, `TEXT` 열에 넣는 값은 텍스트로(무한은 `interval out of range`) 넣고, 정렬은 예전처럼 collation `xq_pg_interval`, 비교와 연산은 위의 함수(텍스트와 BLOB을 모두 읽음)입니다. 예전 스키마가 부르는 `xq_pg_interval()`, `xq_pg_interval_pl()` ...와 collation은 뜻이 그대로 남습니다. 옮기려면 테이블을 다시 만듭니다.

### numeric

`numeric`/`decimal`은 정확한 십진수입니다(`src/dialect/decimal.zig`, 엔진 함수 `src/dialect/decimal_sql.zig`). PostgreSQL처럼 계산하고(반올림은 0에서 먼 쪽, `NaN`과 `±Infinity`, 나눗셈의 스케일은 `select_div_scale()`, 오류와 SQLSTATE), 저장은 값 자체가 정렬 키인 `BLOB`입니다.

- **키**: 바이트 비교(memcmp, SQLite의 BINARY) 순서가 수의 순서이고 같은 수는 같은 바이트열입니다(`1.50`과 `1.5`는 한 키). 그래서 범위 검색, `ORDER BY`, `GROUP BY`, `DISTINCT`, `min`/`max`, PRIMARY KEY, UNIQUE, 외래 키가 SQLite 그대로 인덱스를 씁니다. 형식은 `decimal.zig` 머리말과 [확장](extension.md#numeric-키)에 있습니다. 확장 없는 sqlite3는 값을 바이트로만 보고 쓰지 못합니다(`xq_dec_valid` CHECK).
- **저장**: 열에 넣는 모든 값(수, 문자열, 매개변수, `INSERT ... SELECT`, `UPDATE`)은 `xq_dec_key(v, p, s)`를 지납니다: `numeric(p,s)`는 s자리로 반올림하고 p - s자리를 넘으면 `numeric field overflow`(22003), 무한대도 그 오류. 스케일 없는 `numeric`은 끝의 0을 버립니다(`'1.50'`은 `1.5`로 보임; 비교·유일성·그룹은 PostgreSQL과 같음). `DEFAULT` 상수는 키의 BLOB 상수(`X'40810364'`)로, 그 밖의 기본값과 생성 열은 `xq_dec_key(식, p, s)`로 스키마에 씁니다. 다른 타입(`integer`, `double precision`, `text` ...)의 열에 넣는 numeric은 그 타입으로 바꿉니다(PostgreSQL의 대입 캐스트: `1.5`를 `integer` 열에 넣으면 2).
- **이전 데이터베이스**: 이 변경 전에 만든 테이블의 `numeric` 열(STRICT 저장 `ANY`)은 지금처럼 수를 저장합니다(`xq_dec_number()`). 저장 방식은 열마다 선언된 SQLite 타입(`ANY`/`BLOB`)으로 정해 한 열에서 섞이지 않습니다. 옮기려면 테이블을 다시 만듭니다.
- **식**: `numeric` 연산자는 키의 함수입니다(`a + b` → `xq_dec_add(a, b)`; 리터럴은 `xq_dec('1.50')`로 자릿수와 스케일을 지킴). 비교는 키를 스케일 없이 비교합니다(`n = 1.5` → `n = xq_dec_key('1.5')`: 상수라 인덱스를 씀; 식 인덱스는 `xq_dec_key(식)`으로 저장해 같은 식의 비교가 그 인덱스를 씀). 실수와 만나면 실수로(`xq_dec_float8()`). `round`/`trunc`/`ceil`/`floor`/`abs`/`sign`/`mod`/`div`/`scale`/`min_scale`/`trim_scale`, `sqrt`/`exp`/`ln`/`log`/`log10`/`power`/`^`(아래 초월 함수), `width_bucket`, `sum`/`avg`(윈도우 포함, `sum(bigint)`·`avg(integer)`도 numeric), 정수·실수·텍스트로의 캐스트, `||`·`concat()`·`format()`, JSON(`to_json` ...), 배열 원소(`ARRAY[n]`, `array_agg`)가 키를 읽습니다. 그 밖의 함수에는 수로(`xq_dec_number()`) 넘깁니다.
- **표시 스케일**: 계산한 값은 PostgreSQL의 표시 스케일(dscale)을 키 뒤에 붙여 들고 다닙니다(`10.0 / 4`는 `2.5000000000000000`, `avg()`도). 셸과 서버는 타입의 스케일(`numeric(10,2)` 열, `n + 1`), 없으면 키의 스케일로 보여 줍니다. 저장한 값(스케일 없음)에서 나온 값은 자기 자릿수입니다. 비교, `IN`, `GROUP BY`, `DISTINCT`는 스케일을 떼고 비교·그룹합니다(`xq_dec_key()`, `Rules.group_key`: `VALUES (1.5), (1.50)`은 한 그룹). `UNION`·`INTERSECT`·`EXCEPT`, `count(DISTINCT x)`는 바이트로 비교하므로 스케일만 다른 계산 값을 다른 값으로 봅니다.
- **입력**: `numeric_in()`의 문법(앞뒤 공백, `NaN`, `Infinity`/`inf`, `_` 자리 구분, `0x`/`0o`/`0b` 정수, 지수), 범위(소수점 앞 131072자리, 뒤 16383자리; 넘으면 `value overflows numeric format`). 실수는 15자리(`float8_numeric()`).
- **초월 함수**: `sqrt`, `exp`, `ln`, `log(x)`(밑 10, `log10`도), `log(b, x)`, `power(x, y)`·`x ^ y`는 인자 하나가 `numeric`이고 실수가 없으면 `numeric`으로 계산합니다(`xq_dec_sqrt()` ... `xq_dec_power()`, `src/dialect/decimal_math.zig`; 정수만이거나 실수가 섞이면 `double precision`, `log(b, x)`는 늘 `numeric`). PostgreSQL 18의 `numeric.c`를 같은 10000진 표현으로 따라가므로 결과 스케일(`NUMERIC_MIN_SIG_DIGITS` 16자리, 인자의 스케일 이상, 1000 이하)과 자릿수가 같습니다: `sqrt(2::numeric)`은 `1.414213562373095`, `exp(1.0)`은 `2.7182818284590452`, `ln(2.0)`은 `0.6931471805599453`, `power(2::numeric, 0.5)`는 `1.4142135623730950`, `2::numeric ^ 100`은 정확한 정수. 중간 값을 반올림하는 자리, `mul_var()`가 버리는 곱, `div_var()`의 근사 나눗셈(제수가 10000진 12자리를 넘을 때)까지 같습니다. 오류도 같습니다: `cannot take square root of a negative number`·`zero raised to a negative power is undefined`·`a negative number raised to a non-integer power yields a complex result`(2201F), `cannot take logarithm of zero`/`of a negative number`(2201E), `value overflows numeric format`(22003). `NaN`·`±Infinity`는 POSIX `pow()`의 규칙. `factorial(n)`(numeric, 32177 넘으면 넘침), `width_bucket(x, b1, b2, n)`(`numeric`은 정확히, 실수는 `width_bucket_float8()`). 예전 스키마의 `sqrt(numeric 열)`은 `xq_postgres_sqrt(xq_dec_float8(x))`(실수)를 부르므로 뜻이 그대로입니다.
- **서버**: 텍스트 형식은 위 표시, 이진 형식은 PostgreSQL의 NBASE 10000 형식(결과와 매개변수).

### 카탈로그

| 스키마 | 관계 |
| --- | --- |
| `information_schema` | `tables`, `columns`(`xq_catalog`의 PostgreSQL 선언 타입, identity 여부, 정수 열은 `integer`), `views`, `schemata`, `sequences`, `table_constraints`, `key_column_usage`, `referential_constraints`, `check_constraints` |
| `pg_catalog`(스키마 없이도 보임) | 스키마에서 만드는 것: `pg_namespace`, `pg_class`, `pg_attribute`, `pg_type`, `pg_index`, `pg_constraint`, `pg_attrdef`, `pg_sequence`, `pg_depend`(identity·serial 시퀀스의 소유), `pg_description`, `pg_proc`(내장 타입의 입출력 함수). 그 위의 뷰: `pg_tables`, `pg_views`, `pg_indexes`, `pg_sequences`. 상수: `pg_database`, `pg_roles`, `pg_authid`, `pg_user`, `pg_am`, `pg_opclass`·`pg_opfamily`(PostgreSQL 18의 행을 디스크 순서대로), `pg_extension`(`plpgsql`), `pg_statio_all_tables`·`pg_statio_user_tables`(I/O는 0), `pg_tablespace`, `pg_collation`, `pg_language`, `pg_settings`(세션의 값). 빈 것: `pg_trigger`, `pg_policy`, `pg_inherits`, `pg_rewrite`, `pg_statistic_ext`, `pg_publication*`, `pg_enum`, `pg_range`, `pg_shdescription`, `pg_auth_members`, `pg_partitioned_table`, `pg_foreign_table`, `pg_matviews`, `pg_event_trigger` |

psql의 `\d`, `\dt`, `\di`, `\dv`, `\ds`, `\dn`, `\df`, `\dT`, `\l`, `\du`와 `\d 테이블`(열, 기본값, identity, 인덱스, CHECK, 외래 키, Referenced by), `\d 인덱스`, `\d 시퀀스`가 와이어 서버로 PostgreSQL 16과 같은 출력을 냈습니다([서버](server.md#xqlite-serve)). psql 18의 질의가 읽는 PostgreSQL 17·18의 열(`pg_constraint.conenforced`·`conperiod`, `pg_class.relallfrozen`, `pg_database.datlocale`·`dathasloginevt`, `pg_collation.colllocale`, `pg_publication.pubgencols`)도 있습니다. 다만 psql 18도 `\d` 계열에 배열 문법(`array(...)`, `= any(...)`, 배열 첨자)을 함께 보내므로, 지금은 그것이 들어가기 전까지 오류입니다.

**만드는 법.** 스키마에서 만드는 관계는 엔진 테이블 값 함수(이름 있는 가상 테이블, `Hooks.engine_modules`의 `xq_pg_class` ...)이고, 뷰 텍스트가 열마다 PostgreSQL 타입으로 캐스트합니다(`relhasindex::boolean`이라 클라이언트에 `t`/`f`). 행은 스냅숏(`pgcatalog.zig`)에서 옵니다. 스냅숏은 각 데이터베이스의 메모리 스키마(`Table`, `Index`, 외래 키), 메모리의 카탈로그(선언 타입, identity, 제약 이름, 주석), `xq_sequence`, `sqlite_schema`의 SQL 텍스트(CHECK, 인덱스 식, 뷰)에서 한 번에 읽어 자기 아레나에 복사합니다. 연결은 마지막 스냅숏을 두고, 어느 데이터베이스의 스키마(쿠키·세대)도, 바뀐 행 수(`n_total_change`)도 그대로이면 다시 씁니다. 그래서 행마다 부르는 함수(`pg_table_is_visible()`, reg* 캐스트)도 문장마다 한 번 읽습니다. 쓰기마다 스냅숏을 다시 만드므로 만들 때는 식을 역파스하지 않습니다. 기본값·CHECK·인덱스 조건의 텍스트(`adbin`, `conbin`, `conkey`, `indpred`와 pretty 텍스트)는 그 열을 처음 읽을 때 한 번 읽어 두 모드로 만들고 스냅숏에 둡니다. 가상 테이블은 질의가 읽는 열만 읽으므로 `\d t`는 `t`의 식만 역파스합니다. 인덱스 식만은 열 이름(`pg_attribute.attname`)이 그 텍스트에서 오므로 만들 때 한 번 읽습니다. 관계의 행도 처음 읽을 때 한 번 만들어 둡니다(중첩 루프가 안쪽 관계를 바깥 행마다 다시 읽음). 이 행은 문장이 스냅숏을 쥐고 있는 동안만 두고, 연결의 캐시만 남으면 놓습니다(쉬는 연결이 읽은 행을 붙잡지 않음). 이름·OID로 찾는 것(관계, 열, 제약, 인덱스)은 해시와 관계별 범위로 찾습니다. `information_schema.columns`는 뷰 열의 타입을 `pg_class`·`pg_attribute` 대신 `xq_pg_view_columns`(main의 뷰의 SQLite 이름, 열, 타입 OID, typmod)에서 읽고, 지금 스냅숏이 없는데 main에 뷰가 하나도 없으면 스냅숏을 만들지 않습니다. 뷰 텍스트를 키우는 대신 이렇게 한 이유: `pg_attribute`·`pg_constraint`·`pg_index`는 SQLite의 pragma로는 CHECK 텍스트, 제약 이름, INTEGER PRIMARY KEY의 인덱스, 식 인덱스, 정의 텍스트(`pg_get_constraintdef()`)를 모두 얻지 못하고, psql의 질의마다 여러 번 조인되는 관계를 pragma 질의의 합집합으로 만들면 느립니다. 파일에는 아무것도 쓰지 않으므로 DB는 SQLite 그대로이고, sqlite3와 SQLite 방언에는 `pg_class` 같은 이름이 없습니다(엔진 함수 `xq_pg_*`만 보임).

- 데이터베이스와 스키마: main은 `public`, `CREATE SCHEMA`의 스키마(`"sales.orders"`)는 `sales`, temp의 개체는 `pg_temp_1`, `ATTACH`한 데이터베이스는 그 이름의 스키마입니다. xqlite 자신의 테이블(`sqlite_*`, `xq_*`)은 없습니다.
- 시스템 관계: 위 표의 `pg_catalog` 관계와 `information_schema` 뷰도 PostgreSQL 18처럼 카탈로그에 있습니다. `pg_class`의 행(`pg_class` 1259 `r`, `pg_tables` 12035 `v`, `information_schema.tables` 13546 `v`, `relnamespace`는 11 또는 `information_schema`의 13327, `relacl`, 행 타입 `reltype`과 그 `pg_type` 행), `pg_attribute`의 열(PostgreSQL의 타입: `relacl`은 `aclitem[]`, `relfrozenxid`는 `xid`, `information_schema`의 열은 도메인 `information_schema.sql_identifier` ...), 시스템 테이블의 인덱스(`pg_class_oid_index` ...)와 `pg_index`, PRIMARY KEY·UNIQUE·NOT NULL 제약입니다. 그래서 psql의 `\d pg_class`, `\d information_schema.tables`, `\di pg_constraint*`, `attrelid = 'pg_class'::regclass` 같은 질의가 PostgreSQL과 같은 답을 냅니다. psql의 `\dt`·`\dv`처럼 `nspname <> 'pg_catalog'`, `pg_table_is_visible()`로 거르는 목록에는 PostgreSQL처럼 나오지 않습니다. 행은 PostgreSQL 18에서 뽑아 생성한 `syscatalog.zig`(`tools/dialect/pg-syscatalog.sql`로 다시 만듦)이고, 스냅숏에 넣지 않으므로 스냅숏을 만드는 비용은 그대로입니다. OID가 16384보다 작거나 스키마가 `pg_catalog`·`information_schema`이면 찾는 곳이 이 표이고, `pg_class`·`pg_attribute`·`pg_type`(내장 타입과 시스템 관계의 행 타입)·`pg_index`·`pg_constraint`의 이 행은 컴파일할 때 만들어 둔 셀을 가상 테이블이 스냅숏의 행 앞에 그대로 냅니다.
- 테이블의 시스템 열(`ctid`, `xmin`, `cmin`, `xmax`, `cmax`, `tableoid`, `attnum` -1 ~ -6)도 `pg_attribute`에 있습니다. `pg_index.indclass`는 열 타입의 기본 btree 연산자 클래스(`int4_ops` 1978, varchar는 `text_ops` 3126), 외래 키의 `conindid`는 참조하는 테이블의 키 인덱스, CHECK의 `conkey`는 식이 읽는 열입니다. 제약은 PostgreSQL처럼 NOT NULL, CHECK, 키, 외래 키 순으로 나옵니다.
- NOT NULL 열(PRIMARY KEY의 열 포함)마다 PostgreSQL 18처럼 NOT NULL 제약 `<table>_<column>_not_null`(`contype` `n`, `pg_get_constraintdef()`는 `NOT NULL a`)이 있고, `information_schema.table_constraints`에는 `CHECK`, `check_constraints`에는 `a IS NOT NULL`로 나옵니다.
- INTEGER PRIMARY KEY에도 PostgreSQL처럼 `<table>_pkey` 인덱스와 PRIMARY KEY 제약이 있습니다. UNIQUE·PRIMARY KEY의 자동 인덱스는 제약 이름(`t_b_c_key`, 사용자가 준 이름)입니다. 타입 검사용 CHECK(`integer out of range` ...)는 제약에 나오지 않습니다.
- `pg_attribute`의 타입은 선언 타입의 OID와 typmod(와이어 서버의 RowDescription과 같은 표)이고, SQLite가 만든 테이블은 `information_schema`처럼 `INTEGER`가 `bigint`입니다. 뷰의 열은 그 뷰를 이 방언으로 컴파일한 결과 열의 타입이고, 테이블의 열을 그대로 내는 열은 그 열의 타입(`character varying(200)`, `numeric(10,2)`)입니다. `information_schema.columns`도 뷰의 열을 이 타입으로 씁니다.
- 기본값(`pg_attrdef.adbin`, `pg_get_expr()`)은 저장된 SQLite 텍스트를 PostgreSQL처럼 씁니다: `'x'::text`, `now()`, `false`, `nextval('t_id_seq'::regclass)`. CHECK·생성 열·인덱스 식·뷰는 [정의 텍스트](#정의-텍스트)처럼 PostgreSQL의 역파서가 쓰는 텍스트입니다.
- 함수: `pg_get_userbyid()`, `pg_table_is_visible()`·`pg_type_is_visible()`(`search_path`대로), `pg_function_is_visible()` 등(참), `pg_get_expr()`, `pg_get_indexdef(oid [, n, pretty])`, `pg_get_constraintdef()`, `pg_get_viewdef()`([정의 텍스트](#정의-텍스트)), `pg_get_serial_sequence()`, `pg_get_functiondef()`(NULL), `obj_description()`, `col_description()`, `shobj_description()`(NULL), `has_table_privilege()`·`has_schema_privilege()` ... ·`pg_has_role()`(참: 역할은 슈퍼유저 하나), `to_regclass()`·`to_regtype()`·`to_regnamespace()`·`to_regrole()`, `pg_encoding_to_char()`, `pg_size_pretty()`, `pg_table_size()` 등(0), `pg_typeof()`(값의 저장 형식으로: `integer`, `bigint`, `numeric`, `text` ...), `current_schemas()`(`name[]`), psql이 빈 관계에 부르는 `pg_get_triggerdef()`·`pg_partition_ancestors()` 등.
- `'t'::regclass`, `::regtype`, `::regnamespace`, `::regrole`은 이름(또는 숫자)을 `search_path`를 따라 OID로 읽습니다(`relation "x" does not exist`). 값은 OID라 `attrelid = 't'::regclass`처럼 비교하고, 질의의 결과 열이거나 `::text`로 캐스트하면 이름입니다(경로에서 찾을 수 없으면 `sales.orders`처럼 스키마를 붙임). `::regproc`은 함수 이름 텍스트입니다.
- psql의 철자: `OPERATOR(pg_catalog.=)`은 그 연산자, `COLLATE pg_catalog.default`, 세 부분 열 이름(`pg_catalog.pg_class.relname`).

**OID.** 내장 개체는 PostgreSQL의 OID입니다(`int4` 23, `text` 25, `pg_catalog` 11, `public` 2200, `information_schema` 13327, `pg_class` 1259 ...). 데이터베이스의 개체는 그것을 가리키는 이름(데이터베이스와 SQLite 이름, 제약은 테이블과 이름 ...)의 해시를 [16384, 100000)에 놓은 수입니다. PostgreSQL이 데이터베이스의 첫 개체들에 주는 번호처럼 다섯 자리라서, psql과 클라이언트가 그 열을 PostgreSQL과 같은 폭으로 찍습니다(전에는 [16384, 2^31)의 열 자리 수라 wire-diff에서 OID를 가려도 표의 폭이 달랐음). 범위가 83616개뿐이라 겹침이 있습니다: N개 개체 중 어느 둘이 겹칠 확률은 약 1 − e^(−N²/167232)으로 N=50이면 1.5%, 100이면 6%, 300이면 42%이고, 새 개체 하나가 있던 개체와 겹칠 확률은 N/83616(N=300이면 0.4%)입니다. 한 카탈로그(관계, 타입, 제약, 기본값, 스키마) 안에서 해시가 겹치면 키가 가장 작은 개체(같은 키면 앞의 것)가 그 번호를 갖고, 나머지는 키의 해시를 [100000, 2^31)에 놓은 번호를 키 순서로 받습니다(거기서도 겹치면 다음 빈 번호). 그래서 번호는 개체 집합의 함수이고, 겹치지 않은 개체의 번호는 자기 이름에만 달렸습니다. 겹친 개체가 생기거나 없어질 때 바뀌는 것은 그 짝 가운데 키가 큰 쪽의 번호뿐이고(새 개체의 키가 더 작으면 있던 개체가 여섯 자리 이상으로 밀림), 개체가 많아져도 번호가 한꺼번에 바뀌지 않습니다. 내장 함수(`pg_proc`)의 번호는 겹침을 풀지 않으므로 [16384, 2^31)입니다. `xq_catalog`에 번호를 적는 방식 대신 이것을 고른 이유: 누가 만들었든(sqlite3, 다른 방언) 쓰기 없이 번호가 있고, 연결·재시작·VACUUM(`sqlite_schema`의 rowid를 다시 매김)·다른 개체의 생성과 삭제에도 바뀌지 않습니다(이름 순서 번호는 밀림). 이름을 바꾸면 번호가 바뀝니다(PostgreSQL은 유지).

#### 정의 텍스트

스키마에 남는 식은 엔진이 읽는 SQLite 텍스트이고, 프론트엔드가 PostgreSQL 연산자가 고른 엔진 함수를 그 안에 씁니다(`ddltype.zig`: `CHECK (price >= 0)`은 `xq_dec_key("price") >= xq_dec_key(0)`, `j ->> 'a'`는 `xq_pg_jsonb_get_text("j", 'a')`). `pg_get_constraintdef()`, `pg_get_expr()`(`conbin`, `adbin`), `pg_get_indexdef()`, `pg_get_viewdef()`, `information_schema.check_constraints`·`views`는 그 텍스트를 PostgreSQL이 자기 파스 트리를 다시 쓰는 대로(ruleutils.c) 보여 줍니다. 저장되는 것은 바뀌지 않습니다.

- `deparse.zig`가 SQLite 텍스트를 트리로 읽고, 엔진 호출을 PostgreSQL 파서가 만들었을 연산자·상수·캐스트로 되돌립니다(`xq_dec_key(x)`는 `x`, `xq_dec_add(a, b)`는 `a + b`, `xq_pg_iv('1 hour')`는 `'01:00:00'::interval`, `xq_pg_cast_int4('5')`는 `5`, `xq_pg_any(x, a, 0, 0)`는 `x = ANY (a)`, `xq_like(p, s)`는 `s ~~ p`). 되돌리는 규칙은 이 모듈 한 곳에 모여 있고, 따로 적지 않은 연산자의 함수(`xq_pg_int_xor(a, b)`는 `a # b`)는 `operators.zig`의 표에서 연산자와 타입을 찾습니다.
- 열의 타입으로 상수에 PostgreSQL의 타입을 붙이고 암시 캐스트를 더합니다: `(0)::numeric`, `'x'::text`, varchar 열은 `(v)::text`, `IN (...)`은 `= ANY (ARRAY[...])`, `BETWEEN`은 `>=`와 `<=`의 AND(PostgreSQL 18), interval·timestamp·jsonb·uuid 상수는 그 타입의 출력 형식. 생성 열과 기본값은 열 타입으로의 할당 캐스트도 셈에 넣습니다(보이지 않지만 pretty에서 괄호를 만듦: `(id * 2)`).
- 출력은 ruleutils.c의 두 모드입니다. 기본은 연산자마다 괄호(`CHECK ((price >= (0)::numeric))`), pretty(`pg_get_constraintdef(oid, true)`, psql의 `\d`)는 우선순위가 필요할 때만(`CHECK (price >= 0::numeric)`). 왼쪽으로 이어진 AND·OR는 하나로 펴고, CASE는 줄을 나눕니다. 뷰는 `SELECT`·`FROM`·`WHERE`·`GROUP BY`·`ORDER BY`·`LIMIT`를 줄마다 들여 쓰고, 열이 여럿인 FROM에서는 열에 관계 이름을 붙입니다. pretty의 `pg_get_indexdef()`는 경로에서 보이는 테이블에 스키마를 붙이지 않습니다.
- 인자 타입을 알려 받은 호출(`kind_calls`)은 PostgreSQL이 고른 함수가 받는 타입으로 인자를 캐스트합니다: numeric의 `gcd(a, (0)::numeric)`, bigint의 `lcm(b, (2)::bigint)`, `timezone('UTC'::text, x)`. `x AT TIME ZONE z`는 `xq_pg_at_time_zone()`으로 적혀 쓴 대로 `(x AT TIME ZONE 'UTC'::text)`(두 모드 모두 괄호)이고, `timezone(z, x)`로 쓴 것은 함수 호출입니다. 이 이름 전에 만든 스키마의 `AT TIME ZONE`은 `timezone(z, x)`로 보입니다.
- `IN` 목록에서 열을 읽는 항목은 따로 비교합니다(transformAExprIn()): `'on' IN (b, true, false)`는 `((true = ANY (ARRAY[true, false])) OR (true = b))`. `ELSE`가 없는 CASE는 `ELSE NULL::integer`처럼 결과 타입의 NULL을 보이고, 뷰의 열이 CASE이면 그 앞에서 줄을 한 번만 바꿉니다.
- 하위 질의, 창 함수, 집합 연산, 모르는 엔진 함수가 든 식은 예전처럼 저장 텍스트를 이름만 고쳐 보여 줍니다.

## 타입 매핑

| PostgreSQL | STRICT 저장 | 검사(이름이 PostgreSQL 메시지인 CHECK) |
| --- | --- | --- |
| `smallint`(`smallserial`) | `INTEGER` | 범위 → `smallint out of range`. 넣는 값은 아래 정수 열처럼 |
| `integer`(`serial`) | `INTEGER` | 범위 → `integer out of range` |
| `bigint`, `bigserial`, `oid` | `INTEGER` | |
| `real`, `double precision`, `float(p)` | `REAL` | |
| `numeric(p,s)`, `decimal` | `BLOB` | 정렬 키만(`xq_dec_valid(n, p, s)` → `invalid input syntax for type numeric`). 넣는 모든 값을 `numeric(p,s)`의 키로 바꿈(아래 [numeric](#numeric)) |
| `boolean` | `INTEGER` | 0/1만(`invalid input syntax for type boolean`). 문자열은 불리언 철자로 읽어 넣음(아래) |
| `text` | `TEXT` | |
| `varchar(n)`, `char(n)` | `TEXT` | `length() <= n`(`value too long for type character varying(n)`, `character(n)`). 넣는 문자열의 n자 뒤가 공백뿐이면 잘라 냄(`'abcd    '`는 `'abcd'`). `char(n)`은 뒤 공백을 모두 떼어 저장하고, 셸과 서버가 n자까지 공백으로 채워 보여 줌(`'a   '`) |
| `bytea` | `BLOB` | |
| `date`, `time`, `timestamp[tz]` | `TEXT` | 넣는 문자열은 PostgreSQL이 읽고 쓰는 텍스트로(아래) |
| `interval` | `BLOB` | `xq_pg_iv_valid()`(`invalid input syntax for type interval`); 넣는 값은 interval의 BLOB으로([interval](#interval)). 예전 데이터베이스의 열은 `TEXT` |
| `uuid` | `BLOB` | 16바이트(`invalid input syntax for type uuid`). 넣는 문자열은 `uuid_in()`처럼 읽음([uuid](#uuid)). 예전 테이블의 `TEXT` 열은 텍스트 그대로 |
| `json` | `TEXT` | `json_valid()`; 넣는 값은 검사([JSON](#json)) |
| `jsonb` | `BLOB` | `json_valid(j, 8)`; 넣는 값은 정준 JSONB(이 방식 전에 만든 TEXT 열은 정규화한 텍스트, [JSON](#json)) |
| 배열(`integer[]`, `text[]`, `varchar(n)[]` ...) | `TEXT` | 배열 리터럴(`malformed array literal`); 넣는 값은 원소 타입으로 읽어 정규 텍스트로([배열](#배열)) |

정수 열에 넣는 값은 PostgreSQL의 대입처럼 바꿉니다(`integer.zig`의 저장 함수, `INSERT`·`UPDATE`·`INSERT ... SELECT`). 문자열과 매개변수는 정수 입력으로 읽고(`'  12  '`, `'0x10'`, `'-1_000'`; `'34.5'`, `''`, `'- 1234'`는 `invalid input syntax for type smallint: "..."`, `'100000'`은 `value "100000" is out of range for type smallint`), `numeric`(`34.5`)은 0에서 먼 쪽으로, `double precision`·`real`은 짝수 쪽으로 반올림합니다. 정수는 바꾸지 않으므로 그 INSERT는 SQLite의 것과 같은 코드입니다.

- 선언 타입은 `xq_catalog`의 `type` 키에 `format_type()` 철자(`character varying(20)`, `timestamp with time zone`)로 남습니다.
- 다른 타입의 값을 넣으면 SQLite STRICT 오류(`cannot store TEXT value in INTEGER column t.a`)가 납니다.
- `boolean` 열에 넣는 문자열(상수, 텍스트로 바인딩한 매개변수, `INSERT ... SELECT`의 값)은 PostgreSQL이 그 타입의 입력을 읽듯 읽습니다: `'t'`, `'true'`, `'yes'`, `'on'`, `'1'`(그 접두어 `'tr'`, `'of'` ..., 대소문자·앞뒤 공백 무시)은 1/0. 아니면 `invalid input syntax for type boolean: "x"`(22P02). `numeric` 열에 넣는 값은 모두 `xq_dec_key(v, p, s)`를 지납니다(아래 [numeric](#numeric)). `INSERT`와 `UPDATE`(`ON CONFLICT DO UPDATE` 포함)가 저장 직전에 바꿉니다([타입을 읽는 코드 생성](architecture.md#타입을-읽는-코드-생성)).
- `date`, `time`, `timestamp`, `timestamptz`, `interval` 열에 넣는 문자열도 그 타입의 입력으로 읽어 PostgreSQL의 출력 텍스트로 넣습니다: `'2024-1-5'`는 `2024-01-05`, `'2 hours'`는 `02:00:00`, `timestamptz`의 `'2024-01-01 10:00:00+02'`는 UTC의 `2024-01-01 08:00:00`. 읽지 못하면 `invalid input syntax for type date: "x"`(22007), 범위 밖의 필드는 `date/time field value out of range: "2024-02-30"`(22008). 텍스트는 그대로 sqlite3의 날짜 함수가 읽습니다.
- `interval` 열에 넣는 값(문자열, 텍스트나 바이너리로 바인딩한 매개변수, interval 식)은 `xq_pg_iv()`로 BLOB이 됩니다. `DEFAULT '1 hour'`는 `DEFAULT (xq_pg_iv('1 hour'))`로 남습니다.
- 모르는 타입은 `type "x" does not exist`(배열이면 `type "x[]" does not exist`), `serial[]`은 `array of serial is not implemented`입니다.

### 캐스트

| 캐스트 | xqlite | PostgreSQL과 다른 점 |
| --- | --- | --- |
| `::date`/`::time`/`::timestamp`/`::timestamptz`/`::interval` | `xq_pg_date()`/`xq_pg_time()`/`xq_pg_timestamp()`/`xq_pg_timestamptz()`/`xq_pg_iv()`(interval의 BLOB; `::text`는 `xq_pg_iv_out()`): PostgreSQL의 입력(ISO 날짜, `T`나 공백 뒤의 시각, 오프셋, `BC`; interval의 단위·시각·`ago`·ISO 8601 `P1DT2H`; `now`, `today`, `tomorrow`, `yesterday`, `epoch`)을 읽어 그 출력으로(초의 소수는 끝의 0 없이: `03:04:05.5`). 읽지 못하면 오류 | `infinity`, 시간대 이름(`Asia/Seoul`), `DateStyle`이 바꾸는 입력·출력은 없음. `timestamptz`는 UTC. `::timetz`는 `time()` |
| `::smallint`/`::int`/`::bigint` | `xq_pg_cast_int2/4/8()`(`integer.zig`): 문자열은 정수 입력으로 읽음(`' 0x1F '`, `'1_000'`; `'2.5'::int`는 `invalid input syntax for type integer: "2.5"`, `'70000'::int2`는 `value "70000" is out of range for type smallint`), 실수는 짝수 쪽으로 반올림(`2.5::float8::int`는 2), `numeric`은 0에서 먼 쪽으로(`2.5::int`는 3), 범위 밖은 `smallint out of range` ... . 예전 스키마가 부르는 `xq_pg_int2/4/8()`(실수는 0에서 먼 쪽, 16진·`_` 없음)은 뜻이 그대로 | |
| `::varchar(n)`, `::char(n)` | 자름. `char(n)`의 결과는 n자로 채워 보여 줌 | |
| `::numeric`, `::numeric(p,s)` | `xq_dec(x [, p, s])`: 정확한 키, s로 반올림, p - s자리를 넘으면 `numeric field overflow`(22003) | |
| `::boolean` | `'t'`/`'yes'`/`'on'` 같은 철자를 읽음 | |
| `::json`/`::jsonb` | `xq_pg_json()`/`xq_pg_jsonb()` | |
| `::uuid`, uuid의 `::text` | `xq_pg_uuid()`(16바이트), `xq_pg_uuid_text()`([uuid](#uuid)) | `bytea`·정수에서의 캐스트는 실행 중 오류(PostgreSQL은 해석 중 `cannot cast type`) |
| `::int[]`(`text[]`, `numeric[]` ...) | `xq_pg_array_int4()` ...: 배열 입력, 원소마다 그 타입으로 읽어 정규 텍스트로(위 [배열](#배열)) | 원소 타입의 typmod(`numeric(10,2)[]`의 반올림, `varchar(3)[]`의 길이)는 적용하지 않음 |

## PostgreSQL과 다른 점

| 주제 | PostgreSQL | xqlite | 이유 |
| --- | --- | --- | --- |
| 불리언 | `true`/`false` | 정수 0/1. `SELECT true`는 `1`(SQLITE_INTEGER). 셸과 서버는 `boolean` 열과 불리언 식(`a = b`, `true`, `x IS NULL`)을 psql처럼 `t`/`f`로 보여 줌([값 표시](architecture.md#값-표시)). 뷰의 불리언 식 열은 1/0. 열에 넣는 문자열은 불리언 철자로 읽음(`'yes'`, `' off '`). PostgreSQL은 타입이 `text`인 식(텍스트 열, `'a' \|\| 'b'`)을 넣으면 오류이지만 xqlite는 그것도 읽음 | sqlite3 API로 돌아오는 결과의 타입을 바꿀 수 없음. 저장 값은 값의 타입이 아니라 실행 중 값이 문자열인지로 바꿈 |
| `numeric` | 정확한 십진수 | 정확함(정렬 키 BLOB, [numeric](#numeric)). API로는 값이 키(BLOB, `xqlite.decimal.keyText()`로 읽음). 스케일 없는 `numeric` 열은 끝의 0을 버리고 저장(`'1.50'`은 `1.5`로 보임). 이전에 만든 테이블의 `ANY` 열은 수 그대로 | `stddev`·`variance` 없음. 뷰의 정의 텍스트에서 `x ^ y`는 `power(x, y)`, `mod(x, y)`는 `x % y`(같은 엔진 함수가 됨) |
| 식의 타입 | 연산자·함수 해석이 정함 | 같은 규칙으로 매김: `integer + integer`는 `integer`, `integer + bigint`는 `bigint`, `1`은 `integer`, `1.50`은 `numeric`, `'a'`는 `text`, `count()`·`sum(int)`은 `bigint`, `avg()`는 `numeric`, `now()`은 `timestamp with time zone`, `date + 1`은 `date`([코어의 타입](architecture.md#코어의-타입)). 결과 열의 선언 타입(`sqlite3_column_decltype()`, psql `\gdesc`의 철자), 값 표시, 매개변수의 타입, 정수 산술의 범위 검사(아래 정수 오버플로), 저장 시 변환(`boolean`, `numeric`, 날짜·시각)에 씀. 산술·비트 연산자는 연산자 표로 고르고([연산자 해석](#연산자-해석)), 그 밖에 피연산자 타입으로 고르는 것은 `jsonb` 연산자·비교·`ORDER BY`, interval의 비교·`ORDER BY`, JSON을 만드는 함수의 인자(`overload.zig`) | 함수 해석은 이름으로(인자 타입으로 오버로드를 고르지 않음) |
| NULL 정렬 | NULL이 가장 큰 값 | 같음(ASC면 마지막, DESC면 처음) | SQLite는 반대라 방언이 맞춤. NULL일 수 없는 열(NOT NULL, INTEGER PRIMARY KEY, 외부 조인의 NULL 쪽이 아닌 것)에는 붙이지 않아 인덱스 순서를 그대로 씀(그때 바이트코드는 SQLite와 같음) |
| `LIKE` | 대소문자 구분, 기본 이스케이프 `\` | 같음(엔진 함수 `xq_like()`). `ILIKE`는 ASCII 대소문자만 무시(`xq_ilike()`) | SQLite의 LIKE는 대소문자를 무시하고 기본 이스케이프가 없음 |
| identity·serial | 시퀀스 | 시퀀스 `<table>_<col>_seq`. 아래 [identity](#identity와-serial) | SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않음 |
| `now()`, `current_timestamp` | 시간대가 있는 타임스탬프 | 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음). 셸과 서버는 `timestamptz` 열에 `+00`을 붙여 보여 줌 | SQLite 날짜 함수가 그대로 읽음 |
| 날짜·시각 연산 | 세션 시간대로 계산 | 같은 결과(위 [연산자 해석](#연산자-해석)). `timestamptz`는 늘 UTC로 계산(`SET TIME ZONE`은 보여 주기만 함). 날짜와 타임스탬프의 비교는 ISO 텍스트의 비교(같은 타입끼리와 문자열 상수는 PostgreSQL과 같음; `timestamp = date`는 시각 `00:00:00`이 없는 텍스트라 다름). interval의 비교와 `ORDER BY`는 collation `xq_pg_interval`(한 달은 30일: `'1 mon' = '30 days'`). 그 collation은 jsonb의 것처럼 방언의 것이라, interval을 비교하는 뷰는 SQLite 방언과 평범한 sqlite3에서 읽을 수 없음. [확장](extension.md)을 올린 sqlite3는 collation과 interval 함수(`xq_pg_interval*`)를 가짐 | 저장은 sqlite3가 읽는 TEXT |
| 이름의 대소문자 | `"Foo"`와 `foo`는 다른 이름 | 접기는 하지만 같은 이름 | SQLite의 이름 비교는 대소문자를 구분하지 않음 |
| 오류 문구 | PostgreSQL 문구 | 싼 곳에서만 PostgreSQL 문구(아래 [오류](#오류)). 실행 중 제약 위반도 PostgreSQL 문구와 `DETAIL`(값을 PostgreSQL처럼 쓸 수 있는 타입만) | |
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
- `function foo(integer, unknown) does not exist`(42883): 이름과 인자 수로 맞는 함수가 없는 호출(인자 수가 다른 내장 함수 `round(1, 2, 3)`도)은 PostgreSQL처럼 인자를 먼저 해석하고(인자의 오류 `column "x" does not exist`가 먼저), 그 타입을 `format_type()`의 철자로 적습니다: `integer`, `numeric`, `bigint`, `text`, `boolean`, `character varying`, `timestamp with time zone`, `integer[]` ...; 문자열 상수, NULL, 타입 모르는 매개변수는 `unknown`. 이름 해석이 인자를 타입 매긴 뒤 방언의 오류를 부릅니다(`typing.Rules.no_function`). 코어가 타입을 모르는 인자(SQLite 테이블의 열, 타입 규칙이 없는 함수)도 `unknown`입니다.

#### 위치와 DETAIL·HINT·CONTEXT

psql이 `LINE 1: ...`과 `^`로 보여 주는 위치(ErrorResponse의 `P`)와 그 아래 줄들을 PostgreSQL처럼 냅니다.

- **위치**: 엔진의 오류 오프셋(`sqlite3_error_offset()`)입니다. 문법 오류, 없는 열·함수, 없는 테이블(FROM의 항목과 INSERT/UPDATE/DELETE의 대상: 내림이 `SrcItem.xq_ofst`에 이름의 오프셋을 적음), 없는 연산자(연산자의 글자: `true + 1`의 `+`, 단항 `-`), 그리고 아래 리터럴의 입력 오류가 위치를 갖습니다. 실행 중 오류(`division by zero`, `integer out of range`, 저장할 때의 `numeric field overflow`)는 PostgreSQL처럼 위치가 없습니다.
- **리터럴의 입력**: PostgreSQL은 타입이 정해진 문자열 리터럴(unknown)을 파싱할 때 그 타입의 입력 함수로 읽어, 읽지 못하면 행을 계산하지 않아도 그 리터럴에서 실패합니다. 이 방언도 그렇게 합니다(`typing.Rules.literal_input`, `typing.readLiteral()`).
  - 캐스트(`'x'::int`, `bool 'test'`, `CAST('x' AS jsonb)`), 타입을 아는 피연산자와 만난 리터럴(`'a' + 1`, 불리언과 비교하는 `b = 'xyz'`·`b IN ('xyz')`; PostgreSQL이 공통 타입을 고르는 대로 불리언이 든 IN 목록과 CASE의 결과·`CASE b WHEN`의 값: `true IN ('yes', 'no')`, `'x' IN (b, true)`, `CASE WHEN c THEN b ELSE 'yes' END`), INSERT VALUES·UPDATE SET에서 열에 저장하는 리터럴(`Rules.store`/`store_column`의 저장 함수)이 대상입니다. 그래서 빈 테이블의 `SELECT ... WHERE b = 'xyz'`도 `invalid input syntax for type boolean: "xyz"`로 실패합니다.
  - 스키마에 남는 식도 같습니다: `CREATE VIEW ... WHERE b = 'xyz'`, `CHECK (b <> 'xyz')`는 만들 때 실패하고, 읽을 수 있는 리터럴은 `xq_pg_bool('t')`로 적힙니다(`ddltype.zig`).
  - 그 변환 함수의 인자 하나짜리를 컴파일할 때 불러 봅니다. 결정적(`deterministic`)인 함수만 부르므로 데이터베이스를 읽는 `regclass`의 입력은 실행할 때 읽습니다.
  - PostgreSQL처럼 타입의 매개변수 없이 읽습니다. `numeric(4,4)` 열에 `'1.0'`을 넣는 `numeric field overflow`는 실행 중 오류(위치 없음)이고, `'abc'`는 입력 오류(위치 있음)입니다.
- **DETAIL·HINT·CONTEXT**: 오류 메시지의 첫 줄 뒤에 psql이 찍는 모양의 줄(`\nDETAIL:  ...`, `\nHINT:  ...`, `\nCONTEXT:  ...`)로 붙습니다(`util.detail_mark`). 그래서 `sqlite3_errmsg()`와 셸, 확장을 올린 sqlite3는 그 줄까지 보여 줍니다. 각 줄이 어디서 시작하는지는 오류를 낸 곳이 메시지와 함께 남기므로(`ErrorState.fields`, [오류 코드](architecture.md#오류-코드)), 와이어 서버는 메시지를 읽지 않고 그 자리에서 잘라 ErrorResponse의 `D`, `H`, `W` 필드로 보냅니다(Zig API `ErrorInfo.fields()`). 메시지가 인용한 값에 `\nHINT:  ` 같은 글자가 있어도 필드가 되지 않습니다. NUL이 든 메시지(PostgreSQL에는 없는 텍스트)에는 붙이지 않습니다.

| 오류 | 붙는 줄 |
| --- | --- |
| 없는 함수, 인자 수가 다른 함수(`function f(integer, unknown) does not exist`) | `HINT:  No function matches the given name and argument types. You might need to add explicit type casts.` |
| 없는 연산자(`operator does not exist: boolean + integer`), 하나로 정할 수 없는 연산자 | `HINT:  No operator matches ...`, `HINT:  Could not choose a best candidate operator. ...` |
| json/jsonb의 입력(`invalid input syntax for type json`) | PostgreSQL의 렉서·파서를 따라 다시 읽어 찾은 `DETAIL:  Token "bad" is invalid.`(`The input string ended unexpectedly.`, `Expected ":", but found "1".` ...)와 `CONTEXT:  JSON data, line 1: {bad` |
| `numeric field overflow` | `DETAIL:  A field with precision 4, scale 4 must round to an absolute value less than 1.`(무한대는 `cannot hold an infinite value.`) |
| 배열의 입력(`malformed array literal: "x"`) | `array_in()`의 `DETAIL`: `Array value must start with "{" or dimension information.`, `Unexpected end of input.`, `Unexpected "," character.`, `Incorrectly quoted array element.`, `Multidimensional arrays must have sub-arrays with matching dimensions.`, `Specified array dimensions do not match array contents.`, `Junk after closing right brace.` ... |
| 유니코드 이스케이프(`invalid Unicode escape`) | `HINT:  Unicode escapes must be \uXXXX or \UXXXXXXXX.`(`U&'...'`은 `\XXXX or \+XXXXXX`) |
| `ARRAY[]` | `HINT:  Explicitly cast to the desired type, for example ARRAY[]::integer[].` |
| GENERATED ALWAYS identity 열에 넣은 값 | `DETAIL:  Column "id" is an identity column defined as GENERATED ALWAYS.`, INSERT에는 `HINT:  Use OVERRIDING SYSTEM VALUE to override.`(SQLSTATE 428C9) |
| `CREATE SCHEMA pg_x`, 객체가 남은 `DROP SCHEMA` | `DETAIL:  The prefix "pg_" is reserved for system schemas.`; `DETAIL:  table s.t depends on schema s`(객체마다 한 줄)와 `HINT:  Use DROP ... CASCADE to drop the dependent objects too.` |
| `to_date`·`to_timestamp`의 템플릿 | `DETAIL:  The given value did not match any of the allowed values for this field.`, `Field requires 2 characters, but only 1 could be parsed.`, `Value must be an integer.`; `HINT:  Use the 24-hour clock, or give an hour between 1 and 12.` ... |
| JSON 함수 | `json_build_object()`의 홀수 인자, `jsonb_insert()`의 있는 키, `jsonb_set_lax()`의 `raise_exception`의 `DETAIL`·`HINT` |
| 그 밖 | `uuidv7()`의 범위, `date_trunc('week', interval)`의 `DETAIL` |
| 제약 위반 | 아래 |

실행 중 제약 위반도 PostgreSQL 문구와 SQLSTATE이고, `DETAIL` 줄도 PostgreSQL처럼 붙습니다.

- 중복 키 `Key (a, b)=(1, x) already exists.`, 자식 행의 외래 키 `Key (pid)=(9) is not present in table "p".`, 부모 행의 외래 키 `Key (id)=(1) is still referenced from table "c".`, NOT NULL과 CHECK `Failing row contains (2, 1, null, 2).`(행의 값마다 64바이트에서 잘라 `...`).
- 값은 문장이 실패할 때 프로그램이 레지스터에서 씁니다. 컴파일할 때 메시지의 `dialect.value_mark` 자리와 값을 담은 레지스터, 카탈로그의 열 타입을 P4에 적어 두므로(`dialect/constraint.zig`) 성공하는 경로에는 비용이 없습니다. 문장 끝에 세는 외래 키는 위반을 셀 때(`OP_FkCounter`) 그 값으로 메시지를 써 둡니다.
- 값은 결과를 보일 때와 같은 값 표시 계층(`dialect/valuetext.zig`)으로 씁니다(`constraints.valueText()`): 정수, 실수(`1e+20`), 텍스트, 불리언(`t`/`f`), `numeric`·`uuid`·`interval`·`jsonb`의 BLOB(`dialect/repr.zig`), `timestamptz`(`+00`), 공백을 채운 `char(n)`, 배열과 `json`, 날짜·시각 텍스트, NULL은 `null`. 행의 긴 텍스트는 복사하기 전에 자릅니다. 타입을 모르는 열, `bytea`, 실수로 저장된 스케일 없는 `numeric`의 값이 있으면 그 `DETAIL` 줄을 붙이지 않습니다. VIRTUAL 생성 열이 있는 테이블의 행도 붙이지 않습니다.
- 여러 행이 외래 키를 어기면 PostgreSQL처럼 처음 어긴 행의 값을 씁니다(카운터를 0에서 올린 위반).

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

#### NOTICE

`IF EXISTS`·`IF NOT EXISTS`가 건너뛴 것과 `DROP SCHEMA ... CASCADE`가 함께 지운 것을 PostgreSQL 18의 문구와 SQLSTATE로 알립니다.

| 문장 | 알림 | SQLSTATE |
| --- | --- | --- |
| `DROP TABLE`/`VIEW`/`INDEX`/`SEQUENCE IF EXISTS x`(이름마다) | `table "x" does not exist, skipping`(`view`, `index`, `sequence`) | 00000 |
| `DROP SCHEMA IF EXISTS s` | `schema "s" does not exist, skipping` | 00000 |
| `ALTER TABLE IF EXISTS x`, `DROP COLUMN IF EXISTS c` | `relation "x" does not exist, skipping`, `column "c" of relation "t" does not exist, skipping` | 00000 |
| `ADD COLUMN IF NOT EXISTS c` | `column "c" of relation "t" already exists, skipping` | 42701 |
| `CREATE TABLE`/`INDEX`/`SEQUENCE IF NOT EXISTS x` | `relation "x" already exists, skipping`(같은 이름의 다른 릴레이션이어도: 시퀀스 이름의 `CREATE TABLE IF NOT EXISTS`는 아무것도 만들지 않음) | 42P07 |
| `CREATE SCHEMA IF NOT EXISTS s` | `schema "s" already exists, skipping` | 42P06 |
| `DROP SCHEMA s CASCADE` | `drop cascades to table s.t`, 객체가 여럿이면 `drop cascades to 2 other objects`와 객체마다 한 줄의 `DETAIL` | 00000 |

- 알림은 문장을 컴파일할 때 정해지고(`util.notice()`: `Parse.xq_notices`, `Vdbe.xq_notices`), 문장이 실행될 때마다 알립니다. 스키마가 바뀌면 문장이 다시 컴파일되므로 그때의 스키마로 다시 정해집니다. 바이트코드와 문장이 하는 일은 그대로이고, C API(`sqlite3_step()` ...)에는 보이지 않습니다.
- Zig API는 `Stmt.notices()`(수준, SQLSTATE, 메시지, `DETAIL`)와 `Db.noticeLevel()`(`client_min_messages`: 기본 `notice`, `warning`이면 `NOTICE`를, `error`면 `WARNING`도 뺌)입니다. 와이어 서버는 `NoticeResponse`로 그 문장의 `CommandComplete` 앞에 보내고([서버](server.md#단순-질의)), 셸은 psql처럼 stderr에 `NOTICE:  ...`와 `DETAIL:  ...`을 찍습니다.

## 아직 하지 않은 것

| 영역 | 항목 |
| --- | --- |
| 쿼리 | 결과 열이 없는 `SELECT;`, `DISTINCT ON`, `LATERAL` 서브쿼리, `GROUPING SETS`/`ROLLUP`/`CUBE`, `EXCEPT ALL`/`INTERSECT ALL`, `FETCH ... WITH TIES`, 테이블·함수 별칭의 열 이름 |
| DML | 데이터를 바꾸는 CTE, `ON CONFLICT ON CONSTRAINT`, `COPY` |
| 타입 | `char(n)`의 값 자체의 공백 채움(값은 뒤 공백 없이 저장하고 보여 줄 때만 채움: `octet_length()`, sqlite3에서 읽은 값, `max_len`을 넘는 채움은 다름), `ENUM`·`CREATE TYPE`·도메인, 시퀀스의 데이터 타입(언제나 `bigint`) |
| 정수 | `abs()`·단항 `-`의 `bigint` 최솟값(SQLite의 `integer overflow`), 함수 꼴 캐스트(`float8(x)`, `int4(x)`), 여러 행 `VALUES`에서 타입이 섞인 열의 실수(값마다 `numeric`처럼 0에서 먼 쪽으로 반올림), 정수 열에 넣는 `boolean`(PostgreSQL은 해석 중 오류) |
| 배열 | 배열의 원소 typmod(`numeric(10,2)[]`의 반올림, `varchar(3)[]`의 길이 검사), 배열 슬라이스에 쓰기(`a[1:2] = ...`), `array_fill()`·`trim_array()`·`array_sample()`·`array_shuffle()`, 다차원 배열의 `array_to_json()`, 다른 배열 타입 사이의 캐스트의 원소 변환(`int[]::text[]`는 텍스트를 다시 읽음), `ARRAY[...]`의 원소에 쓰인 타입 모르는 매개변수, 레코드 일반(`_pg_expandarray()`의 `(x,n)`만), `name[]`의 OID 1003, 원소 타입이 다른 배열의 `\|\|`·비교에서의 오류(PostgreSQL은 `operator does not exist`) |
| JSON | jsonpath `like_regex`의 POSIX 문자 클래스·역참조·플래그 `m`/`x`, `.**{n to m}`, `keyvalue()`, `datetime()`과 문자열 메서드; 복합 타입 인자의 `json_populate_record`(`NULL::table`만), `IS JSON`의 비텍스트 인자 오류, select 목록의 레코드 반환 함수(`json_each`), `WITH ORDINALITY`의 select 목록, `jsonb` 첨자에 쓰기(`SET j['a'] = ...`), 맨 위 스칼라의 `->` 첨자 0·-1(TEXT 값, 곧 상수에서: PostgreSQL은 그 스칼라, 이 방언은 예전대로 NULL; JSONB 값은 같음), GIN의 `@>`·`?` 인덱스 검색, sqlite3가 넣은 jsonb의 정규화, PostgreSQL 17의 `JSON_TABLE`/`JSON_VALUE`/`JSON_QUERY`/`JSON_EXISTS` |
| 식과 함수 | 정규식의 BRE 문법(`b` 플래그는 ERE `e`로 읽음)과 로캘의 대소문자·문자 클래스(위 [정규식](#정규식)), 문자열 상수가 아닌 `substring(x FROM 패턴)`의 패턴(텍스트 열: `substr()`이 됨), `escape_string_warning`의 경고, tz 데이터베이스 이름의 시간대와 `time`/`timetz`의 `AT TIME ZONE`, `date_trunc(unit, x, zone)`, `age`, `format()`의 `VARIADIC`에 배열 상수가 아닌 값(`VARIADIC array_agg(x)`), 그 밖의 함수의 이름 붙은 인자, C 밖의 로캘(`lc_numeric`, `lc_time`: `to_char`의 `D`/`G`/`L`/`TM`), 오류의 DETAIL(`pg_input_error_info()`의 `detail` 열에만) |
| 날짜·시각 | `date`·`timestamp`의 `infinity`/`-infinity`, `IntervalStyle`이 바꾸지 않는 것(`interval[]::text`와 배열 함수가 내는 원소의 텍스트, `pg_get_viewdef()`·`pg_get_expr()`의 interval 상수는 기본 형식; `sql_standard`의 부호 규칙은 `pg_input_is_valid()`와 연산자 함수가 실행 중에 읽는 텍스트(예전 TEXT 열, 텍스트 매개변수)에는 없음), 세션 시간대(`timestamptz`는 UTC로만), `timetz`의 연산(표에 없어 SQLite의 연산), interval의 UNIQUE·`UNION`·`count(DISTINCT)`·`IN (SELECT ...)`(바이트로 같은 것끼리: `'1 mon'`과 `'30 days'`는 다름, [interval](#interval)), `timestamp`와 `date`의 비교, 타임스탬프의 범위 294247년부터(PostgreSQL은 294276년까지), 타입을 아는 값(`now()`)을 `date` 열에 넣을 때의 변환(문자열만 읽음) |
| 연산자 해석 | `numeric`·실수와 만난 문자열 상수를 그 타입의 입력으로 읽기(정수만 읽음), `OPERATOR(schema.op)` 문법, 사용자 정의 연산자 |
| DDL | `ALTER TABLE`의 `ALTER COLUMN`·`ADD/DROP CONSTRAINT`·identity 열 추가, auto-vacuum 데이터베이스에서 한 문장으로 여러 테이블 `DROP`(한 테이블을 지우면 다음 테이블의 루트 페이지가 옮겨질 수 있음; 그 밖에는 `DROP TABLE a, b`가 차례로 지움), 임시 테이블의 시퀀스(`main`에 남음), 붙인 데이터베이스 안의 `CREATE SEQUENCE` |
| 스키마 | 스키마 요소가 있는 `CREATE SCHEMA s CREATE TABLE ...`, `ALTER SCHEMA`, `ALTER TABLE ... SET SCHEMA`, `DROP SCHEMA public`, 이름에 `.`이 있는 스키마, 대소문자만 다른 두 스키마(SQLite의 이름 비교처럼 같은 이름), 다른 스키마의 뷰·외래 키가 기대는 것을 `CASCADE`가 따라 지우는 것, 여러 테이블을 지우는 `DROP SCHEMA ... CASCADE`의 auto_vacuum 데이터베이스(거부함), 상수가 아닌 `nextval(x)`의 `search_path`(이름 그대로 main에서 찾음), `public`에 이름이 `s.t`인 개체(스키마 `s`의 `t`와 겹침) |
| 절차·서버 | PL/pgSQL·`CREATE FUNCTION`·트리거, `LISTEN`/`NOTIFY`, `SET LOCAL`, `SET`의 트랜잭션 의미(롤백해도 남음), 격리 수준 |
| 오류 | 제약 위반·산술·저장 변환 밖의 실행 중 엔진 오류(SQLite 내장 함수가 내는 것 등)의 PostgreSQL 문구, PostgreSQL처럼 쓸 수 없는 타입(실수, `timestamptz` ...)의 값이 든 제약 위반의 `DETAIL`, 여러 객체가 남은 `DROP SCHEMA`의 `DETAIL` 줄의 순서와 여러 스키마를 지울 때 다른 스키마의 객체, 스키마로 한정한 없는 함수의 이름(`pg_catalog.foo(integer)`는 `foo(integer)`, 위치도 `foo`)과 `ROW(...)` 인자의 `record`(`unknown`), 없는 스키마로 한정한 `DROP TABLE IF EXISTS s.t`(PostgreSQL은 `schema "s" does not exist, skipping` 알림, xqlite는 오류), `DROP TABLE ... CASCADE`가 함께 지우는 뷰와 그 알림, `DROP SCHEMA ... CASCADE` 알림의 `DETAIL` 줄의 순서, `public.t`로 쓴 없는 테이블의 메시지(`relation "t"`), 여러 행 `VALUES`·`INSERT ... SELECT`에서 열에 저장하는 리터럴의 위치(실행 중 오류) |
| 카탈로그 | 붙인 데이터베이스의 `information_schema`(`pg_catalog`에는 나옴), 시스템 관계는 xqlite에 있는 것만(PostgreSQL 18의 `pg_catalog` 테이블·뷰 144개 중 위 표의 45개와 그 인덱스, `information_schema` 뷰 65개 중 10개; 시스템 관계의 `pg_description`·`pg_depend`, `pg_get_viewdef()`는 없음; `information_schema.tables`·`columns`는 시스템 관계를 내지 않음), 시퀀스의 타입(`seqtypid` 언제나 `bigint`), 인덱스 방식(`USING gin`도 `btree`), 정의 텍스트가 이 모듈 밖인 식(하위 질의, 창 함수, 집합 연산의 뷰: 저장된 SQLite 텍스트 그대로)과 식의 타입을 짐작하는 곳(모르는 함수는 `text`), 키워드 이름의 따옴표(`dec`는 PostgreSQL에서 `"dec"`), `pg_typeof()`의 식 타입(값으로 정함), 크기 함수(0), `COMMENT ON`의 인덱스·시퀀스·스키마·함수 |
| 셸 | dollar-quote 문장 분할(셸은 SQLite 규칙으로 문장을 나눔) |

## 검증

| 도구 | 하는 일 |
| --- | --- |
| `src/dialect/postgres/test.zig` | 종단 테스트 |
| `xqt dialect-diff pg tools/dialect/pg-array-cases.txt` | 배열과 `ANY`/`ALL`의 차등 비교. 기록(`tools/dialect/pg-expected/pg-array-cases.out`, PostgreSQL 18.6)과 비교하고 `zig build check`에 들어 있음. 29개 케이스 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-uuid-cases.txt` | `uuid`의 차등 비교(입력 형식과 오류, 열의 저장·순서·비교, 캐스트, JSON·배열, DEFAULT와 키, `uuidv4`/`uuidv7`의 버전·변형·순서, `uuid_extract_*`). 무작위·시각 값은 버전, 길이, 순서, 개수로 봄. 기록(`pg-uuid-cases.out`, PostgreSQL 18.6)과 비교하고 `zig build check`에 들어 있음. 12개 케이스 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-jsonb-cases.txt` | jsonb 열(JSONB로 저장)의 값, 연산자, 수정 함수, 비교·`ORDER BY`·`IN`·`BETWEEN`·`DISTINCT`·`GROUP BY`·조인, 만드는 함수와 집계, 집합 반환 함수와 jsonpath, 뷰·CHECK·생성 열·인덱스, `jsonb[]`, 큰 값, 첨자, json 열의 차등 비교. 기록(`tools/dialect/pg-expected/pg-jsonb-cases.out`, PostgreSQL 18.6)과 비교하고 `zig build check`에 들어 있음. 12개 케이스 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-numeric-cases.txt` | `numeric`의 차등 비교(입력, 산술과 스케일, 함수, 캐스트, 열과 인덱스·UNIQUE·외래 키, 집계, CHECK·생성 열·뷰, JSON·배열, 카탈로그). 기록과 비교하고 `zig build check`에 들어 있음. 13개 케이스 모두 같음. 회귀 테스트 `numeric`은 138문장 중 92(이전 52) |
| `xqt dialect-diff pg tools/dialect/pg-numeric-math-cases.txt` | `numeric`의 `sqrt`·`exp`·`ln`·`log`·`log10`·`power`·`^`(자릿수와 스케일, 큰·작은 값, `NaN`·무한대, 오류), 인자에 따른 numeric·실수 선택, 열의 스케일, 생성 열·CHECK·뷰, `factorial`, `width_bucket`, `round`·`trunc`·`div`·`mod`. 기록과 비교하고 `zig build check`에 들어 있음. 9개 케이스 모두 같음. 무작위 입력(120자리까지, 지수 ±200) 4000여 문장도 PostgreSQL과 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-integer-cases.txt` | 정수 입력(캐스트, `0x`/`0o`/`0b`/`_`, 범위와 오류), 실수·numeric의 정수 캐스트의 반올림, 정수 열에 넣는 문자열·numeric·실수, 정수 리터럴과 그 오류, `#`, `char(n)`·`varchar(n)`에 넣는 값의 뒤 공백. 기록과 비교하고 `zig build check`에 들어 있음. 7개 케이스 모두 같음. 회귀 테스트는 `int2` 34 → 47/76, `int4` 51 → 64/101, `int8` 98 → 112/174, `varchar` 5 → 10/13, `strings` 153 → 159/458(`setup.sql`의 `CHAR_TBL`·`VARCHAR_TBL`이 만들어짐) |
| `xqt dialect-diff pg tools/dialect/pg-syntax-cases.txt` | 값 둘레의 문법의 차등 비교: interval의 필드와 정밀도(리터럴, 캐스트, 열과 `format_type()`), PostgreSQL 18의 interval 입력과 범위 오류, interval의 `EXTRACT`/`date_part`, `make_interval()`과 이름 붙은 인자, `VARIADIC`, `U&''`·`E''`의 유니코드 이스케이프, 문자열 이어 붙이기. 기록과 비교하고 `zig build check`에 들어 있음. 11개 케이스 모두 같음. 회귀 테스트는 `strings` 458문장 중 172(이전 153), `text` 74 중 39(이전 30) |
| `xqt dialect-diff pg tools/dialect/pg-intervalstyle-cases.txt` | `IntervalStyle`의 차등 비교(설정과 그 오류, 네 형식의 출력, `::text`·`\|\|`·JSON·배열, 형식이 바뀌어도 같은 저장 값, 뷰, `sql_standard`의 부호 입력과 DEFAULT, 어느 형식에서나 읽는 ISO 8601·`@`, `DETAIL`의 값). 기록과 비교하고 `zig build check`에 들어 있음. 10개 케이스 모두 같음. 회귀 테스트 `interval`의 `IntervalStyle` 구간도 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-format-cases.txt` | 형식 함수와 인자 타입을 알려 주는 호출의 차등 비교(`to_char`의 수·날짜·interval 템플릿과 그 오류, `to_number`, `to_date`/`to_timestamp`, `pg_input_is_valid`/`pg_input_error_info`, `gcd`/`lcm`, `date_trunc`/`date_bin`/`AT TIME ZONE`, `gcd`·`lcm`·`AT TIME ZONE`의 정의 텍스트, 불리언과 만난 IN 목록·CASE의 문자열 상수, `float8()`, `booleq`). 기록과 비교하고 `zig build check`에 들어 있음. 21개 케이스 모두 같음 |
| `xqt dialect-diff pg tools/dialect/pg-error-cases.txt` | 해석한 것을 말하는 오류와 알림의 차등 비교: 맞는 함수가 없는 호출의 인자 타입(상수, 캐스트, 열, 식; 인자 수가 다른 내장 함수), 없는 연산자, `IF EXISTS`·`IF NOT EXISTS`·`DROP SCHEMA ... CASCADE`의 `NOTICE`, `client_min_messages`. 기록과 비교하고 `zig build check`에 들어 있음. 9개 케이스 모두 같음(이전에는 함수 오류 3개 케이스가 `f()`로 달랐고, 알림은 비교하지 않았음) |
| `xqt dialect-diff pg tools/dialect/pg-string-cases.txt` | 정규식과 문자열 상수의 차등 비교(`~` 연산자와 정규식 문법·오류, `regexp_match`의 greediness와 반복된 그룹, `regexp_matches`/`regexp_split_to_table`의 행, `regexp_replace`, `regexp_split_to_array`/`regexp_count`/`regexp_instr`/`regexp_substr`/`regexp_like`와 그 오류, `substring`의 패턴, `SIMILAR TO`와 `similar_to_escape`, CHECK·뷰와 `pg_get_viewdef()`, `standard_conforming_strings`). 기록과 비교하고 `zig build check`에 들어 있음. 18개 케이스 모두 같음. 무작위로 만든 패턴·문자열 900쌍(`regexp_match`·`regexp_replace`·`regexp_split_to_array`·`regexp_matches`)도 PostgreSQL 18과 모두 같았음 |
| `xqt dialect-diff pg` + `tools/dialect/pg-cases.txt` | PostgreSQL과 차등 비교. 기본은 저장소에 기록해 둔 PostgreSQL 18.6의 출력(`tools/dialect/pg-expected/pg-cases.out`)과 비교하므로 서버가 필요 없고 `zig build check`에 들어 있음. 82개 케이스 모두 PostgreSQL 18과 같은 행·열 이름·오류를 냄(불리언 `t`/`f`는 1/0으로 맞춰 비교; PostgreSQL 18로 옮길 때 81/82, NOT NULL 제약을 더해 82/82). 오류를 내는 문장은 따로 모은 케이스에 있음(psql의 stderr와 stdout이 podman을 거치며 섞이는 순서가 일정하지 않음) |
| `xqt wire-diff pg` + `tools/dialect/pg-wire-cases.txt`, `pg-client-cases.txt` | 와이어 서버(`xqlite serve --pg`)를 psql 18로 PostgreSQL 18과 차등 비교(기본은 기록 `tools/dialect/pg-expected/pg-wire-cases.out`, `pg-client-cases.out`과: psql만 필요). psql 출력 전체(메타 명령 `\d` 계열, `\gdesc`, `\bind`, 명령 태그, 오류와 NOTICE)를 비교하고, 다른 케이스를 result(조용히 다른 답)·error(거부)·format(표기만 다름)으로 나눔. `pg-client-cases.txt`는 node-postgres·knex·Sequelize·SQLAlchemy·Django·pgjdbc·asyncpg·Prisma가 실제로 보낸 카탈로그 질의(서버 로그에서 모음). 처음 잰 값은 129개 중 22개가 같음(result 11, error 89, format 7): psql의 `\d` 계열과 ORM의 카탈로그 질의는 거의 모두 `pg_am`·`pg_type`·`pg_attribute`·`pg_index`가 없거나 `OPERATOR(pg_catalog.~)`·`!~`·`= ANY($1)`·`schema.table.column` 참조를 못 읽어 거부됨. PostgreSQL 16으로 52개, 18로 옮길 때 51개(psql 18이 `conperiod`·`datlocale`을 읽고, 버전이 16이었음), 배열 문법 뒤 79개, 정의 텍스트와 카탈로그(`pg_opclass`, 시스템 열, `constraint_column_usage` ...) 뒤 99개, 오류 위치·정수 입력·형식 함수·문법 작업과 합쳐 103개(result 8, error 2, format 16). 시스템 관계를 카탈로그에 넣고(`\dS pg_namespace`) 개체의 OID를 다섯 자리로 한 뒤(OID를 가려도 열 폭이 달랐던 format 6개) 111개(result 7, error 2, format 9), 시스템 관계의 `\d` 케이스를 더해 130개 중 112개, 알림과 정규식·interval 작업을 합쳐 113개(result 7, error 2, format 8). 남은 format은 `version()`의 문자열과 왼쪽으로 붙는 정수 열 |
| `xqt wire-diff pg --regress` + `tools/dialect/pg-regress` | PostgreSQL 회귀 테스트 9개(`boolean`, `int2`, `int4`, `int8`, `text`, `varchar`, `case`, `strings`, `uuid`)를 와이어 서버에서 돌려 PostgreSQL이 함께 내놓는 기대 출력과 문장별 통과율을 잼(psql만 필요). 처음 잰 값은 REL_16_STABLE의 951개 중 431개(45.3%), 그 뒤 440개. REL_18_STABLE의 파일(문장 1005개: `to_bin`/`to_oct`, `crc32`, bytea와 정수 변환, `reverse(bytea)` ... 이 더해짐)로 448개(44.5%). 지금은 11개(`interval`, `numeric`이 더해짐) 1229문장이고, 오류 위치와 DETAIL, 정수 입력, 형식 함수, interval·문자열 문법, 카탈로그 작업 뒤 837개(68.1%; `int4`·`varchar`는 모두, `boolean` 77/78, `int8` 169/174). 정규식·`SIMILAR TO`·`standard_conforming_strings`, numeric의 초월 함수, `IntervalStyle`, 알림 작업을 합쳐 1012개(82.3%; `strings` 330/458, `numeric` 119/138, `int8` 170/174). `uuid`는 43개 중 24개(55.8%), 오류의 위치와 `DETAIL` 뒤 30개(69.8%): 나머지는 uuid 중복 키의 `DETAIL`, uuidv7 오류의 `DETAIL`, `pg_input_is_valid()`, `EXPLAIN`의 계획, `infinity` interval, 10000년 이후 `timestamptz`의 순서(TEXT), 여러 테이블의 `DROP TABLE` |
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
