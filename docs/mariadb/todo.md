# 아직 하지 않은 것

[MariaDB 호환](README.md)의 일부입니다.

- 프로그램
  - 저장 프로시저·함수
  - MySQL 문법의 트리거·이벤트
- DML
  - 다중 테이블 `UPDATE`/`DELETE`
  - `SELECT ... INTO`
  - `LOAD DATA`
- SELECT와 식
  - `WITH ROLLUP`
  - `REGEXP`: SQLite처럼 `regexp()` 함수가 있어야 합니다.
  - `MATCH ... AGAINST`
- DDL
  - `ALTER TABLE`의 `CHANGE`/`MODIFY`와 여러 변경
  - `PARTITION`
  - `FULLTEXT`: 보통 인덱스로 만듭니다.
  - `CREATE TABLE ... LIKE`
  - `CREATE OR REPLACE TABLE`
  - `INVISIBLE` 열
- 그 밖
  - utf8 밖의 문자 집합
  - `ONLY_FULL_GROUP_BY` 검사
  - 셸의 문장 분할: SQLite 규칙이라 `'it\'s'` 같은 문자열이 있으면 파일 끝까지 한 덩어리로 실행됩니다.
