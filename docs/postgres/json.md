# JSON

[PostgreSQL 호환](README.md)의 일부입니다.

`json`과 `jsonb`는 PostgreSQL 18과 같은 값을 냅니다. `json`은 TEXT로, `jsonb`는 SQLite 고유의 JSONB(SQLite 3.45+의 이진 JSON, `jsonb()`가 만드는 것)로 저장합니다.

| 타입 | 저장하는 것 | 예 |
| --- | --- | --- |
| `json` | 입력 그대로의 TEXT(공백, 중복 키, 키 순서) | `'{"b":1,  "a":2}'::json` → `{"b":1,  "a":2}` |
| `jsonb` | 정규화한 값의 JSONB BLOB: 키는 길이, 그다음 바이트 순서, 중복 키는 마지막 값, 수는 `numeric_out()` 철자(`1e2`는 `100`, `1.50`은 `1.50`). 보이는 것은 PostgreSQL의 텍스트(공백 포함) | `'{"b":1, "a":[1,2], "a":3}'::jsonb` → `{"a": 3, "b": 1}` |

- `::json`은 검사만 하고(`xq_pg_json()`), `::jsonb`는 정규화합니다(`xq_pg_jsonb()`). 입력 규칙은 PostgreSQL의 것입니다(RFC 8259, `jsonb`의 `\u0000`은 `unsupported Unicode escape sequence`). 잘못된 값은 `invalid input syntax for type json`입니다.
- `json` 열은 TEXT와 CHECK `json_valid()`, `jsonb` 열은 BLOB과 CHECK `json_valid(j, 8)`(JSONB인 BLOB)입니다. INSERT·UPDATE·`ON CONFLICT DO UPDATE`가 넣는 값은 `json` 열이면 검사하고(`jtype.zig`), `jsonb` 열이면 저장 변환(`Rules.store`)이 열의 저장 타입대로 바꿉니다: BLOB 열은 정준 JSONB(`xq_pg_jsonb_bin()`), 이 저장 방식 전에 만든 데이터베이스의 TEXT 열은 지금처럼 정규화한 텍스트(`xq_pg_jsonb_text()`). 상수 DEFAULT는 CREATE TABLE 때 JSONB BLOB 리터럴(`X'...'`)로, 상수가 아닌 DEFAULT와 생성 열은 `xq_pg_jsonb_bin(...)`으로 적습니다. 선언 타입은 `xq_catalog`의 `type` 키에 `json`/`jsonb`로 남습니다.
- 정준 JSONB: 값 하나에 바이트열 하나라서 같은 값은 같은 바이트(UNIQUE, `GROUP BY`, `DISTINCT`가 memcmp로 맞음). 노드마다 가장 작은 헤더, null/true/false, 수는 소수점이 없으면 INT 있으면 FLOAT(지수 없이 `numeric_out()`의 자릿수), 문자열은 이스케이프할 것이 없으면 TEXT 있으면 TEXTRAW(문자 그대로), 객체는 jsonb의 키 순서(`json.zig`의 `toBlob()`). sqlite3 자신의 함수(`jsonb()`, `json_set()` ...)가 쓴 JSONB는 정준이 아닐 수 있습니다(TEXTJ·TEXT5 문자열, JSON5 수, 쓴 순서의 키, 중복 키, 큰 헤더). 연산자와 함수는 그런 값을 읽을 때 정규화하고(`fromBlob()`), 결과는 정준 JSONB입니다. 표시는 저장된 그대로(키 순서, 수의 철자)이고, 그런 값과 정준 값은 바이트가 달라 UNIQUE·`GROUP BY`·`DISTINCT`에서 다른 값입니다(비교 연산자는 같음). `UPDATE t SET j = j`로 정준이 됩니다.
- 표현: jsonb 값이 들어 있는 곳에 따라 BLOB(열에서 온 값과 그 연산자·함수의 결과)이거나 TEXT(상수의 캐스트 `'...'::jsonb`, `to_jsonb()`·`jsonb_build_object()`·`jsonb_agg()` 같은 만드는 함수의 결과, `jsonb[]`의 원소, 예전 TEXT 열)입니다. 엔진 함수는 둘 다 받고, jsonb 인자 중 하나가 JSONB BLOB이면 jsonb 결과도 BLOB입니다(그래서 예전 스키마의 식은 같은 텍스트를 냄). 셸, 와이어 서버(텍스트 형식, 이진 형식은 버전 바이트 1과 텍스트), `jsonb::text`(`xq_pg_jsonb_text()`), `concat()`·`format()`, `jsonb || text`, 배열의 원소는 BLOB의 텍스트를 씁니다(`api/display.zig`의 `textAlloc()`).
- 피연산자 타입으로 정하는 것(`overload.zig`): `jsonb`의 `||`·`-`, `jsonb`의 `->`·`#>`(결과도 jsonb), `jsonb` 비교와 `ORDER BY`(아래), 첨자 `j['a'][0]`(`#>`의 경로, 읽기만), JSON을 만드는 함수의 인자(`json`/`jsonb`는 JSON으로, 불리언은 `true`/`false`로, 배열은 JSON 배열로, `double precision`·`real`·`numeric`은 PostgreSQL 철자의 수로: [PostgreSQL과 다른 점](differences.md)의 JSON 수). 이름을 해석한 뒤 코어의 타입(`Expr.xq_type`)으로 고르므로 테이블 열, 서브쿼리·CTE·뷰의 열, 캐스트, 함수 결과 어디서 온 `jsonb`든 같습니다(`SELECT s.d || '{"b":2}' FROM (SELECT d FROM t) s`, 뷰의 jsonb 열 `||`). 타입을 모르는 쪽(문자열 상수, NULL, 타입 모르는 매개변수)은 다른 쪽 타입으로 읽습니다.
- 이름과 FROM 구조로 정하는 것(`jtype.zig`, 내리기 전): 값으로 쓴 FROM 항목은 그 행(`xq_pg_row_json('a', t.a, ...)`, 값의 JSON 변환은 위처럼 코어가), JSON 집합 반환 함수의 열 참조와 그 옆의 `*`, json 열에 넣는 값(`xq_pg_json()`로 감쌈; 값이 이미 json인 함수 결과면 코어가 감싼 것을 뺌).
- 스키마가 남기는 텍스트(뷰, CHECK, 생성 열, 식 인덱스, CTE 안 포함)에는 그 선택이 함수로 적힙니다(`ddltype.zig`가 같은 식을 해석만 해 보고 트리에 되돌림): `xq_pg_jsonb_concat(...)`, `xq_pg_jsonb_key(j) = xq_pg_jsonb_key(...)`, `CAST(xq_pg_jsonb_text(j) AS TEXT)` ... 그래서 SQLite 방언이나 다른 방언에서 읽어도 같은 뜻이고, 이 방언에서 읽을 때 코어는 뷰·트리거의 텍스트에서 다시 고르지 않습니다(SQLite 방언으로 만든 뷰의 `||`는 이 방언에서도 텍스트 연결).

## 연산자

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
- text[] 인자는 리터럴 `'{a,b}'`, `'{a,b}'::text[]`, `ARRAY['a','b']`, text[] 열입니다(아래 [배열](arrays.md)). `array_to_json()`과 JSON을 만드는 함수는 타입을 아는 배열의 원소를 그 타입대로 씁니다(`int[]`는 수, `boolean[]`은 `true`/`false`).

## 함수

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

## jsonpath

`lax`(기본)/`strict`, `$`, `@`, `$var`(`vars`), `.key`, `."key"`, `.*`, `[*]`, `[n]`, `[n to m]`, `[last]`, `[last - 1]`, 여러 첨자, `.**`, 필터 `? (...)`(`==`, `!=`/`<>`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `exists`, `starts with`, `like_regex`(플래그 `i`, `q`; `.`, `[...]`, `\d`, `^`, `$`, `|`, `*`, `+`, `?`, `{n,m}`), `is unknown`), 산술 `+ - * / %`(numeric처럼: `10 / 3`은 `3.3333333333333333`), 메서드 `type()`, `size()`, `double()`, `abs()`, `floor()`, `ceiling()`. 오류 문구는 PostgreSQL의 것입니다(`JSON object does not contain key "b"`, `jsonpath array subscript is out of bounds`, `syntax error at end of jsonpath input` ...).

## GIN 인덱스

`CREATE INDEX ... USING gin (doc [jsonb_path_ops])`(그리고 `USING hash`)는 같은 열의 B-tree 인덱스로 만듭니다. 이름은 PostgreSQL과 같고(`g_doc_idx`) `pg_indexes`에 나옵니다. 인덱스가 이 열의 검색을 빠르게 하지는 않습니다: `@>`·`?`는 테이블을 훑고, jsonb의 `=`는 정렬 키(`xq_pg_jsonb_key()`)의 비교라 열의 인덱스를 쓰지 않습니다(`((xq_pg_jsonb_key(doc)))`의 식 인덱스는 쓸 수 있음). 열 자체는 평범한 sqlite3가 `json()`, `json_extract()`, `->>`로 읽습니다. `((doc ->> 'name'))` 같은 식 인덱스는 그 식에 쓰입니다. 단 식 인덱스·CHECK·생성 열·뷰의 JSON 연산자와 함수는 스키마에 `xq_pg_*`/`xq_postgres_*` 함수로 남으므로, 평범한 sqlite3에서는 그런 인덱스가 있는 테이블에 쓰거나 그 뷰를 읽을 수 없습니다(열 자체와 `gin` 인덱스는 문제없음). [확장](../extension.md)을 올린 sqlite3는 같은 결과로 계산합니다.
