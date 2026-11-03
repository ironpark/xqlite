# 트랜잭션

[Oracle 호환](README.md)의 일부입니다.

Oracle에는 BEGIN이 없습니다. 트랜잭션은 첫 DML에서 시작해 `COMMIT`이나 `ROLLBACK`까지 갑니다. SQLite의 autocommit에는 이렇게 매핑합니다.

- INSERT·UPDATE·DELETE·MERGE·INSERT ALL은 autocommit 모드의 문장 하나로 실행되고, 끝에서 autocommit을 끕니다(`OP_AutoCommit 0`). 그래서 그 문장과 뒤의 변경이 열린 트랜잭션에 남습니다.
  - 이 코드는 실행할 때 `xq_ora_autocommit()`로 모드를 봅니다. 트랜잭션 밖에서 준비한 문장을 트랜잭션 안에서 실행해도(그 반대도) 맞게 동작합니다.
  - 실패한 DML은 그 문장만 되돌리고 트랜잭션을 열지 않습니다.
- `COMMIT`/`ROLLBACK`은 트랜잭션이 없으면 아무것도 하지 않습니다(SQLite는 오류).
- `SAVEPOINT`는 트랜잭션이 없으면 시작합니다.
- SELECT는 트랜잭션을 열지 않습니다.
- DDL은 Oracle과 달리 커밋하지 않습니다. 열린 트랜잭션 안의 DDL은 그 트랜잭션의 일부이고(SQLite의 DDL은 트랜잭션), 트랜잭션 밖의 DDL은 바로 커밋됩니다.
- 연결을 닫을 때 열린 트랜잭션은 되돌립니다(Oracle API와 같음, SQL*Plus는 종료할 때 커밋). xqlite 셸로 스크립트를 돌릴 때는 끝에 `COMMIT`을 쓰세요.
- DML의 `RETURNING`은 지원하지 않습니다. 이 꼬리 코드가 RETURNING 행보다 먼저 문장을 끝내기 때문이고, Oracle의 `RETURNING ... INTO`는 PL/SQL 구문이기도 합니다.
