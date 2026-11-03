# MSSQL (T-SQL) 호환: 지원 기능

xqlite MSSQL 방언이 지원하는 T-SQL 데이터 타입, DDL/DML 구문, `+` 연산자 해석 규칙, `MERGE` 문, JSON 함수 및 스키마 관리 명세입니다.

---

## 1. 데이터 타입 매핑 및 변환

테이블은 `STRICT` 모드로 생성되며, T-SQL의 데이터 타입 범위와 검사 제약 조건을 엄격히 준수합니다.

| T-SQL 타입 | 저장 타입 | 설명 및 제약 조건 |
| --- | --- | --- |
| `TINYINT`, `SMALLINT`, `INT`, `BIGINT` | `INTEGER` | 각각 8비트(0~255), 16비트, 32비트, 64비트 정수 범위를 검사하며 오버플로우 시 T-SQL 에러를 발생시킵니다. |
| `BIT` | `INTEGER` | 0 또는 1 정수만 허용됩니다. |
| `DECIMAL(p,s)`, `NUMERIC(p,s)`, `MONEY`, `SMALLMONEY` | `REAL` | 정밀도 p와 스케일 s를 메타데이터로 유지하며 출력 시 해당 자릿수를 보장합니다. |
| `FLOAT`, `REAL` | `REAL` | 부동소수점 실수. |
| `CHAR(n)`, `VARCHAR(n)` | `TEXT` | 최대 길이 n을 검사합니다. 기본 collation은 대소문자를 구분하지 않는 `SQL_Latin1_General_CP1_CI_AS`. |
| `NCHAR(n)`, `NVARCHAR(n)`, `NVARCHAR(MAX)`, `TEXT`, `NTEXT` | `TEXT` | UTF-8 유니코드 텍스트. |
| `DATE`, `TIME`, `DATETIME`, `DATETIME2`, `SMALLDATETIME` | `TEXT` | 표준 ISO 형식 문자열. |
| `UNIQUEIDENTIFIER` | `TEXT` | 36자 UUID 텍스트. `NEWID()`로 생성 가능. |
| `BINARY(n)`, `VARBINARY(n)`, `VARBINARY(MAX)`, `IMAGE` | `BLOB` | 바이트 단위 바이너리 데이터. |

---

## 2. 지원 SQL 문장

### 2.1 데이터 정의어 (DDL)
- **스키마 관리**: `CREATE SCHEMA schema_name`, `DROP SCHEMA schema_name`
- **테이블 생성**:
  - `CREATE TABLE [schema.]table_name`
  - 열 속성: `IDENTITY(seed, increment)`, `NOT NULL`, `DEFAULT expr`
  - 계산 열: `col AS (expr) [PERSISTED]`
  - 제약 조건: `PRIMARY KEY`, `UNIQUE`, `CHECK`, `FOREIGN KEY REFERENCES ...`
- **인덱스**: `CREATE [UNIQUE] [CLUSTERED | NONCLUSTERED] INDEX idx_name ON tbl (col)`
- **뷰**: `CREATE VIEW [schema.]view_name AS SELECT ...`

### 2.2 데이터 조작어 (DML)
- **`SELECT`**
  - `TOP (n) [PERCENT]` 페이징
  - `OFFSET n ROWS FETCH NEXT m ROWS ONLY`
  - `CROSS APPLY` 및 `OUTER APPLY` (테이블 값 함수 `OPENJSON`과 함께 사용)
  - `FOR JSON AUTO / PATH` (질의 결과를 JSON 문자열로 직렬화)
  - 공통 테이블 식: `;WITH cte AS (...)`
- **`INSERT`**
  - 일반 및 다중 행 `INSERT INTO tbl VALUES (...)`
  - `INSERT INTO tbl (cols) SELECT ...`
  - `OUTPUT INSERTED.col, ...` 절을 통한 생성 데이터 반환
- **`UPDATE`**
  - 조인 기반 갱신: `UPDATE t SET col = expr FROM t JOIN other ON ...`
  - `OUTPUT DELETED.*, INSERTED.*` 절 지원
- **`DELETE`**
  - 조인 기반 삭제: `DELETE t FROM t JOIN other ON ...`
  - `OUTPUT DELETED.*` 지원
- **`MERGE`**
  - 단일 원자적 문장으로 `WHEN MATCHED THEN UPDATE/DELETE`, `WHEN NOT MATCHED THEN INSERT`를 통합 수행

---

## 3. `+` 연산자의 타입별 해석 규칙

T-SQL에서 `+` 연산자는 피연산자의 데이터 타입 우선순위(Data Type Precedence)에 따라 덧셈 또는 문자열 결합으로 동작합니다.

| 피연산자 A | 피연산자 B | 동작 방식 | 예제 |
| --- | --- | --- | --- |
| 숫자 (INT/REAL) | 숫자 (INT/REAL) | **산술 덧셈** | `10 + 20` → `30` |
| 문자열 (VARCHAR) | 문자열 (VARCHAR) | **문자열 결합** | `'hello ' + 'world'` → `'hello world'` |
| 숫자 (INT/REAL) | 문자열 (VARCHAR) | **문자열을 숫자로 변환 후 덧셈** | `10 + '20'` → `30` (문자열이 숫자가 아니면 변환 에러) |
| NULL | 임의의 값 | **NULL 반환** | `'abc' + NULL` → `NULL` |

---

## 4. JSON 함수군

SQL Server 표준 JSON 함수들을 기본 내장하여 처리합니다.

- **`ISJSON(json_text)`**: 문자열이 유효한 JSON 객체/배열인지 검사 (1 또는 0 반환).
- **`JSON_VALUE(json_text, path)`**: 지정된 JSON 경로에서 스칼라 값을 추출하여 반환.
- **`JSON_QUERY(json_text, path)`**: 지정된 JSON 경로에서 JSON 객체 또는 배열을 추출.
- **`JSON_MODIFY(json_text, path, new_value)`**: JSON의 특정 경로 값을 수정, 추가(`append`), 삭제.
- **`OPENJSON(json_text [, path]) [WITH (...)]`**: JSON 문자열을 관계형 테이블 형태로 분해하는 테이블 값 함수.
  ```sql
  SELECT [key], value, type FROM OPENJSON('{"a": 1, "b": "text"}');
  ```

---

## 5. 시스템 및 내장 함수

- **식별자 및 세션**: `SCOPE_IDENTITY()`, `@@IDENTITY`, `@@ROWCOUNT`, `NEWID()`
- **조건 및 변환**: `ISNULL(expr, alt)`, `COALESCE(...)`, `NULLIF(a, b)`, `CAST(expr AS type)`, `CONVERT(type, expr [, style])`, `TRY_CAST(expr AS type)`, `TRY_CONVERT(type, expr)`
- **문자열 함수**: `LEN()`, `DATALENGTH()`, `SUBSTRING()`, `CHARINDEX()`, `LEFT()`, `RIGHT()`, `LTRIM()`, `RTRIM()`, `UPPER()`, `LOWER()`, `REPLACE()`, `REPLICATE()`, `STUFF()`, `CONCAT()`
- **날짜 및 시간 함수**: `GETDATE()`, `GETUTCDATE()`, `SYSDATETIME()`, `DATEADD(datepart, number, date)`, `DATEDIFF(datepart, startdate, enddate)`, `DATEPART(datepart, date)`, `YEAR()`, `MONTH()`, `DAY()`
- **수학 함수**: `ABS()`, `ROUND()`, `CEILING()`, `FLOOR()`, `POWER()`, `SQRT()`, `SIGN()`
- **메타데이터 카탈로그**: `sys.tables`, `sys.columns`, `sys.schemas`, `sys.objects`, `sys.indexes`, `INFORMATION_SCHEMA.TABLES`, `INFORMATION_SCHEMA.COLUMNS`
