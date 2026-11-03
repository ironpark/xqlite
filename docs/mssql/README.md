# MSSQL(T-SQL) 호환

xqlite의 Microsoft SQL Server(T-SQL) 방언이 지원하는 문법과 의미, 그리고 SQL Server와 다른 점입니다. 방언 구조와 프론트엔드 계약은 [방언 아키텍처](../architecture.md)를 보세요.

## 목차

- [구조](structure.md)
- [지원 범위](support.md)
- [타입 매핑](types.md)
- [`+`의 규칙](plus.md)
- [MERGE](merge.md)
- [JSON](json.md)
- [스키마](schemas.md)
- [SQL Server와 다른 점](differences.md)
- [아직 하지 않은 것](todo.md)
- [검증](testing.md)

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
