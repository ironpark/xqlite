# 구조

[MariaDB 호환](README.md)의 일부입니다.

`src/dialect/mariadb/`의 파일입니다.

| 파일 | 하는 일 |
| --- | --- |
| `frontend.zig` | 방언 진입점: 프론트엔드와 훅(방언 함수, 엔진 함수, 대소문자 무시 기본 collation) |
| `lexer.zig` | 토크나이저: 백틱, MariaDB 문자열과 이스케이프, 주석, 실행 주석, `X'..'`·`0x..`·`b'..'`, `@변수` |
| `parser.zig` | 재귀 하강 파서의 핵심, 식, SELECT |
| `functions.zig` | 함수 호출과 특수 문법(`CAST`, `TRIM`, `SUBSTRING ... FROM`, `GROUP_CONCAT ... SEPARATOR` ...) |
| `dml.zig` | INSERT, REPLACE, UPDATE, DELETE, TRUNCATE |
| `ddl.zig` | CREATE/DROP/ALTER, 인덱스, `xq_catalog` 키 |
| `session.zig` | SET, 트랜잭션, SHOW, DESCRIBE, EXPLAIN, LOCK TABLES, ANALYZE TABLE |
| `databases.zig` | `CREATE/DROP DATABASE`, `USE`, `SHOW DATABASES`, `SHOW TABLES`, `SHOW CREATE DATABASE` |
| `infoschema.zig` | `information_schema.TABLES`, `COLUMNS`, `SCHEMATA`, `VIEWS`, `STATISTICS` |
| `types.zig` | MariaDB 열 타입, 저장 타입, INSERT/UPDATE의 값 변환(`xq_coerce()`) |
| `runtime.zig` | 방언 함수 테이블: SQLite에 없거나 뜻이 다른 연산·함수 |
| `json.zig` | JSON 함수(`JSON_EXTRACT`, `JSON_OBJECT`, `JSON_SET` ...): JSON 파서, 경로, MariaDB 출력 형식 |
| `json_table.zig` | `JSON_TABLE`(엔진 테이블 값 함수 `xq_maria_json_table`), SELECT 끝에서 하는 JSON 처리 |
| `state.zig` | 연결 상태 `ConnState.mariadb`: `sql_mode`, 경고, 사용자 변수, 현재 데이터베이스 |
| `test.zig` | MariaDB 문서의 동작에 맞춘 끝에서 끝까지 테스트 |

## IR 트리, lower, render

- 파서는 문장을 구문 트리 IR(`ir.tree`)로 만듭니다.
- 실행할 문장은 `ir.lower`가 그 트리에서 만듭니다.
- 스키마에 저장되는 것(CREATE TABLE의 CHECK·DEFAULT·생성 열, CREATE VIEW, 인덱스)은 `ir.render`가 같은 트리에서 만듭니다.
- 그래서 같은 식은 질의, CHECK, DEFAULT, 생성 열, 뷰에서 같은 뜻입니다. `/`는 어디서나 `CAST(l AS REAL) / r`이고, `DIV`는 `xq_div()`이며, 바뀐 함수 이름도 같습니다.
- `SHOW`·`DESCRIBE`·`information_schema`는 스키마·pragma 함수·`xq_catalog`를 읽는 SQLite 질의를 만들어 내립니다.
- `information_schema` 뷰의 MariaDB 텍스트는 같은 파서로 트리를 만듭니다.
- `SET`의 값은 트리로 만들어 `ir.lower`로 내립니다.
- MariaDB 의미가 SQLite와 다른 연산·함수는 엔진 함수와 방언 함수 테이블(`runtime.zig`)로 구현합니다.

파서가 트리에 남기는 MariaDB 의미는 다음과 같습니다.

| MariaDB | 트리 / SQLite |
| --- | --- |
| `/` | `div{real}` |
| `DIV` | `div{int}` |
| `XOR`, `^` | 엔진 함수 `xq_xor()`, `xq_bitxor()` |
| `<=>` | `IS` |
| `\|\|` | `OR`(`PIPES_AS_CONCAT`이면 `concat{propagate}`) |
| 두 인자 이상의 `CONCAT()` | `concat{propagate}` |
| `LIKE` | SQLite `LIKE ... ESCAPE '\'`(ASCII 대소문자 무시) |
| 이름이 다른 함수 | SQLite 내장 함수나 엔진 함수(`UCASE` → `upper`, `CHAR_LENGTH` → `length`, `GREATEST` → `max`, `STDDEV` → `xq_stddev_pop` ...) |
| 방언 함수 테이블의 함수 | `Func.dialect = .mariadb`, 스키마에는 `xq_mariadb_left(...)`처럼 한정 이름 |
| INSERT/UPDATE가 열에 저장하는 값 | `coerce` 노드(`xq_coerce()`) |
| `AUTO_INCREMENT` 열의 0 | `nullif(v, 0)`(`NO_AUTO_VALUE_ON_ZERO`가 아니면) |
| VALUES/SET의 `DEFAULT` | IR 공통 의미: 그 열의 DEFAULT, 없으면 NULL(`AUTO_INCREMENT`는 다음 rowid) |

결과 열 이름은 MariaDB처럼 쓴 식의 텍스트입니다. 문자열 상수는 그 값입니다.
