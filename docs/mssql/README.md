# MSSQL (T-SQL) 호환

xqlite의 Microsoft SQL Server (Transact-SQL) 방언이 제공하는 문법, 동작 방식, 사용 방법 및 호환성 가이드입니다. SQL Server 2022 및 Azure SQL Edge 표준을 기준으로 설계되었으며 SQLite 임베디드 코어 위에서 고성능으로 동작합니다.

---

## 1. 켜는 법 (사용 방법)

| 환경 | 활성화 방법 | 설명 |
| --- | --- | --- |
| **SQL 질의** | `PRAGMA xq_dialect = 'mssql';`<br>*(또는 `'tsql'`, `'sqlserver'`)* | 세션의 현재 방언을 T-SQL로 변경합니다. 언제든 `PRAGMA xq_dialect = 'sqlite';`로 돌아올 수 있습니다. |
| **xqlite CLI 셸** | `.dialect mssql` | 인터랙티브 셸 프롬프트에서 T-SQL 방언을 활성화합니다. 배치 구분자 `GO`를 지원합니다. |
| **Zig API** | `db.setDialect(.mssql);` | C/Zig 애플리케이션 임베딩 시 연결 단위로 방언을 설정합니다. |

---

## 2. 빠른 시작 (Quickstart)

```sql
-- T-SQL 방언 활성화
PRAGMA xq_dialect = 'mssql';

-- 스키마 및 테이블 생성 (IDENTITY, NVARCHAR, BIT, DATETIME2 지원)
CREATE TABLE dbo.app_user (
  id         INT IDENTITY(1,1) PRIMARY KEY,
  email      NVARCHAR(100) NOT NULL UNIQUE,
  is_active  BIT NOT NULL DEFAULT 1,
  meta       NVARCHAR(MAX),
  created_at DATETIME2 DEFAULT SYSDATETIME()
);

-- 데이터 삽입 및 OUTPUT 절로 생성된 ID 수신
INSERT INTO dbo.app_user (email, meta)
OUTPUT INSERTED.id, INSERTED.created_at
VALUES (N'user1@example.com', N'{"dept": "dev"}');

-- @@IDENTITY 및 SCOPE_IDENTITY() 조회
SELECT SCOPE_IDENTITY() AS new_user_id;

-- TOP 및 T-SQL 전용 식 조회
SELECT TOP 10 id, email,
       ISNULL(is_active, 0) AS status,
       JSON_VALUE(meta, '$.dept') AS department
FROM dbo.app_user
WHERE email LIKE 'user%'
ORDER BY id DESC;

-- 배치 구분자 GO (셸 환경 지원)
GO

-- SQLite 방언으로 복귀
PRAGMA xq_dialect = 'sqlite';
```

---

## 3. 핵심 기능 요약

- **T-SQL 고유 어휘**: 대괄호 식별자(`[dbo].[app_user]`), 유니코드 문자열(`N'...'`), 로컬 변수(`@my_var`), 배치 구분자(`GO`).
- **T-SQL 데이터 타입**: `BIT`, `INT`, `BIGINT`, `DECIMAL(p,s)`, `DATETIME2`, `UNIQUEIDENTIFIER`, `NVARCHAR(MAX)` 지원.
- **고급 DML 확장**:
  - `TOP (n)` 및 `OFFSET ... FETCH NEXT n ROWS ONLY` 페이징.
  - `OUTPUT INSERTED.* / DELETED.*` 절 지원.
  - 한 문장으로 조건부 삽입/갱신/삭제를 수행하는 `MERGE` 구문.
  - `UPDATE ... FROM` 및 `DELETE ... FROM` 조인 구문.
- **특화 연산자 및 내장 함수**:
  - `+` 연산자의 타입별 자동 해석 (숫자 덧셈 vs 문자열 결합).
  - JSON 내장 함수 (`ISJSON`, `JSON_VALUE`, `JSON_QUERY`, `JSON_MODIFY`, `OPENJSON`).
  - `SCOPE_IDENTITY()`, `NEWID()`, `GETDATE()`, `SYSDATETIME()`, `DATEDIFF()`, `DATEADD()`.
  - 메타데이터 카탈로그: `sys.tables`, `sys.columns`, `sys.schemas`, `INFORMATION_SCHEMA.*`.

---

## 4. 문서 구성 안내

| 문서 | 핵심 내용 | 대상 |
| --- | --- | --- |
| **[지원 기능 (features.md)](features.md)** | T-SQL 지원 문법, 데이터 타입, `MERGE`, `OUTPUT`, `+` 규칙, JSON 함수 | 개발자, 사용자 |
| **[차이점 및 미지원 (differences.md)](differences.md)** | SQL Server와의 동작 차이, 미지원 기능 목록, 제약 사항 및 대안 | 개발자, DBA |
| **[내부 기술 세부사항 (internals.md)](internals.md)** | T-SQL 파서 구조, `MERGE`/`OUTPUT`의 바이트코드 변환 원리, 스토리지 매핑 | 기여자, 코어 개발자 |
| **[테스트 및 검증 (testing.md)](testing.md)** | `dialect-diff mssql`, Azure SQL Edge 기반 교차 검증 및 테스트 가이드 | 기여자, QA |
