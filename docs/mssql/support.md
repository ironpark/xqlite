# 지원 범위

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

## 어휘

- 식별자: 단어(`#temp`, `##global` 포함), `[대괄호]`(`]]`가 `]`), `"큰따옴표"`(QUOTED_IDENTIFIER ON). 대소문자를 구분하지 않습니다.
- 문자열 `'it''s'`, `N'유니코드'`.
- `@변수`, `@@ROWCOUNT` 같은 시스템 함수, 매개변수 `?`.
- 주석 `--`, 중첩되는 `/* */`.
- 2진 상수 `0x0A1B`(홀수 자리는 앞에 0), `1e3`, `.5`.
- 연산자 `!=`, `!<`, `!>`, 복합 대입 `+=` `-=` `*=` `/=` `%=` `&=` `|=` `^=`.

## SELECT

| 영역 | 지원 |
| --- | --- |
| 기본 | `DISTINCT`, `WHERE`, `GROUP BY`, `HAVING` |
| 행 수 제한 | `TOP n`, `TOP (n)`, `TOP n PERCENT`, `ORDER BY ... OFFSET n ROWS [FETCH {FIRST\|NEXT} m ROWS ONLY]` |
| 결과 열 | `expr AS a`, `expr a`, `a = expr`, `'a' = expr`. 이름 없는 식의 열 이름은 SQL Server처럼 빈 문자열 |
| FROM | 테이블(`dbo.t`, `s.t`, `db.dbo.t`, `db.s.t`, `db..t`, `#t`), 서브쿼리, `(VALUES ...) AS v(a, b)`, 테이블 값 함수, `OPENJSON`, 테이블 힌트 `WITH (NOLOCK)`(무시) |
| JOIN | `[INNER]`, `LEFT/RIGHT/FULL [OUTER]`, `CROSS JOIN`, 조인 힌트(`HASH` 등, 무시), 테이블 값 함수의 `CROSS APPLY`/`OUTER APPLY` |
| 집합 연산 | `UNION [ALL]`, `EXCEPT`, `INTERSECT`(INTERSECT가 먼저 묶임); `TOP`이 있는 피연산자 |
| CTE | `WITH`. 자기 이름을 부르면 재귀(RECURSIVE 없이), `;WITH` |
| 그 밖 | `SELECT ... INTO t`(새 테이블), `SELECT @x = ...`, `OPTION (...)`(무시), `FOR JSON`([JSON](json.md)) |
| 윈도우 | `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE ...)`, `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE`, `LAG`, `LEAD` ... |

## DML

- **INSERT** `[TOP (n)] [INTO] t [(열)] [OUTPUT ...] {VALUES (...), ... | SELECT ... | DEFAULT VALUES}`
  - `VALUES`의 `DEFAULT`
  - 열 목록이 없으면 identity 열과 계산 열을 뺀 열에 넣습니다.
- **UPDATE** `[TOP (n)] t SET c = v, c += v, t.c = v [OUTPUT INSERTED.*] [FROM ... JOIN ...] [WHERE]`
  - FROM 절에서 대상을 별칭으로 부를 수 있습니다(`UPDATE x SET ... FROM t AS x JOIN ...`).
- **DELETE** `[TOP (n)] [FROM] t [OUTPUT DELETED.*] [FROM ... JOIN ...] [WHERE]`
- **OUTPUT** `INSERTED.*`, `INSERTED.c`, `DELETED.c`와 식은 `RETURNING`입니다.
- **MERGE**([아래](merge.md))
- **TRUNCATE TABLE**: identity가 처음 값으로 돌아갑니다.
- FROM 절의 대상은 FROM에서 빠지고 그 조인 조건이 WHERE로 갑니다(SQLite의 UPDATE FROM, DELETE ... USING).

## DDL

- **CREATE SCHEMA**, **DROP SCHEMA**, **ALTER SCHEMA ... TRANSFER**([스키마](schemas.md))
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

## 세션과 트랜잭션

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
- `ALTER USER u WITH DEFAULT_SCHEMA = s`는 연결의 기본 스키마를 바꿉니다([스키마](schemas.md)).

## 함수

| 분류 | 함수 |
| --- | --- |
| NULL·조건 | `ISNULL`, `COALESCE`, `NULLIF`, `IIF`, `CHOOSE`, `CASE` |
| 변환 | `CAST`, `CONVERT(type, x [, style])`(날짜 스타일 1-5, 8, 10-12, 20-25, 101-105, 108, 110-112, 120, 121, 126, 127), `TRY_CAST`, `TRY_CONVERT`, `PARSE`, `TRY_PARSE`, `ISNUMERIC`, `ISDATE` |
| 문자열 | `LEN`(끝 공백 제외), `DATALENGTH`, `CHARINDEX`, `SUBSTRING`, `LEFT`, `RIGHT`, `LTRIM`, `RTRIM`, `TRIM([chars FROM] s)`, `UPPER`, `LOWER`, `REPLACE`, `REVERSE`, `REPLICATE`, `SPACE`, `STUFF`, `CONCAT`, `CONCAT_WS`, `ASCII`, `CHAR`, `NCHAR`, `UNICODE`, `QUOTENAME` |
| 수 | `ABS`, `CEILING`, `FLOOR`, `ROUND(x, n [, f])`, `POWER`, `SQUARE`, `SQRT`, `SIGN`, `EXP`, `LOG(x [, base])`, `LOG10`, `PI`, `SIN` 등 삼각 함수, `RAND` |
| 날짜 | `GETDATE()`, `CURRENT_TIMESTAMP`, `GETUTCDATE()`, `SYSDATETIME()`, `SYSUTCDATETIME()`, `SYSDATETIMEOFFSET()`, `DATEADD`, `DATEDIFF`, `DATEDIFF_BIG`, `DATEPART`, `DATENAME`, `YEAR`, `MONTH`, `DAY`, `EOMONTH`, `DATEFROMPARTS` |
| 집계 | `COUNT`, `COUNT_BIG`, `SUM`, `AVG`, `MIN`, `MAX`, `STRING_AGG(x, sep) [WITHIN GROUP (ORDER BY ...)]`, `STDEV`, `STDEVP`, `VAR`, `VARP` |
| identity | `SCOPE_IDENTITY()`, `@@IDENTITY`, `IDENT_CURRENT('t')` |
| JSON | `ISJSON`, `JSON_VALUE`, `JSON_QUERY`, `JSON_MODIFY`, `JSON_PATH_EXISTS`, `JSON_OBJECT`, `JSON_ARRAY`, `STRING_ESCAPE(s, 'json')`([JSON](json.md)) |
| 스키마 | `OBJECT_ID('[db.][s.]t')`, `OBJECT_NAME(id)`, `OBJECT_SCHEMA_NAME(id)`, `SCHEMA_ID(['s'])`, `SCHEMA_NAME([id])`(인자가 없으면 기본 스키마) |
| 그 밖 | `NEWID()`, `DB_NAME()`(`main`), `USER_NAME()`, `@@ROWCOUNT`, `@@TRANCOUNT`, `@@VERSION`, `@@SPID` ... |

- datepart 이름과 약어(`yy`, `mm`, `dd`, `hh`, `mi`, `ss`, `ms`, `dw`, `wk` ...)를 받습니다.
- `DATEDIFF`는 SQL Server처럼 경계를 센 수입니다(`DATEDIFF(year, '2023-12-31', '2024-01-01')`은 1). 주는 일요일에 시작합니다(`@@DATEFIRST` 7).
- `DATEADD`의 결과는 입력의 모양(날짜만, 소수 자리 수, 오프셋)을 따릅니다. 문자열 상수는 SQL Server처럼 `datetime`으로 읽습니다.
- `CHARINDEX`와 `REPLACE`는 기본 collation처럼 대소문자를 무시합니다.

## 카탈로그

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
