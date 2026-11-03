# 사용자와 스키마

[Oracle 호환](README.md)의 일부입니다.

Oracle에서 스키마는 사용자입니다. 이 방언은 사용자를 공용 스키마 구현([방언 아키텍처의 스키마](../architecture.md#스키마네임스페이스))에 올립니다.

- 연결한 사용자는 `MAIN`이고 그 스키마는 SQLite의 `main` 자체입니다. `USER`, `SYS_CONTEXT('USERENV', 'SESSION_USER')`, `USER_*` 뷰의 소유자, `ALL_*` 뷰의 `OWNER`가 `MAIN`입니다. 이름을 설정으로 바꾸지 않는 것은, 같은 파일을 어느 연결이 열어도 개체의 소유자가 같아야 하고 `main.t`·`MAIN.t`가 늘 같은 테이블이어야 하기 때문입니다.
- `CREATE USER u IDENTIFIED BY p`는 스키마 `U`를 목록에 올립니다. 그 개체는 main의 `"U.T"`라는 이름의 개체이고(인덱스 `"U.I"`, 시퀀스 `"U.S"`, identity 시퀀스 `"U.ISEQ$$_T_C"`), sqlite3도 `"U.T"`로 읽고 씁니다.

| 문장 | 하는 일 |
| --- | --- |
| `CREATE USER [IF NOT EXISTS] u IDENTIFIED ...` | 스키마 등록. 암호, `DEFAULT TABLESPACE`, `QUOTA`, `PROFILE`, `ACCOUNT` 같은 옵션은 무시. 이미 있거나 `MAIN`·`SYS`·`SYSTEM`·`PUBLIC`·붙인 데이터베이스 이름이면 `ORA-01920` |
| `DROP USER [IF EXISTS] u [CASCADE]` | 개체(테이블, 뷰, 시퀀스, 다른 사용자 테이블의 인덱스)와 함께 지움. 개체가 있는데 `CASCADE`가 없으면 `ORA-01922`, 없는 사용자는 `ORA-01918` |
| `ALTER USER u ...` | 사용자가 있는지만 검사(`ORA-01918`) |
| `GRANT`, `REVOKE` | 받아들이고 무시(모든 사용자가 모든 권한을 가진 것처럼 동작) |
| `CREATE SCHEMA AUTHORIZATION MAIN CREATE TABLE ... CREATE VIEW ... GRANT ...` | 연결한 사용자의 테이블·뷰를 한 문장(한 트랜잭션)으로 만듦. 다른 사용자 이름이면 `ORA-02421` |
| `ALTER SESSION SET CURRENT_SCHEMA = u` | 한정하지 않은 이름의 스키마. 실행할 때 바뀌고(없는 사용자면 `ORA-01435`), 준비된 문장은 다시 컴파일됨. `MAIN`으로 되돌림 |
| `SYS_CONTEXT('USERENV', p)` | `CURRENT_SCHEMA`는 현재 스키마, `CURRENT_USER`·`SESSION_USER`·`AUTHENTICATED_IDENTITY`는 `MAIN`, 모르는 매개변수는 `ORA-02003`. 다른 네임스페이스는 NULL |

`u.t`는 어디서나 됩니다: 질의·조인·서브쿼리, INSERT·UPDATE·DELETE·MERGE·TRUNCATE, `u.t.col`, `CREATE TABLE u.t`, `REFERENCES u.t`, `CREATE INDEX u.i ON u.t`, `CREATE VIEW u.v`, `CREATE SEQUENCE u.s`와 `u.s.NEXTVAL`, `ALTER TABLE u.t`, `DROP ... u.x`, `COMMENT ON TABLE u.t`.

- 이름 해석: `MAIN`(그리고 데이터 사전과 `DUAL`의 스키마 `SYS`)은 main, 붙인 데이터베이스 이름(`ATTACH`, `TEMP`)은 그 데이터베이스, 등록한 사용자는 main의 `"U.T"`입니다. 컴파일할 때 정하므로 뷰 텍스트에는 `"U.T" AS "T"`처럼 데이터베이스 이름 없이 남고, 별칭이 없는 FROM 항목·DML 대상은 원래 이름 `T`를 별칭으로 가져 `t.col`이 됩니다.
- 현재 스키마가 `U`이면 한정하지 않은 테이블·뷰·인덱스·시퀀스 이름과 DDL이 만드는 개체는 `U`의 것입니다. 단 WITH 질의 이름, 임시 테이블, `DUAL`(`U.DUAL`이 없으면)은 그대로입니다. `USER_*` 뷰는 Oracle처럼 현재 스키마와 상관없이 `MAIN`의 개체입니다.
- 없는 스키마의 오류는 Oracle과 같습니다: 질의·DML·DROP은 `ORA-00942`(시퀀스 `ORA-02289`, 인덱스 `ORA-01418`), `CREATE TABLE`·`CREATE INDEX`는 `ORA-01918`, `CREATE VIEW`·`CREATE SEQUENCE`는 `ORA-01917`.
- 한계: 이름 비교가 대소문자를 구분하지 않으므로 `"hr"`와 `HR`은 같은 사용자입니다. 다른 사용자 스키마의 전역 임시 테이블, 붙인 데이터베이스의 시퀀스, 동의어(`CREATE SYNONYM`)는 지원하지 않습니다. 권한은 검사하지 않습니다. `ALL_USERS.CREATED`는 NULL입니다.
