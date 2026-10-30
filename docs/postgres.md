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
| `funcs.zig` | 방언 함수와 엔진 함수(`xq_like` 등) |
| `json.zig` | json/jsonb 값: PostgreSQL 규칙의 파싱, jsonb 정규화와 출력, 비교·포함 |
| `jsonpath.zig` | jsonpath의 부분집합 |
| `jfuncs.zig` | JSON 연산자·함수·집계·집합 반환 함수의 구현 |
| `jtype.zig` | 파싱 뒤의 json/jsonb 타입 판단: 피연산자 타입에 따른 연산자, FROM의 JSON 집합 반환 함수 열, jsonb 열에 저장하는 값 |
| `session.zig` | `CREATE SCHEMA`/`DROP SCHEMA`, `SET`/`RESET`/`SHOW`, `set_config()`/`current_setting()`/`current_schema()`/`current_schemas()` |
| `state.zig` | 연결별 세션 상태(`search_path`와 그 밖의 매개변수) |
| `catalog_views.zig` | `information_schema`/`pg_catalog` 뷰 |
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
- `SET`은 이 밖에 `application_name`, `client_encoding`, `client_min_messages`, `DateStyle`, `IntervalStyle`, `TimeZone`(`SET TIME ZONE`), `standard_conforming_strings`, `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, `extra_float_digits`, `bytea_output`, `transaction_isolation`을 받아 `SHOW`가 그 값을 보여 줍니다(동작은 바꾸지 않음). 모르는 이름은 `unrecognized configuration parameter "x"`입니다. `RESET ALL`, `SET TRANSACTION ...`(무시)도 됩니다.

### 식과 연산자

| 영역 | 지원 |
| --- | --- |
| 캐스트 | `::type`, `CAST`, 타입 리터럴(`DATE '2024-01-01'`) |
| NULL·진리값 | `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN` |
| 술어 | `BETWEEN`, `IN (목록\|서브쿼리)`, `= ANY (서브쿼리)`/`<> ALL (서브쿼리)`, `EXISTS` |
| 패턴 | `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE` |
| JSON | `->`, `->>`, `#>`, `#>>`, `@>`, `<@`, `?`, `?\|`, `?&`, jsonb의 `\|\|`, `-`, `#-`, `@?`, `@@`, `IS [NOT] JSON` (아래 [JSON](#json)) |
| 그 밖 | `CASE`, 행 값, `ARRAY[...]`(텍스트 리터럴, 아래), `\|\|`(피연산자가 NULL이면 NULL) |
| 집계 | `count(*)`, 집계의 `DISTINCT`/`ORDER BY`/`FILTER` |
| 윈도우 | `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS ... EXCLUDE ...)`, `OVER name` |

연산자 우선순위는 PostgreSQL의 것입니다(낮은 것부터).

`OR` < `AND` < `NOT` < `IS` < 비교 < `BETWEEN`/`IN`/`LIKE` < 기타 연산자(`||`, `->`) < `+ -` < `* / %` < `^` < 단항 < `::`

### 함수

SQLite 내장 함수에 더해 다음을 지원합니다. 같은 이름의 SQLite 내장(`random()`, `floor()` 등)은 이 방언에서 가려집니다.

| 분류 | 함수 |
| --- | --- |
| 날짜·시각 | `now()`, `current_timestamp`, `localtimestamp`, `current_date`, `extract(field FROM x)`/`date_part` |
| 문자열 특수 문법 | `substring(x FROM a FOR b)`, `position(a IN b)`, `trim([BOTH\|LEADING\|TRAILING] [c] FROM x)` |
| 문자열 | `strpos`, `left`/`right`, `concat`/`concat_ws`, `lpad`/`rpad`, `repeat`, `reverse`, `split_part`, `starts_with`, `btrim`, `char_length`, `ascii`/`chr` |
| 집계 | `string_agg`, `bool_and`/`bool_or`/`every` |
| 비교 | `greatest`/`least`(NULL은 건너뜀) |
| 수학 | `floor`, `ceil`, `sqrt`, `power`, `exp`, `ln`, `log`, `mod`, `trunc`, `sign`, `pi` |
| 난수·UUID | `random()`(0 이상 1 미만 실수), `gen_random_uuid()` |
| 시스템 | `version()`, `current_user`, `current_database()`, `current_schema`, `current_schemas(bool)`, `current_setting(name [, missing_ok])`, `set_config(name, value, false)` |
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
- 선언 타입과 피연산자 타입으로 정하는 것(`jtype.zig`): `jsonb`끼리의 `||`·`-`, `jsonb`의 `->`·`#>`(결과도 jsonb), `jsonb` 비교와 `ORDER BY`(아래), JSON을 만드는 함수의 인자(`json`/`jsonb`는 JSON으로, 불리언은 `true`/`false`로, 행은 객체로).

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

| 스키마 | 뷰 |
| --- | --- |
| `information_schema` | `tables`, `columns`(`xq_catalog`의 PostgreSQL 선언 타입, identity 여부), `views`, `schemata`, `sequences` |
| `pg_catalog` | `pg_tables`, `pg_views`, `pg_indexes`, `pg_sequences`, `pg_namespace`, `pg_class`(스키마 없이도 보임) |

- 뷰 정의는 PostgreSQL 텍스트로 쓰여 있고, 프론트엔드가 FROM 자리에서 파싱해 넣습니다. 저장되는 것은 없습니다.
- 모든 테이블은 catalog `main`입니다. `CREATE SCHEMA`의 스키마에 있는 개체(`"sales.orders"`)는 schema `sales`, 이름 `orders`로 나오고 `public`에는 나오지 않습니다. 나머지는 schema `public`입니다.
- `information_schema.schemata`와 `pg_namespace`에는 `CREATE SCHEMA`의 스키마도 나옵니다.
- `pg_namespace`와 `pg_class`의 oid는 지어낸 값입니다(`public` 2200, `pg_catalog` 11, 만든 스키마는 이름 순서로 16384부터). 두 뷰를 `relnamespace = oid`로 조인할 수 있습니다. `pg_class`는 `oid`, `relname`, `relnamespace`, `relkind`(`r`/`v`/`i`/`S`), `relowner`, `relpersistence`, `relhasindex`만 있습니다.
- `ATTACH`로 붙인 데이터베이스는 그 이름의 스키마입니다(`aux.t`). 카탈로그 뷰에는 아직 나오지 않습니다.

## 타입 매핑

| PostgreSQL | STRICT 저장 | 검사(이름이 PostgreSQL 메시지인 CHECK) |
| --- | --- | --- |
| `smallint`(`smallserial`) | `INTEGER` | 범위 → `CHECK constraint failed: smallint out of range` |
| `integer`(`serial`) | `INTEGER` | 범위 → `CHECK constraint failed: integer out of range` |
| `bigint`, `bigserial`, `oid` | `INTEGER` | |
| `real`, `double precision`, `float(p)` | `REAL` | |
| `numeric(p,s)`, `decimal` | `ANY` | 숫자만(`invalid input syntax for type numeric`) |
| `boolean` | `INTEGER` | 0/1만(`invalid input syntax for type boolean`) |
| `text` | `TEXT` | |
| `varchar(n)`, `char(n)` | `TEXT` | `length() <= n`(`value too long for type character varying(n)`, `character(n)`) |
| `bytea` | `BLOB` | |
| `date`, `time`, `timestamp[tz]`, `interval`, `uuid` | `TEXT` | |
| `json`, `jsonb` | `TEXT` | `json_valid()`; 넣는 값은 `json`이면 검사, `jsonb`이면 정규화([JSON](#json)) |

- 선언 타입은 `xq_catalog`의 `type` 키에 `format_type()` 철자(`character varying(20)`, `timestamp with time zone`)로 남습니다.
- 다른 타입의 값을 넣으면 SQLite STRICT 오류(`cannot store TEXT value in INTEGER column t.a`)가 납니다.
- 배열과 모르는 타입은 `type "x" does not exist` 같은 오류입니다.

### 캐스트

| 캐스트 | xqlite | PostgreSQL과 다른 점 |
| --- | --- | --- |
| `::date`/`::timestamp`/`::time` | `date()`/`datetime()`/`time()` | |
| `::int` | 실수를 버림 | PostgreSQL은 반올림 |
| `::varchar(n)` | 자름 | |
| `::numeric(p,s)` | 반올림 | |
| `::boolean` | `'t'`/`'yes'`/`'on'` 같은 철자를 읽음 | |
| `::json`/`::jsonb` | `xq_pg_json()`/`xq_pg_jsonb()` | |
| `::text[]`(`int[]` 등) | `xq_pg_text_array()`: 검사한 배열 리터럴 텍스트 | 배열 값이 아니라 텍스트 |

## PostgreSQL과 다른 점

| 주제 | PostgreSQL | xqlite | 이유 |
| --- | --- | --- | --- |
| 불리언 | `true`/`false` | 정수 0/1. `SELECT true`는 `1`(SQLITE_INTEGER) | sqlite3 API로 돌아오는 결과의 타입을 바꿀 수 없음. 문자열 철자는 `::boolean` 캐스트만 읽음(INSERT에 문자열로 넣으면 STRICT 오류) |
| `numeric` | 고정 소수점 | SQLite 수(정수 또는 실수). `1.50`은 `1.5`로 나옴 | 저장 타입이 `ANY`. 문자열 상수 `'1.5'`는 숫자로 바꿔 넣지만 텍스트로 바인딩한 값은 거부 |
| NULL 정렬 | NULL이 가장 큰 값 | 같음(ASC면 마지막, DESC면 처음) | SQLite는 반대라 방언이 맞춤. NULL일 수 없는 열(NOT NULL, INTEGER PRIMARY KEY, 외부 조인의 NULL 쪽이 아닌 것)에는 붙이지 않아 인덱스 순서를 그대로 씀(그때 바이트코드는 SQLite와 같음) |
| `LIKE` | 대소문자 구분, 기본 이스케이프 `\` | 같음(엔진 함수 `xq_like()`). `ILIKE`는 ASCII 대소문자만 무시(`xq_ilike()`) | SQLite의 LIKE는 대소문자를 무시하고 기본 이스케이프가 없음 |
| identity·serial | 시퀀스 | 시퀀스 `<table>_<col>_seq`. 아래 [identity](#identity와-serial) | SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않음 |
| `now()`, `current_timestamp` | 시간대가 있는 타임스탬프 | 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음) | SQLite 날짜 함수가 그대로 읽음 |
| 이름의 대소문자 | `"Foo"`와 `foo`는 다른 이름 | 접기는 하지만 같은 이름 | SQLite의 이름 비교는 대소문자를 구분하지 않음 |
| 오류 문구 | PostgreSQL 문구 | 싼 곳에서만 PostgreSQL 문구(아래 [오류](#오류)). 실행 중 제약 위반은 SQLite 문구(`UNIQUE constraint failed: t.a`) | |
| 0으로 나누기 | 오류 | `/`는 NULL. `mod(x, 0)`은 `division by zero` 오류 | `/`는 SQLite의 것(정수끼리는 정수 나눗셈) |
| 정수 오버플로 | 오류 | 검사하지 않음 | |
| 외래 키 | 늘 강제 | `PRAGMA foreign_keys = ON`일 때만 강제 | SQLite와 같음 |
| 격리 수준 | 여러 수준 | 파싱만 함 | SQLite는 늘 직렬화 |
| JSON | `jsonb`는 이진 형식 | 정규화한 TEXT. `json`은 입력 텍스트 | sqlite3가 그대로 읽고 `json_extract()` 등을 씀. sqlite3가 넣은 값은 정규화되지 않은 채 남고(연산자·함수는 읽을 때 정규화), CHECK `json_valid()`는 SQLite의 규칙 |
| jsonb 비교 | jsonb의 순서 | 같음(collation `xq_pg_jsonb`). 인덱스는 BINARY라 `=`에 쓰이지 않음 | |
| JSON 수 | numeric과 float8 | 실수는 SQLite 철자: `to_json(100.0::float8)`은 `100.0`(PostgreSQL은 `100`), `to_json(1e20::float8)`은 `1.0e+20`(`1e+20`) | SQLite 수에 numeric/float8 구분이 없음 |
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

## 아직 하지 않은 것

| 영역 | 항목 |
| --- | --- |
| 쿼리 | `DISTINCT ON`, `LATERAL` 서브쿼리, `GROUPING SETS`/`ROLLUP`/`CUBE`, `EXCEPT ALL`/`INTERSECT ALL`, `FETCH ... WITH TIES`, 테이블·함수 별칭의 열 이름 |
| DML | 데이터를 바꾸는 CTE, `ON CONFLICT ON CONSTRAINT`, `COPY` |
| 타입 | 배열 타입 열과 배열 연산(`ARRAY[...]`·`::text[]`은 텍스트 리터럴뿐), `ENUM`·`CREATE TYPE`·도메인, 시퀀스의 데이터 타입(언제나 `bigint`) |
| JSON | jsonpath `like_regex`의 POSIX 문자 클래스·역참조·플래그 `m`/`x`, `.**{n to m}`, `keyvalue()`, `datetime()`과 문자열 메서드; 복합 타입 인자의 `json_populate_record`(`NULL::table`만), `IS JSON`의 비텍스트 인자 오류, select 목록의 레코드 반환 함수(`json_each`), `WITH ORDINALITY`의 select 목록, `jsonb` 부분 쓰기 연산자(`j['a']`), GIN의 `@>`·`?` 인덱스 검색, sqlite3가 넣은 jsonb의 정규화, PostgreSQL 17의 `JSON_TABLE`/`JSON_VALUE`/`JSON_QUERY`/`JSON_EXISTS` |
| 식과 함수 | `SIMILAR TO`와 정규식 연산자(`~`), `AT TIME ZONE`, `interval` 산술, `to_char`/`date_trunc`/`age`, `U&'...'` |
| DDL | `ALTER TABLE`의 `ALTER COLUMN`·`ADD/DROP CONSTRAINT`·identity 열 추가, 한 문장으로 여러 개체 `DROP`(`DROP SCHEMA a, b`만 됨), 임시 테이블의 시퀀스(`main`에 남음), 붙인 데이터베이스 안의 `CREATE SEQUENCE` |
| 스키마 | 스키마 요소가 있는 `CREATE SCHEMA s CREATE TABLE ...`, `ALTER SCHEMA`, `ALTER TABLE ... SET SCHEMA`, `DROP SCHEMA public`, 이름에 `.`이 있는 스키마, 대소문자만 다른 두 스키마(SQLite의 이름 비교처럼 같은 이름), 다른 스키마의 뷰·외래 키가 기대는 것을 `CASCADE`가 따라 지우는 것, 여러 테이블을 지우는 `DROP SCHEMA ... CASCADE`의 auto_vacuum 데이터베이스(거부함), 상수가 아닌 `nextval(x)`의 `search_path`(이름 그대로 main에서 찾음), `public`에 이름이 `s.t`인 개체(스키마 `s`의 `t`와 겹침) |
| 절차·서버 | PL/pgSQL·`CREATE FUNCTION`·트리거, `LISTEN`/`NOTIFY`, `SET LOCAL`, `SHOW ALL`, `SET`의 트랜잭션 의미(롤백해도 남음), 격리 수준 |
| 오류 | 0으로 나누기·오버플로 오류, 실행 중 오류 메시지의 PostgreSQL화 |
| 카탈로그 | INTEGER PRIMARY KEY의 인덱스(`pg_indexes`에 `t_pkey`가 없음), 붙인 데이터베이스(`information_schema`·`pg_catalog` 뷰에 나오지 않음) |
| 셸 | dollar-quote 문장 분할(셸은 SQLite 규칙으로 문장을 나눔) |

## 검증

| 도구 | 하는 일 |
| --- | --- |
| `src/dialect/postgres/test.zig` | 종단 테스트 |
| `xqt dialect-diff pg` + `tools/dialect/pg-cases.txt` | 실제 PostgreSQL과 차등 비교. 66개 케이스(JSON 31개)가 PostgreSQL 16과 같은 행·열 이름·오류를 냄(불리언 `t`/`f`는 1/0으로 맞춰 비교). 오류를 내는 문장은 따로 모은 케이스에 있음(psql의 stderr와 stdout이 podman을 거치며 섞이는 순서가 일정하지 않음) |
| `xqt interop pg` | sqlite3 교차 검증. 이 방언으로 쓴 데이터베이스(`CREATE SCHEMA`의 테이블·뷰 포함)가 sqlite3 무결성 검사를 통과하고, sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 함. sqlite3의 `.tables`에 `sales.orders`가 나오고, sqlite3가 넣은 행을 이 방언이 `sales.orders`로 읽음. `jsonb` 열은 sqlite3의 `json_extract()`로 읽히고, sqlite3가 넣은 JSON을 이 방언의 연산자가 읽으며, sqlite3도 잘못된 JSON을 거부함 |

차등 비교는 PostgreSQL 컨테이너를 띄운 뒤 실행합니다(`$PG_PSQL`, 기본값 `podman exec -i xq-pg psql -U postgres`). 경우들은 병렬로 돌고, 작업자마다 자기 데이터베이스(`xqt_dialect_N`)에서 `public` 스키마를 지우고 다시 만들고, 앞 경우가 만든 스키마를 지운 뒤 시작합니다. 서버에 닿지 않으면 바로 실패하며 `zig build check`에는 들어 있지 않습니다. 둘 다 먼저 `zig build tools`가 필요합니다.

```sh
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
zig-out/bin/xqt dialect-diff pg
zig-out/bin/xqt interop pg
```
