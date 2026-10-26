# 쿼리 플래너 차등 테스트

같은 데이터베이스에서 같은 SQL을 xqlite와 sqlite3 3.54.1로 실행해 세 가지를 비교합니다.

- `res`: 쿼리 결과. DML이면 실행 뒤 `.dump`와 `PRAGMA integrity_check` 결과까지 비교합니다.
- `eqp`: `EXPLAIN QUERY PLAN` 트리
- `code`: `EXPLAIN` 바이트코드(addr, opcode, p1~p5). 트리거 서브프로그램은 xqlite의 EXPLAIN이 아직 나열하지 않으므로 메인 프로그램만 비교합니다.

플래너는 C 코드를 그대로 옮긴 포팅이라 바이트코드까지 같아야 합니다.

## 기준 셸

`sqlite3` 셸의 기본 빌드는 `SQLITE_ENABLE_EXPLAIN_COMMENTS`를 켜는데, 이 옵션은 주석용 `OP_Noop`을 끼워 넣습니다. 바이트코드를 비교하려면 이 옵션을 뺀 3.54.1 셸이 필요합니다. 아말감(`sqlite3.c`, `shell.c`)이 있으면 다음처럼 빌드합니다.

```sh
clang -O1 -DSQLITE_DQS=0 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_STMTVTAB \
  -DSQLITE_ENABLE_BYTECODE_VTAB -DSQLITE_STRICT_SUBTYPE=1 \
  -o /tmp/sqref/sqlite3 shell.c sqlite3.c -lpthread -lm
```

## 사용법

```sh
zig build
SQ=/tmp/sqref/sqlite3 tools/planner/diff.py tools/planner/planner.txt -v
tools/planner/gen-hard.py 1 8 15 > /tmp/c1.txt && SQ=/tmp/sqref/sqlite3 tools/planner/diff.py /tmp/c1.txt
```

- 케이스 파일은 `----` 줄로 블록을 나눕니다. 블록마다 `==` 줄 앞은 스키마와 데이터(기준 셸로 한 번 만들어 둠), 뒤는 한 줄에 쿼리 하나입니다.
- `gen-basic.py`, `gen-hard.py`는 시드로 무작위 케이스를 만듭니다. `gen-hard.py`는 ANALYZE 통계, 스킵 스캔, collation, 식·부분 인덱스, row value, 상관 서브쿼리, 중첩 조인, 트리거, 외래키를 다룹니다.
- `SQOPT=MASK`를 주면 기준 셸에서 `.testctrl optimizations MASK`로 해당 최적화를 끕니다. xqlite에 아직 없는 최적화를 빼고 비교할 때 씁니다.
- Debug 빌드에서는 `XQ_WHERETRACE=1`로 플래너가 만든 WhereLoop 목록을 SQLite 디버그 빌드의 `.wheretrace`와 같은 형식으로 출력합니다. 비용 계산이 어긋날 때 `-DSQLITE_DEBUG -DSQLITE_ENABLE_WHERETRACE`로 빌드한 sqlite3의 출력과 줄 단위로 비교하면 됩니다.
