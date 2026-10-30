# MSSQL(T-SQL) 호환

xqlite의 Microsoft SQL Server(T-SQL) 방언이 지원하는 문법과 의미, 그리고 SQL Server와 다른 점입니다. 방언 구조와 프론트엔드 계약은 [방언 아키텍처](architecture.md)를 보세요.

## 목차

- [켜는 법](#켜는-법)
- [구조](#구조)
- [지원 범위](#지원-범위)
- [타입 매핑](#타입-매핑)
- [`+`의 규칙](#의-규칙)
- [MERGE](#merge)
- [JSON](#json)
- [스키마](#스키마)
- [SQL Server와 다른 점](#sql-server와-다른-점)
- [아직 하지 않은 것](#아직-하지-않은-것)
- [검증](#검증)

## 켜는 법

| 어디서 | 방법 |
| --- | --- |
| SQL | `PRAGMA xq_dialect = 'mssql'`(`'sqlserver'`, `'tsql'` 별칭 허용) |
| 셸 | `.dialect mssql` |
| Zig API | `.dialect = .mssql`, `db.setDialect(.mssql)` |

```sql
PRAGMA xq_dialect = 'mssql';
CREATE TABLE dbo.app_user (
  id         INT IDENTITY(1,1) PRIMARY KEY,
  email      NVARCHAR(100) NOT NULL UNIQUE,
  active     BIT NOT NULL DEFAULT 1,
  created_at DATETIME2 DEFAULT SYSDATETIME()
);
INSERT INTO app_user (email) OUTPUT INSERTED.id VALUES (N'a@x.org');
SELECT SCOPE_IDENTITY();
SELECT TOP 10 id, email FROM app_user WHERE email LIKE 'A%' ORDER BY id DESC;
GO
PRAGMA xq_dialect = 'sqlite';   -- PRAGMA는 SQLite 문법 그대로 통과
```

- `PRAGMA`, `ATTACH`, `DETACH`, `VACUUM`, `REINDEX`는 T-SQL 방언에서도 SQLite 문장으로 넘깁니다.
- T-SQL처럼 세미콜론이 없어도 됩니다. 문장은 `;`, `GO`, 다른 문장을 시작하는 단어(`SELECT`, `INSERT` ...)에서 끝납니다.
- 셸에서는 `GO`만 있는 줄이 그 앞의 문장을 실행합니다(sqlcmd의 배치 끝). `GO 2`의 횟수는 무시합니다.

## 구조

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

### IR 트리, lower, render

- 실행할 문장은 `ir.lower`가, 스키마에 저장되는 것(CHECK, DEFAULT, 계산 열, 뷰, 인덱스)은 `ir.render`가 같은 트리에서 만듭니다.
- SQLite 문법이 있는 것은 SQLite 구문으로 남습니다(`||`, `+`, `/`, `LIKE`, `CAST ... AS TEXT`, `substr()` ...). 그래서 그런 식만 쓰는 스키마는 sqlite3에서도 같은 뜻입니다(`xqt interop mssql`).
- SQL Server의 의미에 SQLite 철자가 없는 것은 엔진 함수입니다. 모든 방언에서 보이므로 스키마에 써도 됩니다.

| T-SQL | 트리 / SQLite |
| --- | --- |
| `a + b` | `\|\|`(문자열끼리), `+`(수), 모를 때 `xq_tsql_add()`([아래](#의-규칙)) |
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
| `JSON_VALUE`, `JSON_QUERY`, `JSON_MODIFY` ... | `xq_tsql_json_value()` 등([JSON](#json)) |
| `OPENJSON(...)` | 테이블 값 함수 `xq_tsql_openjson(json, path)`, `WITH`가 있으면 `"xq_tsql_openjson_<해시>:<스펙>"(json, path)` |
| `... FOR JSON` | 집계 `xq_tsql_for_json()`을 그 질의에 씌운 질의 |

## 지원 범위

### 어휘

- 식별자: 단어(`#temp`, `##global` 포함), `[대괄호]`(`]]`가 `]`), `"큰따옴표"`(QUOTED_IDENTIFIER ON). 대소문자를 구분하지 않습니다.
- 문자열 `'it''s'`, `N'유니코드'`.
- `@변수`, `@@ROWCOUNT` 같은 시스템 함수, 매개변수 `?`.
- 주석 `--`, 중첩되는 `/* */`.
- 2진 상수 `0x0A1B`(홀수 자리는 앞에 0), `1e3`, `.5`.
- 연산자 `!=`, `!<`, `!>`, 복합 대입 `+=` `-=` `*=` `/=` `%=` `&=` `|=` `^=`.

### SELECT

| 영역 | 지원 |
| --- | --- |
| 기본 | `DISTINCT`, `WHERE`, `GROUP BY`, `HAVING` |
| 행 수 제한 | `TOP n`, `TOP (n)`, `TOP n PERCENT`, `ORDER BY ... OFFSET n ROWS [FETCH {FIRST\|NEXT} m ROWS ONLY]` |
| 결과 열 | `expr AS a`, `expr a`, `a = expr`, `'a' = expr`. 이름 없는 식의 열 이름은 SQL Server처럼 빈 문자열 |
| FROM | 테이블(`dbo.t`, `s.t`, `db.dbo.t`, `db.s.t`, `db..t`, `#t`), 서브쿼리, `(VALUES ...) AS v(a, b)`, 테이블 값 함수, `OPENJSON`, 테이블 힌트 `WITH (NOLOCK)`(무시) |
| JOIN | `[INNER]`, `LEFT/RIGHT/FULL [OUTER]`, `CROSS JOIN`, 조인 힌트(`HASH` 등, 무시), 테이블 값 함수의 `CROSS APPLY`/`OUTER APPLY` |
| 집합 연산 | `UNION [ALL]`, `EXCEPT`, `INTERSECT`(INTERSECT가 먼저 묶임); `TOP`이 있는 피연산자 |
| CTE | `WITH`. 자기 이름을 부르면 재귀(RECURSIVE 없이), `;WITH` |
| 그 밖 | `SELECT ... INTO t`(새 테이블), `SELECT @x = ...`, `OPTION (...)`(무시), `FOR JSON`([JSON](#json)) |
| 윈도우 | `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE ...)`, `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE`, `LAG`, `LEAD` ... |

### DML

- **INSERT** `[TOP (n)] [INTO] t [(열)] [OUTPUT ...] {VALUES (...), ... | SELECT ... | DEFAULT VALUES}`
  - `VALUES`의 `DEFAULT`
  - 열 목록이 없으면 identity 열과 계산 열을 뺀 열에 넣습니다.
- **UPDATE** `[TOP (n)] t SET c = v, c += v, t.c = v [OUTPUT INSERTED.*] [FROM ... JOIN ...] [WHERE]`
  - FROM 절에서 대상을 별칭으로 부를 수 있습니다(`UPDATE x SET ... FROM t AS x JOIN ...`).
- **DELETE** `[TOP (n)] [FROM] t [OUTPUT DELETED.*] [FROM ... JOIN ...] [WHERE]`
- **OUTPUT** `INSERTED.*`, `INSERTED.c`, `DELETED.c`와 식은 `RETURNING`입니다.
- **MERGE**([아래](#merge))
- **TRUNCATE TABLE**: identity가 처음 값으로 돌아갑니다.
- FROM 절의 대상은 FROM에서 빠지고 그 조인 조건이 WHERE로 갑니다(SQLite의 UPDATE FROM, DELETE ... USING).

### DDL

- **CREATE SCHEMA**, **DROP SCHEMA**, **ALTER SCHEMA ... TRANSFER**([스키마](#스키마))
- **CREATE TABLE** `[schema.]t` / `#t`(temp 스키마)
  - 열 제약: `NULL`/`NOT NULL`, `DEFAULT`, `IDENTITY[(seed, increment)]`, `PRIMARY KEY [CLUSTERED|NONCLUSTERED]`, `UNIQUE`, `CHECK`, `REFERENCES ... ON DELETE/UPDATE`, `CONSTRAINT 이름`, `COLLATE`, `ROWGUIDCOL`·`SPARSE`(무시)
  - 계산 열: `c AS (식) [PERSISTED]` → 생성 열(`PERSISTED`면 STORED)
  - 테이블 제약: `[CONSTRAINT n] PRIMARY KEY (...)`, `UNIQUE (...)`, `CHECK (...)`, `FOREIGN KEY (...) REFERENCES ...`
  - 테이블 안의 `INDEX ix (열)`
  - `ON [PRIMARY]`, `TEXTIMAGE_ON`, `WITH (...)`는 무시합니다.
- **CREATE [UNIQUE] [CLUSTERED|NONCLUSTERED] INDEX** `ix ON t (열 [ASC|DESC]) [INCLUDE (...)] [WHERE ...]`
- **CREATE [OR ALTER] VIEW**, **ALTER VIEW**. 이름 없는 식 열은 SQL Server처럼 오류입니다.
- **CREATE SEQUENCE** `[AS type] START WITH .. INCREMENT BY .. MINVALUE .. MAXVALUE .. [NO] CYCLE`, `NEXT VALUE FOR s`
- **ALTER TABLE** `t ADD c type ...`(한 번에 하나), `DROP COLUMN [IF EXISTS] c`
  - nullable 열을 DEFAULT와 함께 추가하면 기존 행은 `NULL`입니다(`WITH VALUES`면 기본값).
- **DROP TABLE/VIEW/INDEX/SEQUENCE [IF EXISTS]**, `DROP INDEX ix ON t`, `DROP INDEX [s.]t.ix`
- **EXEC sp_rename** `'[s.]t', 'u'`(스키마는 그대로), `'[s.]t.c', 'd', 'COLUMN'`

### 세션과 트랜잭션

- `BEGIN TRAN[SACTION] [이름]`, `COMMIT`, `ROLLBACK [TRAN 이름]`, `SAVE TRAN 이름`, `@@TRANCOUNT`
  - 열린 트랜잭션 안의 `BEGIN TRAN`은 중첩 수준만 올리고, 안쪽 `COMMIT`은 내리기만 합니다. 바깥쪽 `COMMIT`이 커밋하고 `ROLLBACK`은 전부 되돌립니다.
  - `ROLLBACK TRAN 이름`은 바깥 트랜잭션 이름이면 전부, 아니면 그 세이브포인트까지 되돌립니다.
- `DECLARE @x type [= v] [, ...]`, `SET @x = v`, `SET @x += v`, `SELECT @x = 식 [, @y = 식] FROM ... [ORDER BY ...]`
  - 값은 선언 타입으로 변환합니다(문자열은 길이에서 잘림).
  - 선언하지 않은 변수는 컴파일할 때 `Must declare the scalar variable "@x".`입니다.
  - `SELECT @x = ...`는 행마다 대입하고(마지막 행의 값이 남음) 행을 돌려주지 않습니다. 행이 없으면 값이 그대로입니다.
- `SET IDENTITY_INSERT t ON|OFF`(한 번에 한 테이블)
- `SET NOCOUNT`, `ANSI_NULLS`, `QUOTED_IDENTIFIER`, `XACT_ABORT`, `TRANSACTION ISOLATION LEVEL`, `DATEFORMAT` 같은 옵션은 받아들이고 무시합니다. `SET ROWCOUNT n`(0 아님)과 `IMPLICIT_TRANSACTIONS ON`은 오류입니다.
- `PRINT 식`은 식을 계산하고 아무것도 출력하지 않습니다.
- `USE db`는 데이터베이스가 있는지만 봅니다.
- `ALTER USER u WITH DEFAULT_SCHEMA = s`는 연결의 기본 스키마를 바꿉니다([스키마](#스키마)).

### 함수

| 분류 | 함수 |
| --- | --- |
| NULL·조건 | `ISNULL`, `COALESCE`, `NULLIF`, `IIF`, `CHOOSE`, `CASE` |
| 변환 | `CAST`, `CONVERT(type, x [, style])`(날짜 스타일 1-5, 8, 10-12, 20-25, 101-105, 108, 110-112, 120, 121, 126, 127), `TRY_CAST`, `TRY_CONVERT`, `PARSE`, `TRY_PARSE`, `ISNUMERIC`, `ISDATE` |
| 문자열 | `LEN`(끝 공백 제외), `DATALENGTH`, `CHARINDEX`, `SUBSTRING`, `LEFT`, `RIGHT`, `LTRIM`, `RTRIM`, `TRIM([chars FROM] s)`, `UPPER`, `LOWER`, `REPLACE`, `REVERSE`, `REPLICATE`, `SPACE`, `STUFF`, `CONCAT`, `CONCAT_WS`, `ASCII`, `CHAR`, `NCHAR`, `UNICODE`, `QUOTENAME` |
| 수 | `ABS`, `CEILING`, `FLOOR`, `ROUND(x, n [, f])`, `POWER`, `SQUARE`, `SQRT`, `SIGN`, `EXP`, `LOG(x [, base])`, `LOG10`, `PI`, `SIN` 등 삼각 함수, `RAND` |
| 날짜 | `GETDATE()`, `CURRENT_TIMESTAMP`, `GETUTCDATE()`, `SYSDATETIME()`, `SYSUTCDATETIME()`, `SYSDATETIMEOFFSET()`, `DATEADD`, `DATEDIFF`, `DATEDIFF_BIG`, `DATEPART`, `DATENAME`, `YEAR`, `MONTH`, `DAY`, `EOMONTH`, `DATEFROMPARTS` |
| 집계 | `COUNT`, `COUNT_BIG`, `SUM`, `AVG`, `MIN`, `MAX`, `STRING_AGG(x, sep) [WITHIN GROUP (ORDER BY ...)]`, `STDEV`, `STDEVP`, `VAR`, `VARP` |
| identity | `SCOPE_IDENTITY()`, `@@IDENTITY`, `IDENT_CURRENT('t')` |
| JSON | `ISJSON`, `JSON_VALUE`, `JSON_QUERY`, `JSON_MODIFY`, `JSON_PATH_EXISTS`, `JSON_OBJECT`, `JSON_ARRAY`, `STRING_ESCAPE(s, 'json')`([JSON](#json)) |
| 스키마 | `OBJECT_ID('[db.][s.]t')`, `OBJECT_NAME(id)`, `OBJECT_SCHEMA_NAME(id)`, `SCHEMA_ID(['s'])`, `SCHEMA_NAME([id])`(인자가 없으면 기본 스키마) |
| 그 밖 | `NEWID()`, `DB_NAME()`(`main`), `USER_NAME()`, `@@ROWCOUNT`, `@@TRANCOUNT`, `@@VERSION`, `@@SPID` ... |

- datepart 이름과 약어(`yy`, `mm`, `dd`, `hh`, `mi`, `ss`, `ms`, `dw`, `wk` ...)를 받습니다.
- `DATEDIFF`는 SQL Server처럼 경계를 센 수입니다(`DATEDIFF(year, '2023-12-31', '2024-01-01')`은 1). 주는 일요일에 시작합니다(`@@DATEFIRST` 7).
- `DATEADD`의 결과는 입력의 모양(날짜만, 소수 자리 수, 오프셋)을 따릅니다. 문자열 상수는 SQL Server처럼 `datetime`으로 읽습니다.
- `CHARINDEX`와 `REPLACE`는 기본 collation처럼 대소문자를 무시합니다.

### 카탈로그

| 뷰 | 열 |
| --- | --- |
| `INFORMATION_SCHEMA.TABLES` | `TABLE_CATALOG`, `TABLE_SCHEMA`, `TABLE_NAME`, `TABLE_TYPE` |
| `INFORMATION_SCHEMA.COLUMNS` | 위와 `COLUMN_NAME`, `ORDINAL_POSITION`, `COLUMN_DEFAULT`, `IS_NULLABLE`, `DATA_TYPE`, `CHARACTER_MAXIMUM_LENGTH`, `NUMERIC_PRECISION`, `NUMERIC_SCALE`, `DATETIME_PRECISION` |
| `INFORMATION_SCHEMA.VIEWS` | 최소한의 열 |
| `INFORMATION_SCHEMA.SCHEMATA` | `CATALOG_NAME`, `SCHEMA_NAME`, `SCHEMA_OWNER`, `DEFAULT_CHARACTER_SET_*` |
| `sys.tables`, `sys.views`, `sys.objects` | `name`, `object_id`, `schema_id`, `type`, `type_desc` |
| `sys.columns` | `object_id`, `name`, `column_id`, `max_length`, `precision`, `scale`, `is_nullable`, `is_identity`, `is_computed` |
| `sys.schemas` | `name`, `schema_id`, `principal_id`: `dbo`(1), `guest`, `INFORMATION_SCHEMA`, `sys`, `db_*` 역할 스키마(16384~)와 `CREATE SCHEMA`의 스키마(5~) |
| `sys.sequences` | `name`, `schema_id`, `start_value`, `increment`, `minimum_value`, `maximum_value`, `is_cycling`, `current_value`(identity의 시퀀스는 빠짐) |

- `object_id`는 `sqlite_schema`의 rowid이고 `OBJECT_ID()`가 같은 값을 돌려줍니다.
- 데이터베이스는 SQLite의 스키마(`main`, `ATTACH`로 붙인 것)입니다. main에는 `dbo`와 `CREATE SCHEMA`의 스키마가 있고, 붙인 데이터베이스의 스키마는 언제나 `dbo`입니다. `#temp` 테이블은 SQL Server처럼 나오지 않습니다.

## 타입 매핑

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

## `+`의 규칙

SQL Server의 `+`는 피연산자 타입에 따라 연결이거나 덧셈입니다. 방언은 다음 순서로 정합니다.

1. 파서가 아는 타입: 문자열 상수, 수 상수, `CAST`/`CONVERT`의 대상 타입, 함수의 결과 타입(`UPPER`는 문자열, `LEN`은 수 ...), 변수의 선언 타입, 그리고 FROM 절(UPDATE의 대상, CREATE TABLE 자신의 열)에 있는 테이블 열의 저장 타입.
   - 둘 다 문자열이면 연결(`||`, NULL이면 NULL)
   - 하나라도 수면 덧셈(`+`). SQL Server처럼 문자열은 수로 바뀝니다(`'1' + 1`은 2).
   - 수가 아닌 문자열 상수와 모르는 타입이면 연결(SQL Server에서는 덧셈이 실패할 뿐이기 때문).
2. 그래도 모르면(서브쿼리의 열, 매개변수, `CASE` ...) 실행할 때 `xq_tsql_add()`가 값의 저장 클래스로 정합니다. TEXT와 TEXT는 연결, BLOB과 BLOB은 이어 붙이기, 아니면 덧셈입니다. 방언의 STRICT 테이블에서는 저장 클래스가 선언 타입의 것이므로 결과가 같습니다.

계산 열과 뷰처럼 스키마에 저장되는 식은 1.로 정해지면 SQLite의 `||`·`+`가 되어 sqlite3도 읽습니다.

## MERGE

```sql
MERGE INTO t USING (VALUES (2, 'B'), (4, 'D')) AS s (id, v) ON t.id = s.id
WHEN MATCHED AND s.v = 'del' THEN DELETE
WHEN MATCHED THEN UPDATE SET v = s.v
WHEN NOT MATCHED [BY TARGET] THEN INSERT (id, v) VALUES (s.id, s.v)
WHEN NOT MATCHED BY SOURCE THEN UPDATE SET v = 'gone';
```

한 문장(한 VDBE 프로그램) 안에서 다음 순서로 실행합니다.

1. `WHEN NOT MATCHED`: 대상에 맞는 행이 없는 원본 행을 INSERT하고, 그 원본 행을 표시합니다.
2. `WHEN NOT MATCHED BY SOURCE`: 원본에 맞는 행이 없는 대상 행을 DELETE/UPDATE하고, 그 대상 행(rowid)을 표시합니다.
3. `WHEN MATCHED`: DELETE를 먼저, 그다음 `UPDATE ... FROM 원본`. 1.과 2.에서 표시한 행은 건드리지 않습니다.

- 그래서 각 절은 MERGE 전의 행을 기준으로 정해집니다(1.이 넣은 행이 다시 맞거나, 2.가 바꾼 행이 맞게 되어도 다시 처리하지 않음).
- 원본에는 `row_number() OVER ()`로 번호를 붙여 표시합니다. 원본은 단계마다 다시 읽으므로 같은 행을 같은 순서로 돌려주어야 합니다(대상을 읽는 서브쿼리 원본은 그렇지 않을 수 있음).
- 같은 종류의 절이 둘이면 SQL Server처럼 먼저 쓴 절의 조건이 참이 아닌 행만 뒤의 절이 받습니다.
- 다른 점: 한 대상 행에 원본 행이 여럿 맞으면 SQL Server는 실패하지만, 여기서는 그중 하나로 한 번 바뀝니다.
- 지원하지 않는 것: `OUTPUT`과 `$action`, `MERGE TOP`, `WITH ... MERGE`, `INSERT DEFAULT VALUES`, INSERT 값의 `DEFAULT`.
- SQL Server처럼 `;`로 끝나야 합니다.

## JSON

SQL Server처럼 JSON은 `NVARCHAR` 텍스트이고, 함수는 텍스트를 쓰인 그대로 다룹니다. `JSON_QUERY`, `OPENJSON`의 `value`, `JSON_MODIFY`가 건드리지 않은 부분은 입력의 공백까지 그대로 돌려줍니다. 문법은 RFC 8259입니다(SQLite의 json 함수와 달리 JSON5 확장 없음). 문서는 객체나 배열이어야 합니다.

```sql
DECLARE @j NVARCHAR(MAX) = N'{"id":7,"tags":["a","b"],"owner":{"name":"ann"}}';
SELECT JSON_VALUE(@j, '$.owner.name'), JSON_QUERY(@j, '$.tags'), JSON_MODIFY(@j, 'append $.tags', 'c');
SELECT [key], value, type FROM OPENJSON(@j);
SELECT o.id, l.sku, l.qty FROM orders o
  CROSS APPLY OPENJSON(o.lines) WITH (sku VARCHAR(10), qty INT '$.qty') AS l;
SELECT o.id, o.name, i.sku FROM o JOIN i ON i.oid = o.id ORDER BY o.id FOR JSON AUTO, ROOT('orders');
```

### 함수

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

### 값을 JSON으로 쓰는 방법

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

### OPENJSON

- `OPENJSON(json [, path])`: 경로의 객체 멤버나 배열 원소마다 한 행. 열은 `key`(배열은 `'0'`, `'1'` ...; SQL Server의 BIN2처럼 대소문자를 구분), `value`(스칼라의 텍스트, 객체·배열은 쓰인 그대로), `type`(0 null, 1 문자열, 2 수, 3 true/false, 4 배열, 5 객체).
- `WITH (열 타입 ['경로'] [AS JSON], ...)`: 경로의 배열 원소마다(객체면 그 객체 하나가) 한 행. 경로를 빼면 `$.열이름`. 값은 `CAST`처럼 열 타입으로 바꾸고(`Conversion failed when converting the nvarchar value ...`), `AS JSON`(`NVARCHAR(MAX)`만)은 객체·배열을 그대로 돌려줍니다. 스칼라 자리에 객체·배열이 있거나 그 반대면 lax에서 NULL, strict에서 오류입니다.
- 경로의 값이 스칼라면 lax에서 빈 결과, strict에서 오류. 없는 경로도 같습니다. `json`이 NULL이면 빈 결과입니다.
- `FROM`과 `CROSS APPLY`/`OUTER APPLY`에 씁니다. `t CROSS APPLY OPENJSON(t.doc)`은 조인 `t JOIN xq_tsql_openjson(t.doc)`이고 `OUTER APPLY`는 `LEFT JOIN`입니다. SQLite가 테이블 값 함수의 인자에 앞 테이블의 열을 허용하므로 LATERAL 없이 됩니다.
- 구현: 엔진 테이블 값 함수(이름 없는 가상 테이블, eponymous virtual table) `xq_tsql_openjson`입니다. 인자는 숨은 열 `xq_json`, `xq_path`입니다. `WITH`의 열은 문장마다 다르므로 스펙(JSON `[[이름, 타입, 경로, AS JSON], ...]`)을 모듈 이름 `xq_tsql_openjson_<해시>:<스펙>`에 넣습니다. 처음 보는 `xq_`로 시작하는 테이블 이름이면 방언 훅(`Hooks.table_function`)이 그 이름에서 모듈을 만들어 등록하므로, 이 이름을 쓰는 뷰도 어느 연결·어느 방언에서나 열립니다. 해시는 대소문자만 다른 스펙(경로는 대소문자를 구분)을 가릅니다. `json_each()`로 내리지 않은 것은 `value`·`type`의 값(쓰인 그대로의 텍스트, SQL Server의 타입 번호)과 열 이름, JSON5를 받는 것, 오류가 SQL Server와 달라서입니다.

### FOR JSON

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

### 스키마와 sqlite3

- `ISJSON(x)`만 쓰는 식(`CHECK (ISJSON(doc) = 1)`)은 SQLite의 함수라서 sqlite3도 검사합니다(`xqt interop mssql`).
- 다른 JSON 함수는 엔진 함수(`xq_tsql_json_*`, `xq_tsql_for_json`)이고 `OPENJSON`은 엔진 테이블 값 함수입니다. 계산 열(`AS JSON_VALUE(doc, '$.a')`)이나 뷰에 써도 xqlite는 어느 방언으로든 읽지만, sqlite3는 계산하지 못합니다(`no such function`, `no such table`).

## 스키마

`CREATE SCHEMA`의 스키마는 공용 구현([방언 아키텍처의 스키마](architecture.md#스키마네임스페이스), `src/catalog/schema.zig`)을 씁니다. 스키마 `sales`의 테이블 `orders`는 main의 테이블 `"sales.orders"`이고, 그 인덱스·시퀀스도 `sales.ix`, `sales.orders_id_seq`처럼 이름이 붙습니다. 파일 하나, 트랜잭션 하나이고 sqlite3는 `"sales.orders"`로 읽고 씁니다.

```sql
CREATE SCHEMA sales AUTHORIZATION dbo
GO
CREATE TABLE sales.orders (id INT IDENTITY(1,1) PRIMARY KEY, item VARCHAR(20));
INSERT INTO sales.orders (item) VALUES ('pen');
SELECT orders.id, o.item FROM sales.orders JOIN main.sales.orders o ON o.id = orders.id;
SELECT SCHEMA_NAME(schema_id), name FROM sys.tables;      -- sales | orders
ALTER SCHEMA dbo TRANSFER sales.orders;                    -- 이제 dbo.orders
DROP SCHEMA sales;                                         -- 비어 있어야 함
```

- 이름 해석: `dbo.t`와 한정하지 않은 `t`는 main의 `t`, `#t`·`tempdb..#t`는 temp, `db.dbo.t`·`db..t`는 그 데이터베이스(main, 붙인 데이터베이스)입니다. `s.t`·`main.s.t`는 `CREATE SCHEMA`의 스키마 `s`의 `t`(main의 `"s.t"`)이고, `t`라는 별칭이 붙어서 `t.c`와 `s.t.c`로 열을 부릅니다. DML, 조인, 뷰, `SELECT ... INTO`, `MERGE`, `TRUNCATE`, `CREATE INDEX ... ON s.t`, `NEXT VALUE FOR s.seq`, `IDENTITY`, `SET IDENTITY_INSERT s.t`, `IDENT_CURRENT('s.t')`, `OBJECT_ID('s.t')`, `sp_rename`이 모두 그렇습니다.
- 뷰의 텍스트에는 데이터베이스 없이 `"s.t" AS "t"`로 저장됩니다.
- `CREATE SCHEMA s [AUTHORIZATION o]`: `dbo`, `sys` 같은 내장 스키마 이름은 2760, 있는 스키마는 2714 오류입니다. 스키마 이름에는 `.`을 쓸 수 없고, 데이터베이스 이름(`main`, `temp`, 붙인 데이터베이스)도 쓸 수 없습니다.
  - 뒤에 오는 요소 `CREATE TABLE`, `CREATE VIEW`, `GRANT`/`REVOKE`/`DENY`(받아들이고 무시)는 그 스키마에서 만들어지고, 그 안의 한정하지 않은 이름은 먼저 그 스키마에서 찾습니다(SQL Server처럼). 요소는 `CREATE SCHEMA` 다음에 따로 컴파일되므로 원자적이지 않습니다.
  - SQL Server에서 `CREATE SCHEMA`는 배치의 첫 문장이어야 하지만(111), xqlite에는 배치가 없어서 검사하지 않습니다.
- `DROP SCHEMA [IF EXISTS] s`: SQL Server처럼 `CASCADE`가 없어서 개체(테이블, 뷰, 시퀀스)가 있으면 `Cannot drop schema 's' because it is being referenced by object 'x'.`(3729, 이름순 첫 개체)입니다. 없는 스키마는 15151, 내장 스키마는 15150입니다.
- `ALTER SCHEMA s TRANSFER [OBJECT::]x.t`: 테이블의 이름을 `"s.t"`(dbo면 `t`)로 바꿉니다. 대상에 같은 이름이 있으면 15530입니다. 인덱스는 이름이 그대로이고, 뷰와 `IDENTITY` 열이 있는 테이블(시퀀스 이름이 스키마를 따름)은 지원하지 않습니다.
- `schema_id`는 SQL Server처럼 5부터 비어 있는 가장 작은 수입니다(지운 스키마의 번호를 다시 씀). `xq_catalog`의 `('', 스키마, 'schema_id', 번호)` 행에 둡니다.
- 기본 스키마: SQL Server에서 한정하지 않은 이름은 사용자의 기본 스키마에서 먼저, 다음에 `dbo`에서 찾습니다. xqlite에는 사용자가 없으므로 `ALTER USER u WITH DEFAULT_SCHEMA = s`가 사용자 이름과 상관없이 연결의 기본 스키마를 바꿉니다(`= dbo`나 `NULL`이면 원래대로). 그 뒤 한정하지 않은 이름은 `s`에 있으면 `s`의 것이고(CTE 이름은 그대로), `CREATE TABLE t`는 `s.t`를 만들며, `SCHEMA_NAME()`·`SCHEMA_ID()`는 `s`입니다. SQL Server의 `sa`(dbo)는 기본 스키마를 바꿀 수 없어서(15150) 서버와 비교하지 않았습니다.
- 오류: 없는 스키마의 개체를 만들면 `The specified schema name "s" either does not exist or you do not have permission to use it.`(2760), 읽으면 `Invalid object name 's.t'.`(208), 지우면 `Cannot drop the table 's.t', ...`(3701)입니다.

## SQL Server와 다른 점

### 타입과 값

| 항목 | xqlite |
| --- | --- |
| `decimal`/`money` | `REAL`로 저장합니다. 반올림은 되지만 정확한 십진 연산이 아니고 `2.50`이 `2.5`로 보입니다. |
| 정수 나눗셈 | `7 / 2`는 3으로 같지만, 0으로 나누면 오류가 아니라 `NULL`입니다. |
| 문자열 → 수 | `'abc' + 1`처럼 실행 때 정해지는 덧셈과 비교는 SQLite처럼 0으로 바꿉니다(CAST와 저장은 SQL Server처럼 오류). |
| `char(n)` | 공백으로 채우지 않습니다. |
| 끝 공백 | 비교에서 무시하지 않습니다(`'a' = 'a '`는 거짓). `LEN`은 끝 공백을 뺍니다. |
| collation | `NOCASE`는 ASCII만 접습니다(`'é' = 'É'`는 거짓). ASCII 밖 문자의 정렬 순서는 바이트 순서입니다. |
| `nvarchar` | UTF-8로 저장합니다. `DATALENGTH`는 UTF-8 바이트 수라서 `DATALENGTH(N'a')`가 1입니다(SQL Server는 2). |
| 날짜 | `datetime + 1` 같은 날짜 산술은 없습니다(`DATEADD`를 씁니다). `CAST(날짜 AS VARCHAR)`는 저장 형식 그대로입니다(SQL Server는 `Jan  2 2024 ...`). `GETDATE()`는 UTC입니다. |
| `uniqueidentifier` | 텍스트로 정렬합니다(SQL Server는 바이트 그룹 순서). |
| JSON의 `decimal` | `REAL`이라서 `FOR JSON`과 `JSON_MODIFY`가 `2.50`을 `2.5`로 씁니다. 계산한 `float` 값(`f * 2`)은 타입을 모르므로 `5.0`처럼 씁니다(SQL Server는 `5.000000000000000e+000`). |
| `OPENJSON`의 `value` | `NOCASE`라서 `'é' = 'É'`는 거짓입니다(SQL Server의 CI_AS는 참). |

### 문장의 동작

| 항목 | xqlite |
| --- | --- |
| 배치 | 배치가 없습니다. 문장은 앞 문장이 실행된 뒤에 컴파일되고, 변수는 연결이 끝나거나 다시 선언할 때까지 남습니다. 오류가 배치의 나머지를 건너뛰게 하지 않습니다(셸에서는 SQLite 셸의 `.bail` 규칙). |
| 외래 키 | SQL Server처럼 지키도록, 트랜잭션 밖에서 첫 T-SQL 문장을 컴파일할 때 연결의 `PRAGMA foreign_keys`를 켭니다. SQLite 방언으로 돌아가도 켜진 채입니다. |
| identity | 시퀀스는 트랜잭션에 묶여서 롤백된 값이 다시 나옵니다(SQL Server는 건너뜀). |
| `@@ROWCOUNT` | `changes()`: 마지막 INSERT/UPDATE/DELETE가 바꾼 행 수입니다(SELECT의 행 수가 아님). |
| `OUTPUT DELETED` | DELETE에서만 됩니다. UPDATE의 `DELETED.c`(이전 값)는 `RETURNING`이 새 행만 보므로 오류입니다. |
| UPDATE/DELETE ... FROM | 대상이 FROM의 외부 조인 쪽에 있으면 오류입니다. 대상을 부르는 다른 조인의 `ON`은 쓸 수 없습니다. |
| DROP | 한 문장에서 둘 이상의 있는 객체를 지울 수 없습니다(`DROP TABLE IF EXISTS a, b`는 하나만 있을 때 됨). |
| 인덱스 이름 | 스키마마다 유일합니다(SQL Server는 테이블마다). |
| 스키마 | 붙인 데이터베이스에는 `dbo`만 있습니다. `ALTER SCHEMA ... TRANSFER`는 인덱스 이름을 옮기지 않습니다. `CREATE SCHEMA ... CREATE TABLE ...`의 요소는 따로 실행됩니다. |
| 실행 중 오류 | `UNIQUE constraint failed: t.c` 같은 엔진 오류와 CHECK 위반은 SQLite 문구입니다. 컴파일 오류(`Invalid object name 'x'.`, `Invalid column name 'c'.` ...)와 변환 오류는 SQL Server 문구입니다. |
| 결과 열 이름 | 이름 없는 식은 빈 이름입니다(sqlcmd처럼). 서브쿼리 안에서는 SQLite의 이름입니다. |
| JSON 타입 | 값의 JSON 여부(`JSON_QUERY` ...)는 식의 모양으로 정합니다. `ISNULL(JSON_QUERY(...), ...)`처럼 다른 함수를 거친 JSON은 문자열로 씁니다(SQL Server는 타입을 따라감). |
| `JSON_OBJECT`/`JSON_ARRAY`/`ISJSON(x, type)`/`JSON_PATH_EXISTS` | SQL Server 2022의 함수로, 비교하는 서버(Azure SQL Edge, 엔진 15.0)에 없어서 문서대로 구현하고 서버와 비교하지 않았습니다. |
| `OPENJSON ... WITH` | 같은 이름의 열을 둘 쓸 수 없습니다(가상 테이블의 열 이름). |
| `CROSS APPLY`/`OUTER APPLY` | 테이블 값 함수(`OPENJSON` ...)에만 됩니다. 서브쿼리에는 LATERAL이 없어서 안 됩니다. |

### 스키마에 저장되는 식

- DEFAULT, CHECK, 계산 열, 뷰에는 변수와 매개변수를 쓸 수 없습니다.
- 엔진 함수(`xq_tsql_*`)나 방언 함수(`xq_mssql_*`)를 부르는 스키마는 xqlite에서는 어느 방언으로든 같은 결과를 내지만 sqlite3는 계산할 수 없습니다. 정수형 `CAST`, `LIKE '[a-z]%'`, 날짜 함수, 타입을 모르는 `+`, `ISJSON(x)` 말고의 JSON 함수, `OPENJSON`, `FOR JSON`이 그런 예입니다.
- identity 열은 `DEFAULT (nextval('t_c_seq'))`로 보입니다. rowid가 아닌 identity 열은 sqlite3에서 값 없이 넣을 수 없습니다.

## 아직 하지 않은 것

- 제어 흐름: `IF ... ELSE`, `WHILE`, `BEGIN ... END` 블록, `TRY ... CATCH`, `THROW`/`RAISERROR`, `RETURN`, `GOTO`
- 저장 프로시저·함수·트리거(`CREATE PROCEDURE/FUNCTION/TRIGGER`), `EXEC`(sp_rename 말고)
- 테이블 변수(`DECLARE @t TABLE`), 커서, 임시 저장 프로시저
- 서브쿼리의 `CROSS APPLY`/`OUTER APPLY`: IR에 LATERAL 조인이 없습니다(테이블 값 함수는 됨).
- `TOP ... WITH TIES`, `GROUP BY ROLLUP/CUBE/GROUPING SETS`, `PIVOT`/`UNPIVOT`, `FOR XML`, `STRING_SPLIT`, `FORMAT()`
- `= ANY/SOME/ALL (서브쿼리)`
- `OUTPUT ... INTO`, MERGE의 `OUTPUT`
- `ALTER TABLE ... ADD CONSTRAINT`/`ALTER COLUMN`/`DROP CONSTRAINT`, 여러 열의 ADD/DROP
- `CREATE DATABASE`, 사용자·역할·권한(`CREATE USER`, `GRANT`; `CREATE SCHEMA`의 요소인 `GRANT`는 무시)
- 뷰나 `IDENTITY` 열이 있는 테이블의 `ALTER SCHEMA ... TRANSFER`, 이름에 `.`이 있는 스키마
- `SET ROWCOUNT`, `SET IMPLICIT_TRANSACTIONS ON`, 의미를 바꾸는 옵션(`ANSI_NULLS OFF`, `CONCAT_NULL_YIELDS_NULL OFF`)
- `GO n`의 반복, `DATEFORMAT`/`LANGUAGE`에 따른 날짜 해석(언제나 us_english, mdy)

## 검증

### SQL Server와 비교

`xqt dialect-diff mssql`(`tools/xqt/dialect_diff.zig`)은 `tools/dialect/mssql-cases.txt`의 각 경우를 SQL Server(sqlcmd)와 `xqlite sql`(`.dialect mssql`)에서 실행해 결과 행, 열 이름, `ERROR:` 줄을 비교합니다. 지금 57개 경우가 모두 같습니다.

```sh
zig build tools
podman run -d --name xq-mssql -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD='Xq_Passw0rd!' \
  -e MSSQL_MEMORY_LIMIT_MB=2048 mcr.microsoft.com/azure-sql-edge:latest
podman cp sqlcmd xq-mssql:/tmp/sqlcmd     # go-sqlcmd linux-arm64 (github.com/microsoft/go-sqlcmd 릴리스)
zig-out/bin/xqt dialect-diff mssql [cases-file]
```

- 서버는 Azure SQL Edge(SQL Server 엔진 15.0, arm64 빌드가 있음)입니다. arm64 macOS의 podman에서 `mcr.microsoft.com/mssql/server:2022-latest`(amd64 전용)는 qemu 에뮬레이션에서 시작하자마자 segfault로 죽습니다. Rosetta를 켠 podman 머신이면 그 이미지도 쓸 수 있습니다.
- 이미지에 sqlcmd가 없어서 go-sqlcmd를 컨테이너에 복사해 둡니다. 서버 접속 명령은 `MSSQL_CLIENT`로 바꿉니다(기본 `podman exec -i xq-mssql /tmp/sqlcmd -S localhost -U sa -P Xq_Passw0rd! -C`).
- 각 경우는 새로 만든 데이터베이스 `main`에서 `SET NOCOUNT ON`으로 시작하고, 서버에서는 한 번에 하나씩 돕니다.
- SQL Server는 배치를 실행하기 전에 컴파일하므로, 컴파일 오류가 나는 문장과 그 뒤 문장은 `GO`로 나눕니다.
- 정규화: sqlcmd의 점선, 빈 결과의 머리글, `(n rows affected)`·`Changed database context`·`The statement has been terminated.` 줄을 빼고, 필드의 공백과 소수의 끝 0을 뗍니다. sqlcmd는 좁은 열의 NULL을 열 너비로 자르고(`NU`) 2진 문자열을 16진으로 쓰므로 경우가 그런 모양을 피합니다.

### sqlite3와 교차 검사

`xqt interop mssql`(`tools/xqt/interop/mssql.zig`)은 T-SQL 방언으로 쓴 데이터베이스를 sqlite3로 확인합니다.

- sqlite3의 무결성·외래 키 검사를 통과해야 합니다.
- sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 합니다.
- 다루는 것: STRICT 테이블과 타입의 CHECK, identity 시퀀스, 계산 열(`+`가 열 타입으로 `+`/`||`가 됨), `NOCASE`/`BINARY` 열, 테이블 안과 밖의 인덱스, 뷰, `xq_catalog`, `CHECK (ISJSON(c) = 1)`, `CREATE SCHEMA sales`의 테이블·인덱스·뷰(sqlite3의 `.tables`에 `sales.orders`로 보이고, sqlite3가 쓴 행을 T-SQL 방언이 `sales.orders`로 읽음).
- sqlite3가 타입·제약을 어기는 값을 거부하는지, xqlite가 sqlite3가 바꾼 값을 읽는지도 봅니다.
- 엔진 함수(`xq_tsql_*`)를 쓰는 식은 sqlite3에 없으므로 `src/dialect/mssql/test.zig`에서 확인합니다.

### 퍼저

`zig build fuzz -- ir_roundtrip SEED`의 방언 목록에 `mssql`이 있습니다. 트리를 T-SQL 방언의 훅으로 lower하고, 뷰와 저장된 텍스트를 T-SQL 프론트엔드로 읽습니다.
