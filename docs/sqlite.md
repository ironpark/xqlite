# SQLite 호환

xqlite의 기본 방언은 SQLite 3.54.1입니다. 순수 Zig 포팅이지만 파일 포맷과 SQL 결과를 sqlite3와 같게 맞추고, 가능한 곳에서는 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`)까지 같게 맞춥니다. SQLite 방언은 다른 방언이 추가되어도 동작이 바뀌지 않습니다.

## 목차

- [호환 수준](#호환-수준)
- [구현된 기능](#구현된-기능)
- [내장 모듈과 확장](#내장-모듈과-확장)
- [검증 도구](#검증-도구)
- [아직 하지 않은 것](#아직-하지-않은-것)

## 호환 수준

| 보장하는 것 | 확인 방법 |
| --- | --- |
| 파일 포맷: 기존 SQLite 파일을 그대로 읽고 쓰고, 서로 만든 파일이 `PRAGMA integrity_check`를 통과 | `tools/interop-*.sh` |
| 저널·WAL 호환: 서로의 핫 저널을 복구하고, 한 DB를 두 엔진 프로세스가 동시에 읽고 씀 | `tools/interop-hot-journal.sh`, `tools/interop-wal.sh` |
| 쿼리 결과 | `tools/planner/diff.py`, sqllogictest |
| 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`) | `tools/planner/diff.py` |
| 셸 출력 | `tools/interop-shell.sh` |

## 구현된 기능

### 스토리지

- VFS는 POSIX와 메모리 두 가지입니다.
- 페이지 캐시와 Pager(롤백 저널)가 있습니다. 저널 형식이 SQLite와 바이트 단위로 같아서 서로의 핫 저널을 복구합니다.
- 세이브포인트와 그 위의 문장 트랜잭션을 지원합니다.
- B-Tree 읽기/쓰기와 레코드 포맷을 구현했습니다.
- auto-vacuum과 incremental vacuum을 지원합니다.
- 기존 SQLite 파일을 그대로 읽고 씁니다.

### SQL

- Lexer와 LALR(1) 파서는 SQLite의 `parse.y`에서 생성합니다.
- VDBE와 쿼리 플래너를 포팅했습니다.
- `xqlite sql`은 `sqlite3` 호환 셸입니다. 출력 모드와 자주 쓰는 dot-command(`.dump`, `.schema`, `.tables`, `.mode` 등)를 지원하며, 목록은 `.help`로 볼 수 있습니다.

### 윈도우 함수

- `OVER`, `WINDOW`, `FILTER` 절을 지원합니다.
- ROWS·RANGE·GROUPS 프레임과 `EXCLUDE`를 지원합니다.
- 내장 윈도우 함수(`row_number`, `rank`, `ntile`, `lead`/`lag`, `nth_value` 등)가 있습니다.
- 결과와 바이트코드를 sqlite3 3.54.1과 맞췄습니다.

### 가상 테이블

- `CREATE VIRTUAL TABLE`을 지원합니다.
- 모듈은 `sql.vtab.createModule`로 등록합니다. 모듈은 `sqlite3_module`에 대응하는 Zig 구조체입니다.
- 플래너가 `xBestIndex`로 제약, ORDER BY, IN, LIMIT/OFFSET을 모듈에 전달합니다.
- `xUpdate`로 INSERT/UPDATE/DELETE를 처리합니다.
- `xBegin`부터 `xRollbackTo`까지 트랜잭션과 세이브포인트 메서드를 호출합니다.
- `xRename`과 `xFindFunction` 오버로드를 지원합니다.
- eponymous 테이블과 테이블 값 함수를 지원합니다.
- 결과와 바이트코드를 sqlite3 3.54.1과 맞췄습니다.

### WAL

- 모드 전환
  - `PRAGMA journal_mode=WAL`로 켜고 다른 모드로 되돌릴 수 있습니다.
  - 전환할 때 헤더의 파일 포맷 버전(18·19바이트)도 바꿉니다.
- 파일과 잠금
  - `-wal`·`-shm` 파일 형식과 잠금 프로토콜(shm 바이트 락, dead-man switch)이 SQLite 3.54.1과 같습니다.
  - 그래서 xqlite와 sqlite3 프로세스가 한 DB를 동시에 읽고 씁니다.
  - unix VFS는 `-shm`을 mmap하고, 메모리 VFS는 공유 메모리를 힙에 둡니다.
  - 읽기 전용 shm은 힙 wal-index로 처리합니다.
- 읽기와 복구
  - 읽기 스냅샷과 read mark를 구현했습니다.
  - 크래시 뒤에는 `walIndexRecover`로 wal-index를 재구성합니다.
- 쓰기와 롤백
  - 캐시 스필을 WAL에 프레임으로 씁니다.
  - 세이브포인트와 롤백을 지원합니다.
- 체크포인트
  - PASSIVE, FULL, RESTART, TRUNCATE, NOOP 모드를 지원합니다.
  - `wal_autocheckpoint`, `sqlite3_wal_checkpoint_v2`, WAL 훅을 지원합니다.
  - `journal_size_limit`을 지원합니다.
- `busy_timeout`은 실제 바쁜 핸들러(`sqliteDefaultBusyCallback`)로 동작합니다.
- 결과와 바이트코드를 sqlite3 3.54.1과 맞췄습니다.

### JSON

- `json`/`jsonb` 계열 스칼라 함수와 `->`/`->>` 연산자를 지원합니다.
- 집계 함수 `json_group_array`/`json_group_object`는 윈도우 함수로도 씁니다.
- JSON5 입력과 JSONB 바이너리 형식을 지원합니다.
- 테이블 값 함수 `json_each`/`json_tree`/`jsonb_each`/`jsonb_tree`는 경로 인자, 상관 인자, 조인을 지원합니다.
- 결과를 sqlite3 3.54.1과 바이트 단위로 맞췄습니다.

## 내장 모듈과 확장

| 모듈 | 위치 | 등록 |
| --- | --- | --- |
| `pragma_*` 테이블 값 함수 | `src/sql/pragma.zig` | 항상 |
| `json_each`, `json_tree`, `jsonb_each`, `jsonb_tree` | `src/sql/json.zig` | 항상 |
| `bytecode()`, `tables_used()` | `src/vdbe/vdbevtab.zig` | 항상 |
| `generate_series()` (`ext/misc/series.c` 포팅) | `src/ext/series.zig` | 셸(`xqlite sql`)이 등록합니다. sqlite3 셸과 같습니다. |
| `vtablog` (`ext/misc/vtablog.c` 포팅, 메서드 호출을 출력) | `src/ext/vtablog.zig` | 셸에서 `XQ_VTABLOG` 환경 변수가 있을 때만 등록합니다. 차등 테스트용입니다. |

## 검증 도구

| 도구 | 확인하는 것 |
| --- | --- |
| `tools/interop-btree.sh`, `interop-sql.sh` | 서로 만든 DB 파일을 교차로 읽고 쓰고 `PRAGMA integrity_check` |
| `tools/interop-pragma.sh`, `interop-shell.sh` | PRAGMA 결과, 셸 출력·dot-command·오류, `.dump` 왕복 |
| `tools/interop-savepoint.sh`, `interop-hot-journal.sh` | 세이브포인트·문장 롤백, 핫 저널 복구 |
| `tools/interop-wal.sh` | WAL 파일 상호 읽기, 체크포인트, 크래시 복구, 두 엔진 프로세스 동시 접근 |
| `tools/planner/diff.py` | 쿼리 결과·`EXPLAIN QUERY PLAN`·바이트코드를 sqlite3와 비교 |
| `tools/slt/run.py` | sqllogictest. WAL 모드로도 돌립니다([tools/slt/README.md](../tools/slt/README.md)). |
| `xqlite fuzzcheck` | SQLite 퍼즈 코퍼스(`test/fuzzdata*.db`)에서 크래시·누수 |

실행 방법은 [테스트 문서](testing.md)를 보세요.

## 아직 하지 않은 것

문장으로 쓰면 `not supported yet` 오류가 나는 것:

- `ATTACH`, `DETACH`
- `VACUUM`, `ANALYZE`, `PRAGMA optimize`
- `PRAGMA locking_mode=EXCLUSIVE`. 그래서 힙 메모리 WAL 모드도 없습니다.
- `PRAGMA journal_mode=MEMORY`
- `PRAGMA encoding=UTF-16`

그 밖에 없는 것:

- WAL 스냅샷 API
- 백업 API
- 다중 DB 커밋의 super journal 쓰기. 복구할 때 읽기만 합니다.
- 메모리 맵 I/O. `PRAGMA mmap_size`는 항상 0을 돌려줍니다.
- sqllogictest 전체 통과
- Windows VFS
- sqlite3 호환 C ABI
