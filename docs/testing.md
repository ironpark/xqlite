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
- [퍼징](#퍼징)
- [방언 차등 테스트](#방언-차등-테스트)
- [WebAssembly](#webassembly)
- [C API](#c-api)
- [그 밖의 도구](#그-밖의-도구)
- [테스트 전략](#테스트-전략)

## 도구 한눈에 보기

xqlite 밖에서 돌리는 테스트 도구는 모두 Zig로 쓴 `xqt` 하나입니다(셸·Python 스크립트는 없습니다). `zig build tools`가 `zig-out/bin/xqt`, 크래시 shim(`zig-out/lib/libcrashshim.dylib`, Linux는 `.so`), 그리고 xqlite를 빌드합니다. 구조와 검사를 추가하는 방법은 [tools/xqt/README.md](../tools/xqt/README.md)에 있습니다.

```sh
zig build tools
zig-out/bin/xqt help            # 명령과 공통 옵션
zig-out/bin/xqt help planner    # 명령별 옵션
zig-out/bin/xqt list            # interop 모듈, 플래너 케이스 파일, 쓰는 바이너리
```

| 명령 | 확인하는 것 | 기준 |
| --- | --- | --- |
| `zig build test` | 단위 테스트, 문서·예제의 이름, 전역 상태, 시드 퍼저 스모크 | — |
| `zig build check` | 아래의 대부분을 병렬로 한 번에: 단위 테스트, `xqt` 자체의 테스트, `xqt interop`, `xqt planner`, `fuzzcheck` (`-Dslt`, `-Dfuzz`, `-Dfast`로 더) | 아래와 같음 |
| `xqt interop [NAME...]` | DB 파일, SQL 결과, 셸 출력, PRAGMA, WAL, 크래시 복구를 sqlite3와 교차 비교. 모듈은 [sqlite3 교차 검증](#sqlite3-교차-검증) | `--sqlite3`/`SQLITE3` (3.54.1) |
| `xqt planner [FILE...]` | 쿼리 결과·`EXPLAIN QUERY PLAN`·바이트코드 | `--sq`/`SQ` (3.54.1, 주석 없는 빌드) |
| `xqt planner gen basic\|hard ...` | 무작위 플래너 케이스 생성 | — |
| `xqt slt [PATH...]` | sqllogictest | `--ref` (선택) |
| `xqlite fuzzcheck` | SQLite 퍼즈 코퍼스에서 크래시·메모리 누수·close 실패 | — |
| `zig build fuzz` | 시드 퍼저: `btree_model`, `btree_corrupt`, `btree_sqlite3`, `ir_roundtrip` | — |
| `xqt dialect-diff pg` | PostgreSQL 방언을 실제 PostgreSQL 16과 차등 비교 | PostgreSQL 서버(podman) |
| `xqt dialect-diff mariadb` | MariaDB 방언을 실제 MariaDB 11과 차등 비교 | MariaDB 서버(podman) |
| `xqt dialect-diff mssql` | MSSQL(T-SQL) 방언을 실제 SQL Server(Azure SQL Edge, 엔진 15.0)와 차등 비교 | SQL Server 서버(podman)와 go-sqlcmd |
| `xqt dialect-diff oracle` | Oracle 방언을 실제 Oracle Database 23ai와 차등 비교 | Oracle 서버(podman) |
| `xqt wire-diff pg` | psql로 실제 PostgreSQL 16과 `xqlite serve --pg`를 차등 비교(메타 명령, 클라이언트·ORM의 카탈로그 질의) | PostgreSQL 서버와 그 psql(podman) |
| `xqt wire-diff pg --regress` | PostgreSQL 회귀 테스트 일부를 `xqlite serve --pg`에서 돌려 문장별 통과율 | psql(podman) |
| `xqt bench [WORKLOAD...]` | 같은 작업의 xqlite·sqlite3 실행 시간 | `--sqlite3`/`SQLITE3` |
| `zig build test-wasi` | wasm32-wasi 단위 테스트(wasmtime)와 `xqt wasi` | wasmtime, `--sqlite3`/`SQLITE3` |
| `xqt wasi [--wasm PATH]` | WASI 빌드의 SQL 결과, 저널·WAL, 크래시 복구, 방언 | sqlite3, 네이티브 xqlite(`--xq`), wasmtime |
| `zig build wasm-example` | 브라우저용 모듈을 Node.js에서 (`examples/wasm/node.mjs`) | node |
| `xqt gen fixtures\|parser\|opcodes` | `src/testdata`의 테스트용 DB, `grammar.zig`, `opcodes.zig` 재생성 | `PATH`의 sqlite3(fixtures) |
| `xqt gen superjournal [DIR]` | `src/testdata/superjournal`(여러 파일 커밋 도중 죽은 sqlite3가 남긴 파일) 재생성 | `--sqlite3`/`SQLITE3`, 크래시 shim |
| `zig build test-capi` | C 프로그램으로 C ABI(`libxqlite3`, 정적·공유) 검사 | — |
| `zig build test-minimal` | 방언·확장을 모두 뺀 엔진(`-Ddialects=none -Dext=none`)으로 `tools/minimal_test.zig` | — |
| `zig build capi-fast` | ReleaseFast 정적 `libxqlite3`로 C 검사와 `tools/capi/bench.c`를 8번씩 실행 | — |
| `zig build capi-shell` | SQLite의 `shell.c`를 `libxqlite3`에 링크해 스모크 스크립트 실행 | 아말감 `shell.c` |
| `zig build capi-sortbench` | 정렬 벤치마크(`tools/capi/sortbench.c`)를 SQLite와 ReleaseFast `libxqlite3`에서 돌려 시간과 결과 순서 비교 | 아말감 `sqlite3.c` |
| `zig build bench-btree` | 엔진 없이 B-tree 커서의 삽입·탐색·스캔·삭제 시간(`pkg/storage/bench/btree.zig`) | — |
| `xqt fetch sqlite\|slt` | `ref/sqlite`, `ref/sqllogictest` 내려받기 | — |

## 준비

### 참고 소스

포팅 기준 SQLite 소스(현재 3.54.1)는 `ref/sqlite`에 받아 두고 참고합니다. `ref/`는 git에서 제외됩니다.

```sh
zig build tools
zig-out/bin/xqt fetch sqlite    # ref/sqlite (SQLITE_VERSION, SQLITE_YEAR로 버전 변경)
zig-out/bin/xqt fetch slt       # ref/sqllogictest (약 1.2GB, git clone --depth 1; SLT_REPO로 저장소 변경)
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

### 바이너리 고르기

바이너리마다 명령줄 옵션, 환경 변수, 기본값 순서로 정합니다.

| 바이너리 | 옵션 | 환경 변수 | 기본값 | 쓰는 명령 |
| --- | --- | --- | --- | --- |
| xqlite | `--xq` | `XQ` | 이 저장소의 `zig-out/bin/xqlite` | 모든 명령 |
| sqlite3 | `--sqlite3` | `SQLITE3` | `zig-out/bin/sqlite3-ref`가 있으면 그것, 없으면 `PATH`의 `sqlite3` | `interop`(모든 모듈), `bench`, `gen superjournal` |
| 플래너 기준 | `--sq` | `SQ` | `zig-out/bin/sqlite3-planner`가 있으면 그것, 없으면 `PATH`의 `sqlite3` | `planner`. `SQLITE_ENABLE_EXPLAIN_COMMENTS` 없이 빌드한 3.54.1이어야 합니다([위](#기준-sqlite3-셸)) |
| 크래시 shim | `--crashshim` | `XQT_CRASHSHIM` | 이 저장소의 `zig-out/lib/libcrashshim.dylib`(Linux는 `.so`) | `interop attach`, `interop vacuum`, `gen superjournal` |

예전 스크립트는 `PATH`의 `sqlite3`를 쓰는 것과 `SQLITE3`를 쓰는 것이 섞여 있었습니다. 이제 모든 interop 모듈이 같은 sqlite3 하나를 씁니다. `XQLITE` 변수는 없어졌고 `--xq`나 `XQ`를 씁니다. `xqt list`가 실제로 고른 바이너리를 보여 줍니다.

다음은 이 규칙 밖에서 외부 프로그램을 씁니다.

| 명령 | 쓰는 것 |
| --- | --- |
| `gen fixtures` | `PATH`의 `sqlite3`, 또는 `--fixtures-sqlite3 PATH`. 커밋한 fixture는 헤더에 3.44.4라는 버전이 들어 있으므로 `SQLITE3`를 따르지 않습니다 |
| `gen parser`, `gen opcodes` | `zig cc`(lemon, mkkeywordhash), `zig run`(변환기), `opcodes`는 `tclsh`도. `ZIG`로 zig 바이너리를 바꿉니다 |
| `dialect-diff` | podman 컨테이너의 클라이언트(`PG_PSQL`, `MARIA_CLIENT`, `ORA_SQLPLUS`) |
| `wire-diff` | psql을 `sh -c`로 돌리는 명령(`PG_WIRE_EXEC`), 컨테이너에서 본 호스트(`PG_WIRE_HOST`), xqlite가 받는 주소(`PG_WIRE_LISTEN`), 회귀 테스트 디렉터리(`PG_REGRESS_DIR`) |
| `fetch slt` | `git` |

### 그 밖의 환경 변수

| 변수 | 쓰는 곳 | 뜻 |
| --- | --- | --- |
| `STRESS_TXNS` | `interop wal` | 스트레스 실행의 프로세스당 트랜잭션 수(기본 3000, 프로세스 4개) |
| `RUNS`, `ROWS` | `bench` | 실행 횟수(기본 3, 가장 빠른 것을 씀), 테이블 행 수(기본 1000000). `--runs`, `--rows`와 같음 |
| `SQOPT` | `planner` | 기준 셸에서 `.testctrl optimizations MASK`로 끌 최적화 |
| `XQ_VTABLOG`, `XQ_WHERETRACE` | `planner` | [tools/planner/README.md](../tools/planner/README.md) |
| `SQLITE_VERSION`, `SQLITE_YEAR`, `SLT_REPO` | `fetch` | 내려받을 SQLite 릴리스, sqllogictest 저장소 |

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
- `xqt interop`: 모든 interop 모듈
- `xqt planner --known tools/planner/known-failures.list`: `vtablog.txt`를 뺀 모든 케이스 파일
- `xqlite fuzzcheck`: `ref/sqlite/test/fuzzdata1.db`..`fuzzdata8.db`를 파일마다 프로세스 하나로
- `-Dslt=true`이면 `xqt slt ref/sqllogictest/test`
- `-Dfuzz=true`이면 `btree_model`, `btree_corrupt`, `btree_sqlite3`, `ir_roundtrip`을 무작위 시드로 한 번씩
- `-Dfast=true`이면 `zig build capi-fast`: ReleaseFast 정적 라이브러리로 C 검사와 삽입 벤치마크를 여러 번

플래너 부분 때문에 `SQ`에 [주석 없는 기준 셸](#기준-sqlite3-셸)을 주어야 합니다. 주지 않으면 `PATH`의 `sqlite3`와 비교하므로 바이트코드가 다릅니다. `SQLITE3`도 같은 방식으로 받습니다.

`-Doptimize`는 단위 테스트, `xqt interop`, `xqt planner`가 쓰는 빌드를 정합니다. 오래 걸리는 fuzzcheck, sqllogictest(`-Dslt`), 시드 퍼저(`-Dfuzz`)는 `-Doptimize`와 상관없이 따로 만든 ReleaseSafe 빌드로 돕니다. `xqt`에는 같은 빌드의 xqlite(`--xq`)와 크래시 shim(`--crashshim`)을 넘기고 저장소 루트에서 실행하므로 `zig build tools`를 따로 할 필요가 없습니다. `xqt dialect-diff`·`xqt wire-diff`(서버 필요)와 `xqt bench`는 들어 있지 않습니다.

### known-failures.list

`tools/planner/known-failures.list`는 플래너가 아직 sqlite3와 다른 것으로 알려진 쿼리의 목록입니다. 한 줄에 `케이스파일 종류 쿼리` 하나이고, 쿼리는 케이스 파일에 쓴 그대로입니다. 지금은 `eqp_select.txt`의 `VALUES(1),(2),(3)`(sqlite3 3.54.1은 여러 행 VALUES를 co-routine으로 돌리고, xqlite는 아직 행마다 `ResultRow`를 냄) 하나의 `code`, `eqp` 두 줄뿐입니다.

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
- VFS(`pkg/vfs`), 스토리지(`pkg/storage`), 공용(`pkg/base`) 패키지의 단위 테스트. 엔진 모듈과 다른 모듈이라 모듈의 테스트에 들어가지 않으므로 따로 빌드해 돌립니다(`vfsTests()`, `storageTests()`, `baseTests()`). B-tree, 페이저, WAL, 저널, 페이지 캐시의 테스트는 스토리지 패키지에 있습니다. `zig build test-pkg`는 이것들(과 ReleaseSafe 저널 테스트)만 엔진 없이 돌립니다.
- `docs/names_test.zig`: [docs/zig-api.md](zig-api.md)가 쓰는 이름(`xqlite.Value`, `Db.lastError` ...)과 `examples/`가 쓰는 이름이 모듈에 있는지 검사합니다.
- `tools/globals_test.zig`: `src/`(그리고 `pkg/vfs/src`, `pkg/storage/src`, `pkg/base/src`, `tools/xqt`)에 허용 목록 밖의 가변 전역이 없는지 검사합니다.
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
| `mariadb` | MariaDB 방언으로 쓴 DB(STRICT 테이블, 이름 있는 CHECK, DEFAULT·생성 열, `AUTO_INCREMENT`, `"t$i"` 인덱스, 뷰, `xq_catalog`)를 같은 방식으로 확인합니다. sqlite3에 없는 엔진 함수(`xq_*`)를 쓰는 식은 xqlite 안의 테스트(`src/dialect/mariadb/test.zig`)가 확인합니다. |
| `mssql` | MSSQL 방언으로 쓴 DB(STRICT 테이블과 타입의 CHECK, identity 시퀀스, 계산 열, `NOCASE`/`BINARY` 열, 인덱스, 뷰, `xq_catalog`)를 같은 방식으로 확인합니다. sqlite3에 없는 엔진 함수(`xq_tsql_*`)를 쓰는 식은 `src/dialect/mssql/test.zig`가 확인합니다. |
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

`-k res,eqp,code`로 비교할 것을 고르고, `--known`은 [알려진 차이](#known-failureslist)를 받습니다. 케이스 파일 형식, 케이스 모음(`vtab.txt`, `json.txt`, `window.txt`, `wal.txt`, `attach.txt`, `vacuum.txt` ...), 무작위 케이스 생성기, `SQOPT`·`XQ_WHERETRACE` 같은 옵션은 [tools/planner/README.md](../tools/planner/README.md)에 있습니다.

## sqllogictest

[sqllogictest](https://sqlite.org/sqllogictest/)를 `xqlite slt`(C 실행기의 Zig 포팅)로 돌립니다.

```sh
zig build tools -Doptimize=ReleaseSafe
zig-out/bin/xqt fetch slt
zig-out/bin/xqt slt ref/sqllogictest/test             # 전부 병렬로, 실패를 원인별로 묶음
zig-out/bin/xqt slt ref/sqllogictest/test -- --wal    # -- 뒤는 xqlite slt의 인자
```

C 실행기와의 대조(`--ref`), WAL 모드 실행 같은 옵션은 [tools/slt/README.md](../tools/slt/README.md)에 있습니다.

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

**일부러 검사하지 않는 것.**

- `identity_default`: 계약의 예외이고, 시퀀스는 읽을 때마다 증가합니다.
- 결정적이지 않은 함수
- 방언 d에서 렌더링한 텍스트를 제3의 방언 e가 읽을 때, e가 가린 SQLite 내장 함수 이름이 텍스트에 그대로 있는 경우. 계약은 SQLite 방언과 d만 다루고, e에서는 그 이름이 e의 함수를 뜻합니다(예: PostgreSQL 뷰의 `concat()`은 MariaDB 연결에서 MariaDB의 `CONCAT()`).
- 상수가 파라미터와 다르게 해석되는 ORDER BY/GROUP BY가 있는 트리의 파라미터 비교. 정수 상수는 열 번호이기 때문입니다.
- 뷰가 서브쿼리와 달리 실행 중 오류가 나는 식을 계산하지 않는 경우(sqlite3도 같음)


## 방언 차등 테스트

`xqt dialect-diff pg|mariadb|mssql|oracle [CASES]`는 같은 케이스를 실제 서버와 `xqlite sql`(해당 방언)에서 실행해 행, 열 이름(행이 있는 결과), `ERROR:` 줄을 비교합니다. 케이스는 `-- case: NAME` 줄로 시작하고 빈 데이터베이스에서 돕니다. 서버는 기본으로 podman 컨테이너를 쓰며, 서버가 필요하므로 `zig build check`에는 들어 있지 않습니다. 서버에 닿지 않으면 바로 실패하고 컨테이너를 띄우는 명령을 알려 줍니다.

### PostgreSQL

```sh
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
zig build tools
zig-out/bin/xqt dialect-diff pg [cases-file]        # 기본: tools/dialect/pg-cases.txt
```

- 서버 접속 명령은 `PG_PSQL`로 바꿉니다(기본 `podman exec -i xq-pg psql -U postgres`).
- 케이스는 작업자 데이터베이스(`xqt_dialect_N`, 최대 8개, 실행 전에 만들고 뒤에 지움)에서 병렬로 돌고, 케이스마다 `public` 스키마를 지우고 다시 만든 뒤 시작합니다.
- psql의 불리언 `t`/`f`는 방언이 돌려주는 1/0으로 맞춰 비교합니다.

### MariaDB

```sh
podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
zig build tools
zig-out/bin/xqt dialect-diff mariadb [cases-file]   # 기본: tools/dialect/maria-cases.txt
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
zig-out/bin/xqt dialect-diff mssql [cases-file]     # 기본: tools/dialect/mssql-cases.txt
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
zig-out/bin/xqt dialect-diff oracle [cases-file]    # 기본: tools/dialect/oracle-cases.txt
```

- 서버 접속 명령은 `ORA_SQLPLUS`로 바꿉니다(기본 `podman exec -i xq-ora sqlplus -s -L xq/xqpass@FREEPDB1`). arm64 macOS의 podman(메모리 약 4 GiB)에서도 `23-slim-faststart` 이미지가 돕니다. 다른 큰 컨테이너와 함께 띄우면 메모리가 모자랄 수 있습니다.
- SQL*Plus는 `SET MARKUP CSV ON DELIMITER |`로 행과 머리글을 내고, 케이스마다 사용자 XQ의 테이블·뷰·시퀀스를 지우고 `NLS_DATE_FORMAT`/`NLS_TIMESTAMP_FORMAT`을 방언이 저장하는 형식(`YYYY-MM-DD HH24:MI:SS[.FF6]`)으로 맞춘 뒤 시작합니다.
- 오류는 ORA- 코드로 비교합니다. 실행 중 제약 위반도 ORA- 코드로 나옵니다(`ORA-00001` ...). SQLite 문구로 나오는 것(`UNIQUE constraint failed` ..., SQLite 방언으로 컴파일한 SQL)은 Oracle이 같은 경우에 내는 코드로 맞춥니다.
- Oracle의 `.5`, `TRUE`/`FALSE`와 xqlite의 `2.0`은 `0.5`, `1`/`0`, `2`로 맞춰 비교합니다.

방언별 결과와 알려진 차이는 [PostgreSQL 호환](postgres.md), [MariaDB 호환](mariadb.md), [MSSQL 호환](mssql.md), [Oracle 호환](oracle.md)에 있습니다.

### 와이어 차등 테스트 (PostgreSQL)

`dialect-diff pg`가 `xqlite sql`의 행을 비교한다면, `xqt wire-diff pg`는 psql 사용자가 보는 것을 비교합니다. 같은 psql(`postgres:16-alpine` 컨테이너의 psql 16)이 같은 스크립트를 실제 PostgreSQL과 `xqlite serve --pg`(케이스마다 새 서버와 빈 DB 파일)에 보내고, 정렬된 표, 명령 태그, NOTICE, `LINE`/`DETAIL`/`HINT`가 붙은 `ERROR`, 메타 명령(`\d`, `\dt`, `\gdesc`, `\bind` ...)의 출력 전체가 같아야 합니다.

```sh
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
zig build && zig build tools
zig-out/bin/xqt wire-diff pg [--out DIR] [cases-file...]
zig-out/bin/xqt wire-diff pg --regress [--out DIR] [TEST...]
```

- 기본 케이스는 `tools/dialect/pg-wire-cases.txt`(세션 설정, psql 메타 명령 `\d` 계열·`\l`·`\du`·`\dx`·`\dp`, `\gdesc`·`\bind`·`\gset`·`\gx`·`\pset`, 값의 출력 형식, 명령 태그, 트랜잭션, 오류와 NOTICE, `information_schema`·`regclass`·`format_type`)와 `tools/dialect/pg-client-cases.txt`입니다.
- `pg-client-cases.txt`는 실제 클라이언트가 보내는 질의입니다. PostgreSQL 16을 `log_statement=all`로 띄우고 node-postgres·knex·Sequelize, SQLAlchemy(psycopg2, psycopg 3)·Django, pgjdbc `DatabaseMetaData`, asyncpg, `prisma db pull`이 파일 머리의 스키마를 들여다보게 한 뒤 서버 로그에서 모았습니다. 확장 질의로 온 문장은 psql의 `\bind ... \g`로, 한 연결의 `BEGIN`…`COMMIT`/`ROLLBACK`은 케이스 하나로 옮겼고, 질의 안의 개체 OID는 `\gset`으로 먼저 구한 psql 변수로 바꿨습니다.
- 케이스 파일: `-- case: NAME`이 케이스를 시작하고, 첫 케이스 앞의 줄은 그 파일의 모든 케이스 앞에 조용히(`QUIET`) 도는 셋업입니다. psql은 케이스의 입력을 되풀이해 찍습니다(`ECHO all`). 케이스 안의 `-- xqt: mask-oids`는 출력에서 다섯 자리 이상의 수를 `<oid>`로 바꿉니다(양쪽이 만든 개체의 OID가 다름).
- 양쪽 모두 `-U postgres -d xqt_wire_N`으로 붙으므로 psql이 찍는 소유자·데이터베이스 이름은 같습니다. 줄 앞의 `psql:<stdin>:N:`은 지우고 비교합니다. psql의 표준 출력과 오류는 컨테이너 안에서 `2>&1`로 합쳐 psql이 쓴 순서를 지킵니다.
- 다른 케이스는 `DIFF [class] NAME`으로 나오고, 마지막 줄이 세 가지로 센 수입니다. psql이 되풀이한 입력 줄로 출력을 문장별로 나눠, 다른 문장마다 아래 중 하나로 정하고 케이스는 가장 나쁜 것(result, error, format 순)을 받습니다.
  - `result`: xqlite가 답했지만 PostgreSQL과 다른 답(또는 PostgreSQL이 오류를 낸 문장에 답함)
  - `error`: PostgreSQL이 답한 문장에 xqlite가 오류를 냄
  - `format`: 대소문자, 공백, 표의 선(`-`, `+`, `|`), 오류 문구와 그 주변 줄(`LINE`과 `^`, `DETAIL`, `HINT`, `CONTEXT`, `NOTICE`, `WARNING`), 서버의 `version()` 문자열만 다름
- `--out DIR`은 케이스마다 두 출력을 `DIR/NAME.pg`, `DIR/NAME.xq`에 씁니다.
- psql을 돌리는 명령은 `PG_WIRE_EXEC`(기본 `podman exec -i xq-pg`, 그 뒤에 `sh -c "psql ... 2>&1"`), 컨테이너에서 본 호스트는 `PG_WIRE_HOST`(기본 `host.containers.internal`, macOS podman), xqlite가 받는 주소는 `PG_WIRE_LISTEN`(기본 `0.0.0.0`)으로 바꿉니다.
- `--regress`는 `tools/dialect/pg-regress`(`PG_REGRESS_DIR`)의 PostgreSQL 회귀 테스트(REL_16_STABLE의 `boolean`, `int2`, `int4`, `int8`, `text`, `varchar`, `case`, `strings`, PostgreSQL 라이선스는 그 디렉터리의 `COPYRIGHT`)를 pg_regress처럼(`psql -X -a -q`, `PGTZ=PST8PDT`, `PGDATESTYLE='Postgres, MDY'`) xqlite에서만 돌리고 `expected/TEST.out`과 문장별로 비교합니다. `setup.sql`(`test_setup.sql`의 `INT4_TBL` 등)이 테스트마다 먼저 돕니다. 출력이 있는 문장 중 기대 출력과 같은 것의 비율과, 다른 것의 세 가지 분류를 찍습니다.

## WebAssembly

```sh
zig build test-wasi                      # 단위 테스트(wasm32-wasi, wasmtime) + xqt wasi
zig build -Dtarget=wasm32-wasi && zig-out/bin/xqt wasi --wasm zig-out/bin/xqlite.wasm
zig build wasm-example                   # wasm32-freestanding 모듈을 Node.js에서
```

`zig build test-wasi`는 wasmtime(`PATH`)이 필요하고 `zig build check`에는 들어 있지 않습니다. 하는 일은 다음과 같습니다.

- 모듈(`src/root.zig`), CLI(`src/cli/main.zig`), VFS·스토리지·공용 패키지(`pkg/vfs`, `pkg/storage`, `pkg/base`)의 단위 테스트를 wasm32-wasi로 빌드해 `wasmtime run --dir .`로 저장소 루트에서 돌립니다. 테스트의 임시 디렉터리는 `.zig-cache/tmp`입니다. POSIX VFS의 `-shm` 파일과 파일 권한에 기대는 테스트 셋은 WASI에서 건너뜁니다.
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

`zig build test-capi`(`zig build check`에 포함)는 `tools/capi/capi_test.c`를 `include/sqlite3.h`와 함께 컴파일해 정적·공유 `libxqlite3`에 각각 링크하고 돌립니다. 실패한 검사를 출력하고 0이 아닌 코드로 끝납니다. 이 프로그램은 SQLite 아말감에 링크해도 xqlite 확장과 문서에 적은 차이 말고는 모두 통과하므로, 기대값은 SQLite의 동작입니다.

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
| `xqt gen parser` | SQLite 문법(`parse.y`)에서 `src/parse/grammar.zig`를 다시 만듭니다. `ref/sqlite`가 필요하고, lemon과 mkkeywordhash를 `zig cc`로 빌드합니다. |
| `xqt gen opcodes` | `src/vdbe/opcodes.zig`를 다시 만듭니다. `ref/sqlite`와 tclsh가 필요합니다. |

`xqt gen`은 이름을 여럿 받아(`xqt gen parser opcodes`) 동시에 돌립니다. 출력은 프로세스 안에서 `zig fmt`와 같은 형식으로 맞춥니다.

## 테스트 전략

| 영역 | 방법 | 지금 |
| --- | --- | --- |
| SQLite | [sqllogictest](https://www.sqlite.org/sqllogictest/)와 SQLite TCL 테스트 스위트 일부를 포팅 | sqllogictest 실행기, 플래너 케이스 일부를 TCL 테스트에서 뽑음 |
| 파일 포맷 | 순정 SQLite와 xqlite가 서로 만든 DB 파일을 교차로 읽고 쓰고 `PRAGMA integrity_check`로 검증 | `xqt interop` |
| PostgreSQL / MariaDB / MSSQL / Oracle | 같은 쿼리를 실제 서버와 xqlite에서 실행해 비교(differential testing), 각 DB의 regression test에서 필요한 부분을 가져옴 | `xqt dialect-diff pg`, `xqt dialect-diff mariadb`, `xqt dialect-diff mssql`, `xqt dialect-diff oracle`, `xqt wire-diff pg`(와이어 서버, `--regress`) |
| 퍼징 | 파서, 레코드 디코더, B-Tree 페이지 디코더, IR | `fuzzcheck`, 시드 퍼저 |
| 크래시 복구 | 오류를 주입하는 VFS로 쓰기 도중 전원 차단을 흉내 내고, sqlite3는 preload shim으로 죽임 | `pkg/vfs/src/crash.zig`, `tools/crashshim.c`, `xqlite crash-write`(`xqt interop wal`, `attach`, `vacuum`, `hot-journal`) |
