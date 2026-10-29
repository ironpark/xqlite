# 쿼리 플래너 차등 테스트

같은 데이터베이스에서 같은 SQL을 xqlite와 sqlite3 3.54.1로 실행해 세 가지를 비교합니다.

- `res`: 쿼리 결과. DML이면 실행 뒤 `.dump`와 `PRAGMA integrity_check` 결과까지 비교합니다.
- `eqp`: `EXPLAIN QUERY PLAN` 트리
- `code`: `EXPLAIN` 바이트코드(addr, opcode, p1~p5). 트리거 서브프로그램은 xqlite의 EXPLAIN이 아직 나열하지 않으므로 메인 프로그램만 비교합니다.

플래너는 C 코드를 그대로 옮긴 포팅이라 바이트코드까지 같아야 합니다.

다른 테스트 도구는 [테스트와 검증](../../docs/testing.md)에 정리되어 있습니다.

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
zig build tools
SQ=/tmp/sqref/sqlite3 zig-out/bin/xqt planner tools/planner/planner.txt -v
SQ=/tmp/sqref/sqlite3 zig-out/bin/xqt planner -k code tools/planner/window.txt
SQ=/tmp/sqref/sqlite3 zig-out/bin/xqt planner     # vtablog.txt를 뺀 전부
zig-out/bin/xqt planner gen hard 1 8 15 > /tmp/c1.txt && SQ=/tmp/sqref/sqlite3 zig-out/bin/xqt planner /tmp/c1.txt
```

- `xqt planner`(예전 `diff.py`)는 파일마다 실패한 쿼리를 `FAIL[종류] block N: 쿼리`로, 마지막에 `N queries; failures: code=…, eqp=…, res=…`를 출력합니다. `-k res,eqp,code`로 비교할 것을 고르고, `-v`는 다른 부분을 보여 줍니다(바이트코드는 unified diff). 블록의 셋업을 모두 병렬로 만든 뒤, 쿼리를 블록 안에서도 8개씩 나눠 각자 블록 디렉터리의 사본에서 병렬로 돌립니다. 엔진은 쿼리마다 60초가 지나면 `TIMEOUT`이 됩니다.
- `--known FILE`은 알려진 차이의 목록(`known-failures.list`, 줄마다 `케이스파일 종류 쿼리`)입니다. 목록에 있는 실패는 `KNOWN`으로 출력하고 종료 코드에 넣지 않으며, 다시 같아진 항목은 `FIXED`로 실패합니다. `zig build check`가 이 목록을 씁니다.
- 케이스 파일은 `----` 줄로 블록을 나눕니다. 블록마다 `==` 줄 앞은 스키마와 데이터(기준 셸로 한 번 만들어 둠), 뒤는 한 줄에 쿼리 하나입니다.
- `vtab.txt`는 가상 테이블 케이스입니다. 두 엔진에 다 있는 모듈만 씁니다: `pragma_*` 테이블 값 함수(`sqlite_schema`와 조인, 숨은 열 제약, ORDER BY, LIMIT), 셸이 등록하는 `generate_series`, `bytecode()`/`tables_used()`, `sqlite_schema`에 써 넣은 가상 테이블(xConnect, DDL)과 오류("no such module", "may not be modified" 등). 일부는 SQLite TCL 테스트(`tabfunc01.test`, `pragma5.test` 등)에서 뽑았습니다.
- `vtablog.txt`는 `ext/misc/vtablog.c`(모듈 메서드 호출을 모두 출력하는 가상 테이블)로 xBestIndex 입력, xUpdate 인자, 트랜잭션·세이브포인트 호출 순서를 비교합니다. vtablog.c를 넣어 빌드한 sqlite3가 필요하고, xqlite는 `XQ_VTABLOG=1`일 때 셸에 Zig 포팅(`src/ext/vtablog.zig`)을 등록합니다. 아말감(`make sqlite3.c shell.c`)으로 다음처럼 빌드합니다.

  ```sh
  cat > extra.c <<'C'
  #include "sqlite3.h"
  int sqlite3_vtablog_init(sqlite3*, char**, const void*);
  int vtablog_extra_init(const char *z){
    (void)z;
    return sqlite3_auto_extension((void(*)(void))sqlite3_vtablog_init);
  }
  C
  clang -O1 -DSQLITE_DQS=0 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_STMTVTAB \
    -DSQLITE_ENABLE_BYTECODE_VTAB -DSQLITE_STRICT_SUBTYPE=1 \
    -DSQLITE_EXTRA_INIT=vtablog_extra_init -DSQLITE_CORE \
    -o /tmp/sqref-vtablog/sqlite3 shell.c sqlite3.c ref/sqlite/ext/misc/vtablog.c extra.c -lpthread -lm
  XQ_VTABLOG=1 SQ=/tmp/sqref-vtablog/sqlite3 zig-out/bin/xqt planner tools/planner/vtablog.txt
  ```

  블록마다 가상 테이블을 하나만 둡니다. 스키마 해시를 도는 순서(연결을 닫을 때의 xDisconnect, integrity_check의 xIntegrity)가 SQLite의 해시와 다르기 때문입니다.
- 셋업 줄 중 `.`으로 시작하는 줄은 dot-command로 따로 넘깁니다(예: `.dbconfig defensive off`). `.each SQL` 줄은 블록의 모든 쿼리 앞에 같은 연결에서 `SQL`을 실행합니다(예: `.each ATTACH 'aux.db' AS aux`). 두 엔진은 블록마다 따로 둔 디렉터리에서 실행하므로 SQL의 상대 경로 파일은 그 안에 생깁니다. 쓰기가 있는 쿼리(SELECT/VALUES가 아니거나 `;`이 있는 쿼리)는 세 비교 모두 DB 사본에서 돌립니다. EXPLAIN도 첫 문장 뒤의 문장은 실제로 실행되기 때문입니다.
- EXPLAIN의 P4에 나오는 `vtab:주소`는 `vtab:PTR`로 바꿔서 비교합니다.
- `json.txt`는 JSON 함수 케이스입니다. SQLite TCL 테스트(`json1*.test`, `json50*.test`, `jsonb01.test`)에서 뽑은 쿼리와, 끝부분의 `json_each`/`json_tree` 블록(같은 테스트와 `join.test`, `join8.test`, `whereF.test`, `tabfunc01.test` 등에서 뽑은 쿼리, 조인·상관 인자·경로 인자·ORDER BY/LIMIT·JSONB 입력·오류를 다루는 쿼리)으로 이루어집니다.
- `attach.txt`는 `ATTACH`/`DETACH` 문장 자체(`sqlite_attach()`/`sqlite_detach()`를 부르는 `OP_Function`, `OP_Expire`)와 붙인 데이터베이스 위의 조인, DML, 트리거, 뷰, PRAGMA, `sqlite_schema` 케이스입니다. 스키마를 해시 순서로 도는 `integrity_check`와 `table_list`는 뺐습니다. 해시 순서가 SQLite와 다르기 때문입니다.
- `analyze.txt`는 `ANALYZE`와 `PRAGMA optimize` 케이스입니다. 모든 형태의 `ANALYZE`(데이터베이스, 테이블, 인덱스, TEMP, 오류)의 바이트코드와 `sqlite_stat1` 행, `analysis_limit`, sqlite3가 분석한 DB와 같은 연결에서 분석한 DB의 통계에 따라 달라지는 실행 계획, 직접 쓴 `unordered`·`sz=`·`noskipscan` 표시, 스키마 해시 순서가 드러나는 테이블 30여 개짜리 DB를 비교합니다.
- `vacuum.txt`는 `VACUUM`과 `VACUUM INTO`의 모든 형태(스키마 이름, INTO 식, TEMP, 오류)의 `OP_Vacuum` 바이트코드와, `page_size`·`auto_vacuum`을 바꾼 VACUUM 뒤의 `.dump`·`integrity_check`·PRAGMA 결과(롤백 저널, WAL, 붙인 DB)를 비교합니다. VACUUM이 행을 옮기는 전송 최적화(`INSERT INTO t1 SELECT * FROM t2`)가 쓰이는 경우와 쓰이지 않는 경우의 바이트코드도 비교합니다.
- `wal.txt`는 WAL PRAGMA(`journal_mode` 전환, 모드별 `wal_checkpoint`, `wal_autocheckpoint`) 케이스입니다. 롤백 저널 DB와 WAL DB에서 결과와 `OP_JournalMode`·`OP_Checkpoint` 바이트코드를 비교합니다.
- `window.txt`는 윈도우 함수 케이스입니다. SQLite TCL 테스트(`window*.test`)에서 뽑은 쿼리와, 뷰·서브쿼리·조인·복합 SELECT·DML 등 select.c와 맞물리는 경로를 다루는 쿼리로 이루어집니다.
- `xqt planner gen basic|hard SEED NBLOCKS NQUERIES`(예전 `gen-basic.py`, `gen-hard.py`)는 시드로 무작위 케이스를 만듭니다. 같은 인자면 예전 스크립트와 바이트까지 같은 케이스가 나옵니다(CPython의 `random.Random`을 그대로 옮김). `hard`는 ANALYZE 통계, 스킵 스캔, collation, 식·부분 인덱스, row value, 상관 서브쿼리, 중첩 조인, 트리거, 외래키를 다룹니다.
- `SQOPT=MASK`를 주면 기준 셸에서 `.testctrl optimizations MASK`로 해당 최적화를 끕니다. xqlite에 아직 없는 최적화를 빼고 비교할 때 씁니다.
- Debug 빌드에서는 `XQ_WHERETRACE=1`로 플래너가 만든 WhereLoop 목록을 SQLite 디버그 빌드의 `.wheretrace`와 같은 형식으로 출력합니다. 비용 계산이 어긋날 때 `-DSQLITE_DEBUG -DSQLITE_ENABLE_WHERETRACE`로 빌드한 sqlite3의 출력과 줄 단위로 비교하면 됩니다.
