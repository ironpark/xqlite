# AGENTS.md

이 저장소에서 작업하는 에이전트(사람 포함)를 위한 지시사항과 테스트 방식입니다. 자세한 도구 설명은 [docs/testing.md](docs/testing.md), 구조는 [docs/architecture.md](docs/architecture.md)에 있습니다.

## 프로젝트

- xqlite는 SQLite 3.54.1을 순수 Zig(0.17)로 옮긴 것입니다. 파일 형식과 바이트코드가 SQLite와 호환됩니다.
- 3.54.1 뒤의 SQLite 업스트림은 따라가지 않습니다. 코드는 업스트림에서 다시 생성하지 않고(lemon 문법 대신 손으로 쓴 파서, `src/dialect/sqlite/parser.zig`) 고쳐 나갑니다. 아래의 SQLite 방언 호환 규칙은 그대로입니다.
- 방언은 sqlite, postgres, mariadb, mssql, oracle입니다. 각 방언은 `src/dialect/<방언>/`에 있습니다.
- 그 밖에 sqlite3 C ABI, WASI/wasm 대상, 와이어 서버(`src/server`: PostgreSQL v3, MySQL), sqlite3용 확장([docs/extension.md](docs/extension.md))이 있습니다.
- 문서는 한국어입니다. 동작이 바뀌면 같은 작업에서 해당 문서(`docs/*.md`, 방언별 폴더 `docs/<방언>/`, `README.md`)를 기존 문체로 고칩니다.

## 지켜야 할 것

- **SQLite 방언은 결과가 같아야 함**: SQLite 방언이 SQLite(3.54.1)와 같아야 하는 것은 다음입니다.
  - 파일 형식(레코드와 인덱스 키의 인코딩, collation, 저널·WAL)과 `sqlite_schema`에 저장되는 텍스트. 한 데이터베이스를 두 엔진이 번갈아 읽고 씁니다.
  - 실행 결과: 값과 타입, 오류 문구와 위치, 여러 제약 중 어느 위반이 먼저 보고되는지, 트리거 순서, `changes()`·`last_insert_rowid()` 같은 부수 효과.
  - sqlite3 C ABI와 확장(가상 테이블의 `xBestIndex` 계약 포함).
  - `ORDER BY`가 없는 결과의 행 순서도 지금은 같게 둡니다. 실행 계획을 바꾸는 작업에서 케이스별로 풉니다.
  - 코어의 타입 계층은 SQLite 방언에서 꺼져 있습니다(`typing.active(db)`가 false).
- **바이트코드와 실행 계획은 같지 않아도 됨**: 처음에는 포팅의 오류를 잡으려고 바이트코드(레지스터 번호, 라벨과 opcode의 순서)까지 SQLite와 맞췄습니다. 이제는 목표가 아닙니다. 코드 생성과 VDBE는 C의 구조를 따르지 않고 Zig답게 고쳐도 됩니다. 그래서 `EXPLAIN`의 내용, `bytecode()` 가상 테이블, `sqlite3_stmt_status()`의 카운터(`VM_STEP`, `FULLSCAN_STEP`, `SORT` ...)는 SQLite와 달라질 수 있고, API와 형식만 유지합니다.
  - 대신 바뀐 것은 기록에 남깁니다. `xqt planner`는 `EXPLAIN`과 `EXPLAIN QUERY PLAN`을 xqlite 자신의 기록(`tools/planner/expected/*.plan`)과 비교합니다. 바이트코드를 바꾸지 않는 리팩터링은 기록이 그대로 통과해야 합니다.
  - 의도해서 바꿨으면 바꾸기 전 빌드와 비교해(`xqt planner --base 예전-xqlite -v`) 달라진 것이 의도한 것뿐인지 본 뒤 `xqt planner --record`로 기록을 갱신하고, 무엇이 왜 달라졌는지 커밋 메시지에 씁니다.
- **스키마에 저장되는 엔진 함수의 의미는 바꾸지 않음**: CHECK, DEFAULT, 생성 열, 식 인덱스, 뷰가 부르는 `xq_*` 함수, collation, 정렬 키 인코딩이 여기에 해당합니다.
  - 식 인덱스와 STORED 생성 열은 결과를 디스크에 남깁니다. 의미가 바뀌면 xqlite끼리도, xqlite와 sqlite3 + 확장 사이에서도 인덱스가 깨집니다.
  - 동작을 바꿔야 하면 새 이름을 쓰고 확장의 ABI 버전을 올립니다([docs/extension.md](docs/extension.md)).
- **코드 생성은 타입 있는 빌더로**: VDBE 명령은 `aux.emit()` 계열로 내고, 레지스터·커서·라벨·주소는 `Reg`·`Cursor`·`Label`·`Addr`로 둡니다([docs/architecture.md](docs/architecture.md#코드-생성과-vdbe-피연산자)). 타입 없는 `aux.emitRaw()`는 피연산자에 타입을 줄 수 없는 곳(이미 낸 명령의 복사 등)에만 씁니다.
- **방언은 빌드에서 뺄 수 있음**(`-Ddialects=`). 그래서 다음을 지킵니다.
  - 테스트는 쓰는 방언이 빌드되지 않았으면 건너뜁니다.
    - Zig 테스트: `try Dialect.requireBuilt(&.{ .postgres })`
    - 컴파일 시점의 참조: `if (comptime Dialect.x.built())`
    - xqt interop 모듈: `pub const dialect = "..."`
    - C 테스트: `dialect_built()`
  - 공용 IR(`src/ir/lower.zig`, `render.zig`)이 모든 방언에 쓰는 엔진 함수는 방언 디렉터리 밖에 둡니다(예: `src/dialect/like.zig`).
- **커밋**: 요청이 있을 때만 합니다. 병렬 작업의 에이전트는 커밋하지 않고 워크트리에 변경을 남깁니다. 기본 브랜치에서 커밋해야 하면 먼저 브랜치를 만듭니다.
- **건드리지 않을 것**: 공유 캐시 `~/.cache/zig`, 이 프로젝트가 아닌 podman 컨테이너와 이미지.

## 테스트 단계

검사는 세 단계입니다. 병렬로 일하는 에이전트는 1·2단계까지만 돌립니다. 3단계는 통합하는 쪽이 합친 뒤 한 번 돌립니다. 여러 에이전트가 동시에 3단계를 돌리면 CPU를 나눠 써서 모두 느려집니다.

### 1. 빠른 단계 (작업 중)

```sh
zig build                                              # 빌드만
zig build test -Dtest-filter='pg: arrays'              # 이름에 그 텍스트가 든 테스트만
zig-out/bin/xqlite sql t.db ".dialect postgres" "SELECT ...;" </dev/null
zig build tools && zig-out/bin/xqt dialect-diff pg     # 기록과 비교, 서버 필요 없음 (1초 미만)
zig-out/bin/xqt dialect-diff pg tools/dialect/pg-array-cases.txt
zig-out/bin/xqt interop pg                             # 한 모듈만
```

`-Ddialects=X`로 특정 구성만 직접 빌드하면 `zig-out/bin/xqlite`가 그 구성으로 바뀝니다. 그 뒤에는 `zig build && zig build tools`로 되돌립니다. `check-matrix`는 zig-out을 건드리지 않습니다.

퍼저(`src/fuzz_tests.zig`)를 시드 여러 개로 돌릴 때는 ReleaseSafe로 한 번 빌드하고 병렬로 실행합니다. Debug로 하나씩 돌리면 몇 분이 걸리는 것이 시드 20개에 10초 안팎입니다.

```sh
zig build fuzz -Doptimize=ReleaseSafe -- ir_roundtrip 1 --events 1    # 빌드만
F=$(ls -t .zig-cache/o/*/fuzz | head -1)
for s in 1 2 3 4 5 6 7 8; do $F ir_roundtrip $s --events 3000 & done; wait
```

실패를 찾으면 같은 시드를 통합 전 커밋에서도 돌려 이번 변경 때문인지부터 가립니다.

### 2. 표준 단계 (작업을 마칠 때)

```sh
zig build check
zig fmt --check src tools
```

`check`에는 단위 테스트, xqt 자체 테스트, `xqt interop` 전체, planner, fuzzcheck, 기록된 `dialect-diff pg`가 들어 있습니다.

### 3. 전체 단계 (통합할 때만)

```sh
zig build check check-matrix -Dfuzz=true   # 기본 구성 전부 + 방언 없음·방언 하나씩의 다섯 구성 (한 빌드, 약 6분)
zig build test-wasi
zig build test-pkg
zig build wasm
zig-out/bin/xqt wire-diff pg     # psql 18 필요(없으면 일회용 클라이언트 컨테이너)
zig-out/bin/xqt wire-diff pg --regress
```

## PostgreSQL 비교와 기록 데이터셋

기준은 PostgreSQL 18입니다.

- **기록과 비교(기본)**: PostgreSQL의 출력은 `tools/dialect/pg-expected/*.out`에 기록되어 있고, 기본 모드는 이 기록과 비교하므로 DB 서버가 필요 없습니다.
  - 케이스 텍스트가 바뀌면 `STALE RECORDING`, 기록이 없으면 `NOT RECORDED`로 실패합니다.
  - 회귀 테스트(`--regress`)는 PostgreSQL이 함께 배포하는 `expected/*.out`을 기대값으로 씁니다.
- **새 케이스를 더할 때**:
  1. 케이스 파일(`tools/dialect/pg-*.txt`)에 씁니다.
  2. 실제 서버에서 기록합니다. 기록에는 컨테이너가 필요합니다.

     ```sh
     podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18-alpine
     zig-out/bin/xqt dialect-diff pg --record [CASES-FILE]
     zig-out/bin/xqt wire-diff pg --record
     ```

  3. 새 케이스 파일은 `build.zig`의 `recorded_dialects`에 넣어 `zig build check`에 들어가게 합니다.
- **컨테이너 규칙**:
  - xq-* DB 컨테이너는 한 번에 하나만 띄웁니다.
  - 여러 에이전트가 같은 `xq-pg`를 함께 쓸 때는 각자 자기 데이터베이스만 씁니다. 도구는 pid를 넣은 이름(`xqt_dialect_<pid>_N`)을 쓰고, 손으로 쓰는 질의는 `podman exec -i xq-pg psql -U postgres -d <내 DB>`로 합니다.
  - 만든 데이터베이스는 지우고, 컨테이너를 멈추거나 다시 만들지 않습니다. 컨테이너는 그것을 띄운 쪽이 지웁니다.
  - 일회용 클라이언트 컨테이너(`podman run --rm ... psql`)는 써도 됩니다.
  - MariaDB 컨테이너는 로그에 `ready for connections.*port: 3306`이 나온 뒤에 씁니다.
- **다른 방언**: MariaDB, SQL Server, Oracle은 아직 기록이 없습니다. 지금은 `xqt dialect-diff mariadb|mssql|oracle --live`로 서버와 직접 비교합니다.

## 병렬 작업

- **워크트리**: 에이전트마다 자기 워크트리(`.claude/worktrees/`)에서 일합니다.
  - 워크트리에는 gitignore된 `ref/`가 없습니다. fuzzcheck가 그 코퍼스를 쓰므로 필요하면 본 체크아웃의 `ref/`를 심볼릭 링크로 걸고, 끝나기 전에 지웁니다.
- **함께 쓰는 파일**: 여러 작업이 같이 건드리기 쉬운 곳입니다. 고칠 때는 한 덩어리로 모아 두어 합치기 쉽게 합니다.
  - 저장 변환 `Rules.store`, 값 표시 계층
  - `src/dialect/postgres/operators.zig`, `overload.zig`, `funcs.zig`, `pgcatalog.zig`, `catalog_views.zig`
  - `build.zig`, 확장의 함수 목록
- **최종 보고**: 설계와 그 근거, 범위별로 한 것, 실제 PostgreSQL과 비교한 수치, 바꾼 파일, 돌린 검사와 결과, 남은 한계를 씁니다. 실패한 검사는 출력과 함께 그대로 보고합니다.

## 명령에서 주의할 것

- `xqlite sql`은 stdin을 읽습니다. 늘 입력을 넘깁니다(`</dev/null` 또는 here-doc).
- macOS에는 `timeout` 명령이 없습니다.
- 백그라운드로 띄운 서버(`xqlite serve` 등)는 끝나기 전에 종료합니다.
- `xqlite serve`의 비밀번호는 `--password` 대신 `$XQLITE_PASSWORD`로 넘기고, 로그에 남기지 않습니다.
- git hook이 `git` 명령을 다른 도구로 바꾸는 환경이면 `/usr/bin/git`을 직접 씁니다.
