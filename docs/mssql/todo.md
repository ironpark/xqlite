# 아직 하지 않은 것

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

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
