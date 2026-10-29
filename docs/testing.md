# 테스트와 검증

xqlite의 호환성을 확인하는 테스트와 도구, 그리고 실행 방법입니다. 호환성은 주장이 아니라 테스트로 증명한다는 것이 원칙입니다.

## 목차

- [도구 한눈에 보기](#도구-한눈에-보기)
- [준비](#준비)
- [한 번에 전부: zig build check](#한-번에-전부-zig-build-check)
- [단위 테스트](#단위-테스트)
- [sqlite3 교차 검증](#sqlite3-교차-검증)
- [플래너 차등 테스트](#플래너-차등-테스트)
- [sqllogictest](#sqllogictest)
- [퍼징](#퍼징)
- [방언 차등 테스트](#방언-차등-테스트)
- [그 밖의 도구](#그-밖의-도구)
- [테스트 전략](#테스트-전략)

## 도구 한눈에 보기

모든 스크립트는 먼저 `zig build`를 해 두어야 합니다. `xqt`는 `zig build tools`로 빌드합니다([tools/xqt/README.md](../tools/xqt/README.md)). 셸·Python 스크립트는 `xqt`로 옮기는 중입니다.

| 도구 | 확인하는 것 | 기준 |
| --- | --- | --- |
| `zig build test` | 단위 테스트, 문서·예제의 이름, 전역 상태, 시드 퍼저 스모크 | — |
| `zig build check` | 아래 표의 대부분을 병렬로 한 번에: 단위 테스트, `xqt interop`, `xqt planner`, `fuzzcheck` (`-Dslt`, `-Dfuzz`로 더) | 아래와 같음 |
| `tools/interop-btree.sh` | 서로 쓴 테이블·인덱스를 읽고 수정, `integrity_check` 비교 | sqlite3 (`PATH`) |
| `xqt interop sql` | 같은 SQL을 두 엔진으로 실행, 결과·`integrity_check` 비교 | `SQLITE3` (3.54.1) |
| `xqt interop hot-journal` | 서로 남긴 핫 저널 복구 | `SQLITE3` (3.54.1) |
| `tools/interop-shell.sh` | `xqlite sql` 셸과 sqlite3 셸의 출력·오류·종료 코드, `.dump` 왕복 | `SQLITE3` (3.54.1) |
| `tools/interop-pragma.sh` | PRAGMA 결과 | `SQLITE3` (3.54.1) |
| `tools/interop-savepoint.sh` | SAVEPOINT·문장 롤백을 저널 모드·캐시 크기별로 비교 | `SQLITE3` |
| `tools/interop-wal.sh` | WAL 파일 상호 읽기, 체크포인트, 크래시 복구, 두 엔진 동시 접근, 스트레스 | `SQLITE3` (3.54.1) |
| `tools/interop-attach.sh` | 서로의 파일을 `ATTACH`해 읽고 쓰기, 여러 파일 트랜잭션, 커밋 도중 크래시와 super journal 복구 | `SQLITE3` (3.54.1), C 컴파일러(`CC`) |
| `tools/interop-analyze.sh` | 같은 데이터에서 같은 `sqlite_stat1` 행, 서로 분석한 DB의 실행 계획·`PRAGMA optimize` | `SQLITE3` (3.54.1) |
| `tools/interop-vacuum.sh` | 두 엔진이 `VACUUM`/`VACUUM INTO`한 파일의 바이트 비교, 셸의 `.backup`/`.save`/`.restore`, VACUUM 도중 크래시 복구 | `SQLITE3` (3.54.1), C 컴파일러(`CC`) |
| `tools/interop-pg.sh` | PostgreSQL 방언이 쓴 DB를 sqlite3가 검사하고 같은 행·스키마를 읽음 | sqlite3 (`PATH`) |
| `tools/interop-mariadb.sh` | MariaDB 방언이 쓴 DB를 sqlite3가 검사하고 같은 행·스키마를 읽음 | `SQLITE3` |
| `xqt planner` | 쿼리 결과·`EXPLAIN QUERY PLAN`·바이트코드 | `SQ` (3.54.1, 주석 없는 빌드) |
| `xqt slt` | sqllogictest | `--ref` (선택) |
| `xqlite fuzzcheck` | SQLite 퍼즈 코퍼스에서 크래시·메모리 누수·close 실패 | — |
| `zig build fuzz` | 시드 퍼저: `btree_model`, `btree_corrupt`, `ir_roundtrip` | — |
| `tools/dialect/pg-diff.sh` | PostgreSQL 방언을 실제 PostgreSQL 16과 차등 비교 | PostgreSQL 서버 |
| `tools/dialect/maria-diff.sh` | MariaDB 방언을 실제 MariaDB 11과 차등 비교 | MariaDB 서버 |
| `tools/gen-fixtures.sh` | `src/testdata`의 테스트용 DB 재생성 | sqlite3 |
| `tools/gen-superjournal-fixtures.sh` | `src/testdata/superjournal`(여러 파일 커밋 도중 죽은 sqlite3가 남긴 파일) 재생성 | `SQLITE3`, C 컴파일러(`CC`) |

## 준비

### 참고 소스

포팅 기준 SQLite 소스(현재 3.54.1)는 `ref/sqlite`에 받아 두고 참고합니다. `ref/`는 git에서 제외됩니다.

```sh
./tools/fetch-sqlite.sh     # ref/sqlite (SQLITE_VERSION, SQLITE_YEAR로 버전 변경)
./tools/fetch-slt.sh        # ref/sqllogictest (약 1.2GB)
```

`fuzzcheck`의 코퍼스(`ref/sqlite/test/fuzzdata*.db`)도 `ref/sqlite`에 들어 있습니다.

### 기준 sqlite3 셸

교차 검증 도구는 순정 sqlite3 셸과 결과를 비교합니다. 출력 형식이 버전마다 조금씩 다르므로 포팅 기준과 같은 3.54.1 셸을 쓰는 것이 좋습니다.

| 변수 | 쓰는 도구 | 기본값 |
| --- | --- | --- |
| `SQLITE3` | `interop-shell.sh`, `interop-pragma.sh`, `interop-wal.sh`, `interop-attach.sh`, `interop-analyze.sh`, `interop-vacuum.sh`, `bench.sh` | `/tmp/xq-sqlite-build/sqlite3`가 있으면 그것, 없으면 `PATH`의 `sqlite3` |
| `SQLITE3` | `interop-savepoint.sh`, `interop-mariadb.sh` | `PATH`의 `sqlite3` |
| `SQLITE3` | `xqt interop` (모든 모듈) | `/tmp/xq-sqlite-build/sqlite3`가 있으면 그것, 없으면 `PATH`의 `sqlite3` |
| `SQ` | `xqt planner` | `PATH`의 `sqlite3` |
| `XQ` | `xqt` | 이 저장소의 `zig-out/bin/xqlite` |

`interop-btree.sh`, `interop-pg.sh`는 `PATH`의 `sqlite3`를 씁니다. `xqt`에서는 같은 변수를 `--sqlite3`, `--sq`, `--xq` 옵션으로도 줄 수 있고, 옵션이 환경 변수보다 앞섭니다.

**`SQ`는 따로 빌드한 셸이어야 합니다.** sqlite3 셸의 기본 빌드는 `SQLITE_ENABLE_EXPLAIN_COMMENTS`를 켜는데, 이 옵션은 주석용 `OP_Noop`을 바이트코드에 끼워 넣습니다. 그래서 바이트코드를 비교하려면 이 옵션을 뺀 3.54.1 셸이 필요합니다. 아말감(`sqlite3.c`, `shell.c`)으로 다음처럼 빌드합니다.

```sh
clang -O1 -DSQLITE_DQS=0 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_STMTVTAB \
  -DSQLITE_ENABLE_BYTECODE_VTAB -DSQLITE_STRICT_SUBTYPE=1 \
  -o /tmp/sqref/sqlite3 shell.c sqlite3.c -lpthread -lm
```

같은 셸을 `SQLITE3`에도 쓸 수 있습니다. 가상 테이블 로그(`vtablog.txt`)용 빌드는 [tools/planner/README.md](../tools/planner/README.md)에 있습니다.

## 한 번에 전부: zig build check

```sh
SQ=/tmp/sqref/sqlite3 zig build check -Doptimize=ReleaseSafe
zig build check -Dslt=true      # sqllogictest도 (ref/sqllogictest, 몇 분)
zig build check -Dfuzz=true     # 시드 퍼저 셋을 무작위 시드로 한 번씩
```

다음을 모두 병렬로 돌리고, 하나라도 실패하면 실패합니다.

- `zig build test`의 모든 것과 `xqt` 자체의 단위 테스트
- `xqt interop`: 옮긴 모든 interop 모듈
- `xqt planner`: `vtablog.txt`를 뺀 모든 케이스 파일. 알려진 차이(`tools/planner/known-failures.list`)는 실패로 세지 않습니다.
- `xqlite fuzzcheck`: `ref/sqlite/test/fuzzdata1.db`..`fuzzdata8.db`를 파일마다 프로세스 하나로

`-Doptimize`는 단위 테스트, `xqt interop`, `xqt planner`가 쓰는 빌드를 정합니다. 오래 걸리는 fuzzcheck, sqllogictest(`-Dslt`), 시드 퍼저(`-Dfuzz`)는 `-Doptimize`와 상관없이 ReleaseSafe 빌드로 돕니다. 같은 빌드의 xqlite와 크래시 shim을 `xqt`에 넘기므로 `zig build`를 따로 할 필요가 없습니다. 아직 옮기지 않은 셸 스크립트(`interop-btree.sh` 등)는 들어 있지 않습니다.

## 단위 테스트

```sh
zig build test
```

다음을 함께 실행합니다.

- 모듈의 단위 테스트
- `docs/names_test.zig`: [docs/zig-api.md](zig-api.md)가 쓰는 이름(`xqlite.Value`, `Db.lastError` ...)과 `examples/`가 쓰는 이름이 모듈에 있는지 검사합니다.
- `tools/globals_test.zig`: `src/`에 허용 목록 밖의 가변 전역이 없는지 검사합니다.
- 모든 [시드 퍼저](#시드-퍼저)의 스모크 실행(고정 시드, 적은 이벤트)

모듈의 단위 테스트는 Debug로 빌드합니다. 다만 `src/pager/journal.zig`의 테스트(저널 체크섬)는 ReleaseSafe로 한 번 더 돌립니다. Zig 0.17이 super journal 이름의 체크섬 루프를 최적화 빌드에서만 잘못 컴파일했기 때문입니다. 모듈 전체를 최적화해 돌리려면 `zig test -O ReleaseSafe -lc src/root.zig`를 씁니다.

## sqlite3 교차 검증

같은 작업을 xqlite와 sqlite3로 하고 결과와 파일을 비교합니다. 파일을 서로 넘겨 읽고 쓰므로 파일 포맷 호환도 함께 확인합니다.

```sh
zig build
./tools/interop-btree.sh
zig build tools
zig-out/bin/xqt interop sql hot-journal     # 이름 없이: 옮긴 모듈 전부
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-shell.sh
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-pragma.sh
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-savepoint.sh
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-wal.sh
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-attach.sh
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-analyze.sh
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-vacuum.sh
./tools/interop-pg.sh
SQLITE3=/tmp/sqref/sqlite3 ./tools/interop-mariadb.sh
```

| 스크립트 | 자세한 내용 |
| --- | --- |
| `interop-btree.sh` | xqlite가 만든 테이블·인덱스를 sqlite3가 검사하고, sqlite3가 만든 DB를 xqlite가 수정합니다. auto-vacuum(full, incremental) DB에서도 반복합니다. |
| `xqt interop sql` | 어느 쪽이 쓴 DB에서든 같은 문장이 같은 결과를 내고 `integrity_check`를 통과해야 합니다. |
| `xqt interop hot-journal` | 커밋 중에 죽은 xqlite의 핫 저널을 sqlite3가 되돌리고, 그 반대도 확인합니다. |
| `interop-shell.sh` | 모든 출력 모드, 헤더, nullvalue, 구분자, `.tables`/`.schema`/`.indexes`/`.dump`, 오류의 표준 출력·표준 오류·종료 코드를 비교합니다. xqlite의 `.dump`로 sqlite3에서 DB를 다시 만듭니다. |
| `interop-pragma.sh` | 각 PRAGMA의 결과 행을 비교합니다. 헤더를 바꾸는 PRAGMA(page_size, auto_vacuum, user_version, journal_mode ...) 뒤에는 `integrity_check`도 봅니다. |
| `interop-savepoint.sh` | SAVEPOINT / RELEASE / ROLLBACK TO와 도중에 실패하는 문장을 저널 모드마다, 스필이 일어나는 작은 캐시로 비교합니다. |
| `interop-wal.sh` | 체크포인트되지 않은 `-wal`의 상호 읽기, 체크포인트 모드, 페이지 크기 512..65536, 크래시 복구, 두 엔진 프로세스의 동시 접근과 무작위 스트레스(`STRESS_TXNS`, 기본 3000)를 확인합니다. |
| `interop-attach.sh` | 두 엔진이 서로 쓴 파일을 `ATTACH`해 바꾸고 행과 `integrity_check`를 비교합니다. 붙인 데이터베이스를 쓰는 스크립트(PRAGMA, `sqlite_schema`, TEMP 트리거, 뷰, `DETACH`, 오류)의 출력이 같은지 봅니다. 세 파일에 쓰는 트랜잭션을 저널 모드(DELETE, PERSIST, TRUNCATE)마다 한쪽이 커밋하고 다른 쪽이 읽습니다. 그 커밋 도중 파일을 바꾸는 지점마다 한쪽을 죽이고, 다른 쪽이 세 파일을 모두 이전 행이나 모두 새 행으로 복구하는지 확인합니다. |
| `interop-analyze.sh` | 30개가 넘는 테이블(스키마 해시의 가장 큰 버킷 배열)과 부분·식·NOCASE·UNIQUE·WITHOUT ROWID 인덱스가 있는 같은 DB를 두 엔진이 각각 `ANALYZE`해서 `sqlite_stat1` 행이 rowid까지 같은지, `analysis_limit`에서도 같은지 봅니다. 그다음 서로 분석한 DB를 읽어 자기가 분석한 DB와 같은 실행 계획이 나오는지, 데이터를 바꾼 뒤 `PRAGMA optimize`가 같은 행을 쓰는지 확인합니다. |
| `interop-vacuum.sh` | 롤백 저널·auto-vacuum(FULL, INCREMENTAL)·WAL DB(어느 엔진이 만든 것이든)를 두 엔진이 같은 문장으로 `VACUUM`해서 파일이 바이트 단위로 같은지 봅니다. 문장은 `page_size`(512..65536)와 `auto_vacuum` 변경, 저널 모드를 섞습니다. DB에는 빈 자리가 있는 테이블, UNIQUE 인덱스, 오버플로 페이지, WITHOUT ROWID 테이블, AUTOINCREMENT, `sqlite_stat1`, 뷰, 트리거가 있습니다. `VACUUM INTO`(URI의 `reserve=N` 포함)와 셸의 `.backup`·`.save`·`.restore`(페이지 크기가 다른 대상 포함)도 같은 바이트를 쓰는지, 서로의 결과가 `integrity_check`를 통과하는지 봅니다. 마지막으로 VACUUM 도중 파일·저널·WAL을 바꾸는 지점마다 한쪽을 죽이고, 다른 쪽이 VACUUM 전이나 후의 파일(WAL 모드는 같은 행)로 복구하는지 확인합니다. |
| `interop-pg.sh` | PostgreSQL 방언으로 쓴 DB(STRICT 테이블, CHECK, identity 시퀀스, `xq_catalog`/`xq_sequence`, 뷰, 인덱스)를 확인합니다. |
| `interop-mariadb.sh` | MariaDB 방언으로 쓴 DB(STRICT 테이블, 이름 있는 CHECK, DEFAULT·생성 열, `AUTO_INCREMENT`, `"t$i"` 인덱스, 뷰, `xq_catalog`)를 확인합니다. sqlite3에 없는 엔진 함수(`xq_*`)를 쓰는 식은 xqlite 안의 테스트가 확인합니다. |

크래시는 두 가지 방법으로 만듭니다.

- `interop-wal.sh`: 오류를 주입하는 VFS(`src/vfs/crash.zig`)를 씁니다. N번째 쓰기에서 프로세스를 바로 끝내 전원 차단을 흉내 내고, 선택하면 그 쓰기를 절반만 기록합니다. `xqlite` 명령이 `$XQLITE_TEST_CRASH`를 받을 때만 설치하고, 라이브러리는 쓰지 않습니다.
- `xqt interop hot-journal`: `xqlite crash-write FILE BYTE`가 모든 페이지를 덮어쓴 뒤 커밋 1단계에서 끝나 핫 저널을 남깁니다.
- `interop-attach.sh`, `interop-vacuum.sh`: xqlite는 `$XQLITE_TEST_CRASH`(`db:N`, `journal:N`, `wal:N`)로, sqlite3는 스크립트가 `CC`로 빌드해 미리 올리는 라이브러리(`interop-attach.sh`는 `tools/crashshim.c`, macOS `DYLD_INSERT_LIBRARIES`, Linux `LD_PRELOAD`)로 죽입니다. 이 라이브러리는 이름이 정한 접미사로 끝나는 파일의 N번째 변경(쓰기, 자르기, 삭제)에서 프로세스를 끝냅니다. 빌드할 수 없거나 sqlite3에 닿지 않으면 그 단계만 건너뜁니다.

## 플래너 차등 테스트

같은 DB에서 같은 SQL을 xqlite와 sqlite3로 실행해 결과, `EXPLAIN QUERY PLAN`, `EXPLAIN` 바이트코드를 비교합니다. 플래너는 C 코드를 그대로 옮긴 포팅이라 바이트코드까지 같아야 합니다.

```sh
zig build
zig build tools
SQ=/tmp/sqref/sqlite3 zig-out/bin/xqt planner tools/planner/planner.txt -v
SQ=/tmp/sqref/sqlite3 zig-out/bin/xqt planner      # vtablog.txt를 뺀 전부, 블록과 쿼리까지 병렬로
```

케이스 파일 형식, 케이스 모음(`vtab.txt`, `json.txt`, `window.txt`, `wal.txt`, `attach.txt`, `vacuum.txt` ...), 무작위 케이스 생성기, `SQOPT`·`XQ_WHERETRACE` 같은 옵션은 [tools/planner/README.md](../tools/planner/README.md)에 있습니다.

## sqllogictest

[sqllogictest](https://sqlite.org/sqllogictest/)를 `xqlite slt`(C 실행기의 Zig 포팅)로 돌립니다.

```sh
./tools/fetch-slt.sh
zig build tools -Doptimize=ReleaseSafe
zig-out/bin/xqt slt ref/sqllogictest/test     # 전부 병렬로, 실패를 원인별로 묶음
```

C 실행기와의 대조, WAL 모드 실행 같은 옵션은 [tools/slt/README.md](../tools/slt/README.md)에 있습니다.

## 퍼징

| 도구 | 입력 | 찾는 것 |
| --- | --- | --- |
| `xqlite fuzzcheck` | SQLite의 퍼즈 코퍼스 | 크래시, 메모리 누수, close 실패 |
| `btree_model` | 무작위 삽입·교체·삭제, 커밋 또는 롤백 | 트랜잭션마다 모델과 다른 내용 |
| `btree_corrupt` | 유효한 DB의 무작위 바이트를 덮어쓴 파일 | 크래시, 실패한 assert, 누수(오류는 괜찮음) |
| `ir_roundtrip` | 무작위 구문 트리 IR | render ≡ lower 위반 |

### fuzzcheck

SQLite `fuzzcheck`의 포팅입니다.

```sh
zig-out/bin/xqlite fuzzcheck ref/sqlite/test/fuzzdata*.db
```

| 옵션 | 뜻 |
| --- | --- |
| `--start N` | 각 DB의 처음 N개 케이스를 건너뜀. 크래시가 나면 케이스 번호가 출력되므로 그다음부터 이어 돌릴 때 씀 |
| `-v`, `--verbose` | 실행하는 케이스를 하나씩 출력. 세그폴트처럼 패닉 핸들러를 거치지 않는 크래시를 찾을 때 씀 |
| `--sqlid N`, `--dbid N` | 그 id의 스크립트, 그 id의 DB 이미지만 실행 |
| `--timeout MS` | 케이스를 MS 밀리초 뒤에 중단(기본 10000) |

### 시드 퍼저

```sh
zig build fuzz -Doptimize=ReleaseSafe -- btree_model [SEED] [--events N]
zig build fuzz -Doptimize=ReleaseSafe -- btree_corrupt [SEED]
zig build fuzz -Doptimize=ReleaseSafe -- ir_roundtrip [SEED] [--events N]
zig build fuzz -- smoke      # 모든 퍼저를 고정 시드로 짧게
```

- 같은 시드면 같은 동작을 재현합니다.
- 시드를 생략하면 무작위로 골라 먼저 출력합니다.
- 커밋 해시(40자리)도 시드로 받습니다.
- `zig build test`는 모든 시드 퍼저를 고정 시드로 짧게 돌립니다.

### ir_roundtrip

[render ≡ lower 계약](architecture.md#render와-lower의-계약)을 검사합니다.

**만드는 것.** `src/ir/gen.zig`가 시드로 고정된 작은 스키마 위에서 무작위 트리를 만듭니다.

- 스키마: INTEGER/REAL/TEXT/BLOB/타입 없는 열
- 경계값 행: NULL, 0, -0.0, i64 최솟값/최댓값, 1e308, 빈 문자열, 대소문자 섞인 문자열, 비ASCII, 블롭
- 의미 노드: `cast` 모든 방식, `concat` 두 NULL 정책, `div` 세 종류, BINARY/NOCASE/RTRIM 비교, `like`의 대소문자·이스케이프, SQLite 내장·엔진·방언 함수, `coerce`, 불리언, 바인딩된 파라미터
- 질의 구조: CASE, IN, BETWEEN, 서브쿼리, 집계, GROUP BY, 윈도우, `NULLS FIRST/LAST` 정렬, LIMIT/OFFSET, 복합 질의, CTE

어떤 노드가 얼마나 자주 나올지는 실행마다 무작위로 정합니다(스웜 테스트, 64 이벤트마다 새로).

**비교하는 것.** 이벤트마다 새 메모리 DB에서, 방언 d마다 다음 세 결과가 같아야 합니다.

| | 결과 |
| --- | --- |
| A | lower(t)를 d에서 실행한 행 |
| B | d에서 렌더링한 render(t)를 SQLite 프론트엔드가 각 방언에서 컴파일해 실행한 행 |
| C | 트리로 `CREATE VIEW`를 만들어 각 방언에서 `SELECT * FROM v`한 행. 기대값은 lower(`SELECT * FROM (t)`) |

- 값의 타입과 값이 정확히 같아야 합니다. 실수는 비트 단위로 비교합니다.
- ORDER BY가 없으면 다중집합으로 비교합니다.
- 둘 다 오류면 결과 코드가 같아야 합니다.
- render를 두 번 하면 같은 텍스트여야 합니다.
- 파라미터는 lower에서는 바인딩하고, render(파라미터를 받지 않음)에는 그 값의 리터럴로 넣습니다.

**테이블 이벤트.** CHECK·DEFAULT·생성 열이 있는 테이블을 트리로 만듭니다. lower한 INSERT(`DEFAULT` 항목, 빠뜨린 열)와 SQLite 텍스트 INSERT로 행을 넣고, 저장된 행과 CHECK 결과가 같은 값으로 lower한 질의가 계산한 것과 같은지 봅니다.

불일치하면 시드, 이벤트 번호, 렌더링한 텍스트, 재현 명령을 출력합니다. 찾은 문제의 회귀 테스트는 `src/ir/roundtrip_test.zig`에 있습니다.

**일부러 검사하지 않는 것.**

- `identity_default`: 계약의 예외이고, 시퀀스는 읽을 때마다 증가합니다.
- 결정적이지 않은 함수
- 방언 d에서 렌더링한 텍스트를 제3의 방언 e가 읽을 때, e가 가린 SQLite 내장 함수 이름이 텍스트에 그대로 있는 경우. 계약은 SQLite 방언과 d만 다루고, e에서는 그 이름이 e의 함수를 뜻합니다(예: PostgreSQL 뷰의 `concat()`은 MariaDB 연결에서 MariaDB의 `CONCAT()`).
- 상수가 파라미터와 다르게 해석되는 ORDER BY/GROUP BY가 있는 트리의 파라미터 비교. 정수 상수는 열 번호이기 때문입니다.
- 뷰가 서브쿼리와 달리 실행 중 오류가 나는 식을 계산하지 않는 경우(sqlite3도 같음)

## 방언 차등 테스트

같은 케이스를 실제 서버와 `xqlite sql`(해당 방언)에서 실행해 행, 열 이름(행이 있는 결과), `ERROR:` 줄을 비교합니다. 서버는 기본으로 podman 컨테이너를 씁니다.

### PostgreSQL

```sh
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
zig build
tools/dialect/pg-diff.sh [cases-file]        # 기본: tools/dialect/pg-cases.txt
```

- 서버 접속 명령은 `PG_PSQL`로 바꿉니다(기본 `podman exec -i xq-pg psql -U postgres`).
- 케이스마다 빈 `public` 스키마에서 시작합니다.
- psql의 불리언 `t`/`f`는 방언이 돌려주는 1/0으로 맞춰 비교합니다.

### MariaDB

```sh
podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
zig build
tools/dialect/maria-diff.sh [cases-file]     # 기본: tools/dialect/maria-cases.txt
```

- 서버 접속 명령은 `MARIA_CLIENT`로 바꿉니다(기본 `podman exec -i xq-maria mariadb -uroot`).
- 케이스마다 `main`이라는 빈 데이터베이스(xqlite의 스키마 이름)에서, collation `utf8mb4_general_ci`로 시작합니다.
- 소수부가 있는 수는 끝의 0을 떼고 비교합니다. MariaDB의 DECIMAL은 `3.5000`, 방언의 REAL은 `3.5`로 출력하기 때문입니다.

방언별 결과와 알려진 차이는 [PostgreSQL 호환](postgres.md), [MariaDB 호환](mariadb.md)에 있습니다.

## 그 밖의 도구

| 도구 | 하는 일 |
| --- | --- |
| `tools/gen-fixtures.sh` | `src/testdata`의 테스트용 DB를 sqlite3 셸로 다시 만듭니다. 내용은 결정적이고 테스트가 같은 식으로 검사합니다. |
| `tools/gen-superjournal-fixtures.sh` | 세 파일 트랜잭션을 커밋하던 sqlite3를 `tools/crashshim.c`로 네 지점(super journal을 지우기 직전, 지운 뒤 저널을 하나도·하나·둘 지운 때)에서 죽여 남은 파일을 `src/testdata/superjournal`에 저장합니다. `src/sql/attach_test.zig`가 xqlite로 복구해 봅니다. |
| `tools/bench.sh [workload...]` | 같은 작업을 xqlite와 sqlite3로 재고 비율을 출력합니다. `zig build -Doptimize=ReleaseFast` 뒤에 씁니다(`RUNS`, `ROWS`, `XQLITE`, `SQLITE3`). |
| `tools/gen-parser.sh` | SQLite 문법(`parse.y`)에서 `src/parse/grammar.zig`를 다시 만듭니다. `ref/sqlite`와 C 컴파일러가 필요합니다. |
| `tools/gen-opcodes.sh` | `src/vdbe/opcodes.zig`를 다시 만듭니다. `ref/sqlite`, tclsh, C 컴파일러가 필요합니다. |

## 테스트 전략

| 영역 | 방법 | 지금 |
| --- | --- | --- |
| SQLite | [sqllogictest](https://www.sqlite.org/sqllogictest/)와 SQLite TCL 테스트 스위트 일부를 포팅 | sqllogictest 실행기, 플래너 케이스 일부를 TCL 테스트에서 뽑음 |
| 파일 포맷 | 순정 SQLite와 xqlite가 서로 만든 DB 파일을 교차로 읽고 쓰고 `PRAGMA integrity_check`로 검증 | `xqt interop`, `interop-*.sh` |
| PostgreSQL / MariaDB / MSSQL | 같은 쿼리를 실제 서버와 xqlite에서 실행해 비교(differential testing), 각 DB의 regression test에서 필요한 부분을 가져옴 | `pg-diff.sh`, `maria-diff.sh` |
| 퍼징 | 파서, 레코드 디코더, B-Tree 페이지 디코더, IR | `fuzzcheck`, 시드 퍼저 |
| 크래시 복구 | 오류를 주입하는 VFS로 쓰기 도중 전원 차단을 흉내 냄 | `src/vfs/crash.zig`(`interop-wal.sh`), `xqlite crash-write`(`xqt interop hot-journal`) |
