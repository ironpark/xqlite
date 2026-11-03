# JSON

[Oracle 호환](README.md)의 일부입니다.

Oracle Database 23ai의 JSON을 지원합니다. JSON 값은 텍스트이고, 경로 언어와 함수는 이 방언이 직접 구현합니다(`json.zig`). SQLite의 `json1`과는 문법(lax), 경로(`[*]`, 필터, 항목 메서드), 숫자와 출력 형식이 달라서 쓰지 않습니다.

## JSON 타입과 IS JSON

- `JSON` 열은 `TEXT`로 저장하고 `CHECK (json_valid(열))`을 붙입니다. 선언 타입 `JSON`은 `xq_catalog`에 남고 `USER_TAB_COLUMNS`는 `JSON`, 길이 8200입니다.
- INSERT·UPDATE가 넣는 값은 저장 변환(`xq_ora_coerce()`)이 Oracle처럼 바꿉니다.
  - lax 문법을 읽고, 압축 형식(공백 없음)으로 씁니다. `'{a : 1}'` → `{"a":1}`
  - 숫자는 Oracle `NUMBER`의 철자입니다. `1.50` → `1.5`, `1e2` → `100`, `-0.0` → `0`
  - 문법 오류는 `ORA-40441`, 중복 키는 `ORA-40444`
- 그래서 저장된 값은 RFC 8259 JSON이고, sqlite3도 `json_valid()` 검사와 `json_extract()`를 그대로 씁니다.
- `x IS [NOT] JSON [STRICT|LAX] [WITH UNIQUE KEYS] [DISALLOW SCALARS]`는 `xq_ora_is_json(x, flags)`입니다. NULL이면 NULL입니다. CHECK에 쓸 수 있습니다.
- lax 문법(기본): 따옴표 없는 키, 작은따옴표 문자열, 대소문자 무관한 `true`/`null`, `.5`·`+1`·`01`·`1.`·`0x10`·`NaN`, 끝의 쉼표, `/* */`·`//` 주석. `STRICT`는 RFC 8259입니다.

## 함수

| Oracle | xqlite | 지원 |
| --- | --- | --- |
| `JSON_VALUE` | `xq_ora_json_value()` | `RETURNING`(`VARCHAR2(n)`, `NUMBER(p,s)`, `DATE`, `TIMESTAMP`, `BOOLEAN`, `CLOB`, `JSON` ...), `TRUNCATE`, `ERROR`/`NULL`/`DEFAULT e ON ERROR`, `... ON EMPTY`(없으면 `ON ERROR`를 따름), `PASSING` |
| `JSON_QUERY` | `xq_ora_json_query()` | `WITH [CONDITIONAL\|UNCONDITIONAL] [ARRAY] WRAPPER`, `WITHOUT WRAPPER`, `PRETTY`, `ASCII`, `RETURNING`, `ERROR`/`NULL`/`EMPTY [ARRAY\|OBJECT] ON ERROR\|EMPTY`, `PASSING` |
| `JSON_EXISTS` | `xq_ora_json_exists()` | `PASSING e AS "v"`, `TRUE`/`FALSE`/`ERROR ON ERROR`. 조건(`WHERE`)으로도, 결과 열(23ai의 BOOLEAN)로도 |
| `JSON_OBJECT` | `xq_ora_json_object()` | `[KEY] k VALUE v`, `k : v`, `KEY k IS v`, 열 이름만(`JSON_OBJECT(k)`는 `{"k": ...}`, 쓴 대로의 이름), `*`, `FORMAT JSON`, `NULL`/`ABSENT ON NULL`, `RETURNING`, `STRICT`, `WITH UNIQUE KEYS` |
| `JSON_ARRAY` | `xq_ora_json_array()` | `FORMAT JSON`, `NULL`/`ABSENT ON NULL`(기본 `ABSENT`), `RETURNING` |
| `JSON_OBJECTAGG`, `JSON_ARRAYAGG` | 집계 `xq_ora_json_objectagg()`, `xq_ora_json_arrayagg()` | `ORDER BY`(배열), `NULL`/`ABSENT ON NULL`, `RETURNING`. 행이 없으면 NULL |
| `JSON_MERGEPATCH` | `xq_ora_json_mergepatch()` | RFC 7396, `PRETTY`, `ASCII`, `RETURNING`, `TRUNCATE`, `NULL`/`ERROR ON ERROR` |
| `JSON_SERIALIZE` | `xq_ora_json_serialize()` | `PRETTY`, `ASCII`, `ORDERED`, `TRUNCATE`, `RETURNING` |
| `JSON_TRANSFORM` | `xq_ora_json_transform()` | `SET`, `INSERT`(배열 위치 포함, 있으면 `ORA-40763`), `REPLACE`, `APPEND`, `REMOVE`, `RENAME`(맨 뒤로 옮김), `KEEP` |
| `JSON(x)`, `JSON_SCALAR(x)` | `xq_ora_json()`, `xq_ora_json_scalar()` | |
| `t.col.a.b[0].size()` | `xq_ora_json_dot()` | 점 표기([아래](#점-표기)) |
| `JSON_TABLE` | 테이블 함수 `xq_ora_json_table()` | [아래](#json_table) |

- 경로: `$`, `.key`, `."키"`, `.*`, `..key`(후손), `[n]`, `[n to m]`, `[n, m]`, `[last]`, `[last - n]`, `[*]`, 필터 `?(...)`(`== != < <= > >=`, `&&`, `\|\|`, `!`, `exists(...)`, `starts with`, `has substring`, `like`, `in (...)`, `@`, `$변수`), 항목 메서드(`size()`, `type()`, `length()`, `lower()`, `upper()`, `number()`, `string()`, `boolean()`, `abs()`, `ceiling()`, `floor()`, `double()`, `count()`, `sum()`, `avg()`, `min()`, `max()` ...). lax 모드입니다(배열의 멤버 접근은 원소마다, 스칼라의 `[0]`은 그 값).
- 경로는 문자열 상수여야 하고, 문장을 컴파일할 때 검사합니다. `$`로 시작하지 않거나 문법이 틀리면 `ORA-40597`, `lax`/`strict` 앞말은 Oracle 23ai처럼 `ORA-40442`입니다.
- 출력 형식은 SQL*Plus가 보여 주는 Oracle의 것입니다.
  - 압축 형식에는 공백이 없습니다(`{"a":1,"b":[1,2]}`).
  - `PRETTY`는 두 칸 들여쓰기, `"키" : 값`입니다. 컨테이너는 키 다음 줄에서 시작하고 빈 컨테이너는 여는 줄과 닫는 줄입니다.
  - 제어 문자는 `\u0001`, `ASCII`는 `é`입니다.
- 숫자
  - `JSON_VALUE`는 `NUMBER`의 철자입니다(`1e-2` → `0.01`).
  - `JSON_QUERY`와 다른 함수는 텍스트 문서의 철자를 지키고 지수 문자만 대문자로 씁니다(`1.50`, `1E2`).
  - SQL 숫자는 JSON에 `0.5`처럼 씁니다(Oracle의 `.5`가 아님).
- 오류 코드: `ORA-40441`(문법), `ORA-40456`(스칼라 아님), `ORA-40462`(값 없음), `ORA-40470`(값 여럿), `ORA-40480`(래퍼 필요), `ORA-40478`·`ORA-61723`(길이), `ORA-40473`(중복 키), `ORA-40629`(패치), `ORA-40762`·`ORA-40763`(`JSON_TRANSFORM`).
- JSON 결과에는 SQLite의 JSON 서브타입이 붙습니다. 그래서 `JSON_OBJECT('k' VALUE JSON_QUERY(...))`처럼 JSON 생성 함수에 준 JSON 결과는 문자열이 아니라 JSON입니다. 파서가 이렇게 바꾸는 값도 있습니다.
  - `JSON` 열은 `xq_ora_json(열)`로 감쌉니다.
  - 날짜는 ISO 8601 텍스트입니다(`replace(d, ' ', 'T')` → `"2024-01-02T00:00:00"`).
  - `TRUE`/`FALSE` 상수는 JSON의 `true`/`false`입니다.
- `JSON_VALUE`의 기본 결과는 `VARCHAR2(4000)` 텍스트입니다. 숫자 상수와 비교하면(`JSON_VALUE(d, '$.a') = 5`) Oracle처럼 숫자로 바꿔 비교합니다(`xq_ora_cast(..., 'NUMBER')`).
- `''`는 NULL입니다. `JSON_OBJECT('a' VALUE '')`는 `{"a":null}`이고 `JSON_VALUE('', ...)`는 NULL입니다.

## 점 표기

`t.col.a.b[0].c`, `t.col.a.size()`(테이블 별칭이 필요함)는 파싱 뒤에 FROM을 보고 정합니다. `t`가 FROM에 없으면 예전처럼 `스키마.테이블.열`입니다.

| 열 | 결과 |
| --- | --- |
| `JSON` 타입 | JSON 텍스트. 스칼라도 JSON(`"str"`, `true`, `null`) |
| 텍스트(`IS JSON` 검사가 있는 `VARCHAR2`·`CLOB`) | 스칼라는 SQL 값(`str`, `true`, JSON null은 NULL), 객체·배열은 JSON |

값이 여럿이면 배열로 감쌉니다. 항목 메서드로 끝나면 그 SQL 값입니다. 결과 열 이름은 첫 배열 단계 앞의 마지막 키(대문자)입니다.

## JSON_TABLE

`JSON_TABLE(doc [FORMAT JSON], '행 경로' [ERROR|NULL ON ERROR] COLUMNS (...)) [별칭]`은 엔진의 테이블 함수(eponymous 가상 테이블) `xq_ora_json_table(doc, spec)`입니다.

- `spec`은 파서가 쓰는 열 정의(JSON)입니다.
- 가상 테이블의 열은 `c0` ... `c99`이고, 파서가 JSON_TABLE 열의 참조(`jt.a`, 다른 테이블에 없는 `a`, `*`, `jt.*`)를 그 열로 바꿉니다. 결과 열 이름은 JSON_TABLE 열의 이름입니다.
- SQLite의 테이블 함수처럼 앞의 FROM 항목을 인자로 받습니다(`FROM t, JSON_TABLE(t.doc, ...) jt`, Oracle의 측면 조인).
- 상관 서브쿼리에서는 한정한 이름(`jt.a`)만 바꿉니다.

| 열 정의 | 뜻 |
| --- | --- |
| `name FOR ORDINALITY` | 그 단계의 행 번호(1부터) |
| `name [type] [TRUNCATE] [PATH 'p'] [... ON ERROR] [... ON EMPTY]` | `JSON_VALUE`. 타입이 없으면 `VARCHAR2(4000)`, 경로가 없으면 `'$.name'`(쓴 대로의 이름: `a`는 `$.a`, `A`는 `$.A`) |
| `name [type] FORMAT JSON [WITH ... WRAPPER] [PATH 'p']` | `JSON_QUERY` |
| `name [type] EXISTS [PATH 'p']` | `JSON_EXISTS`. 숫자 타입이면 1/0, 문자 타입이면 `'true'`/`'false'` |
| `NESTED [PATH] 'p' COLUMNS (...)` | 바깥 행마다 그 경로의 행(외부 조인: 없으면 NULL 한 행). 형제 `NESTED`는 Oracle처럼 합집합(다른 형제의 열은 NULL) |

`DEFAULT`는 상수만 됩니다(Oracle과 같음). 문서가 JSON이 아니면 행이 없습니다(`ERROR ON ERROR`면 `ORA-40441`).

## sqlite3에서

- `JSON` 열은 sqlite3가 그대로 읽고 씁니다. 검사는 `json_valid()`입니다. 다만 sqlite3가 넣는 값은 저장 변환을 거치지 않습니다(lax 문법은 거부되고, 숫자는 그대로).
- `IS JSON` 검사, 그리고 SQL/JSON 함수나 `JSON_TABLE`을 쓰는 뷰·생성 열은 `xq_ora_*` 엔진 함수를 부릅니다. 그래서 평범한 sqlite3에서는 그 테이블에 쓰거나 그 뷰를 읽을 수 없습니다(다른 방언 함수와 같은 한계). xqlite는 어느 방언의 연결이든 읽고, [확장](../extension.md)을 올린 sqlite3도 `JSON_TABLE`(엔진의 테이블 값 함수) 말고는 읽고 씁니다.
