# 구조

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

프론트엔드는 `src/dialect/mssql/`에 있습니다. 문장을 구문 트리 IR(`src/ir/tree.zig`)로 파싱하고, 내림·렌더링·카탈로그 기록은 공용 `src/ir/lower.zig`와 `render.zig`가 합니다.

| 파일 | 내용 |
| --- | --- |
| `frontend.zig` | 진입점과 훅: 문장 분기, `SELECT @x = ...`·`SELECT ... INTO`, SQLite 오류 문구를 SQL Server 문구로, 방언 함수·엔진 함수 표, 기본 collation `NOCASE` |
| `lexer.zig` | `[x]`·`"x"` 식별자, `N'..'`, `@x`·`@@x`, 중첩 주석, `0x..`, `GO` |
| `parser.zig` | 파서 핵심, 식, SELECT(`TOP`, `OFFSET/FETCH`), `+`의 해석, DML 대상의 카탈로그 정보 |
| `functions.zig` | 함수 호출과 특수 문법(`CAST`/`CONVERT`/`TRY_CAST`, `DATEADD` 등의 datepart, `STRING_AGG ... WITHIN GROUP`), `@@` 함수 |
| `dml.zig` | INSERT, UPDATE, DELETE(`OUTPUT`, `FROM ... JOIN`, `TOP`), MERGE, TRUNCATE |
| `ddl.zig` | CREATE/DROP TABLE·INDEX·VIEW·SEQUENCE, ALTER TABLE |
| `schemas.zig` | CREATE/DROP SCHEMA, `ALTER SCHEMA ... TRANSFER`, `ALTER USER ... WITH DEFAULT_SCHEMA`, `SCHEMA_ID`·`SCHEMA_NAME`·`OBJECT_NAME`·`OBJECT_SCHEMA_NAME` |
| `session.zig` | `DECLARE`, `SET`, 트랜잭션, `PRINT`, `USE`, `EXEC sp_rename` |
| `catalog_views.zig` | `INFORMATION_SCHEMA`와 `sys` 뷰 |
| `types.zig` | SQL Server 타입 → STRICT 저장 타입·검사·철자 |
| `runtime.zig` | 방언 함수와 엔진 함수(`xq_tsql_*`): 변환, 날짜, `LIKE`, 세션 |
| `json.zig` | JSON 텍스트 스캐너, 경로(`lax`/`strict`, `append`), SQL Server의 이스케이프와 오류 문구 |
| `json_func.zig` | JSON 엔진 함수(`xq_tsql_json_*`)와 `FOR JSON`의 집계 함수 |
| `json_sql.zig` | 파서 쪽: JSON 함수의 특수 문법, `FOR JSON`, `FROM`의 `OPENJSON`, 값의 JSON 종류 |
| `openjson.zig` | `OPENJSON`의 엔진 테이블 값 함수(`xq_tsql_openjson`) |
| `state.zig` | 연결 상태 `ConnState.mssql`: 변수, `IDENTITY_INSERT`, 마지막 identity, 트랜잭션 중첩, 기본 스키마 |
| `test.zig` | 종단 테스트 |

## IR 트리, lower, render

- 실행할 문장은 `ir.lower`가, 스키마에 저장되는 것(CHECK, DEFAULT, 계산 열, 뷰, 인덱스)은 `ir.render`가 같은 트리에서 만듭니다.
- SQLite 문법이 있는 것은 SQLite 구문으로 남습니다(`||`, `+`, `/`, `LIKE`, `CAST ... AS TEXT`, `substr()` ...). 그래서 그런 식만 쓰는 스키마는 sqlite3에서도 같은 뜻입니다(`xqt interop mssql`).
- SQL Server의 의미에 SQLite 철자가 없는 것은 엔진 함수입니다. 모든 방언에서 보이므로 스키마에 써도 됩니다.

| T-SQL | 트리 / SQLite |
| --- | --- |
| `a + b` | `\|\|`(문자열끼리), `+`(수), 모를 때 `xq_tsql_add()`([아래](plus.md)) |
| `/` | SQLite `/`(정수끼리는 정수 나눗셈) |
| `^` | `(a \| b) & ~(a & b)` |
| `LIKE` | 상수 패턴이고 `[...]`가 없으면 SQLite `LIKE`(대소문자 무시, 이스케이프 없음), 아니면 `xq_tsql_like()` |
| `CAST(x AS INT)` 등 | `xq_tsql_cast(x, 'int')`, `TRY_CAST`는 `xq_tsql_try_cast()` |
| `CAST(x AS VARCHAR(n))` | `substr(CAST(x AS TEXT), 1, n)`(길이 없으면 30) |
| 열에 저장하는 값 | `xq_tsql_store(v, 'type\|table\|column')`(상수가 이미 맞으면 그대로) |
| `AVG(x)`(OVER 없이) | `xq_tsql_avg()`: 정수만이면 정수(몫을 0 쪽으로 자름) |
| `NEWID()` | `xq_tsql_newid()` |
| 방언 함수 표의 함수 | `Func.dialect = .mssql`, 스키마에는 `xq_mssql_dateadd(...)`처럼 한정 이름 |
| `ISJSON(x)` | `CASE WHEN x IS NULL THEN NULL WHEN json_valid(x) THEN json_type(x) IN ('object', 'array') ELSE 0 END` |
| `JSON_VALUE`, `JSON_QUERY`, `JSON_MODIFY` ... | `xq_tsql_json_value()` 등([JSON](json.md)) |
| `OPENJSON(...)` | 테이블 값 함수 `xq_tsql_openjson(json, path)`, `WITH`가 있으면 `"xq_tsql_openjson_<해시>:<스펙>"(json, path)` |
| `... FOR JSON` | 집계 `xq_tsql_for_json()`을 그 질의에 씌운 질의 |
