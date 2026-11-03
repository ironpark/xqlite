# JSON

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

SQL Server처럼 JSON은 `NVARCHAR` 텍스트이고, 함수는 텍스트를 쓰인 그대로 다룹니다. `JSON_QUERY`, `OPENJSON`의 `value`, `JSON_MODIFY`가 건드리지 않은 부분은 입력의 공백까지 그대로 돌려줍니다. 문법은 RFC 8259입니다(SQLite의 json 함수와 달리 JSON5 확장 없음). 문서는 객체나 배열이어야 합니다.

```sql
DECLARE @j NVARCHAR(MAX) = N'{"id":7,"tags":["a","b"],"owner":{"name":"ann"}}';
SELECT JSON_VALUE(@j, '$.owner.name'), JSON_QUERY(@j, '$.tags'), JSON_MODIFY(@j, 'append $.tags', 'c');
SELECT [key], value, type FROM OPENJSON(@j);
SELECT o.id, l.sku, l.qty FROM orders o
  CROSS APPLY OPENJSON(o.lines) WITH (sku VARCHAR(10), qty INT '$.qty') AS l;
SELECT o.id, o.name, i.sku FROM o JOIN i ON i.oid = o.id ORDER BY o.id FOR JSON AUTO, ROOT('orders');
```

## 함수

| 함수 | 동작 |
| --- | --- |
| `ISJSON(x)` | 객체나 배열이면 1, 아니면 0, NULL이면 NULL. SQLite의 `json_valid()`와 `json_type()`으로 내려서 `CHECK (ISJSON(doc) = 1)`을 sqlite3도 검사합니다. |
| `ISJSON(x, VALUE \| ARRAY \| OBJECT \| SCALAR)` | SQL Server 2022: 아무 값, 배열, 객체, 문자열이나 수 |
| `JSON_VALUE(x, path)` | 스칼라의 텍스트(문자열은 이스케이프를 푼 값, 수와 `true`/`false`는 쓰인 그대로). 객체·배열·없는 경로는 lax에서 NULL, strict에서 오류. 4000자가 넘으면 NULL(strict는 오류) |
| `JSON_QUERY(x [, path])` | 객체나 배열의 텍스트. 스칼라·없는 경로는 lax에서 NULL, strict에서 오류 |
| `JSON_MODIFY(x, path, v)` | 바꾸기, 없는 속성 추가, `append`(배열 끝에, 없으면 `[v]`를 만듦), lax에서 `NULL`이면 속성 삭제(배열 원소는 `null`). strict에서 없는 경로는 오류. 경로 `$`만은 `append $`일 때만 됩니다. |
| `JSON_PATH_EXISTS(x, path)` | SQL Server 2022: 경로에 값이 있으면 1 |
| `JSON_OBJECT('k': v, ... [NULL \| ABSENT ON NULL])` | SQL Server 2022, 기본 `NULL ON NULL` |
| `JSON_ARRAY(v, ... [NULL \| ABSENT ON NULL])` | SQL Server 2022, 기본 `ABSENT ON NULL` |
| `STRING_ESCAPE(s, 'json')` | JSON 문자열의 본문으로 이스케이프 |

- 경로: `[append ][lax |strict ]$` 뒤에 `.key`, `."key"`, `[n]`. 키는 대소문자를 구분하고, 같은 키가 둘이면 처음 것입니다. 따옴표 없는 키는 ASCII 글자와 `_`로 시작하고 숫자를 이을 수 있습니다. 앞뒤 공백과 `strict$.a`를 받습니다.
- SQL Server처럼 문서를 필요한 만큼만 읽습니다. `JSON_VALUE`와 `JSON_QUERY`는 찾은 값에서 멈추고(`JSON_VALUE('{"a":1', '$.a')`는 1), 경로가 다른 종류의 값으로 이어지면 더 보지 않고(`JSON_VALUE('[1, 2', '$.zz')`는 NULL), 찾지 못하면 문서 끝까지 확인합니다. `OPENJSON`은 원소를 하나씩 읽고, `ISJSON`과 `JSON_MODIFY`는 전부 읽습니다.
- 오류 문구는 SQL Server의 것입니다: `JSON text is not properly formatted. Unexpected character 'x' is found at position 8.`(위치는 문자 단위, 잘못된 문자열·수·리터럴은 그 시작, 텍스트의 끝은 `'.'`), `JSON path is not properly formatted. ...`, `Property cannot be found on the specified JSON path.` 등.
- 리터럴 `NULL` 경로, 수인 문서 인자, `JSON_MODIFY`의 날짜·`money`·2진·`uniqueidentifier` 값은 SQL Server처럼 컴파일 오류입니다.

## 값을 JSON으로 쓰는 방법

`FOR JSON`, `JSON_MODIFY`, `JSON_OBJECT`, `JSON_ARRAY`가 값을 쓰는 방법은 SQL Server처럼 값의 SQL 타입이 정합니다. 파서가 타입을 알아내어(`CAST`/`CONVERT`의 대상, 리터럴, 함수, FROM 절 테이블 열의 선언 타입, `OPENJSON ... WITH`의 열) 엔진 함수에 값마다 종류를 넘깁니다.

| 타입 | JSON |
| --- | --- |
| 문자열, `uniqueidentifier` | 문자열. `"`, `\`, `/`(`\/`), 제어 문자(`\n`, `\t`, `\u0001` ...)를 이스케이프 |
| 정수, `decimal`, 모르는 타입의 수 | 수 |
| `bit` | `true`/`false` |
| `float`(지수가 있는 리터럴 포함) | `1.500000000000000e+000` |
| `real` | `FOR JSON`에서 `1.5000000e+000`, `JSON_MODIFY`에서 `float`처럼 |
| 날짜·시간 | 문자열, 날짜와 시각 사이에 `T`(`2024-01-02T03:04:05.123`), 오프셋 앞 공백 없음 |
| `binary`/`varbinary` | base64 문자열 |
| JSON(`JSON_QUERY`, `JSON_MODIFY`, `JSON_OBJECT`, `JSON_ARRAY`, `WITHOUT_ARRAY_WRAPPER` 없는 `FOR JSON` 서브쿼리) | 그대로(이스케이프하지 않음) |

그래서 `JSON_MODIFY(j, '$.a', '[1]')`은 문자열 `"[1]"`을, `JSON_MODIFY(j, '$.a', JSON_QUERY('[1]'))`은 배열을 넣습니다.

## OPENJSON

- `OPENJSON(json [, path])`: 경로의 객체 멤버나 배열 원소마다 한 행. 열은 `key`(배열은 `'0'`, `'1'` ...; SQL Server의 BIN2처럼 대소문자를 구분), `value`(스칼라의 텍스트, 객체·배열은 쓰인 그대로), `type`(0 null, 1 문자열, 2 수, 3 true/false, 4 배열, 5 객체).
- `WITH (열 타입 ['경로'] [AS JSON], ...)`: 경로의 배열 원소마다(객체면 그 객체 하나가) 한 행. 경로를 빼면 `$.열이름`. 값은 `CAST`처럼 열 타입으로 바꾸고(`Conversion failed when converting the nvarchar value ...`), `AS JSON`(`NVARCHAR(MAX)`만)은 객체·배열을 그대로 돌려줍니다. 스칼라 자리에 객체·배열이 있거나 그 반대면 lax에서 NULL, strict에서 오류입니다.
- 경로의 값이 스칼라면 lax에서 빈 결과, strict에서 오류. 없는 경로도 같습니다. `json`이 NULL이면 빈 결과입니다.
- `FROM`과 `CROSS APPLY`/`OUTER APPLY`에 씁니다. `t CROSS APPLY OPENJSON(t.doc)`은 조인 `t JOIN xq_tsql_openjson(t.doc)`이고 `OUTER APPLY`는 `LEFT JOIN`입니다. SQLite가 테이블 값 함수의 인자에 앞 테이블의 열을 허용하므로 LATERAL 없이 됩니다.
- 구현: 엔진 테이블 값 함수(이름 없는 가상 테이블, eponymous virtual table) `xq_tsql_openjson`입니다. 인자는 숨은 열 `xq_json`, `xq_path`입니다. `WITH`의 열은 문장마다 다르므로 스펙(JSON `[[이름, 타입, 경로, AS JSON], ...]`)을 모듈 이름 `xq_tsql_openjson_<해시>:<스펙>`에 넣습니다. 처음 보는 `xq_`로 시작하는 테이블 이름이면 방언 훅(`Hooks.table_function`)이 그 이름에서 모듈을 만들어 등록하므로, 이 이름을 쓰는 뷰도 어느 연결·어느 방언에서나 열립니다. 해시는 대소문자만 다른 스펙(경로는 대소문자를 구분)을 가릅니다. `json_each()`로 내리지 않은 것은 `value`·`type`의 값(쓰인 그대로의 텍스트, SQL Server의 타입 번호)과 열 이름, JSON5를 받는 것, 오류가 SQL Server와 달라서입니다.

## FOR JSON

```sql
SELECT a, b AS [x.y] FROM t ORDER BY a FOR JSON PATH
-- 내림:
SELECT xq_tsql_for_json('<스펙>', xq_fj.xq_j0, xq_fj.xq_j1) AS "JSON_F52E2B61-18A1-11d1-B105-00805F49916B"
FROM (SELECT a AS xq_j0, b AS xq_j1 FROM t ORDER BY xq_j0 LIMIT -1) AS xq_fj HAVING count(*) > 0
```

- `FOR JSON PATH`와 `AUTO`, `ROOT[('이름')]`, `INCLUDE_NULL_VALUES`, `WITHOUT_ARRAY_WRAPPER`. 결과 열 이름은 SQL Server처럼 `JSON_F52E2B61-18A1-11d1-B105-00805F49916B`이고, 행이 없으면 결과도 없습니다(서브쿼리로는 NULL).
- 질의는 그대로 두고 열 이름만 바꿔 집계로 감쌉니다. `ORDER BY`가 결과 열 이름을 부르면 바꾼 이름으로 고치고, `LIMIT`이 순서를 지킵니다. `*`와 `t.*`는 FROM 절 테이블(카탈로그), 서브쿼리, `OPENJSON`의 열로 펼칩니다.
- PATH: 점이 있는 이름(`[x.y]`)은 중첩 객체이고 이웃한 열의 같은 객체는 합칩니다. 값이 모두 NULL인 객체는 뺍니다. 같은 속성이 되는 이름(`a`와 `a`, 떨어진 `x.a`와 `x.b`, `x`와 `x.b`)은 SQL Server의 오류(`Property 'x.b' cannot be generated in JSON output ...`)입니다.
- AUTO: 선택 목록에 처음 나오는 순서로 테이블마다 한 단계이고, 다음 테이블의 열은 그 테이블의 이름(별칭)으로 된 배열에 들어갑니다. 열이 아닌 식은 앞 열의 단계입니다. 앞 단계의 값이 같은 연속된 행은 한 객체를 나눠 씁니다. 점이 있는 이름은 그대로 키입니다. FROM이 없으면 오류입니다.
- 이름 없는 식 열은 오류입니다. `FOR JSON` 서브쿼리는 JSON이라서(`WITHOUT_ARRAY_WRAPPER`가 아니면) 바깥 `FOR JSON`이나 `JSON_MODIFY`에서 이스케이프하지 않습니다.

## 스키마와 sqlite3

- `ISJSON(x)`만 쓰는 식(`CHECK (ISJSON(doc) = 1)`)은 SQLite의 함수라서 sqlite3도 검사합니다(`xqt interop mssql`).
- 다른 JSON 함수는 엔진 함수(`xq_tsql_json_*`, `xq_tsql_for_json`)이고 `OPENJSON`은 엔진 테이블 값 함수입니다. 계산 열(`AS JSON_VALUE(doc, '$.a')`)이나 뷰에 써도 xqlite는 어느 방언으로든 읽지만, sqlite3는 계산하지 못합니다(`no such function`, `no such table`).
