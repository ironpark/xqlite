# 스키마

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

`CREATE SCHEMA`의 스키마는 공용 구현([방언 아키텍처의 스키마](../architecture.md#스키마네임스페이스), `src/catalog/schema.zig`)을 씁니다. 스키마 `sales`의 테이블 `orders`는 main의 테이블 `"sales.orders"`이고, 그 인덱스·시퀀스도 `sales.ix`, `sales.orders_id_seq`처럼 이름이 붙습니다. 파일 하나, 트랜잭션 하나이고 sqlite3는 `"sales.orders"`로 읽고 씁니다.

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
