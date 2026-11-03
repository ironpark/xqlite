# SQL Server와 다른 점

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

## 타입과 값

| 항목 | xqlite |
| --- | --- |
| `decimal`/`money` | `REAL`로 저장합니다. 반올림은 되지만 정확한 십진 연산이 아닙니다. API로는 `2.50`이 `2.5`이고, 셸과 서버는 `decimal(p,s)` 열을 s자리로 보여 줍니다(`2.50`, [값 표시](../architecture.md#값-표시)). `CAST(x AS decimal(p,s))`와 스케일을 아는 식(`1.50`, `d * 2`, `7 / 2.0`의 `3.500000`, `AVG(d)`)도 그렇습니다. |
| 식의 타입 | SQL Server의 데이터 타입 우선순위와 정밀도·스케일 규칙으로 매깁니다: 정수 리터럴은 `int`, `1.50`은 `numeric(3,2)`, `'abc'`는 `varchar(3)`, `int`끼리는 `int`, `decimal`끼리는 `+ -`가 scale max(s1, s2)·정밀도 max(s1, s2) + max(p1 - s1, p2 - s2) + 1, `*`가 s1 + s2·p1 + p2 + 1, `/`가 scale max(6, s1 + p2 + 1), 38자리를 넘으면 38로 줄이고 scale을 정수부가 남기는 만큼(단순화), 문자열 `+`는 길이의 합인 `varchar`, `COUNT()`은 `int`, `SUM(decimal(p,s))`은 `decimal(38,s)`, `AVG(decimal(p,s))`은 `decimal(38,max(s,6))`([코어의 타입](../architecture.md#코어의-타입)). 만든 `decimal`은 `numeric(p,s)`로 씁니다. 결과 열의 선언 타입과 값 표시, 매개변수 타입, 정수 산술의 범위 검사(아래 정수 나눗셈)에 씁니다. `COUNT_BIG()`은 `count()`로 내려가 `int`입니다. |
| 정수 나눗셈 | `7 / 2`는 3으로 같습니다. 0으로 나누면 SQL Server처럼 `Divide by zero error encountered.`(8134), 64비트를 넘는 정수 결과는 `Arithmetic overflow error converting expression to data type bigint.`(8115)입니다. 타입이 `int`인 연산(`int`끼리, 32비트 리터럴끼리의 `SELECT 2147483647 + 1`)은 그 범위를 넘으면 `Arithmetic overflow error converting expression to data type int.`(8115, 22003), `smallint`·`tinyint`(0..255)끼리는 `Arithmetic overflow error for data type tinyint, value = 256.`(220, 22003)입니다. `SUM()` of `int`도 `int`라 합이 2³¹을 넘으면 같은 오류입니다(창 함수 `SUM() OVER`는 아직 검사하지 않음). 이 방언으로 컴파일한 문장에서만이고, CHECK·계산 열의 식과 sqlite3·SQLite 방언에서는 64비트로 계산합니다([타입을 읽는 코드 생성](../architecture.md#타입을-읽는-코드-생성)). 프론트엔드가 값에 맡긴 `+`(`xq_tsql_add()`, 피연산자가 문자열인지 모를 때)는 검사하지 않습니다. |
| 문자열 → 수 | `'abc' + 1`처럼 실행 때 정해지는 덧셈과 비교는 SQLite처럼 0으로 바꿉니다(CAST와 저장은 SQL Server처럼 오류). |
| `char(n)` | 공백으로 채우지 않습니다. |
| 끝 공백 | 비교에서 무시하지 않습니다(`'a' = 'a '`는 거짓). `LEN`은 끝 공백을 뺍니다. |
| collation | `NOCASE`는 ASCII만 접습니다(`'é' = 'É'`는 거짓). ASCII 밖 문자의 정렬 순서는 바이트 순서입니다. |
| `nvarchar` | UTF-8로 저장합니다. `DATALENGTH`는 UTF-8 바이트 수라서 `DATALENGTH(N'a')`가 1입니다(SQL Server는 2). |
| 날짜 | `datetime + 1` 같은 날짜 산술은 없습니다(`DATEADD`를 씁니다). `CAST(날짜 AS VARCHAR)`는 저장 형식 그대로입니다(SQL Server는 `Jan  2 2024 ...`). `GETDATE()`는 UTC입니다. |
| `uniqueidentifier` | 텍스트로 정렬합니다(SQL Server는 바이트 그룹 순서). |
| JSON의 `decimal` | `REAL`이라서 `FOR JSON`과 `JSON_MODIFY`가 `2.50`을 `2.5`로 씁니다. 계산한 `float` 값(`f * 2`)은 타입을 모르므로 `5.0`처럼 씁니다(SQL Server는 `5.000000000000000e+000`). |
| `OPENJSON`의 `value` | `NOCASE`라서 `'é' = 'É'`는 거짓입니다(SQL Server의 CI_AS는 참). |

## 문장의 동작

| 항목 | xqlite |
| --- | --- |
| 배치 | 배치가 없습니다. 문장은 앞 문장이 실행된 뒤에 컴파일되고, 변수는 연결이 끝나거나 다시 선언할 때까지 남습니다. 오류가 배치의 나머지를 건너뛰게 하지 않습니다(셸에서는 SQLite 셸의 `.bail` 규칙). |
| 외래 키 | SQL Server처럼 지키도록, 트랜잭션 밖에서 첫 T-SQL 문장을 컴파일할 때 연결의 `PRAGMA foreign_keys`를 켭니다. 외래 키를 강제하지 않는 방언으로 바꾸면 그 방언의 첫 문장 앞에서(트랜잭션 중이면 끝난 뒤) 다시 끕니다. 응용이 먼저 켜 두었거나 그 사이에 바꾼 설정은 그대로 둡니다(PostgreSQL, MariaDB, Oracle 방언도 같음). |
| identity | 시퀀스는 트랜잭션에 묶여서 롤백된 값이 다시 나옵니다(SQL Server는 건너뜀). |
| `@@ROWCOUNT` | `changes()`: 마지막 INSERT/UPDATE/DELETE가 바꾼 행 수입니다(SELECT의 행 수가 아님). |
| `OUTPUT DELETED` | DELETE에서만 됩니다. UPDATE의 `DELETED.c`(이전 값)는 `RETURNING`이 새 행만 보므로 오류입니다. |
| UPDATE/DELETE ... FROM | 대상이 FROM의 외부 조인 쪽에 있으면 오류입니다. 대상을 부르는 다른 조인의 `ON`은 쓸 수 없습니다. |
| DROP | 한 문장에서 둘 이상의 있는 객체를 지울 수 없습니다(`DROP TABLE IF EXISTS a, b`는 하나만 있을 때 됨). |
| 인덱스 이름 | 스키마마다 유일합니다(SQL Server는 테이블마다). |
| 스키마 | 붙인 데이터베이스에는 `dbo`만 있습니다. `ALTER SCHEMA ... TRANSFER`는 인덱스 이름을 옮기지 않습니다. `CREATE SCHEMA ... CREATE TABLE ...`의 요소는 따로 실행됩니다. |
| 실행 중 오류 | 제약 위반은 SQL Server 문구와 번호입니다([제약 위반](#제약-위반)). 그 밖의 엔진 오류는 SQLite 문구입니다. 컴파일 오류(`Invalid object name 'x'.`, `Invalid column name 'c'.` ...)와 변환 오류는 SQL Server 문구입니다. |
| 결과 열 이름 | 이름 없는 식은 빈 이름입니다(sqlcmd처럼). 서브쿼리 안에서는 SQLite의 이름입니다. |
| JSON 타입 | 값의 JSON 여부(`JSON_QUERY` ...)는 식의 모양으로 정합니다. `ISNULL(JSON_QUERY(...), ...)`처럼 다른 함수를 거친 JSON은 문자열로 씁니다(SQL Server는 타입을 따라감). |
| `JSON_OBJECT`/`JSON_ARRAY`/`ISJSON(x, type)`/`JSON_PATH_EXISTS` | SQL Server 2022의 함수로, 비교하는 서버(Azure SQL Edge, 엔진 15.0)에 없어서 문서대로 구현하고 서버와 비교하지 않았습니다. |
| `OPENJSON ... WITH` | 같은 이름의 열을 둘 쓸 수 없습니다(가상 테이블의 열 이름). |
| `CROSS APPLY`/`OUTER APPLY` | 테이블 값 함수(`OPENJSON` ...)에만 됩니다. 서브쿼리에는 LATERAL이 없어서 안 됩니다. |

## 제약 위반

이 방언으로 컴파일한 문장의 제약 위반은 SQL Server의 문구와 번호입니다.

| 위반 | 메시지 | 번호 | SQLSTATE |
| --- | --- | --- | --- |
| PRIMARY KEY | `Violation of PRIMARY KEY constraint 'pk'. Cannot insert duplicate key in object 'dbo.t'. The duplicate key value is (1).` | 2627 | 23505 |
| UNIQUE 제약 | `Violation of UNIQUE KEY constraint 'uq'. ...` | 2627 | 23505 |
| 유일 인덱스 | `Cannot insert duplicate key row in object 'dbo.t' with unique index 'ix'. The duplicate key value is (1, a).` | 2601 | 23505 |
| `CREATE UNIQUE INDEX`가 중복을 찾음 | `The CREATE UNIQUE INDEX statement terminated because a duplicate key was found for the object name 'dbo.t' and the index name 'ix'.` | 1505 | 23505 |
| NOT NULL | `Cannot insert the value NULL into column 'a', table 'main.dbo.t'; column does not allow nulls. INSERT fails.`(UPDATE면 `UPDATE fails.`) | 515 | 23502 |
| CHECK | `The INSERT statement conflicted with the CHECK constraint "ck". The conflict occurred in database "main", table "dbo.t".` | 547 | 23514 |
| 외래 키(자식 행) | `The INSERT statement conflicted with the FOREIGN KEY constraint "fk". The conflict occurred in database "main", table "dbo.p", column 'id'.` | 547 | 23503 |
| 외래 키(부모 행) | `The DELETE statement conflicted with the REFERENCE constraint "fk". The conflict occurred in database "main", table "dbo.t", column 'b'.` | 547 | 23503 |

- SQL Server는 이름 없는 제약에 무작위 꼬리가 붙은 이름(`PK__t__3213E83F0AD2A005`)을 붙입니다. 같은 이름을 만들 수 없어서 꼬리 없는 고정된 이름을 씁니다: `PK__<table>`, `UQ__<table>__<columns>`, `FK__<table>__<columns>`, `CK__<table>`. 이름을 준 제약의 이름은 CREATE TABLE이 `xq_catalog`에 적어 둡니다(키 `constraint:<종류>:<열>`).
- CHECK 오류는 열 CHECK여도 `column 'c'`를 붙이지 않습니다. 오류 뒤에 오는 `The statement has been terminated.`(3621)도 없습니다.
- 문장이 끝날 때 찾는 외래 키 위반은 마지막으로 센 위반의 제약을 말합니다. 어느 제약인지 모를 때(지연 제약의 COMMIT, DROP TABLE)는 `The statement conflicted with a FOREIGN KEY constraint.`입니다.

## 스키마에 저장되는 식

- DEFAULT, CHECK, 계산 열, 뷰에는 변수와 매개변수를 쓸 수 없습니다.
- 엔진 함수(`xq_tsql_*`)나 방언 함수(`xq_mssql_*`)를 부르는 스키마는 xqlite에서는 어느 방언으로든 같은 결과를 내지만 평범한 sqlite3는 계산할 수 없습니다. 정수형 `CAST`, `LIKE '[a-z]%'`, 날짜 함수, 타입을 모르는 `+`, `ISJSON(x)` 말고의 JSON 함수, `OPENJSON`, `FOR JSON`이 그런 예입니다. [확장](../extension.md)을 올린 sqlite3는 `OPENJSON`(엔진의 테이블 값 함수)과 세션·스키마 카탈로그를 읽는 함수(`SCOPE_IDENTITY()`, `SCHEMA_NAME()` ...) 말고는 모두 xqlite와 같은 결과로 계산합니다.
- identity 열은 `DEFAULT (nextval('t_c_seq'))`로 보입니다. rowid가 아닌 identity 열은 평범한 sqlite3에서는 값 없이 넣을 수 없고, 확장을 올리면 `PRAGMA trusted_schema=ON`에서 xqlite와 같은 시퀀스(`xq_sequence`)로 번호를 받습니다. `NEXT VALUE FOR`의 DEFAULT(`xq_mssql_xq_tsql_next_value`)도 같습니다.
