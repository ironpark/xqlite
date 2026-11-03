# 타입 매핑

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

테이블은 `STRICT`이고 원래 타입은 `xq_catalog`(`type` 키)에 소문자 철자로 기록합니다(`varchar(20)`, `decimal(10,2)`, `datetime2(7)`).

| SQL Server | 저장 타입 | 검사 |
| --- | --- | --- |
| `bigint` | `INTEGER` | |
| `int`, `smallint`, `tinyint` | `INTEGER` | 범위 |
| `bit` | `INTEGER` | 0 또는 1 |
| `decimal(p,s)`, `numeric`, `money`, `smallmoney` | `REAL` | |
| `float`, `real` | `REAL` | |
| `[n]char(n)`, `[n]varchar(n)` | `TEXT` | 길이 ≤ n |
| `[n]varchar(max)`, `[n]text`, `xml` | `TEXT` | |
| `binary(n)`, `varbinary(n)` | `BLOB` | 길이 ≤ n |
| `varbinary(max)`, `image` | `BLOB` | |
| `date`, `time`, `datetime`, `datetime2`, `smalldatetime`, `datetimeoffset` | `TEXT` | |
| `uniqueidentifier` | `TEXT` | |
| `sql_variant` | `ANY` | |
| 계산 열 | `ANY` | |

- 검사는 이름 있는 CHECK이고 이름이 SQL Server의 문구입니다. 다른 방언이나 sqlite3가 쓴 값도 지킵니다.
- 문자 열에는 언제나 `COLLATE`를 적습니다. 기본(`SQL_Latin1_General_CP1_CI_AS`)과 `_CI_`는 `NOCASE`, `_CS_`·`_BIN`은 `BINARY`입니다. 그래서 `UNIQUE`도 대소문자를 무시합니다.
- **값 변환**: INSERT/UPDATE가 저장하는 값은 SQL Server처럼 열 타입으로 바뀝니다(`xq_tsql_store()`).
  - `decimal(p,s)`은 s자리로 반올림(0에서 먼 쪽), 정밀도를 넘으면 `Arithmetic overflow error ...`.
  - 정수 타입은 실수를 자르고, 범위 밖이면 `Arithmetic overflow error for data type tinyint, value = 300.`.
  - `bit`는 0이 아니면 1, `'true'`/`'false'`도 받습니다.
  - 너무 긴 문자열은 `String or binary data would be truncated in table 'main.dbo.t', column 'c'. Truncated value: '...'.`(잘리는 것이 공백뿐이면 잘라 저장).
  - 날짜·시간은 SQL Server의 출력 형식으로 저장합니다: `date` `2024-01-02`, `datetime` `2024-01-02 03:04:05.123`(1/300초 단위), `datetime2(n)` 소수 n자리, `time(n)`, `smalldatetime`(분), `datetimeoffset` `... +02:00`. `'20240102'`, `'01/02/2024'`(mdy), `'2024-01-02T03:04'`, `AM/PM`을 읽습니다.
  - `uniqueidentifier`는 형식을 검사하고 대문자로 저장합니다.
- **IDENTITY(seed, increment)**: 시퀀스 `<table>_<column>_seq`로 번호를 매깁니다(PostgreSQL 방언의 identity와 같은 IR 기능). 정수 PRIMARY KEY면 SQLite의 `INTEGER PRIMARY KEY`(rowid)입니다.
  - 열 목록에 identity 열이 있으면 `SET IDENTITY_INSERT t ON`이어야 하고, 그 값이 현재 값을 넘으면 identity가 따라갑니다.
  - identity 열의 UPDATE는 오류입니다.
  - `SCOPE_IDENTITY()`와 `@@IDENTITY`는 연결이 마지막으로 넣은 identity 값, `IDENT_CURRENT('t')`는 테이블 시퀀스의 마지막 값입니다.
