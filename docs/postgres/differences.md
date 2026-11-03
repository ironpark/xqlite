# PostgreSQL과 다른 점

[PostgreSQL 호환](README.md)의 일부입니다.

| 주제 | PostgreSQL | xqlite | 이유 |
| --- | --- | --- | --- |
| 불리언 | `true`/`false` | 정수 0/1. `SELECT true`는 `1`(SQLITE_INTEGER). 셸과 서버는 `boolean` 열과 불리언 식(`a = b`, `true`, `x IS NULL`)을 psql처럼 `t`/`f`로 보여 줌([값 표시](../architecture.md#값-표시)). 뷰의 불리언 식 열은 1/0. 열에 넣는 문자열은 불리언 철자로 읽음(`'yes'`, `' off '`). PostgreSQL은 타입이 `text`인 식(텍스트 열, `'a' \|\| 'b'`)을 넣으면 오류이지만 xqlite는 그것도 읽음 | sqlite3 API로 돌아오는 결과의 타입을 바꿀 수 없음. 저장 값은 값의 타입이 아니라 실행 중 값이 문자열인지로 바꿈 |
| `numeric` | 정확한 십진수 | 정확함(정렬 키 BLOB, [numeric](numeric.md)). API로는 값이 키(BLOB, `xqlite.decimal.keyText()`로 읽음). 스케일 없는 `numeric` 열은 끝의 0을 버리고 저장(`'1.50'`은 `1.5`로 보임). 이전에 만든 테이블의 `ANY` 열은 수 그대로 | `stddev`·`variance` 없음. 뷰의 정의 텍스트에서 `x ^ y`는 `power(x, y)`, `mod(x, y)`는 `x % y`(같은 엔진 함수가 됨) |
| 식의 타입 | 연산자·함수 해석이 정함 | 같은 규칙으로 매김: `integer + integer`는 `integer`, `integer + bigint`는 `bigint`, `1`은 `integer`, `1.50`은 `numeric`, `'a'`는 `text`, `count()`·`sum(int)`은 `bigint`, `avg()`는 `numeric`, `now()`은 `timestamp with time zone`, `date + 1`은 `date`([코어의 타입](../architecture.md#코어의-타입)). 결과 열의 선언 타입(`sqlite3_column_decltype()`, psql `\gdesc`의 철자), 값 표시, 매개변수의 타입, 정수 산술의 범위 검사(아래 정수 오버플로), 저장 시 변환(`boolean`, `numeric`, 날짜·시각)에 씀. 산술·비트 연산자는 연산자 표로 고르고([연산자 해석](expressions.md#연산자-해석)), 그 밖에 피연산자 타입으로 고르는 것은 `jsonb` 연산자·비교·`ORDER BY`, interval의 비교·`ORDER BY`, JSON을 만드는 함수의 인자(`overload.zig`) | 함수 해석은 이름으로(인자 타입으로 오버로드를 고르지 않음) |
| NULL 정렬 | NULL이 가장 큰 값 | 같음(ASC면 마지막, DESC면 처음) | SQLite는 반대라 방언이 맞춤. NULL일 수 없는 열(NOT NULL, INTEGER PRIMARY KEY, 외부 조인의 NULL 쪽이 아닌 것)에는 붙이지 않아 인덱스 순서를 그대로 씀(그때 바이트코드는 SQLite와 같음) |
| `LIKE` | 대소문자 구분, 기본 이스케이프 `\` | 같음(엔진 함수 `xq_like()`). `ILIKE`는 ASCII 대소문자만 무시(`xq_ilike()`) | SQLite의 LIKE는 대소문자를 무시하고 기본 이스케이프가 없음 |
| identity·serial | 시퀀스 | 시퀀스 `<table>_<col>_seq`. 아래 [identity](#identity와-serial) | SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않음 |
| `now()`, `current_timestamp` | 시간대가 있는 타임스탬프 | 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음). 셸과 서버는 `timestamptz` 열에 `+00`을 붙여 보여 줌 | SQLite 날짜 함수가 그대로 읽음 |
| 날짜·시각 연산 | 세션 시간대로 계산 | 같은 결과(위 [연산자 해석](expressions.md#연산자-해석)). `timestamptz`는 늘 UTC로 계산(`SET TIME ZONE`은 보여 주기만 함). 날짜와 타임스탬프의 비교는 ISO 텍스트의 비교(같은 타입끼리와 문자열 상수는 PostgreSQL과 같음; `timestamp = date`는 시각 `00:00:00`이 없는 텍스트라 다름). interval의 비교와 `ORDER BY`는 collation `xq_pg_interval`(한 달은 30일: `'1 mon' = '30 days'`). 그 collation은 jsonb의 것처럼 방언의 것이라, interval을 비교하는 뷰는 SQLite 방언과 평범한 sqlite3에서 읽을 수 없음. [확장](../extension.md)을 올린 sqlite3는 collation과 interval 함수(`xq_pg_interval*`)를 가짐 | 저장은 sqlite3가 읽는 TEXT |
| 이름의 대소문자 | `"Foo"`와 `foo`는 다른 이름 | 접기는 하지만 같은 이름 | SQLite의 이름 비교는 대소문자를 구분하지 않음 |
| 오류 문구 | PostgreSQL 문구 | 싼 곳에서만 PostgreSQL 문구(아래 [오류](#오류)). 실행 중 제약 위반도 PostgreSQL 문구와 `DETAIL`(값을 PostgreSQL처럼 쓸 수 있는 타입만) | |
| 0으로 나누기 | 오류 | 같음(`/`, `%`가 `division by zero`, 22012). 이 방언으로 컴파일한 문장에서만이고, sqlite3나 SQLite 방언에서 같은 뷰·CHECK를 계산하면 NULL | 엔진의 산술 정책(`Hooks.arith`) |
| 정수 오버플로 | int4·int2 연산도 오류 | 같음: 타입이 `integer`인 연산(`integer + integer`, 32비트 리터럴끼리의 `SELECT 2147483647 + 1`, 단항 `-`, `(-2147483647 - 1) / -1`)은 `integer out of range`, `smallint`끼리는 `smallint out of range`, `bigint`는 64비트를 넘으면 `bigint out of range`(모두 22003). 이 방언으로 컴파일한 문장에서만이고(뷰와 트리거 본문 포함), CHECK·생성 열의 식과 sqlite3·SQLite 방언에서는 64비트로 계산. 매개변수는 추론한 타입(`a + $1`의 `integer`)이라 클라이언트가 `int8`로 지정해도 `integer`로 검사 | 코드 생성이 연산의 P5에 폭을 적음([타입을 읽는 코드 생성](../architecture.md#타입을-읽는-코드-생성)) |
| 복합 질의의 타입 | 항들의 타입을 맞추거나 실패(`UNION types boolean and integer cannot be matched`) | 공통 타입이 있으면 그 타입, 없으면 실패하지 않고 타입을 모름(값은 저장된 대로 보임) | |
| 외래 키 | 늘 강제 | 같음. 이 방언의 첫 문장에서 연결의 `PRAGMA foreign_keys`를 켬. 응용이 끈 것은 그대로 둠 | sqlite3는 여전히 끈 채로 씀 |
| 격리 수준 | 여러 수준 | 파싱만 함 | SQLite는 늘 직렬화 |
| JSON | `jsonb`는 이진 형식 | SQLite의 JSONB(정준 인코딩). `json`은 입력 텍스트. 이 방식 전에 만든 TEXT 열은 정규화한 TEXT | 확장 없는 sqlite3가 `json(j)`, `json_extract()`, `->>`로 읽음. sqlite3는 TEXT를 넣지 못하고(STRICT BLOB) `jsonb('...')`로 넣으며, 그 값은 정준이 아닐 수 있음(연산자·함수는 읽을 때 정규화; 확장을 올린 sqlite3는 `xq_pg_jsonb_bin(x)`로 정준 JSONB를 넣을 수 있음). CHECK `json_valid(j, 8)`(깊이 1000까지)는 SQLite의 규칙. 연산자(`->`, `@>`, `?` ...)의 식 인덱스·CHECK·뷰는 [확장](../extension.md)을 올린 sqlite3가 같은 결과로 계산 |
| jsonb 비교 | jsonb의 순서 | 같음(정렬 키 `xq_pg_jsonb_key()`). 열의 인덱스는 `=`에 쓰이지 않음. UNIQUE·`GROUP BY`·`DISTINCT`는 정준 JSONB의 바이트라 수의 철자만 다른 같은 값(`1.0`과 `1`)은 다른 값(PostgreSQL은 같은 값; 예전 TEXT 저장도 그랬음). 복합 질의의 `ORDER BY`는 위 [JSON](json.md) | |
| JSON 수 | numeric과 float8 | 같음: 타입을 아는 인자는 JSON을 만드는 함수가 PostgreSQL 철자로 씀. `double precision`/`real`은 `float8out()`처럼 되읽히는 가장 짧은 자릿수, 지수가 -4~14면 고정 소수점, 아니면 두 자리 이상의 지수(`to_json(100.0::float8)`은 `100`, `1e20::float8`은 `1e+20`, `1e-5::float8`은 `1e-05`; `xq_pg_float_json()`), `numeric`은 그 자릿수(`to_json(1.50)`은 `1.50`, `numeric(5,2)` 열의 2는 `2.00`, `avg()`는 `1.5000000000000000`; 키는 `xq_pg_dec_json()`, 리터럴은 `xq_pg_numeric_json()`), `NaN`·`Infinity`는 문자열. `row_to_json`·`json_agg`의 열도 | 타입을 모르는 값은 SQLite 철자(`2.5`, `1.0e+20`) |
| 배열 | 원소 타입이 있는 이진 값 | PostgreSQL의 배열 텍스트(`{1,2}`)를 TEXT로. 원소 타입은 식의 타입([배열](arrays.md)). API로도 텍스트. 원소 타입을 모르는 곳(타입 모르는 매개변수, `ANY`의 문자열 상수 밖)에서는 원소를 적힌 대로 값으로 비교. `name[]`은 원소 타입이 없어 와이어에서 `text[]`(1009, PostgreSQL은 1003) | sqlite3가 그대로 읽고, 와이어·psql·카탈로그가 이미 이 텍스트를 씀. 배열 열의 CHECK(`xq_pg_array_valid()`)와 첨자·연산자의 식, collation `xq_pg_array`·`xq_pg_array_num`의 정렬은 [확장](../extension.md)을 올린 sqlite3가 계산 |
| 저장되는 식 | | IR이 SQLite 텍스트로 렌더링. PostgreSQL 함수는 `xq_postgres_greatest(...)`, LIKE는 `xq_like(...)`처럼 저장 | SQLite 방언이나 다른 방언의 연결에서 읽어도 같은 뜻. 평범한 sqlite3에서는 그런 식을 계산할 수 없고, [확장](../extension.md)(`libxqlite_ext`)을 올린 sqlite3·Python·Datasette는 같은 결과로 계산(세션·카탈로그를 읽는 `current_setting()`, `pg_get_viewdef()` 같은 것만 빠짐). 그 함수들의 뜻은 파일 형식의 일부라 바뀌지 않음([ABI 규칙](../extension.md#abi-규칙)) |

저장되는 식은 CHECK, DEFAULT, 생성 열, 인덱스 식, 뷰입니다.

## identity와 serial

- `serial`과 `GENERATED ... AS IDENTITY`는 시퀀스 `<table>_<col>_seq`로 번호를 매깁니다(PostgreSQL과 같은 이름).
- 열은 `INTEGER NOT NULL DEFAULT (nextval('seq'))`이고, 키이면 SQLite의 INTEGER PRIMARY KEY(rowid)가 됩니다.
- `xq_catalog`에 `identity`/`identity_kind` 키가 남습니다.
- INSERT가 빠뜨린 identity 열(그리고 `DEFAULT`)은 공용 내림(`src/ir/lower.zig`)이 catalog의 `identity` 키를 보고 `nextval()`로 채웁니다. DEFAULT 텍스트에 기대지 않는 이유는 둘입니다.
  - SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않습니다.
  - `trusted_schema`가 꺼져 있으면 스키마의 `nextval()`은 unsafe use입니다.
- `GENERATED ALWAYS`는 명시한 값을 거부합니다(`cannot insert a non-DEFAULT value into column "id"`). `OVERRIDING SYSTEM VALUE`로 허용합니다.
- 테이블을 지우면 시퀀스도 지웁니다. `TRUNCATE ... RESTART IDENTITY`는 시퀀스를 다시 시작합니다.
- sqlite3에서 이 테이블에 키 없이 넣으면 rowid가 번호를 매깁니다.
- 키가 아닌 identity 열은 DEFAULT의 `nextval()`이 번호를 매깁니다. [확장](../extension.md)을 올린 sqlite3는 `PRAGMA trusted_schema=ON`에서 같은 시퀀스(`xq_sequence`)로 번호를 매기므로, 두 엔진이 번갈아 넣어도 겹치지 않습니다.

## 결과 열 이름

PostgreSQL 규칙을 따릅니다: `?column?`, 함수 이름, 상수 캐스트면 `int4` 같은 타입 이름, `case`, `exists`.

## 오류

PostgreSQL 문구를 쓰는 오류입니다.

- `syntax error at or near "x"`, `syntax error at end of input`
- `relation "t" does not exist`, `column "c" does not exist`
- `column reference "a" is ambiguous`
- `relation "t" already exists`
- 스키마의 오류([스키마](statements.md#스키마))
- `cannot insert a non-DEFAULT value into column "id"`
- `function foo(integer, unknown) does not exist`(42883): 이름과 인자 수로 맞는 함수가 없는 호출(인자 수가 다른 내장 함수 `round(1, 2, 3)`도)은 PostgreSQL처럼 인자를 먼저 해석하고(인자의 오류 `column "x" does not exist`가 먼저), 그 타입을 `format_type()`의 철자로 적습니다: `integer`, `numeric`, `bigint`, `text`, `boolean`, `character varying`, `timestamp with time zone`, `integer[]` ...; 문자열 상수, NULL, 타입 모르는 매개변수는 `unknown`. 이름 해석이 인자를 타입 매긴 뒤 방언의 오류를 부릅니다(`typing.Rules.no_function`). 코어가 타입을 모르는 인자(SQLite 테이블의 열, 타입 규칙이 없는 함수)도 `unknown`입니다.

### 위치와 DETAIL·HINT·CONTEXT

psql이 `LINE 1: ...`과 `^`로 보여 주는 위치(ErrorResponse의 `P`)와 그 아래 줄들을 PostgreSQL처럼 냅니다.

- **위치**: 엔진의 오류 오프셋(`sqlite3_error_offset()`)입니다. 문법 오류, 없는 열·함수, 없는 테이블(FROM의 항목과 INSERT/UPDATE/DELETE의 대상: 내림이 `SrcItem.xq_ofst`에 이름의 오프셋을 적음), 없는 연산자(연산자의 글자: `true + 1`의 `+`, 단항 `-`), 그리고 아래 리터럴의 입력 오류가 위치를 갖습니다. 실행 중 오류(`division by zero`, `integer out of range`, 저장할 때의 `numeric field overflow`)는 PostgreSQL처럼 위치가 없습니다.
- **리터럴의 입력**: PostgreSQL은 타입이 정해진 문자열 리터럴(unknown)을 파싱할 때 그 타입의 입력 함수로 읽어, 읽지 못하면 행을 계산하지 않아도 그 리터럴에서 실패합니다. 이 방언도 그렇게 합니다(`typing.Rules.literal_input`, `typing.readLiteral()`).
  - 캐스트(`'x'::int`, `bool 'test'`, `CAST('x' AS jsonb)`), 타입을 아는 피연산자와 만난 리터럴(`'a' + 1`, 불리언과 비교하는 `b = 'xyz'`·`b IN ('xyz')`; PostgreSQL이 공통 타입을 고르는 대로 불리언이 든 IN 목록과 CASE의 결과·`CASE b WHEN`의 값: `true IN ('yes', 'no')`, `'x' IN (b, true)`, `CASE WHEN c THEN b ELSE 'yes' END`), INSERT VALUES·UPDATE SET에서 열에 저장하는 리터럴(`Rules.store`/`store_column`의 저장 함수)이 대상입니다. 그래서 빈 테이블의 `SELECT ... WHERE b = 'xyz'`도 `invalid input syntax for type boolean: "xyz"`로 실패합니다.
  - 스키마에 남는 식도 같습니다: `CREATE VIEW ... WHERE b = 'xyz'`, `CHECK (b <> 'xyz')`는 만들 때 실패하고, 읽을 수 있는 리터럴은 `xq_pg_bool('t')`로 적힙니다(`ddltype.zig`).
  - 그 변환 함수의 인자 하나짜리를 컴파일할 때 불러 봅니다. 결정적(`deterministic`)인 함수만 부르므로 데이터베이스를 읽는 `regclass`의 입력은 실행할 때 읽습니다.
  - PostgreSQL처럼 타입의 매개변수 없이 읽습니다. `numeric(4,4)` 열에 `'1.0'`을 넣는 `numeric field overflow`는 실행 중 오류(위치 없음)이고, `'abc'`는 입력 오류(위치 있음)입니다.
- **DETAIL·HINT·CONTEXT**: 오류 메시지의 첫 줄 뒤에 psql이 찍는 모양의 줄(`\nDETAIL:  ...`, `\nHINT:  ...`, `\nCONTEXT:  ...`)로 붙습니다(`util.detail_mark`). 그래서 `sqlite3_errmsg()`와 셸, 확장을 올린 sqlite3는 그 줄까지 보여 줍니다. 각 줄이 어디서 시작하는지는 오류를 낸 곳이 메시지와 함께 남기므로(`ErrorState.fields`, [오류 코드](../architecture.md#오류-코드)), 와이어 서버는 메시지를 읽지 않고 그 자리에서 잘라 ErrorResponse의 `D`, `H`, `W` 필드로 보냅니다(Zig API `ErrorInfo.fields()`). 메시지가 인용한 값에 `\nHINT:  ` 같은 글자가 있어도 필드가 되지 않습니다. NUL이 든 메시지(PostgreSQL에는 없는 텍스트)에는 붙이지 않습니다.

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
| 타입 검사(위 [타입 매핑](types.md)) | `integer out of range` ... | 22003, 22001, 22P02 |
| 외래 키(자식 행) | `insert or update on table "t" violates foreign key constraint "t_b_fkey"` | 23503 |
| 외래 키(부모 행) | `update or delete on table "p" violates foreign key constraint "t_b_fkey" on table "t"` | 23503 |

- 제약 이름은 사용자가 준 이름(`CONSTRAINT x`, 인덱스 이름)이고, 없으면 PostgreSQL이 붙이는 이름입니다: `<table>_pkey`, `<table>_<columns>_key`, `<table>_<columns>_fkey`, `<table>_<column>_check`, `<table>_check`. 같은 이름이 겹칠 때 PostgreSQL이 붙이는 번호(`t_a_key1`)는 붙이지 않습니다.
- SQLite가 남기지 않는 UNIQUE, PRIMARY KEY, FOREIGN KEY의 이름은 CREATE TABLE이 `xq_catalog`에 적어 둡니다(키 `constraint:<종류>:<열>`). 그 뒤 RENAME COLUMN으로 열 이름이 바뀌면 기본 이름으로 돌아갑니다.
- 문장이 끝날 때 찾는 외래 키 위반(여러 행, 부모 행 지우기)은 마지막으로 센 위반의 제약을 말합니다. COMMIT에서 찾는 지연 제약(`DEFERRABLE INITIALLY DEFERRED`)은 어느 제약인지 모르므로 `insert or update violates foreign key constraint`입니다.
- 이 방언으로 컴파일한 문장에서만입니다. sqlite3나 SQLite 방언의 문장은 SQLite 문구(`UNIQUE constraint failed: t.a`)입니다.

### NOTICE

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
- Zig API는 `Stmt.notices()`(수준, SQLSTATE, 메시지, `DETAIL`)와 `Db.noticeLevel()`(`client_min_messages`: 기본 `notice`, `warning`이면 `NOTICE`를, `error`면 `WARNING`도 뺌)입니다. 와이어 서버는 `NoticeResponse`로 그 문장의 `CommandComplete` 앞에 보내고([서버](../server.md#단순-질의)), 셸은 psql처럼 stderr에 `NOTICE:  ...`와 `DETAIL:  ...`을 찍습니다.
