# 아직 하지 않은 것

[Oracle 호환](README.md)의 일부입니다.

| 영역 | 항목 |
| --- | --- |
| PL/SQL | `BEGIN ... END;`, `DECLARE`, 프로시저·함수·패키지·트리거·타입(`CREATE PROCEDURE` ...), `RETURNING ... INTO`, `SELECT ... INTO` |
| 쿼리 | `CONNECT BY` 계층 질의(`LEVEL`, `PRIOR`, `SYS_CONNECT_BY_PATH`), `PIVOT`/`UNPIVOT`, `MODEL`, `GROUPING SETS`/`ROLLUP`/`CUBE`, `KEEP (DENSE_RANK ...)`, `FETCH ... PERCENT`/`WITH TIES`, `SEARCH`/`CYCLE`, 플래시백(`AS OF`), `SAMPLE`, `LATERAL`/`CROSS APPLY` |
| 함수 | 정규식(`REGEXP_LIKE` ...), `INTERVAL` 상수와 연산, `AT TIME ZONE`, `NUMTODSINTERVAL`, `TO_CHAR`의 `TH`/`SP` 접미사, NLS 매개변수, `UPPER`/`LOWER`의 ASCII 밖 문자 |
| DML | `UPDATE t SET c = ROWNUM`, `LOG ERRORS`, `WHERE CURRENT OF` |
| DDL | `ALTER TABLE ... MODIFY`·`ADD CONSTRAINT`·`DROP CONSTRAINT`, 한 번에 여러 열 추가·삭제, `CREATE SYNONYM`, 구체화된 뷰, 파티션, `ORGANIZATION INDEX`, `ON COMMIT DELETE ROWS`(임시 테이블은 `PRESERVE ROWS`로 동작), `ALTER SEQUENCE`, 권한 검사(`GRANT`/`REVOKE`는 무시) |
| 트랜잭션 | DDL의 암묵적 커밋, 격리 수준 |
| JSON | `IS JSON (OBJECT\|ARRAY\|SCALAR)`, `strict` 경로 모드, `JSON_TRANSFORM`의 처리기(`IGNORE ON MISSING` ...)와 `NESTED PATH`·`CASE`·`SORT` 같은 연산, `JSON_TABLE`의 `TYPE(STRICT)`와 100개가 넘는 열, 경로의 `like_regex`·`eq_regex`와 날짜 비교, `JSON_ARRAY(서브쿼리)`, `JSON_OBJECT`의 비교식 값(`'k' VALUE a > b`), JSON 검색 인덱스, `JSON_DATAGUIDE`, `JSON_EQUAL`, JSON 관계형 이중성 뷰 |
| 오류 | 제약 위반·0으로 나누기·저장 변환 밖의 실행 중 오류(SQLite 내장 함수가 내는 것 등)의 ORA- 코드화, `ORA-30926`(MERGE의 중복 일치) |
