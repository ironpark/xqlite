# 테스트와 검증

xqlite의 호환성을 확인하는 테스트와 도구, 그리고 실행 방법입니다. 호환성은 주장이 아니라 테스트로 증명한다는 것이 원칙입니다.

## 목차

- [도구 한눈에 보기](#도구-한눈에-보기)
- [준비](#준비)
- [xqt 공통 옵션](#xqt-공통-옵션)
- [한 번에 전부: zig build check](#한-번에-전부-zig-build-check)
- [병렬화와 실행 시간](#병렬화와-실행-시간)
- [단위 테스트](#단위-테스트)
- [sqlite3 교차 검증](#sqlite3-교차-검증)
- [플래너 차등 테스트](#플래너-차등-테스트)
- [sqllogictest](#sqllogictest)
- [SQLite의 TCL 테스트](#sqlite의-tcl-테스트)
- [퍼징](#퍼징)
- [방언 차등 테스트](#방언-차등-테스트)
- [WebAssembly](#webassembly)
- [C API](#c-api)
- [그 밖의 도구](#그-밖의-도구)
- [테스트 전략](#테스트-전략)

## 도구 한눈에 보기

xqlite 밖에서 돌리는 테스트 도구는 모두 Zig로 쓴 `xqt` 하나입니다(셸·Python 스크립트는 없습니다). `zig build tools`가 `zig-out/bin/xqt`, 크래시 shim(`zig-out/lib/libcrashshim.dylib`, Linux는 `.so`), sqlite3용 확장(`zig-out/lib/libxqlite_ext.dylib`, [sqlite3용 확장](extension.md)), 그리고 xqlite를 빌드합니다. 구조와 검사를 추가하는 방법은 [tools/xqt/README.md](../tools/xqt/README.md)에 있습니다.

```sh
zig build tools
zig-out/bin/xqt help            # 명령과 공통 옵션
zig-out/bin/xqt help planner    # 명령별 옵션
zig-out/bin/xqt list            # interop 모듈, 플래너 케이스 파일, 쓰는 바이너리
```

| 명령 | 확인하는 것 | 기준 |
| --- | --- | --- |
| `zig build test` | 단위 테스트, 문서·예제의 이름, 전역 상태, 시드 퍼저 스모크 | — |
| `zig build check` | 아래의 대부분을 병렬로 한 번에: 단위 테스트, `xqt` 자체의 테스트, `xqt interop`, `xqt planner`, `xqt dialect-diff pg`(기록과), `fuzzcheck` (`-Dslt`, `-Dfuzz`, `-Dfast`로 더) | 아래와 같음 |
| `xqt interop [NAME...]` | DB 파일, SQL 결과, 셸 출력, PRAGMA, WAL, 크래시 복구를 sqlite3와 교차 비교. 모듈은 [sqlite3 교차 검증](#sqlite3-교차-검증) | `--sqlite3`/`SQLITE3` (3.54.1) |
| `xqt planner [FILE...]` | 쿼리 결과·`EXPLAIN QUERY PLAN`·바이트코드 | `--sq`/`SQ` (3.54.1, 주석 없는 빌드) |
| `xqt planner gen basic\|hard ...` | 무작위 플래너 케이스 생성 | — |
| `xqt slt [PATH...]` | sqllogictest | `--ref` (선택) |
| `xqt tcl [PATH...]` | SQLite의 TCL 테스트(`ref/sqlite/test`)를 libxqlite3와 SQLite에 링크한 같은 테스트 픽스처로 돌려 테스트 케이스마다 분류 | 같은 하네스의 SQLite 3.54.1 (`zig build testfixture`) |
| `xqlite fuzzcheck` | SQLite 퍼즈 코퍼스에서 크래시·메모리 누수·close 실패 | — |
| `zig build fuzz` | 시드 퍼저: `btree_model`, `btree_corrupt`, `btree_sqlite3`, `ir_roundtrip`, `ir_ext`(`$XQT_EXT`의 확장으로) | — |
| `xqt dialect-diff pg [--live\|--record]` | PostgreSQL 방언을 PostgreSQL 18의 출력과 차등 비교. 기본은 저장소의 기록(`tools/dialect/pg-expected`)과 | 기록; `--live`·`--record`는 PostgreSQL 서버(podman) |
| `xqt dialect-diff mariadb --live` | MariaDB 방언을 실제 MariaDB 11과 차등 비교 | MariaDB 서버(podman) |
| `xqt dialect-diff mssql --live` | MSSQL(T-SQL) 방언을 실제 SQL Server(Azure SQL Edge, 엔진 15.0)와 차등 비교 | SQL Server 서버(podman)와 go-sqlcmd |
| `xqt dialect-diff oracle --live` | Oracle 방언을 실제 Oracle Database 23ai와 차등 비교 | Oracle 서버(podman) |
| `xqt wire-diff pg [--live\|--record]` | psql로 PostgreSQL 18과 `xqlite serve --pg`를 차등 비교(메타 명령, 클라이언트·ORM의 카탈로그 질의). 기본은 기록과 | psql 18(호스트, 없으면 podman); `--live`·`--record`는 PostgreSQL 서버(podman) |
| `xqt wire-diff pg --regress` | PostgreSQL 18 회귀 테스트 일부를 `xqlite serve --pg`에서 돌려 문장별 통과율 | psql 18(호스트, 없으면 podman) |
| `xqt bench [WORKLOAD...]` | 같은 작업의 xqlite·sqlite3 실행 시간 | `--sqlite3`/`SQLITE3` |
| `zig build test-wasi` | wasm32-wasi 단위 테스트(wasmtime)와 `xqt wasi` | wasmtime, `--sqlite3`/`SQLITE3` |
| `xqt wasi [--wasm PATH]` | WASI 빌드의 SQL 결과, 저널·WAL, 크래시 복구, 방언 | sqlite3, 네이티브 xqlite(`--xq`), wasmtime |
| `zig build wasm-example` | 브라우저용 모듈을 Node.js에서 (`examples/wasm/node.mjs`) | node |
| `xqt gen fixtures\|opcodes` | `src/testdata`의 테스트용 DB, `opcodes.zig` 재생성 | `PATH`의 sqlite3(fixtures) |
| `xqt gen superjournal [DIR]` | `src/testdata/superjournal`(여러 파일 커밋 도중 죽은 sqlite3가 남긴 파일) 재생성 | `--sqlite3`/`SQLITE3`, 크래시 shim |
| `zig build test-capi` | C 프로그램으로 C ABI(`libxqlite3`, 정적·공유) 검사. sqlite3용 확장을 올리는 것도 | — |
| `zig build ext` | sqlite3용 확장 `libxqlite_ext`([sqlite3용 확장](extension.md)). `xqt interop ext`가 씀 | — |
| `zig build check-matrix` | 방언 없이, 그리고 방언 하나씩 빌드한 엔진 다섯 가지(`-Ddialects=none`, `postgres`, `mariadb`, `mssql`, `oracle`이 빌드하는 것)를 한 빌드에서 병렬로: 구성마다 단위 테스트(엔진·CLI·서버), 정적 라이브러리의 C API 검사, 그 구성의 확장으로 `xqt interop`, 그 방언의 기록된 `dialect-diff`. 방언과 상관없는 것(fuzzcheck, planner, 패키지)은 `check`에만 있음. `zig build check check-matrix`로 함께 | — |
| `zig build test-minimal` | 방언·확장을 모두 뺀 엔진(`-Ddialects=none -Dext=none`)으로 `tools/minimal_test.zig` | — |
| `zig build capi-fast` | ReleaseFast 정적 `libxqlite3`로 C 검사와 `tools/capi/bench.c`를 8번씩 실행 | — |
| `zig build capi-shell` | SQLite의 `shell.c`를 `libxqlite3`에 링크해 스모크 스크립트 실행 | 아말감 `shell.c` |
| `zig build capi-sortbench` | 정렬 벤치마크(`tools/capi/sortbench.c`)를 SQLite와 ReleaseFast `libxqlite3`에서 돌려 시간과 결과 순서 비교 | 아말감 `sqlite3.c` |
| `zig build bench-btree` | 엔진 없이 B-tree 커서의 삽입·탐색·스캔·삭제 시간(`pkg/storage/bench/btree.zig`) | — |
| `xqt fetch sqlite\|slt\|tcl` | `ref/sqlite`, `ref/sqllogictest` 내려받기, `ref/tcl`에 Tcl 8.6 빌드 | — |

## 준비

### 참고 소스

포팅 기준 SQLite 소스(현재 3.54.1)는 `ref/sqlite`에 받아 두고 참고합니다. `ref/`는 git에서 제외됩니다.

```sh
zig build tools
zig-out/bin/xqt fetch sqlite    # ref/sqlite (SQLITE_VERSION, SQLITE_YEAR로 버전 변경)
zig-out/bin/xqt fetch slt       # ref/sqllogictest (약 1.2GB, git clone --depth 1; SLT_REPO로 저장소 변경)
zig-out/bin/xqt fetch tcl       # ref/tcl: Tcl 8.6.17을 소스에서 빌드(SHA-256 확인, 시스템 C 컴파일러, 약 1분)
```

`--dest DIR`로 다른 곳에 받을 수 있습니다. 새 트리를 다 받은 뒤에야 대상을 바꿉니다. `fuzzcheck`의 코퍼스(`ref/sqlite/test/fuzzdata*.db`)도 `ref/sqlite`에 들어 있습니다.

### 기준 sqlite3 셸

교차 검증 도구는 순정 sqlite3 셸과 결과를 비교합니다. 출력 형식이 버전마다 조금씩 다르므로 포팅 기준과 같은 3.54.1 셸을 씁니다. 이 셸은 직접 빌드하지 않아도 됩니다. `build.zig.zon`이 SQLite 3.54.1 아말감(`sqlite-amalgamation-3540100.zip`)을 해시로 고정한 lazy 의존성 `sqlite`로 두고, `zig build tools`(그리고 `zig build check`)가 처음 필요할 때 한 번 내려받아(Zig 전역 캐시) 셸 두 개를 빌드합니다.

| 셸 | 설치 위치 | 컴파일 옵션 | 쓰는 곳 |
| --- | --- | --- | --- |
| 기준 셸 | `zig-out/bin/sqlite3-ref` | SQLite의 configure·make 빌드와 같음(`pragma_compile_options`가 같음). `SQLITE_HAVE_ZLIB`만 뺌(셸의 `.archive`만 씀) | `SQLITE3`: `interop`, `bench`, `wasi`, `gen superjournal`, `btree_sqlite3` 퍼저 |
| 플래너 셸 | `zig-out/bin/sqlite3-planner` | `SQLITE_ENABLE_EXPLAIN_COMMENTS` 없이 `-DSQLITE_DQS=0 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_STMTVTAB -DSQLITE_ENABLE_BYTECODE_VTAB -DSQLITE_STRICT_SUBTYPE=1` | `SQ`: `planner` |

**플래너 셸이 따로 있는 이유.** sqlite3 셸의 기본 빌드는 `SQLITE_ENABLE_EXPLAIN_COMMENTS`를 켜는데, 이 옵션은 주석용 `OP_Noop`을 바이트코드에 끼워 넣습니다. 그래서 바이트코드를 비교하려면 이 옵션을 뺀 셸이 필요합니다.

xqlite를 의존성으로 쓰는 프로젝트의 빌드는 SQLite를 내려받지 않습니다(루트 프로젝트일 때만). `SQLITE3`, `SQ`(또는 `--sqlite3`, `--sq`)를 주면 그 셸을 씁니다. 가상 테이블 로그(`vtablog.txt`)용 셸은 아말감에 없는 `ext/misc/vtablog.c`가 필요해 여전히 직접 빌드합니다([tools/planner/README.md](../tools/planner/README.md)).

## xqt 공통 옵션

공통 옵션은 `--` 앞이라면 명령 앞뒤 어디에 와도 됩니다.

| 옵션 | 뜻 |
| --- | --- |
| `-j N` | 동시에 돌릴 검사 수(기본: CPU 수). `-j 1`이면 모두 차례로 돕니다 |
| `-v` | 통과한 검사의 로그도 출력. `planner`에서는 다른 부분을 출력 |
| `--keep` | 실패한 검사의 임시 디렉터리를 남기고 경로를 출력 |
| `--xq PATH` | 시험할 xqlite |
| `--sqlite3 PATH` | 교차 검증의 기준 sqlite3 |
| `--sq PATH` | 플래너의 기준 sqlite3 |
| `--crashshim PATH` | `tools/crashshim.c`를 빌드한 preload 라이브러리 |
| `--ext PATH` | sqlite3용 확장(`zig build ext`) |

### 바이너리 고르기

바이너리마다 명령줄 옵션, 환경 변수, 기본값 순서로 정합니다.

| 바이너리 | 옵션 | 환경 변수 | 기본값 | 쓰는 명령 |
| --- | --- | --- | --- | --- |
| xqlite | `--xq` | `XQ` | 이 저장소의 `zig-out/bin/xqlite` | 모든 명령 |
| sqlite3 | `--sqlite3` | `SQLITE3` | `zig-out/bin/sqlite3-ref`가 있으면 그것, 없으면 `PATH`의 `sqlite3` | `interop`(모든 모듈), `bench`, `gen superjournal` |
| 플래너 기준 | `--sq` | `SQ` | `zig-out/bin/sqlite3-planner`가 있으면 그것, 없으면 `PATH`의 `sqlite3` | `planner`. `SQLITE_ENABLE_EXPLAIN_COMMENTS` 없이 빌드한 3.54.1이어야 합니다([위](#기준-sqlite3-셸)) |
| 크래시 shim | `--crashshim` | `XQT_CRASHSHIM` | 이 저장소의 `zig-out/lib/libcrashshim.dylib`(Linux는 `.so`) | `interop attach`, `interop vacuum`, `gen superjournal` |
| sqlite3용 확장 | `--ext` | `XQT_EXT` | 이 저장소의 `zig-out/lib/libxqlite_ext.dylib`(Linux는 `.so`) | `interop ext`(sqlite3에 `-cmd .load`로 올림) |

예전 스크립트는 `PATH`의 `sqlite3`를 쓰는 것과 `SQLITE3`를 쓰는 것이 섞여 있었습니다. 이제 모든 interop 모듈이 같은 sqlite3 하나를 씁니다. `XQLITE` 변수는 없어졌고 `--xq`나 `XQ`를 씁니다. `xqt list`가 실제로 고른 바이너리를 보여 줍니다.

다음은 이 규칙 밖에서 외부 프로그램을 씁니다.

| 명령 | 쓰는 것 |
| --- | --- |
| `gen fixtures` | `PATH`의 `sqlite3`, 또는 `--fixtures-sqlite3 PATH`. 커밋한 fixture는 헤더에 3.44.4라는 버전이 들어 있으므로 `SQLITE3`를 따르지 않습니다 |
| `gen opcodes` | `zig cc`(lemon), `zig run`(변환기), `tclsh`. `ZIG`로 zig 바이너리를 바꿉니다 |
| `dialect-diff` | podman 컨테이너의 클라이언트(`PG_PSQL`, `MARIA_CLIENT`, `ORA_SQLPLUS`) |
| `wire-diff` | psql을 `sh -c`로 돌리는 명령(`PG_WIRE_EXEC`), 컨테이너에서 본 호스트(`PG_WIRE_HOST`), xqlite가 받는 주소(`PG_WIRE_LISTEN`), 회귀 테스트 디렉터리(`PG_REGRESS_DIR`) |
| `fetch slt` | `git` |
| `fetch tcl` | `sh`, `make`, C 컴파일러(`$CC`, 기본 `cc`) |
| `tcl` | `zig build testfixture`의 두 픽스처(`--fixture`, `--ref`), `ref/tcl`의 Tcl 스크립트 라이브러리(`--tcl-library`) |

### 그 밖의 환경 변수

| 변수 | 쓰는 곳 | 뜻 |
| --- | --- | --- |
| `STRESS_TXNS` | `interop wal` | 스트레스 실행의 프로세스당 트랜잭션 수(기본 3000, 프로세스 4개) |
| `RUNS`, `ROWS` | `bench` | 실행 횟수(기본 3, 가장 빠른 것을 씀), 테이블 행 수(기본 1000000). `--runs`, `--rows`와 같음 |
| `SQOPT` | `planner` | 기준 셸에서 `.testctrl optimizations MASK`로 끌 최적화 |
| `XQ_VTABLOG`, `XQ_WHERETRACE` | `planner` | [tools/planner/README.md](../tools/planner/README.md) |
| `SQLITE_VERSION`, `SQLITE_YEAR`, `SLT_REPO` | `fetch` | 내려받을 SQLite 릴리스, sqllogictest 저장소 |
| `XQT_SEED` | `interop ext` | `generated calls`의 시드(기본은 고정) |
| `XQT_EXT_RECORD` | `interop ext` | 있으면 `tools/ext/abi-*.out`을 xqlite의 출력으로 다시 기록(함수를 더했을 때만, [ABI 규칙](extension.md#abi-규칙)) |

## 한 번에 전부: zig build check

```sh
zig build check -Doptimize=ReleaseSafe
zig build check -Dslt=true      # sqllogictest도 (ref/sqllogictest, 몇 분)
zig build check -Dfuzz=true     # 시드 퍼저를 무작위 시드로 한 번씩
zig build check -Dfast=true     # capi-fast도 (약 90초)
```

기준 셸 두 개는 빌드한 것을 넘깁니다([기준 sqlite3 셸](#기준-sqlite3-셸)). `SQLITE3`, `SQ`를 주면 그것을 씁니다.

다음을 모두 병렬로 돌리고, 하나라도 실패하면 실패합니다.

- `zig build test`의 모든 것과 `xqt` 자체의 단위 테스트
- `zig build test-capi`: C 프로그램으로 C ABI 검사
- `zig build test-minimal`: 방언·확장을 모두 뺀 엔진의 테스트
- `xqt interop`: 모든 interop 모듈(`ext`에는 같은 빌드의 확장을 `--ext`로 넘김)
- `xqt planner --known tools/planner/known-failures.list`: `vtablog.txt`를 뺀 모든 케이스 파일
- `xqt dialect-diff pg`: PostgreSQL 방언이 빌드에 들어 있으면 기록해 둔 PostgreSQL의 출력과 비교(서버 없이, [방언 차등 테스트](#방언-차등-테스트))
- `xqlite fuzzcheck`: `ref/sqlite/test/fuzzdata1.db`..`fuzzdata8.db`를 파일마다 프로세스 하나로
- `-Dslt=true`이면 `xqt slt ref/sqllogictest/test`
- `-Dfuzz=true`이면 `btree_model`, `btree_corrupt`, `btree_sqlite3`, `ir_roundtrip`, `ir_ext`(같은 빌드의 확장으로)를 무작위 시드로 한 번씩
- `-Dfast=true`이면 `zig build capi-fast`: ReleaseFast 정적 라이브러리로 C 검사와 삽입 벤치마크를 여러 번

플래너 부분 때문에 `SQ`에 [주석 없는 기준 셸](#기준-sqlite3-셸)을 주어야 합니다. 주지 않으면 `PATH`의 `sqlite3`와 비교하므로 바이트코드가 다릅니다. `SQLITE3`도 같은 방식으로 받습니다.

`-Doptimize`는 단위 테스트, `xqt interop`, `xqt planner`가 쓰는 빌드를 정합니다. 오래 걸리는 fuzzcheck, sqllogictest(`-Dslt`), 시드 퍼저(`-Dfuzz`)는 `-Doptimize`와 상관없이 따로 만든 ReleaseSafe 빌드로 돕니다. `xqt`에는 같은 빌드의 xqlite(`--xq`), 크래시 shim(`--crashshim`), 확장(`--ext`, interop만)을 넘기고 저장소 루트에서 실행하므로 `zig build tools`를 따로 할 필요가 없습니다. 서버에 붙는 `xqt dialect-diff --live`/`--record`, psql이 필요한 `xqt wire-diff`, 그리고 `xqt bench`는 들어 있지 않습니다.

### known-failures.list

`tools/planner/known-failures.list`는 플래너가 아직 sqlite3와 다른 것으로 알려진 쿼리의 목록입니다. 한 줄에 `케이스파일 종류 쿼리` 하나이고, 쿼리는 케이스 파일에 쓴 그대로입니다. 지금은 비어 있습니다.

- 항목 하나는 실패 하나와 정확히 맞아야 합니다(파일, 종류, 쿼리).
- 목록에 있는 실패는 `KNOWN`으로 출력하고 실패로 세지 않습니다.
- 목록에 있지만 더는 실패하지 않는 항목은 `FIXED`로 출력하고 실행을 실패시킵니다. 고쳤으면 그 줄을 지웁니다.
- 목록에 없는 실패는 모두 실행을 실패시킵니다.

## 병렬화와 실행 시간

`xqt`의 명령은 검사(check)들을 `-j N`개(기본: CPU 수)의 작업 풀에서 돌립니다. 검사마다 자기 임시 디렉터리에서 돌고, 끝나는 순간 결과(`ok`, `FAIL`과 로그, `skip`과 이유)를 한 덩어리로 출력하므로 출력이 섞이지 않습니다. 마지막 요약은 실패한 검사를 추가한 순서대로 나열하고, 실패가 하나라도 있으면 종료 코드는 1입니다.

검사를 나누는 방식은 명령마다 다릅니다.

| 명령 | 나누는 단위 |
| --- | --- |
| `interop` | 예전 스크립트의 독립된 단계와 반복이 각각 검사 하나입니다(모두 182개). 모든 모듈의 검사가 한 풀에서 섞여 돕니다. 앞 단계의 파일을 이어 쓰던 단계는 그 파일을 같은 문장으로 다시 만들어 의존을 끊고, `pg`·`mariadb`처럼 여러 검사가 같은 DB에서 시작하면 한 번 만든 DB의 사본을 나눠 씁니다(`interop/base_db.zig`). |
| `interop` 안의 큰 검사 | 작은 실행이 많은 검사(`vacuum`의 문장별 사례, `attach`·`vacuum`의 크래시 지점마다 한 번씩)는 검사 안에서 다시 병렬로 돌립니다(`interop/parts.zig`). 검사 하나가 동시에 돌리는 수는 `-j`의 1/8(올림)입니다. `pragma`는 문장 목록을 덩어리로 나눠 덩어리마다 DB 사본에서 돌립니다. |
| `planner` | 두 단계입니다. 먼저 모든 파일의 블록 셋업을 병렬로 만들고, 그다음 쿼리를 블록 안에서도 8개씩 나눠 각자 블록 디렉터리의 사본에서 돌립니다. 엔진은 쿼리마다 60초가 지나면 `TIMEOUT`입니다. |
| `slt` | 스크립트마다 `xqlite slt` 프로세스 하나 |
| `dialect-diff` | PostgreSQL은 작업자 데이터베이스 최대 8개(`-j`와 케이스 수로 제한)에서 케이스를 병렬로 돌립니다. MariaDB는 케이스가 데이터베이스 이름 `main`을 쓰므로 서버에서는 한 번에 한 케이스씩, xqlite 쪽만 병렬로 돕니다. Oracle도 케이스가 사용자 XQ의 스키마 하나를 쓰므로 서버에서는 한 번에 한 케이스씩 돕니다. |
| `wire-diff` | PostgreSQL 쪽은 `dialect-diff`처럼 작업자 데이터베이스(`xqt_wire_N`, 최대 8개)에서, xqlite 쪽은 케이스마다 새 `xqlite serve`(포트 0)와 새 DB 파일로 병렬로 돕니다. `--regress`는 테스트마다 서버 하나 |
| `bench` | 서로 느려지지 않도록 언제나 하나씩 차례로 |
| `gen` | 이름을 준 생성기를 동시에. `superjournal`은 따로 |

`zig build check`는 각 단계(단위 테스트, `xqt interop`, `xqt planner`, fuzzcheck 코퍼스 8개 ...)를 Zig 빌드 시스템이 병렬로 돌립니다.

방언 구성마다 `zig build check -Ddialects=X`를 따로 돌리면, 구성마다 엔진 전체를 다시 빌드하고 방언과 상관없는 검사(fuzzcheck와 그 ReleaseSafe 빌드, planner)도 되풀이합니다. `check-matrix`는 다섯 구성을 한 빌드 그래프에서 병렬로 컴파일하고, 방언에 따라 달라지는 검사만 구성마다 돌립니다. 소스 한 줄을 고친 뒤 잰 시간입니다(Debug, CPU 20개).

| 실행 | 시간 |
| --- | --- |
| `check -Ddialects=X`를 다섯 구성 차례로 | 835초 (구성마다 약 165초) |
| `check-matrix` | 191초 |
| `check` | 173초 |
| `check`와 다섯 구성 따로(예전의 전체 검사) | 약 1008초 |
| `check check-matrix` (한 빌드) | 367초 |

예전의 차례로 도는 스크립트와 `xqt`의 실행 시간입니다(Debug xqlite, CPU 20개).

| 도구 | 예전 | xqt |
| --- | --- | --- |
| interop 전부 | 약 258초 (스크립트 12개) | 35초 (검사 182개) |
| `vacuum` | 133초 | 약 15초 |
| `wal` | 54초 | 약 25초. 프로세스 4개의 스트레스 실행이 가장 오래 걸림 |
| `attach` | 28초 | 약 5초 |
| `savepoint` | 23초 | 약 5초 |
| `planner`, 모든 파일 | 502초 | 66초 |

플래너 시간에는 `vtab.txt`의 `generate_series('a')` 케이스를 `LIMIT 5`로 묶은 것도 들어 있습니다. 그 전에는 두 엔진 모두 60초 시간 초과까지 돌았습니다.

## 단위 테스트

```sh
zig build test
```

다음을 함께 실행합니다.

- 모듈의 단위 테스트
- VFS(`pkg/vfs`), 스토리지(`pkg/storage`), sqlparse(`pkg/sql/parse`) 패키지와 `std`만 쓰는 패키지(공용 base, uuid, sqllex, decimal, datetime, json, regex, pgtext: `build.zig`의 `leaf_pkgs`)의 단위 테스트. 엔진 모듈과 다른 모듈이라 모듈의 테스트에 들어가지 않으므로 따로 빌드해 돌립니다(`vfsTests()`, `storageTests()`, `sqlparseTests()`, `leafTests()`). sqllex의 테스트는 방언들의 규칙을 흉내 낸 `Spec`으로 스캐너의 경계(닫히지 않은 따옴표와 주석, 중첩 주석, `$$` 따옴표, `1e`·`.5`·`0x`·`1_000`·`123abc`)를 봅니다. sqlparse의 테스트는 장난감 방언으로 두 토큰 공급원의 커서(앞보기, 되감기, eof, 키워드 순서열, 목록)와 오류 훅을 봅니다. B-tree, 페이저, WAL, 저널, 페이지 캐시의 테스트는 스토리지 패키지에 있습니다. `zig build test-pkg`는 이것들(과 ReleaseSafe 저널 테스트)만 엔진 없이 돌립니다.
- `docs/names_test.zig`: [docs/zig-api.md](zig-api.md)가 쓰는 이름(`xqlite.Value`, `Db.lastError` ...)과 `examples/`가 쓰는 이름이 모듈에 있는지 검사합니다.
- `tools/globals_test.zig`: `src/`(그리고 `pkg/vfs/src`, `pkg/storage/src`, `pkg/base/src`, `pkg/uuid/src`, `pkg/sql/lexer/src`, `pkg/sql/parse/src`, `pkg/{decimal,datetime,json,regex,pgtext}/src`, `tools/xqt`)에 허용 목록 밖의 가변 전역이 없는지 검사합니다.
- 모든 [시드 퍼저](#시드-퍼저)의 스모크 실행(고정 시드, 적은 이벤트)

모듈의 단위 테스트는 Debug로 빌드합니다. 다만 `pkg/storage/src/pager/journal.zig`의 테스트(저널 체크섬)는 ReleaseSafe로 한 번 더 돌립니다. Zig 0.17이 super journal 이름의 체크섬 루프를 최적화 빌드에서만 잘못 컴파일했기 때문입니다. 모듈 전체를 최적화해 돌리려면 세 패키지를 모듈로 붙여 `zig test -O ReleaseSafe -lc --dep xqlite_vfs --dep xqlite_storage --dep xqlite_base -Mroot=src/root.zig --dep xqlite_vfs --dep xqlite_base -Mxqlite_storage=pkg/storage/src/root.zig -lc -Mxqlite_vfs=pkg/vfs/src/root.zig -Mxqlite_base=pkg/base/src/root.zig`를 씁니다.

VFS 패키지는 혼자서도 테스트할 수 있습니다. 엔진 없이 패키지 디렉터리에서 빌드합니다.

```sh
cd pkg/vfs
zig build test                          # 네이티브
zig build test -Dtest-filter=memdb      # 이름에 memdb가 든 테스트만
```

memdb의 테스트는 C 라이브러리의 `malloc`을 힙으로 쓰는 인스턴스(`Memdb(test_heap)`)로 돌고, 엔진의 할당자로 도는 memdb는 루트의 단위 테스트(`src/sql/serialize.zig`)와 C API 테스트가 검사합니다. wasm32-wasi에서는 루트의 `zig build test-wasi`가 패키지 테스트도 wasmtime으로 돌립니다.

스토리지 패키지도 같습니다. VFS와 공용 패키지에 경로 의존성이 있어서 그 디렉터리에서 바로 빌드됩니다. 루트에서는 `zig build test-pkg`가 세 패키지를 함께 돌립니다. 엔진 없이 컴파일하므로 B-tree나 페이저를 고칠 때 루트 테스트보다 훨씬 빨리 돕니다.

```sh
cd pkg/storage
zig build test                          # B-tree, 페이저, WAL, 저널 (저널은 ReleaseSafe로 한 번 더)
zig build test -Dtest-filter=wal        # 이름에 wal이 든 테스트만
```

## sqlite3 교차 검증

같은 작업을 xqlite와 sqlite3로 하고 결과와 파일을 비교합니다. 파일을 서로 넘겨 읽고 쓰므로 파일 포맷 호환도 함께 확인합니다.

```sh
zig build tools
zig-out/bin/xqt interop               # 모든 모듈
zig-out/bin/xqt interop wal attach    # 이름을 준 모듈만
zig-out/bin/xqt interop vacuum -j 4 --keep -v
```

| 모듈 | 자세한 내용 |
| --- | --- |
| `sql` | 어느 쪽이 쓴 DB에서든 같은 문장이 같은 결과를 내고 sqlite3의 `integrity_check`를 통과해야 합니다. |
| `hot-journal` | 커밋 중에 죽은 xqlite의 핫 저널을 sqlite3가 되돌리고, 트랜잭션 도중 죽인 sqlite3의 핫 저널을 xqlite가 되돌리는지 확인합니다. |
| `btree` | xqlite가 처음부터 만든 테이블·인덱스(`xqlite bt-fill`)를 sqlite3가 검사하고 같은 SQL로 만든 것과 내용을 비교합니다. sqlite3가 만든 DB를 xqlite가 수정(`bt-churn`)하고 같은 문장을 돌린 sqlite3와 비교합니다. 손상된 파일에서 xqlite의 `check`가 sqlite3와 같은 판정을 내는지 보고, auto-vacuum(full, incremental) DB에서 앞의 두 가지를 반복합니다(포인터 맵, full 모드는 빈 페이지가 남지 않아야 함). |
| `savepoint` | SAVEPOINT / RELEASE / ROLLBACK TO와 도중에 실패하는 문장을 저널 모드마다, 스필이 일어나는 작은 캐시로 비교하고 남은 DB의 `integrity_check`를 봅니다. |
| `pragma` | 각 PRAGMA의 결과 행을 비교합니다. 헤더를 바꾸는 PRAGMA(page_size, auto_vacuum, user_version, journal_mode ...) 뒤에는 두 엔진의 `integrity_check`도 봅니다. 문장마다 새 연결이라 설정이 이어지지 않고 파일을 바꾸지도 않으므로, 문장 목록을 덩어리로 나눠 각자 DB 사본에서 돌립니다. |
| `shell` | 모든 출력 모드, 헤더, nullvalue, 구분자, `.tables`/`.schema`/`.indexes`/`.dump`, 오류의 표준 출력·표준 오류·종료 코드를 비교합니다. xqlite의 `.dump`로 sqlite3에서 DB를 다시 만듭니다. 3.54.1보다 오래된 셸은 일부 출력 형식이 다릅니다. |
| `wal` | 체크포인트되지 않은 `-wal`의 상호 읽기와 체크포인트, WAL 모드에서 나가기, 체크포인트 모드와 결과 행, `wal_autocheckpoint`, 페이지 크기 512..65536, auto_vacuum, 크래시 복구(트랜잭션 도중, 커밋 도중, 커밋 프레임 직후, 체크포인트 도중), 두 엔진 프로세스의 동시 접근(다른 엔진의 커밋보다 오래 사는 스냅샷, 쓰기 경합과 busy_timeout, 읽는 쪽 옆의 체크포인트)과 프로세스 4개의 무작위 스트레스(`STRESS_TXNS`, 기본 3000)를 확인합니다. |
| `attach` | 두 엔진이 서로 쓴 파일을 `ATTACH`해 바꾸고 행과 `integrity_check`를 비교합니다. 붙인 데이터베이스를 쓰는 스크립트(PRAGMA, `sqlite_schema`, TEMP 트리거, 뷰, `DETACH`, 오류)의 출력이 같은지 봅니다. 세 파일에 쓰는 트랜잭션을 저널 모드(DELETE, PERSIST, TRUNCATE)마다 한쪽이 커밋하고 다른 쪽이 읽습니다. 그 커밋 도중 파일을 바꾸는 지점마다 한쪽을 죽이고, 다른 쪽이 세 파일을 모두 이전 행이나 모두 새 행으로 복구하고 super journal을 지우는지 확인합니다. |
| `vacuum` | 롤백 저널·auto-vacuum(FULL, INCREMENTAL)·WAL DB(어느 엔진이 만든 것이든)를 두 엔진이 같은 문장으로 `VACUUM`해서 파일이 바이트 단위로 같은지 봅니다. 문장은 `page_size`(512..65536)와 `auto_vacuum` 변경, 저널 모드를 섞습니다. DB에는 빈 자리가 있는 테이블, UNIQUE 인덱스, 오버플로 페이지, WITHOUT ROWID 테이블, AUTOINCREMENT, `sqlite_stat1`, 뷰, 트리거가 있습니다. `VACUUM INTO`(URI의 `reserve=N` 포함)와 셸의 `.backup`·`.save`·`.restore`(페이지 크기가 다른 대상 포함)도 같은 바이트를 쓰는지, 서로의 결과가 `integrity_check`를 통과하는지 봅니다. 마지막으로 VACUUM 도중 파일·저널·WAL을 바꾸는 지점마다 한쪽을 죽이고, 다른 쪽이 VACUUM 전이나 후의 파일(WAL 모드는 같은 행)로 복구하는지 확인합니다. |
| `analyze` | 30개가 넘는 테이블(스키마 해시의 가장 큰 버킷 배열)과 부분·식·NOCASE·UNIQUE·WITHOUT ROWID 인덱스가 있는 같은 DB를 두 엔진이 각각 `ANALYZE`해서 `sqlite_stat1` 행이 rowid까지 같은지, `analysis_limit`에서도 같은지 봅니다. 그다음 서로 분석한 DB를 읽어 자기가 분석한 DB와 같은 실행 계획이 나오는지, 데이터를 바꾼 뒤 `PRAGMA optimize`가 같은 행을 쓰는지 확인합니다. |
| `pg` | PostgreSQL 방언으로 쓴 DB(STRICT 테이블, CHECK, identity 시퀀스, `xq_catalog`/`xq_sequence`, 뷰, 인덱스)가 sqlite3의 무결성 검사를 통과하고, sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽는지 확인합니다. |
| `mariadb` | MariaDB 방언으로 쓴 DB(STRICT 테이블, 이름 있는 CHECK, DEFAULT·생성 열, `AUTO_INCREMENT`, `"t$i"` 인덱스, 뷰, `xq_catalog`)를 같은 방식으로 확인합니다. 엔진 함수(`xq_*`)를 쓰는 식은 `ext`가 확인합니다. |
| `mssql` | MSSQL 방언으로 쓴 DB(STRICT 테이블과 타입의 CHECK, identity 시퀀스, 계산 열, `NOCASE`/`BINARY` 열, 인덱스, 뷰, `xq_catalog`)를 같은 방식으로 확인합니다. 엔진 함수(`xq_tsql_*`)를 쓰는 식은 `ext`가 확인합니다. |
| `ext` | [sqlite3용 확장](extension.md#검증)을 올린 sqlite3로, 빌드에 있는 방언마다 엔진 함수의 CHECK·생성 열·식 인덱스·뷰·collation이 있는 DB를 검사(`integrity_check`; 확장 없는 sqlite3는 통과하지 못해야 함), 같은 결과, 방언 CHECK 위반의 같은 오류, sqlite3가 쓴 jsonb·배열·interval·numeric·boolean·identity 행을 xqlite가 `integrity_check`하고 방언으로 다시 읽음, 시스템 Python의 `sqlite3`로 같은 읽기(없으면 건너뜀). 그리고 기록된 ABI 케이스(`tools/ext/abi-*.sql`과 `.out`, 두 엔진 모두 기록과 같아야 함)와 생성한 호출(결정적인 `xq_*` 함수마다 가장자리 값의 인자로, 두 엔진의 결과와 오류 문구를 비교, `XQT_SEED`). 방언 모듈이 아니라 방언마다 검사를 넣고 뺍니다. |
| `oracle` | Oracle 방언으로 쓴 DB(Oracle 타입의 CHECK가 있는 STRICT 테이블, identity와 시퀀스, MERGE, `(+)` 조인 뷰, `xq_catalog`/`xq_sequence`, `COMMIT`으로 끝낸 암묵적 트랜잭션)를 같은 방식으로 확인하고, sqlite3가 타입 검사를 강제하는지, `ROLLBACK`이 암묵적 트랜잭션을 되돌리는지 봅니다. |

모듈별 차이 몇 가지입니다.

- `wal`의 `wal_autocheckpoint` 검사는 예전 스크립트에서 SQL을 표준 입력으로 넘겼지만 무시되어 실제로는 돌지 않았습니다. 이제 SQL을 실행합니다.
- `wal` 스트레스 실행의 SQL은 awk의 `rand()` 대신 `std.Random`으로 만듭니다. 시드와 문장의 비율은 같습니다.

크래시는 세 가지 방법으로 만듭니다.

- xqlite: 오류를 주입하는 VFS(`pkg/vfs/src/crash.zig`)를 씁니다. `$XQLITE_TEST_CRASH`(`db:N`, `journal:N`, `wal:N`, 뒤에 `:torn`이면 그 쓰기를 절반만 기록)를 받으면 N번째 쓰기에서 프로세스를 바로 끝내 전원 차단을 흉내 냅니다. `xqlite` 명령이 이 변수를 받을 때만 설치하고, 라이브러리는 쓰지 않습니다. `wal`, `attach`, `vacuum`이 씁니다. `hot-journal`은 `xqlite crash-write FILE BYTE`(모든 페이지를 덮어쓴 뒤 커밋 1단계에서 끝나 핫 저널을 남김)를 씁니다.
- sqlite3(`attach`, `vacuum`, `gen superjournal`): `zig build tools`가 빌드한 공유 라이브러리 `tools/crashshim.c`를 미리 올립니다(macOS `DYLD_INSERT_LIBRARIES`, Linux `LD_PRELOAD`). 이름이 정한 접미사로 끝나는 파일의 N번째 변경(쓰기, 자르기, 삭제)에서 프로세스를 끝냅니다. shim이 없거나 sqlite3에 닿지 않으면(시스템 sqlite3는 SIP 때문에 preload를 무시함) 그 검사만 건너뜁니다.
- 프로세스 죽이기: `hot-journal`과 `wal`은 트랜잭션이나 체크포인트 도중의 sqlite3 셸을 SIGKILL로 끝냅니다.

## 플래너 차등 테스트

같은 DB에서 같은 SQL을 xqlite와 sqlite3로 실행해 결과, `EXPLAIN QUERY PLAN`, `EXPLAIN` 바이트코드를 비교합니다. 플래너는 C 코드를 그대로 옮긴 포팅이라 바이트코드까지 같아야 합니다.

```sh
zig build tools
zig-out/bin/xqt planner tools/planner/planner.txt -v
zig-out/bin/xqt planner -k code tools/planner/window.txt
zig-out/bin/xqt planner --known tools/planner/known-failures.list   # vtablog.txt를 뺀 전부
zig-out/bin/xqt planner gen hard 1 8 15 > /tmp/c1.txt    # 무작위 케이스(basic 또는 hard)
```

`-k res,eqp,code`로 비교할 것을 고르고, `--known`은 [알려진 차이](#known-failureslist)를 받습니다. 케이스 파일 형식, 케이스 모음(`vtab.txt`, `json.txt`, `window.txt`, `wal.txt`, `pager.txt`, `utf16.txt`, `math.txt`, `attach.txt`, `vacuum.txt` ...), 무작위 케이스 생성기, `SQOPT`·`XQ_WHERETRACE` 같은 옵션은 [tools/planner/README.md](../tools/planner/README.md)에 있습니다.

## sqllogictest

[sqllogictest](https://sqlite.org/sqllogictest/)를 `xqlite slt`(C 실행기의 Zig 포팅)로 돌립니다.

```sh
zig build tools -Doptimize=ReleaseSafe
zig-out/bin/xqt fetch slt
zig-out/bin/xqt slt ref/sqllogictest/test             # 전부 병렬로, 실패를 원인별로 묶음
zig-out/bin/xqt slt ref/sqllogictest/test -- --wal    # -- 뒤는 xqlite slt의 인자
```

C 실행기와의 대조(`--ref`), WAL 모드 실행 같은 옵션은 [tools/slt/README.md](../tools/slt/README.md)에 있습니다.

## SQLite의 TCL 테스트

SQLite가 자기 저장소에서 쓰는 TCL 테스트(`ref/sqlite/test/*.test`, 1199개)를 C ABI(`libxqlite3`)에서 돌립니다. SQLite의 testfixture(`tclsqlite.c`와 `test*.c` 도우미)를 공개 API만으로 링크되게 다듬은 하네스를 `libxqlite3`와 SQLite 3.54.1 아말감에 각각 링크하고, 테스트 케이스마다 두 결과를 맞춰 **두 쪽 통과**, **두 쪽 실패**(하네스가 통과시킬 수 없는 것), **xqlite만 실패**(비호환)로 나눕니다.

```sh
zig build tools
zig-out/bin/xqt fetch sqlite                  # ref/sqlite (test/, src/test*.c, tool/lemon.c)
zig-out/bin/xqt fetch tcl                     # ref/tcl: Tcl 8.6.17 (시스템 tclsh는 8.5라 쓸 수 없음)
zig build testfixture                         # zig-out/bin/testfixture-xqlite, testfixture-sqlite
zig-out/bin/xqt -j 6 tcl --log tcl.log        # test/*.test 전부, 파일마다 시간 제한 300초
zig-out/bin/xqt tcl --set veryquick           # permutations.test의 veryquick 집합
zig-out/bin/xqt tcl ref/sqlite/test/where.test
```

- `xqt fetch tcl`은 Tcl 소스(`tcl-core8.6.17-src.tar.gz`)를 받아 고정한 SHA-256을 확인하고 시스템 C 컴파일러(`$CC`)로 `ref/tcl`에 빌드합니다. 시스템에는 아무것도 설치하지 않습니다.
- `zig build testfixture`는 `ref/sqlite`의 `parse.y`와 `vdbe.c`로 `parse.h`·`opcodes.h`를 만들고(lemon, `mkopcodeh.tcl`), 같은 소스를 두 라이브러리에 링크합니다. `libxqlite3`는 `-Dtcl-optimize`(기본 ReleaseSafe)로 빌드하므로 엔진의 패닉이 메시지와 위치를 남깁니다.
- 파일 하나와 픽스처 하나가 프로세스 하나이고, 자기 임시 디렉터리에서 돕니다. 결과는 파일마다 `ok`, `fail`, `error`(스크립트가 Tcl 오류로 멈춤), `crash`(패닉이면 메시지와 엔진의 함수), `timeout`이고, 끝에 남은 메모리(`Unfreed memory`)를 따로 셉니다.
- 요약은 xqlite에서만 실패한 테스트를 원인별(오류 메시지에서 숫자와 이름을 지운 것)·파일별로, xqlite에서만 멈춘 파일을 이유별로 묶습니다. `--log`는 파일마다의 상태와 실패한 테스트 전부(기대값과 실제값)를 씁니다.

하네스의 구성(어떤 `test*.c`를 그대로 쓰고, 무엇을 공개 API로 다시 쓰고, 무엇을 뺐는지)과 두 쪽 모두 실패하는 이유는 [tools/tcl/README.md](../tools/tcl/README.md)에 있습니다. 주된 것은 SQLITE_TEST 빌드의 코어만 세는 카운터(`sqlite_search_count` 등), SQLite testfixture의 1024바이트 기본 페이지, OOM·I/O 오류 주입, 페이저·B-tree 내부 명령입니다. 이 실행은 `zig build check`에 들어 있지 않습니다(약 20분, `-j 6`).

### 기준선

2026-11, `-j 6`, 시간 제한 300초, `--set all`(1186개 파일)의 결과입니다. 전체 목록은 `--log`로 다시 만들 수 있습니다.

| | xqlite | SQLite |
| --- | --- | --- |
| 끝까지 돈 파일(`ok` + `fail`) | 1163 (1012 + 151) | 1162 (1019 + 143) |
| 도중에 멈춘 파일(`error`, `crash`, `timeout`) | 17, 0, 6 | 18, 0, 6 |
| 통과한 테스트 케이스(출력 줄) | 785,275 | 792,934 |
| 실패한 테스트 케이스 | 4,792 | 4,709 |

시간 제한을 넘는 것은 두 쪽 모두 `crash.test`, `crash4.test`, `crash9.test`, `corruptC.test`, `savepoint4.test`, `walcrash3.test`처럼 반복이 많은 파일입니다. 통과한 케이스 수는 이 파일들이 300초 안에 몇 번 도는지에 따라 실행마다 크게 달라집니다(기기가 한가하면 200만을 넘음). 테스트 이름으로 맞추면 두 쪽 통과 776,437, 두 쪽 실패 4,592, xqlite만 실패 85, SQLite만 실패 2이고, xqlite에서 파일이 먼저 멈춰 돌지 못한 것이 8,007입니다(시간 제한까지 돌아 두 쪽이 돈 반복 수가 다른 파일).

러너는 fixture가 열 수 있는 파일 수를 4096으로 낮춥니다. `misc7.test`는 더 열 수 없을 때까지 파일을 여는데, 셸의 한도(macOS는 시스템 전체의 절반)를 물려주면 두 fixture가 시스템의 디스크립터를 다 써서 옆에서 도는 테스트가 `unable to open database file`로 실패하고, `misc7.test` 자신은 시간 제한을 넘깁니다. 낮춘 뒤에는 3초 안에 끝납니다.

처음 기준선(UTF-16, `journal_mode=MEMORY`, `locking_mode=EXCLUSIVE`가 없던 때)은 xqlite만 실패 2,209, xqlite에서만 멈춘 파일 43개였습니다. 그때 가장 많던 `not supported yet`(3,170줄)과, 임시 DB에서 `SQLITE_FULL` 뒤 인덱스가 깨지던 `tempfault-2-full.*`가 없어졌고, `sqlite3_exec()`가 문장마다 남은 SQL의 길이를 다시 재던 것(문장 수의 제곱 시간, `speed1.test`·`speed2.test`가 시간 초과)도 고쳤습니다. 그 뒤 하네스가 찾은 엔진 패닉과 크래시(echo 가상 테이블의 `INSERT`, `sqlite3_result_error16`의 정렬, backup의 페이지 수, 옛 `sqlite3_prepare()`가 스키마 변경 뒤 다시 컴파일하던 것, `GETMALLOC`의 재귀, `GETMUTEX`·`SQLITE_CONFIG_MUTEX`가 없던 것)를 고쳤습니다. 가끔 나던 `tableapi-3.7`(xqlite)의 크래시는 아래 공유 캐시 작업에서 고쳤고, 남은 것은 `thread004-1.2`(SQLite)입니다. 이어서 xqlite만 실패하던 다음 원인을 고쳤습니다.

- COLLATE가 붙은 ORDER BY의 복합 SELECT(`selectA`, `selectE`): 서브쿼리로 바꿀 때 만든 Select가 초기화되지 않아 `no such column`이 남
- 바인딩 값에 기대는 계획(`reprepare`, `index9`): `LIMIT ?`, `x=?`의 0·1 추정, LIKE 접두사, 부분 인덱스의 `WHERE x=?`가 다시 컴파일할 때 바인딩된 값을 보고, 값이 바뀌면 문장이 만료됨(`sqlite3VdbeGetBoundValue()`, `smimask`)
- DELETE·UPDATE의 `INDEXED BY`(`indexedby`, `where9`), 트리거가 고정된 커서의 행을 옮기면 `SQLITE_CONSTRAINT_PINNED`(`OP_CursorLock`, `conflict3`), 임포스터 테이블 표시(`expridx1`)와 식 인덱스 항목을 찾지 못한 `OP_IdxDelete`의 재탐색(`sqlite3VdbeFindIndexKey()`)
- C ABI: UTF-16 값의 NUL·짝 없는 서로게이트(`bind`, `tkt-3fe897352e`), `SQLITE_UTF16_ALIGNED` collation(`utf16align`), 다른 인코딩으로만 정의된 collation(`enc2`), `sqlite3_db_cacheflush()`(`cacheflush`), `SQLITE_FCNTL_PRAGMA`(`pragma-19`), `PRAGMA collation_list`의 순서, `SQLITE_TESTCTRL_PENDING_BYTE`(`mmap1`)
- 기본 VFS(os_unix.c의 나머지, [C API의 기본 VFS](c-api.md#기본-vfs)): `"unix-excl"`(`unixexcl`, `sysfault`), 바꿀 수 있는 시스템 호출 표(`syscall`, `sysfault`, `oserror`의 `sqlite3_log()` 기록까지), 파일 제어 `PERSIST_WAL`(`walpersist`)·`POWERSAFE_OVERWRITE`와 URI `psow`(`zerodamage`)·`CHUNK_SIZE`·`SIZE_HINT`(`chunksize`, `fallocate`)·`HAS_MOVED`(`pager4`: 옮겨진 데이터베이스는 `SQLITE_READONLY_DBMOVED`)·`EXTERNAL_READER`·`LOCKSTATE`·`LAST_ERRNO`·`TEMPFILENAME`, 페이저의 URI `nolock`·`immutable`과 `SQLITE_IOCAP_IMMUTABLE`(`nolock`), 읽기 전용 `-shm`(`readonly_shm`, `walro`, `walro2`), 기본 VFS 파일의 `SQLITE_FCNTL_FILE_POINTER`(`shmlock`, `superlock`, `mmapwarm`, `external_reader`), main.c의 `JOURNAL_POINTER`·`DATA_VERSION`(`dataversion1`)·`RESERVE_BYTES`(`reservebytes`)·`RESET_CACHE`. 대상 14개 파일의 xqlite만 실패는 공유 캐시의 `e_uri-11.*` 9개를 빼고 148개(멈춘 파일 5개 포함)에서 0개가 되었습니다. 남은 것은 아래의 `filectrl-1.5`입니다. 데이터베이스를 열고 닫기를 되풀이할 때 닫기를 미룬 파일 서술자를 다시 쓰고(`findReusableFd()`, `readonly-1.3`), 잠금 없는 `"unix-none"` VFS(`shared6-2.*`)도 있습니다. `sysfault`는 SQLite보다 시스템 호출을 덜 불러 오류 주입 반복 수가 적습니다(1287과 1354, 모두 통과).

- 공유 캐시([C API의 공유 캐시](c-api.md#공유-캐시)): 연결마다의 핸들 `Btree`와 파일의 `BtShared`를 나누고, 테이블 잠금(`OP_TableLock`과 그것을 넣는 `sqlite3TableLock()` 15곳, BLOB 증분 I/O의 `OP_TableLock`), 스키마 잠금(`database schema is locked`), 공유 스키마, `PRAGMA read_uncommitted`, 캐시의 뮤텍스를 옮겼습니다(`thread005` 499개, `shared*`, `incrblob2`, `tkt2854`, `pragma3`, `e_uri-11.*`, `sharedlock`, `shared_err`). 그러면서 `sqlite3VdbeSwap()`이 SQL 텍스트를 바꿔 두던 것(tclsqlite의 문장 캐시가 해제된 텍스트를 가리켜 `tableapi-3.7`이 가끔 크래시)과, `empty_result_callbacks`에서 `sqlite3_get_table()`이 빈 결과를 행으로 세던 것(`tableapi-3.*`)도 고쳤습니다.

- 그다음 묶음(xqlite만 실패 165개 → 89개, 새로 실패한 것 없음):
  - 오류 문구: 실행 중 ROLLBACK된 문장은 `SQLITE_ABORT_ROLLBACK`(`abort due to ROLLBACK`, `misc8`, `savepoint7`, `trans3`), ALTER ADD COLUMN의 다시 읽기가 내부 함수를 모른다고 알림(`alter-22.2`, C의 `init.busy==2`), `OP_IdxDelete`의 인덱스 손상은 메시지 없이 `SQLITE_CORRUPT_INDEX`(`dbfuzz001`), VFS가 메시지와 함께 돌려준 `SQLITE_NOMEM`(`pragma-19.3`, `sqlite3ApiExit()`는 `IOERR_NOMEM`만 메모리 부족으로 봄)
  - `SQLITE_DBCONFIG_RESET_DATABASE`와 `writable_schema`를 B-tree가 연결에서 읽음(`resetdb`, `incrvacuum-17.1`), `SQLITE_LIMIT_SCHEMA`(`createtab-4.1`), `SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS`와 스키마의 루트 페이지 검사(`corruptL-15.2`), 스키마 해시의 C 순서로 도는 `table_list`·`integrity_check`·`foreign_key_check`·REINDEX(`pragma4-6.2`, `corrupt2-5.1`), 페이저·WAL의 난수가 `sqlite3_randomness()`의 PRNG(`rowid-12.4`)
  - 파일 열기: 저널 이름이 `mxPathname`을 넘으면 `SQLITE_CANTOPEN`(`pager1-16.1`), 읽기 전용으로만 열리는 hot journal(`pager1.4.7.2`, `tkt3457`), 커밋 때 저널이 없어진 것(`SQLITE_IOERR_DELETE_NOENT`, `pager1-33.1`), `SQLITE_OPEN_NOFOLLOW`(`symlink`), memdb의 truncate가 `SQLITE_CORRUPT`(`memdb1-830`), `sqlite3_system_errno()`, VFS가 없을 때의 `sqlite3_sleep()`(`capi3`), 섹터 크기에 맞춘 기본 페이지 크기(`io-5`), `"unix-dotfile"`·`"unix-flock"` VFS(`lock5`)
  - 콜백: collation을 더할 때는 문장을 만료하지 않음(`schema-7`), `result_text`의 소멸자를 결과가 끝날 때 부름(`func-12.1`), `sqlite3_aggregate_count()`(`func-23.1`), MISUSE에서도 함수의 소멸자를 부름(`func3-4.2`), `%n`(`printf-14.2`), `expanded_sql`의 NUL(`trace3-8.7`), 뷰의 열 이름을 구할 때 잡은 테이블 참조를 바로 놓음(`view3`)
  - 값과 기타: REAL 기본값의 48비트 정수는 정수로 인덱스에 들어감(`intreal-7.2x`), `table_column_metadata`의 `rowid`(`colmeta-101`), `close_v2` 뒤의 prepare가 MISUSE(`close-1.4.3`), 긴 리터럴이 `string or blob too big`(`sqlite3ErrorToParser()`, `sqllimits1`), `OP_ReopenIdx`가 커서 위치를 지움(`in4-12.1`), iVersion 1 VFS의 `PRAGMA mmap_size`(`sort5-1.0`)

- 그다음 묶음(xqlite만 실패 89개 → 84개. 새로 실패한 것 없음):
  - 오류 로그: 엔진이 `sqlite3_log()`로 남기는 기록을 옮김([C API의 오류 로그](c-api.md#오류-로그): `autoindex1-113`, `wal-23.4`)
  - `SQLITE_CONFIG_COVERING_INDEX_SCAN`(`coveridxscan-3.*`), overflow 페이지를 파일에서 바로 읽기와 `compile_options`의 `DIRECT_OVERFLOW_READ`(`ctime-3.0.1`)
  - 바인딩의 소멸자를 SQLite처럼 값을 다 쓴 뒤 부름, 닫힌 연결 검사를 `exec`·`errcode`·`prepare16`에도 둠
  - 시간 제한에 가려져 있던 `misc7`의 두 가지: 저널을 만들 수 없는 디렉터리는 `SQLITE_READONLY_DIRECTORY`(`misc7-23.4`), 연결 없는 `sqlite3_errmsg16()`은 `out of memory`(`misc7-8`)
  - ATTACH가 스키마를 읽는 동안 모든 b-tree 뮤텍스를 잡음(`attach.c`처럼). 공유 캐시를 쓰는 스레드들이 같은 스키마를 동시에 읽어 `thread002`가 부하에서 가끔 `malformed database schema ... already exists`나 패닉으로 끝나던 것
  - fixture의 C 소스를 `-DTCL_THREADS=1`로 컴파일함(`build.zig`). libtcl은 스레드로 빌드되는데 이 정의가 없으면 `tcl.h`가 `Tcl_MutexLock()`을 빈 매크로로 만들어, `test1.c`의 포인터 표(`ptr:0x...` 문자열 → 포인터)를 `sqlthread`의 스레드들이 잠금 없이 고쳤음. `thread004-1.2`가 xqlite fixture에서는 가끔 빈 포인터로, SQLite fixture에서는 가끔 SEGV로 끝나던 원인(짧게 줄인 테스트로 32번 중 xqlite 6번 실패·SQLite 8번 SEGV → 두 쪽 모두 0번)

전체 xqlite만 실패는 950개에서 84개가 되었습니다. 지금 xqlite만 실패하는 주된 원인은 다음과 같습니다(`trans`·`avtrans`의 109개는 테스트 이름에 `random()`으로 정해지는 행 수가 들어가 두 쪽이 다른 이름을 돈 것이고, 실패 수는 두 쪽이 같습니다).

| 원인 | 예 |
| --- | --- |
| macOS의 프록시 잠금(`SQLITE_ENABLE_LOCKING_STYLE`의 `SQLITE_FCNTL_SET_LOCKPROXYFILE`)을 옮기지 않음 | `filectrl-1.5`(`SQLITE_NOTFOUND`) |
| 메모리 통계(lookaside, `sqlite3_db_status`의 바이트 수) | `lookaside`(12개), `dbstatus`(38개), `dbstatus2`, `memsubsys1`, `memsubsys2`, `shrink` |
| 사용자 페이지 캐시·뮤텍스 구현(`SQLITE_CONFIG_PCACHE2`, `MUTEX`)을 SQLite처럼 쓰지 않음 | `pcache2`, `init`, `mutex1`, `mutex2` |
| C API | 모든 연결을 닫은 뒤 메모리가 남음(xqlite 1163개 파일) |

## 퍼징

| 도구 | 입력 | 찾는 것 |
| --- | --- | --- |
| `xqlite fuzzcheck` | SQLite의 퍼즈 코퍼스 | 크래시, 메모리 누수, close 실패 |
| `btree_model` | 무작위 삽입·교체·삭제, 탐색, 열어 둔 읽기 커서의 이동, `transferRow` 복사, 문장 savepoint, `clearTable`, 커밋 또는 롤백 | 모델과 다른 내용(연산마다, 트랜잭션마다 양방향 스캔), 실패한 디버그 검사 |
| `btree_sqlite3` | `btree_model`이 남긴 DB | SQLite의 `PRAGMA quick_check` 오류(`SQLITE3`가 가리키는 sqlite3로) |
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

케이스마다 fuzzcheck.c처럼 힙 한도 100MB를 둡니다. 메모리 VFS의 파일도 엔진의 할당자로 잡으므로 한도에 듭니다(fuzzcheck.c의 memdb가 `sqlite3_malloc()`으로 페이지를 잡는 것과 같음). 그래서 행을 끝없이 넣는 케이스도 시간 초과 전에 메모리 부족으로 끝납니다.

난수열도 fuzzcheck.c처럼 케이스마다 고정합니다(`SQLITE_TESTCTRL_PRNG_SEED` 1: DB 헤더의 스키마 쿠키, 없으면 1). `randomblob()` 값에 따라 끝나는 시점이 달라지는 케이스가 있어서, 고정하지 않으면 실행마다 결과가 달라집니다.

### 시드 퍼저

```sh
zig build fuzz -Doptimize=ReleaseSafe -- btree_model [SEED] [--events N]
zig build fuzz -Doptimize=ReleaseSafe -- btree_corrupt [SEED]
zig build fuzz -Doptimize=ReleaseSafe -- btree_sqlite3 [SEED] [--events N]
zig build fuzz -Doptimize=ReleaseSafe -- ir_roundtrip [SEED] [--events N]
zig build fuzz -- ir_ext [SEED] --ext zig-out/lib/libxqlite_ext.dylib   # 또는 $XQT_EXT
zig build fuzz -- smoke      # 모든 퍼저를 고정 시드로 짧게
```

- 같은 시드면 같은 동작을 재현합니다.
- 시드를 생략하면 무작위로 골라 먼저 출력합니다.
- 커밋 해시(40자리)도 시드로 받습니다.
- `zig build test`는 모든 시드 퍼저를 고정 시드로 짧게 돌립니다.
- `btree_model`은 유효한 DB만 다루므로 손상을 가정하지 않는 디버그 검사(`corrupt.never_corrupt`, [아키텍처](architecture.md#스토리지-패키지))를 켜고, 손상 오류가 나면 어느 검사가 걸렸는지 출력합니다. 이 검사는 런타임 안전 검사가 있는 빌드(Debug, ReleaseSafe)에서만 돕니다.
- `btree_model`의 읽기 커서는 다른 커서가 b-tree를 바꾸는 동안 열려 있습니다. 바뀐 뒤 한 칸 움직이면 원래 있던 키의 모델상 이웃에 가야 합니다(그 키가 지워졌어도). 커서 위치 저장·복원(`saveAllCursors`, `skip_next`)을 확인합니다.
- `btree_sqlite3`는 `btree_model`이 끝난 DB를 SQLite의 sqlite3 셸로 `PRAGMA quick_check`합니다. 모델의 b-tree는 `sqlite_schema`에 적혀 있고 행은 레코드입니다(quick_check가 행마다 열 하나를 읽으므로). `SQLITE3`, 없으면 `zig-out/bin/sqlite3-ref`(`zig build fuzz`와 `check`가 먼저 설치)를 쓰고, 둘 다 없으면 건너뜁니다. 실패하면 DB를 `.zig-cache/btree-sqlite3-SEED.db`에 남깁니다.

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

`ir_ext`는 같은 테이블 이벤트를 [sqlite3용 확장](extension.md#ir_ext-퍼저-렌더링한-텍스트를-sqlite3확장으로)을 올린 sqlite3로 봅니다: xqlite가 쓴 파일의 `integrity_check`와 저장된 행, sqlite3+확장이 같은 INSERT를 돌렸을 때 거부하는 행과 저장하는 행이 xqlite와 같아야 합니다. 확장(`--ext PATH` 또는 `$XQT_EXT`)을 주어야 돌고(`zig build check -Dfuzz=true`는 같은 빌드의 것을 줌), 없으면 건너뜁니다.

**일부러 검사하지 않는 것.**

- `identity_default`: 계약의 예외이고, 시퀀스는 읽을 때마다 증가합니다.
- 결정적이지 않은 함수
- 방언 d에서 렌더링한 텍스트를 제3의 방언 e가 읽을 때, e가 가린 SQLite 내장 함수 이름이 텍스트에 그대로 있는 경우. 계약은 SQLite 방언과 d만 다루고, e에서는 그 이름이 e의 함수를 뜻합니다(예: PostgreSQL 뷰의 `concat()`은 MariaDB 연결에서 MariaDB의 `CONCAT()`).
- 상수가 파라미터와 다르게 해석되는 ORDER BY/GROUP BY가 있는 트리의 파라미터 비교. 정수 상수는 열 번호이기 때문입니다.
- 뷰가 서브쿼리와 달리 실행 중 오류가 나는 식을 계산하지 않는 경우(sqlite3도 같음)
- 방언의 타입이 값의 뜻을 정한 문장: PostgreSQL의 정확한 십진수를 계산하거나(`Parse.xq_exact_numeric`) 불리언과 만난 문자열 상수를 불리언으로 읽은 문장(`xq_pg_bool()` 호출: `true IN ('yes', 'no')`, `coalesce(NULL, 'on')`, `VALUES (true), ('no')`). 같은 트리의 SQLite 텍스트(다른 방언이 만든 뷰·CHECK)는 실수와 텍스트로, 텍스트로 바인딩한 파라미터는 텍스트로 계산합니다.
- 두 쪽 중 한쪽만 여러 행 `VALUES`를 co-routine으로 돌렸고(`Parse.xq_values_coroutine`) 결과가 다른 경우. SQLite는 같은 행을 `WITH` 아래, 뷰, 파라미터가 있을 때는 `UNION ALL`로 돌리는데, 그때는 열의 affinity와 collation이 달라질 수 있습니다(sqlite3도 같음: NOCASE 열 `c`에 대한 `VALUES (1, 'abc') UNION SELECT 1, c`는 바로 돌리면 두 행을, 뷰로는 한 행을 남김). 결과가 같으면 그대로 비교합니다.


## 방언 차등 테스트

`xqt dialect-diff pg|mariadb|mssql|oracle [--live|--record] [CASES]`는 같은 케이스를 실제 서버와 `xqlite sql`(해당 방언)에서 실행해 행, 열 이름(행이 있는 결과), `ERROR:` 줄을 비교합니다. PostgreSQL은 오류 아래의 `DETAIL:`, `HINT:`, `CONTEXT:` 줄과 `NOTICE:` 줄(그 아래의 `DETAIL:`도)도 비교하고, 위치를 가리키는 줄(psql의 `LINE N:`과 `^`, 셸의 `^--- error here`)만 뺍니다. 두 쪽의 프렐류드가 `client_min_messages`를 `warning`으로 두므로 알림을 비교하는 케이스는 `SET client_min_messages = notice`로 시작합니다(`tools/dialect/pg-error-cases.txt`). 케이스는 `-- case: NAME` 줄로 시작하고 빈 데이터베이스에서 돕니다.

서버 쪽 출력은 세 가지 중 하나에서 옵니다.

| 모드 | 서버 쪽 | 필요한 것 |
| --- | --- | --- |
| 기본 | 저장소에 기록해 둔 서버 클라이언트의 출력(`tools/dialect/pg-expected/pg-cases.out`: 케이스 파일 `NAME.txt`마다 `NAME.out`) | xqlite만 |
| `--live` | 서버에서 지금 돌린 출력 | 서버(podman 컨테이너) |
| `--record` | 서버에서 지금 돌린 출력. 그것으로 기록을 다시 쓰고 `--live`처럼 비교 | 서버(podman 컨테이너) |

- 기록은 케이스 파일마다 텍스트 파일 하나입니다. 머리의 `# ` 줄은 어느 명령이 어느 서버로 만들었는지(`# server: PostgreSQL 18.6 on ...`, wire-diff는 `# client: psql (PostgreSQL) 18.6`도), 그 뒤로 케이스마다 `==== case HASH NAME` 줄과 클라이언트가 찍은 출력 그대로입니다. 정규화는 비교할 때 하므로 정규화를 고쳐도 다시 기록할 필요가 없고, git diff로 서버 출력이 어떻게 바뀌었는지 그대로 보입니다.
- `HASH`는 기록할 때 케이스 글(wire-diff는 파일의 셋업과 `mask-oids`도)의 SHA-256 앞 8바이트입니다. 기록에 없는 케이스는 `NOT RECORDED`, 글이 바뀐 케이스는 `STALE RECORDING`으로 따로 찍고 실패로 셉니다. 케이스를 고치거나 더하면 `--record`로 다시 기록합니다.
- 기록이 있는 방언(지금은 PostgreSQL, `build.zig`의 `recorded_dialects`)은 `zig build check`에서 기본 모드로 돕니다. 나머지 방언은 아직 기록이 없어 `--live`로 돌리고, 서버를 띄운 뒤 `--record`로 기록을 만들면 됩니다(`tools/dialect/maria-expected` ...).
- `--live`·`--record`는 서버에 닿지 않으면 바로 실패하고 컨테이너를 띄우는 명령을 알려 줍니다.

### PostgreSQL

```sh
zig build tools
zig-out/bin/xqt dialect-diff pg [cases-file]        # 기본: tools/dialect/pg-cases.txt, 기록과
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18-alpine
zig-out/bin/xqt dialect-diff pg --live              # PostgreSQL 18과 지금
zig-out/bin/xqt dialect-diff pg --record            # tools/dialect/pg-expected/pg-cases.out을 다시 씀
```

- 기준은 PostgreSQL 18(`postgres:18-alpine`, 기록은 18.6)입니다.
- 서버 접속 명령은 `PG_PSQL`로 바꿉니다(기본 `podman exec -i xq-pg psql -U postgres`).
- 케이스는 작업자 데이터베이스(`xqt_dialect_PID_N`, 최대 8개, 실행 전에 만들고 뒤에 지움)에서 병렬로 돌고, 케이스마다 `public` 스키마를 지우고 다시 만든 뒤 시작합니다. 이름에 프로세스 ID가 들어가므로 같은 서버에서 동시에 돈 두 실행(또는 서버를 함께 쓰는 다른 작업)이 서로의 데이터베이스를 건드리지 않습니다.
- psql의 불리언 `t`/`f`는 방언이 돌려주는 1/0으로 맞춰 비교합니다.

### MariaDB

```sh
podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
zig build tools
zig-out/bin/xqt dialect-diff mariadb --live [cases-file]   # 기본: tools/dialect/maria-cases.txt (기록은 아직 없음)
```

- 서버 접속 명령은 `MARIA_CLIENT`로 바꿉니다(기본 `podman exec -i xq-maria mariadb -uroot`).
- 케이스마다 `main`이라는 빈 데이터베이스(xqlite의 스키마 이름)에서, collation `utf8mb4_general_ci`로 시작합니다. 케이스와 MariaDB의 오류 메시지가 `main`이라는 이름을 쓰므로 서버에서는 한 번에 한 케이스씩 돌고, xqlite 쪽만 병렬로 돕니다.
- 소수부가 있는 수는 끝의 0을 떼고 비교합니다. MariaDB의 DECIMAL은 `3.5000`, 방언의 REAL은 `3.5`로 출력하기 때문입니다.

### MSSQL

```sh
podman run -d --name xq-mssql -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD='Xq_Passw0rd!' \
  -e MSSQL_MEMORY_LIMIT_MB=2048 mcr.microsoft.com/azure-sql-edge:latest
podman cp sqlcmd xq-mssql:/tmp/sqlcmd                # go-sqlcmd, linux-arm64
zig build tools
zig-out/bin/xqt dialect-diff mssql --live [cases-file]     # 기본: tools/dialect/mssql-cases.txt (기록은 아직 없음)
```

- arm64 호스트에서 `mcr.microsoft.com/mssql/server`(amd64 전용)는 qemu 에뮬레이션에서 segfault로 죽으므로, arm64 빌드가 있는 Azure SQL Edge(SQL Server 엔진)를 씁니다. 이미지에 sqlcmd가 없어 go-sqlcmd를 복사해 둡니다.
- 서버 접속 명령은 `MSSQL_CLIENT`로 바꿉니다(기본 `podman exec -i xq-mssql /tmp/sqlcmd -S localhost -U sa -P Xq_Passw0rd! -C`, 그 뒤에 `-W -s '|' -i /dev/stdin`).
- 케이스마다 새로 만든 데이터베이스 `main`에서 `SET NOCOUNT ON`으로 시작하고, 서버에서는 한 번에 한 케이스씩 돕니다. 케이스의 `GO`는 양쪽에서 문장(배치)을 끝냅니다.
- sqlcmd의 점선·빈 결과의 머리글·`(n rows affected)` 같은 메시지를 빼고, 필드의 공백과 소수의 끝 0을 떼고 비교합니다.
- 메모리(서버에 약 2GB)가 모자라면 podman 머신이 멈출 수 있으니 다른 DB 컨테이너와 동시에 띄우지 않는 것이 좋습니다.

### Oracle

```sh
podman run -d --name xq-ora -e ORACLE_PASSWORD=xqpass -e APP_USER=xq -e APP_USER_PASSWORD=xqpass \
  gvenzl/oracle-free:23-slim-faststart
zig build tools
zig-out/bin/xqt dialect-diff oracle --live [cases-file]    # 기본: tools/dialect/oracle-cases.txt (기록은 아직 없음)
```

- 서버 접속 명령은 `ORA_SQLPLUS`로 바꿉니다(기본 `podman exec -i xq-ora sqlplus -s -L xq/xqpass@FREEPDB1`). arm64 macOS의 podman(메모리 약 4 GiB)에서도 `23-slim-faststart` 이미지가 돕니다. 다른 큰 컨테이너와 함께 띄우면 메모리가 모자랄 수 있습니다.
- SQL*Plus는 `SET MARKUP CSV ON DELIMITER |`로 행과 머리글을 내고, 케이스마다 사용자 XQ의 테이블·뷰·시퀀스를 지우고 `NLS_DATE_FORMAT`/`NLS_TIMESTAMP_FORMAT`을 방언이 저장하는 형식(`YYYY-MM-DD HH24:MI:SS[.FF6]`)으로 맞춘 뒤 시작합니다.
- 오류는 ORA- 코드로 비교합니다. 실행 중 제약 위반도 ORA- 코드로 나옵니다(`ORA-00001` ...). SQLite 문구로 나오는 것(`UNIQUE constraint failed` ..., SQLite 방언으로 컴파일한 SQL)은 Oracle이 같은 경우에 내는 코드로 맞춥니다.
- Oracle의 `.5`, `TRUE`/`FALSE`와 xqlite의 `2.0`은 `0.5`, `1`/`0`, `2`로 맞춰 비교합니다.

방언별 결과와 알려진 차이는 [PostgreSQL 호환](postgres/README.md), [MariaDB 호환](mariadb/README.md), [MSSQL 호환](mssql/README.md), [Oracle 호환](oracle/README.md)에 있습니다.

### 와이어 차등 테스트 (PostgreSQL)

`dialect-diff pg`가 `xqlite sql`의 행을 비교한다면, `xqt wire-diff pg`는 psql 사용자가 보는 것을 비교합니다. 같은 psql 18(`postgres:18-alpine`)이 같은 스크립트를 PostgreSQL 18과 `xqlite serve --pg`(케이스마다 새 서버와 빈 DB 파일)에 보내고, 정렬된 표, 명령 태그, NOTICE, `LINE`/`DETAIL`/`HINT`가 붙은 `ERROR`, 메타 명령(`\d`, `\dt`, `\gdesc`, `\bind` ...)의 출력 전체가 같아야 합니다.

```sh
zig build && zig build tools
zig-out/bin/xqt wire-diff pg [--out DIR] [cases-file...]     # 기록과: psql만 필요
zig-out/bin/xqt wire-diff pg --regress [--out DIR] [TEST...] # PostgreSQL의 기대 출력과: psql만 필요
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18-alpine
zig-out/bin/xqt wire-diff pg --live                          # PostgreSQL 18과 지금
zig-out/bin/xqt wire-diff pg --record                        # tools/dialect/pg-expected/pg-wire-cases.out, pg-client-cases.out을 다시 씀
```

- PostgreSQL 쪽은 `dialect-diff`처럼 기본으로 기록(`tools/dialect/pg-expected/NAME.out`, [방언 차등 테스트](#방언-차등-테스트)의 형식, `# client: psql (PostgreSQL) 18.6`도 적음)에서 옵니다. 케이스의 해시에는 그 파일의 셋업과 `mask-oids`도 들어가므로 셋업을 고치면 그 파일의 케이스가 모두 `STALE RECORDING`이 됩니다. 기록할 때 실행마다 달라지는 것(`psql:<stdin>:N:`의 줄 번호, `mask-oids` 케이스의 OID)은 지우고 적으므로, 다시 기록해도 서버의 답이 같으면 파일이 바뀌지 않습니다.
- 기본 모드에는 서버가 필요 없고 psql만 있으면 됩니다. `PATH`에 psql 18이 있으면 그것을(xqlite는 `127.0.0.1`에서 받음), 없으면 케이스마다 잠깐 띄우는 컨테이너 `podman run --rm -i postgres:18-alpine`의 psql을 씁니다(macOS podman에서 컨테이너가 호스트를 `host.containers.internal`로 찾음, xqlite는 `0.0.0.0`에서 받음). 기록한 psql과 버전이 다르면 그렇다고 알려 줍니다. psql이 podman에 기대므로 `zig build check`에는 들어 있지 않습니다.
- `--live`·`--record`의 서버 쪽은 작업자마다 데이터베이스 `xqt_wire_PID_N`(프로세스 ID를 7자리로 넣음, 실행 전에 만들고 뒤에 지움)을 씁니다. 출력에서는 그 이름을 같은 길이의 `xqt_wire_recording`으로 바꾸므로(표의 너비가 그대로), 기록을 재생할 때 xqlite는 그 이름으로 붙습니다. `\l`은 서버의 모든 데이터베이스를 보이므로 케이스는 `\l :DBNAME`(자기 데이터베이스만)입니다.

- 기본 케이스는 `tools/dialect/pg-wire-cases.txt`(세션 설정, psql 메타 명령 `\d` 계열·`\l`·`\du`·`\dx`·`\dp`, `\gdesc`·`\bind`·`\gset`·`\gx`·`\pset`, 값의 출력 형식, 명령 태그, 트랜잭션, 오류와 NOTICE, `information_schema`·`regclass`·`format_type`)와 `tools/dialect/pg-client-cases.txt`입니다.
- `pg-client-cases.txt`는 실제 클라이언트가 보내는 질의입니다. PostgreSQL 16을 `log_statement=all`로 띄우고 node-postgres·knex·Sequelize, SQLAlchemy(psycopg2, psycopg 3)·Django, pgjdbc `DatabaseMetaData`, asyncpg, `prisma db pull`이 파일 머리의 스키마를 들여다보게 한 뒤 서버 로그에서 모았습니다. 확장 질의로 온 문장은 psql의 `\bind ... \g`로, 한 연결의 `BEGIN`…`COMMIT`/`ROLLBACK`은 케이스 하나로 옮겼고, 질의 안의 개체 OID는 `\gset`으로 먼저 구한 psql 변수로 바꿨습니다.
- 케이스 파일: `-- case: NAME`이 케이스를 시작하고, 첫 케이스 앞의 줄은 그 파일의 모든 케이스 앞에 조용히(`QUIET`) 도는 셋업입니다. psql은 케이스의 입력을 되풀이해 찍습니다(`ECHO all`). 케이스 안의 `-- xqt: mask-oids`는 출력에서 다섯 자리 이상의 수를 `<oid>`로 바꿉니다(양쪽이 만든 개체의 OID가 다름).
- 양쪽 모두 `-U postgres -d DB`로 붙으므로 psql이 찍는 소유자·데이터베이스 이름은 같습니다. 줄 앞의 `psql:<stdin>:N:`은 지우고 비교합니다. psql의 표준 출력과 오류는 컨테이너 안에서 `2>&1`로 합쳐 psql이 쓴 순서를 지킵니다.
- 다른 케이스는 `DIFF [class] NAME`으로 나오고, 마지막 줄이 세 가지로 센 수입니다. psql이 되풀이한 입력 줄로 출력을 문장별로 나눠, 다른 문장마다 아래 중 하나로 정하고 케이스는 가장 나쁜 것(result, error, format 순)을 받습니다.
  - `result`: xqlite가 답했지만 PostgreSQL과 다른 답(또는 PostgreSQL이 오류를 낸 문장에 답함)
  - `error`: PostgreSQL이 답한 문장에 xqlite가 오류를 냄
  - `format`: 대소문자, 공백, 표의 선(`-`, `+`, `|`), 오류 문구와 그 주변 줄(`LINE`과 `^`, `DETAIL`, `HINT`, `CONTEXT`, `NOTICE`, `WARNING`), 서버의 `version()` 문자열만 다름
- 두 서버가 다르게 답해도 둘 다 맞는 것은 같은 답으로 봅니다(`sameAnswers()`). 정렬된 표는 셀(앞뒤 공백을 뺀 값)로 비교하므로 열 너비는 상관없지만, psql이 숫자 타입 열을 오른쪽에 붙이는 정렬은 열마다 비교합니다(정수를 `text`로 알린 열은 다름). 그 밖에 `version()` 문자열인 셀과, 표 앞의 문장(앞 표 뒤로 psql이 되풀이한 입력)에 `ORDER BY`가 없는 표의 행 순서는 보지 않습니다.
- 남은 차이(기록과 비교해 130개 중 3개)는 xqlite가 사실대로 답하는 것입니다. `\dt+`의 크기(PostgreSQL 힙 페이지의 `16 kB`, xqlite는 `0 bytes`), `\l`의 `Collate`·`Ctype`(기록한 컨테이너의 `en_US.utf8`, xqlite의 정렬은 바이트 순이라 `C`), `ORDER BY` 없는 `array_agg()`의 원소 순서(PostgreSQL 해시 조인의 순서)입니다.
- `--out DIR`은 케이스마다 두 출력을 `DIR/NAME.pg`, `DIR/NAME.xq`에 씁니다.
- psql을 돌리는 명령은 `PG_WIRE_EXEC`(주면 모든 모드에서 그것을, 그 뒤에 `sh -c "psql ... 2>&1"`; `--live`·`--record`의 기본은 `podman exec -i xq-pg`), psql이 xqlite를 찾는 호스트는 `PG_WIRE_HOST`(기본 `host.containers.internal`, 호스트의 psql이면 `127.0.0.1`), xqlite가 받는 주소는 `PG_WIRE_LISTEN`(기본 `0.0.0.0`, 호스트의 psql이면 `127.0.0.1`)으로 바꿉니다.
- `--regress`는 `tools/dialect/pg-regress`(`PG_REGRESS_DIR`)의 PostgreSQL 회귀 테스트(REL_18_STABLE의 `boolean`, `int2`, `int4`, `int8`, `numeric`, `text`, `varchar`, `case`, `strings`, `uuid`, PostgreSQL 라이선스는 그 디렉터리의 `COPYRIGHT`)를 pg_regress처럼(`psql -X -a -q`, `PGTZ=PST8PDT`, `PGDATESTYLE='Postgres, MDY'`) xqlite에서만 돌리고 `expected/TEST.out`과 문장별로 비교합니다. `setup.sql`(`test_setup.sql`의 `INT4_TBL` 등)이 테스트마다 먼저 돕니다. 출력이 있는 문장 중 기대 출력과 같은 것의 비율과, 다른 것의 세 가지 분류를 찍습니다. psql은 기본 모드처럼 고르고(`--live`이면 `xq-pg` 안의 것), 서버는 쓰지 않습니다.
- 회귀 테스트는 따로 기록하지 않고 PostgreSQL이 테스트와 함께 내놓는 `expected/*.out`을 그대로 기준으로 씁니다. 그 파일이 곧 pg_regress가 서버를 판정하는 기준이고 같은 브랜치(REL_18_STABLE)의 `sql/*.sql`과 짝이므로, 다시 기록하면 같은 것을 한 벌 더 두는 셈입니다. 게다가 기록하려면 pg_regress가 하는 대로(데이터베이스 `regression`, 앞 테스트들이 만든 개체, 시간대·날짜 형식) 서버를 맞춰야 하는데, 받은 파일은 그럴 필요가 없습니다. 고른 9개 테스트에는 로캘·플랫폼별 대체 기대 파일(`*_1.out`)이 없습니다.

## WebAssembly

```sh
zig build test-wasi                      # 단위 테스트(wasm32-wasi, wasmtime) + xqt wasi
zig build -Dtarget=wasm32-wasi && zig-out/bin/xqt wasi --wasm zig-out/bin/xqlite.wasm
zig build wasm-example                   # wasm32-freestanding 모듈을 Node.js에서
```

`zig build test-wasi`는 wasmtime(`PATH`)이 필요하고 `zig build check`에는 들어 있지 않습니다. 하는 일은 다음과 같습니다.

- 모듈(`src/root.zig`), CLI(`src/cli/main.zig`), `pkg/` 아래 패키지(`pkg/vfs`, `pkg/storage`, `pkg/base`, `pkg/uuid`, `pkg/sql/lexer`, `pkg/sql/parse`, `pkg/decimal`, `pkg/datetime`, `pkg/json`, `pkg/regex`, `pkg/pgtext`)의 단위 테스트를 wasm32-wasi로 빌드해 `wasmtime run --dir .`로 저장소 루트에서 돌립니다. 테스트의 임시 디렉터리는 `.zig-cache/tmp`입니다. POSIX VFS의 `-shm` 파일과 파일 권한에 기대는 테스트 셋은 WASI에서 건너뜁니다.
- `xqt wasi`: ReleaseSafe로 빌드한 WASI `xqlite`를 `wasmtime run --dir . xqlite.wasm ...`으로 검사 디렉터리에서 돌립니다. WASI 빌드가 쓴 파일은 모두 sqlite3의 `PRAGMA integrity_check`를 통과해야 합니다.

| 검사 | 확인하는 것 |
| --- | --- |
| runtime and module | wasmtime이 모듈을 돌리고, 버전·시계·난수가 동작함 |
| same results as sqlite3 | WASI가 쓴 DB(오버플로 페이지, WITHOUT ROWID)에서 sqlite3와 같은 질의 결과 |
| transactions with the rollback journal | 커밋, 롤백, 세이브포인트의 출력이 sqlite3와 같고 저널이 남지 않음 |
| WAL: write, reopen, read by sqlite3 | WAL 모드로 쓰고, 다른 WASI 프로세스가 다시 열고, sqlite3가 쓴 것을 다시 읽고, `journal_mode=delete`로 WAL을 지움 |
| WAL left by a killed sqlite3 is recovered | 죽은 sqlite3가 남긴 WAL을 WASI 빌드가 `-shm` 없이 복구함 |
| hot journal left under WASI, rolled back by sqlite3 | WASI의 `xqlite crash-write`가 남긴 핫 저널을 sqlite3가 되돌림 |
| dialect postgres/mariadb/mssql/oracle | 방언마다 같은 스크립트의 출력과 다시 연 `.schema`가 네이티브 xqlite와 같음 |

wasm 경로는 `--wasm`, `XQ_WASM`, 기본값 `zig-out/bin/xqlite.wasm` 순으로, 런타임은 `--runtime`, `WASMTIME`, `wasmtime` 순으로 정합니다. 브라우저용 모듈(`wasm32-freestanding`)은 `zig build wasm-example`이 Node.js에서 검사합니다(메모리 DB, 방언 넷, node:fs 위의 롤백 저널·WAL·다시 열기, `integrity_check`). 자세한 내용은 [WebAssembly](wasm.md)에 있습니다.

## C API

`zig build test-capi`(`zig build check`에 포함)는 `tools/capi/capi_test.c`를 `include/sqlite3.h`와 함께 컴파일해 정적·공유 `libxqlite3`에 각각 링크하고 돌립니다. 인자로 테스트용 확장(`tools/capi/ext_test.c`)과 sqlite3용 확장(`libxqlite_ext`)을 받아, 둘 다 `sqlite3_load_extension()`으로 올려 봅니다(`test_b_ext()`, `test_b_xqlite_ext()`). 같은 테스트용 확장을 Zig API의 `Db.loadExtension()`으로도 올립니다(`tools/capi/zig_load_test.zig`: 함수·집계 호출, PostgreSQL 방언, 없는 파일·진입점·초기화 실패의 오류, 꺼진 SQL 함수 `load_extension()`). 실패한 검사를 출력하고 0이 아닌 코드로 끝납니다. 이 프로그램은 SQLite 아말감에 링크해도 xqlite 확장과 문서에 적은 차이 말고는 모두 통과하므로, 기대값은 SQLite의 동작입니다.

```sh
zig cc -std=gnu99 -Iinclude -DSQLITE_ENABLE_COLUMN_METADATA tools/capi/capi_test.c xqstub.c "$AMALGAMATION/sqlite3.c" -lpthread -lm
```

(`xqstub.c`는 `xqlite_set_dialect()`, `xqlite_dialect()`의 빈 구현입니다. `$AMALGAMATION`은 아말감 디렉터리입니다. `zig build`가 받은 것은 `zig build --fetch` 뒤 Zig 전역 캐시에 있습니다.)

`zig build capi-fast`(`zig build check -Dfast=true`에 포함)는 `-Doptimize`와 상관없이 ReleaseFast로 정적 `libxqlite3`를 만들고 `capi_test.c`와 `tools/capi/bench.c`(`:memory:`에 준비된 INSERT를 한 트랜잭션에서 30만 번 실행하고 행 수와 합을 확인)를 링크해 각각 8번 돌립니다. ReleaseFast는 `undefined`로 둔 메모리를 채우지 않아(Debug·ReleaseSafe는 0xaa로 채움) 그런 값을 읽는 버그가 할당 주소에 따라 일부 실행에서만 드러나기 때문입니다. 예를 들어 OP_Function 문맥의 `out`이 앞서 해제된 같은 모양 문장의 값을 그대로 가져 인자를 묶지 않은 버그는 `capi_test` 실행의 약 40%에서 `DETACH aux`를 실패시켰습니다.

`zig build capi-shell`은 SQLite 3.54.1 아말감의 `shell.c`(`-Dsqlite-shell-c`, 기본은 의존성 `sqlite`의 것)를 고치지 않고 `libxqlite3`에 링크해 `zig-out/bin/sqlite3-xqlite`를 만들고, `tools/capi/shell_smoke.sql`의 표준 출력을 `tools/capi/shell_smoke.expected`와 비교합니다. 자세한 것은 [C API](c-api.md#테스트)에 있습니다.

`zig build capi-sortbench`는 정렬 벤치마크 `tools/capi/sortbench.c`(무작위 30만 행에 ORDER BY, GROUP BY, CREATE INDEX)를 SQLite 3.54.1 아말감의 `sqlite3.c`(`-Dsqlite-c`, 기본은 의존성 `sqlite`의 것)와 ReleaseFast 정적 `libxqlite3`에 각각 링크해 차례로 돌립니다. 각 질의의 결과 행을 순서대로 해시하므로, xqlite 쪽은 SQLite 쪽 출력(`-ref`)과 해시를 줄마다 비교해 다르면 `DIFFERENT`를 붙이고 실패하며, 시간 비율(`x0.65`는 SQLite 시간의 0.65배)도 함께 출력합니다. `--` 뒤의 인자는 두 실행에 모두 갑니다. `-n ROWS`는 행 수, `-spill`은 캐시를 10페이지로 줄여 정렬이 PMA를 쓰고 병합하게 합니다.

```sh
zig build capi-sortbench                  # 메모리 정렬
zig build capi-sortbench -- -spill        # 디스크로 넘치는 정렬
```

`zig build bench-btree`(또는 `pkg/storage`에서 `zig build bench`)는 엔진 없이 `pkg/storage`의 B-tree 커서만으로 테이블과 인덱스에 무작위 순서로 넣고, 찾고, 양방향으로 훑고, 절반을 지우는 시간을 잽니다. 메모리 VFS와 데이터베이스가 다 들어가는 캐시를 써서 B-tree와 페이지 캐시만 잽니다. 줄마다 세 번 중 가장 빠른 시간, 연산당 시간, 읽은 내용의 체크섬을 출력합니다(`-- -n ROWS -page-size BYTES`).

## 그 밖의 도구

| 명령 | 하는 일 |
| --- | --- |
| `xqt gen fixtures` | `src/testdata`의 테스트용 DB(`btree.db`, `autovacuum.db`, `sql.db`)를 sqlite3 셸로 다시 만듭니다. 내용은 결정적이고 테스트가 같은 식으로 검사합니다. 커밋한 파일은 3.44.4로 만든 것이라 헤더에 그 버전이 들어 있으므로 `PATH`의 `sqlite3`(또는 `--fixtures-sqlite3 PATH`)를 씁니다. |
| `xqt gen superjournal [DIR]` | 세 파일 트랜잭션을 커밋하던 sqlite3를 크래시 shim으로 네 지점(super journal을 지우기 직전, 지운 뒤 저널을 하나도·하나·둘 지운 때)에서 죽여 남은 파일을 `src/testdata/superjournal`(또는 `DIR`)에 저장합니다. `src/sql/attach_test.zig`가 xqlite로 복구해 봅니다. sqlite3가 super journal 이름을 무작위로 고르므로 저널은 다시 만들 때마다 바이트가 달라집니다. 그래서 생성기는 바이트 대신 상태마다 있어야 할 파일들이 있는지 확인합니다. |
| `xqt bench [WORKLOAD...]` | 같은 작업을 xqlite와 sqlite3로 재고 비율을 출력합니다. `zig build -Doptimize=ReleaseFast` 뒤에 씁니다(`--runs`/`RUNS`, `--rows`/`ROWS`, `--xq`, `--sqlite3`). |
| `xqt gen opcodes` | `src/vdbe/opcodes.zig`를 다시 만듭니다. `ref/sqlite`와 tclsh가 필요합니다. |

`xqt gen`은 이름을 여럿 받아(`xqt gen fixtures opcodes`) 동시에 돌립니다. 출력은 프로세스 안에서 `zig fmt`와 같은 형식으로 맞춥니다.

## 테스트 전략

| 영역 | 방법 | 지금 |
| --- | --- | --- |
| SQLite | [sqllogictest](https://www.sqlite.org/sqllogictest/)와 SQLite TCL 테스트 스위트 일부를 포팅 | sqllogictest 실행기, 플래너 케이스 일부를 TCL 테스트에서 뽑음 |
| 파일 포맷 | 순정 SQLite와 xqlite가 서로 만든 DB 파일을 교차로 읽고 쓰고 `PRAGMA integrity_check`로 검증 | `xqt interop` |
| PostgreSQL / MariaDB / MSSQL / Oracle | 같은 쿼리를 실제 서버와 xqlite에서 실행해 비교(differential testing), 각 DB의 regression test에서 필요한 부분을 가져옴 | `xqt dialect-diff pg`, `xqt dialect-diff mariadb`, `xqt dialect-diff mssql`, `xqt dialect-diff oracle`, `xqt wire-diff pg`(와이어 서버, `--regress`) |
| 퍼징 | 파서, 레코드 디코더, B-Tree 페이지 디코더, IR | `fuzzcheck`, 시드 퍼저 |
| 크래시 복구 | 오류를 주입하는 VFS로 쓰기 도중 전원 차단을 흉내 내고, sqlite3는 preload shim으로 죽임 | `pkg/vfs/src/crash.zig`, `tools/crashshim.c`, `xqlite crash-write`(`xqt interop wal`, `attach`, `vacuum`, `hot-journal`) |
