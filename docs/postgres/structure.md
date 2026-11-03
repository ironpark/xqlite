# 구조

[PostgreSQL 호환](README.md)의 일부입니다.

프론트엔드는 `src/dialect/postgres/`에 있습니다. 문장을 구문 트리 IR(`src/ir/tree.zig`)로 파싱하고, 내림·렌더링·카탈로그 기록은 공용 `src/ir/lower.zig`와 `render.zig`가 합니다.

| 파일 | 내용 |
| --- | --- |
| `frontend.zig` | 진입점. 한 문장을 파싱해 IR로 내림. `PRAGMA`·`ATTACH`·`DETACH`·`VACUUM`·`REINDEX`는 SQLite 문법으로, `ANALYZE [VERBOSE] [[schema.]name]`는 같은 인자로 SQLite에 넘김(`public`은 `main`, `CREATE SCHEMA`의 스키마는 `main."s.t"`, `VERBOSE`는 무시; `VACUUM`은 [SQLite 호환](../sqlite/features.md#vacuum과-백업-api)의 VACUUM) |
| `lexer.zig` | PostgreSQL 어휘(아래 [어휘](statements.md#어휘)) |
| `parser.zig` | 재귀 하강 파서. IR을 만들면서 PostgreSQL 의미를 해석함(캐스트, LIKE/ILIKE, 함수 이름과 특수 문법, 결과 열 이름, NULL 정렬, 스키마 이름과 `search_path` 해석, 카탈로그 뷰, 짧은 INSERT VALUES, DDL의 타입·검사·identity) |
| `ddl.zig` | DDL의 PostgreSQL 문구 검사, 이름 없는 인덱스의 이름 |
| `types.zig` | 타입 → STRICT 저장 타입·검사·`format_type()` 철자·캐스트 |
| `funcs.zig` | 방언 함수와 엔진 함수(`xq_like`, 예전 정규식 연산자의 `xq_pg_regex` 등), `boolean`·`numeric`·`varchar(n)`·`char(n)` 열의 저장 함수 |
| `integer.zig` | 정수(`smallint`/`integer`/`bigint`)의 입력 `parse()`(PostgreSQL의 `int2in()` ...: 앞뒤 공백, `0x`/`0o`/`0b`, `_`; 캐스트·열에 넣는 값·`pg_input_is_valid()`가 함께 씀), 캐스트 `xq_pg_cast_int2/4/8()`, 정수 열의 저장 함수, `#`의 `xq_pg_int_xor()` |
| `are.zig` | PostgreSQL의 정규식 엔진(ARE, 아래 [정규식](expressions.md#정규식)): Pike VM으로 일치 범위를, PostgreSQL의 분해 규칙으로 부분식을 찾음 |
| `regexp.zig` | `~` 연산자(`xq_pg_re()`), `SIMILAR TO`(`xq_pg_similar_escape()`), `regexp_*()` 함수, `substring(x FROM 패턴)` |
| `regex.zig` | 예전의 작은 정규식 엔진: jsonpath `like_regex`와, 예전 데이터베이스의 스키마가 부르는 `xq_pg_regex()` |
| `json.zig` | json/jsonb 값: PostgreSQL 규칙의 파싱, jsonb 정규화와 출력, 비교·포함, jsonb의 정준 JSONB(`toBlob()`, `fromBlob()`)와 정렬 키(`appendKey()`). JSONB 노드 읽기·검사·텍스트는 방언 밖의 `dialect/jsonb.zig`(값 표시도 씀) |
| `jsonpath.zig` | jsonpath의 부분집합 |
| `jfuncs.zig` | JSON 연산자·함수·집계·집합 반환 함수의 구현 |
| `array.zig` | 배열 값(PostgreSQL의 텍스트: `{1,2,NULL}`)의 읽기·쓰기, 원소 타입의 입력·출력, 배열의 엔진 함수(캐스트와 저장, `ARRAY[...]`, `ANY`/`ALL`, 첨자, `unnest()`의 행 ...)와 방언 함수(`array_length()` ...), collation `xq_pg_array`/`xq_pg_array_num` |
| `typing.zig` | 식 타입의 규칙(`Hooks.typing`, [아키텍처](../architecture.md)의 코어의 타입): 리터럴·연산자·함수의 결과 타입 |
| `operators.zig` | 연산자 표(`pg_operator`처럼 연산자, 피연산자 타입, 결과 타입, 구현)와 PostgreSQL 규칙의 연산자 해석(아래 [연산자 해석](expressions.md#연산자-해석)) |
| `ivinput.zig` | PostgreSQL 18의 interval 입력(`interval_in()`: `ParseDateTime()`, `DecodeInterval()`, ISO 8601)과 타입 수식자(`interval day to second(3)`), `EXTRACT`/`date_part`의 interval, `make_interval()`; 엔진 함수 `xq_pg_iv_in()`, `xq_pg_iv_extract()`, `xq_pg_iv_date_part()` |
| `datetime.zig` | `date`/`time`/`timestamp[tz]`/`interval` 값의 PostgreSQL 입력·출력, 그 연산자의 엔진 함수(`xq_pg_date_pli()`, `xq_pg_iv_interval_pl()` ...)와 캐스트(`xq_pg_date()`, `xq_pg_iv()` ...), interval BLOB의 함수(`xq_pg_iv_key()`, `xq_pg_iv_sum()`, `justify_*()` ...), `IntervalStyle`의 네 출력 형식(`formatIntervalStyle()`, `xq_pg_iv_out()`), 예전 텍스트 interval의 함수와 collation `xq_pg_interval`. interval 값 자체(필드, 연산, BLOB 인코딩)는 방언 밖의 `src/dialect/interval.zig` |
| `formatting.zig` | `to_char()`·`to_number()`·`to_date()`·`to_timestamp()`(아래 [형식 함수](formatting.md)). 수의 템플릿은 `numformat.zig`, 날짜·시각의 템플릿은 `dtformat.zig`(PostgreSQL `formatting.c`의 이식) |
| `builtins.zig`, `dtfuncs.zig`, `inputinfo.zig` | `gcd`/`lcm`, `float8()`/`float4()`, `booleq`/`boolne`, `interval_hash()`; `date_trunc`, `date_bin`, `timezone()`(`AT TIME ZONE`); `pg_input_is_valid()`, `pg_input_error_info()` |
| `overload.zig` | 피연산자 타입에 따른 선택(`Rules.overload`): 산술·비트 연산자를 연산자 표로, 값만으로는 모르는 인자 타입을 알려 주는 호출(표 `kind_calls`: `to_char(x, t)` → `xq_pg_to_char(x, t, 종류)`, `gcd`·`lcm` → `xq_pg_gcd(a, b, 비트)`, `timezone` → `xq_pg_timezone(z, x, 종류)`, `x AT TIME ZONE z` → `xq_pg_at_time_zone(z, x, 종류)`), `jsonb`의 `\|\|`·비교·`ORDER BY`, interval의 비교·`ORDER BY`, `->`·`#>`의 json/jsonb 함수, JSON을 만드는 함수의 인자, 배열의 `\|\|`·비교·`ORDER BY`와 원소 타입을 알아야 하는 배열 함수(아래 [배열](arrays.md)). 이름을 해석한 코어가 부름. 아래 네 타입의 선택은 그 타입의 모듈(`repr/*.zig`)을 부르고, `IN`/`BETWEEN`·캐스트·`GROUP BY`·`ORDER BY`는 기술자 표(`repr.zig`)에서 찾음 |
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
