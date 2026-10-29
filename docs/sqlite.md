# SQLite 호환

xqlite의 기본 방언은 SQLite 3.54.1입니다. 순수 Zig 포팅이지만 파일 포맷, SQL 결과, 그리고 가능한 곳에서는 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`)까지 sqlite3와 같게 맞춥니다. SQLite 방언은 다른 방언이 추가되어도 동작이 바뀌지 않습니다.

## 구현된 것

- 기반과 스토리지: VFS(POSIX·메모리), 페이지 캐시, Pager(롤백 저널), 세이브포인트, B-Tree 읽기/쓰기(auto-vacuum·incremental vacuum 포함), 레코드 포맷. 기존 SQLite 파일을 그대로 읽고 씁니다.
- SQL: Lexer/LALR(1) 파서(SQLite `parse.y`에서 생성), VDBE, 플래너, `sqlite3` 호환 셸(`xqlite sql`).
- 윈도우 함수: `OVER`/`WINDOW`/`FILTER`, ROWS·RANGE·GROUPS 프레임과 `EXCLUDE`, 내장 윈도우 함수(`row_number`, `rank`, `ntile`, `lead`/`lag`, `nth_value` 등). 결과와 바이트코드를 sqlite3 3.54.1과 맞춤
- 가상 테이블: `CREATE VIRTUAL TABLE`, 모듈 등록(`sql.vtab.createModule`, `sqlite3_module`에 대응하는 Zig 구조체), `xBestIndex` 기반 플래너(제약·ORDER BY·IN·LIMIT/OFFSET 전달), `xUpdate`로 INSERT/UPDATE/DELETE, `xBegin`~`xRollbackTo` 트랜잭션·세이브포인트, `xRename`, `xFindFunction` 오버로드, eponymous 테이블과 테이블 값 함수. 내장 모듈로 `pragma_*` 테이블 값 함수, `bytecode()`/`tables_used()`, 셸의 `generate_series`. 결과와 바이트코드를 sqlite3 3.54.1과 맞춤
- WAL: `PRAGMA journal_mode=WAL`과 다른 모드로 되돌리기(헤더의 파일 포맷 버전 18/19바이트 포함), `-wal`·`-shm` 파일 형식과 잠금 프로토콜(shm 바이트 락, dead-man switch)을 SQLite 3.54.1과 같게 맞춰 xqlite와 sqlite3 프로세스가 한 DB를 동시에 읽고 씀. 읽기 스냅샷과 read mark, `walIndexRecover`로 크래시 뒤 wal-index 재구성, 캐시 스필과 세이브포인트·롤백, 체크포인트(PASSIVE/FULL/RESTART/TRUNCATE/NOOP, `wal_autocheckpoint`, `sqlite3_wal_checkpoint_v2`, WAL 훅), `journal_size_limit`, 읽기 전용 shm(heap wal-index). unix VFS는 `-shm`을 mmap하고 메모리 VFS는 공유 메모리를 힙에 둠. `busy_timeout`이 실제 바쁜 핸들러(`sqliteDefaultBusyCallback`)로 동작. 결과와 바이트코드를 sqlite3 3.54.1과 맞춤. `locking_mode=EXCLUSIVE`, 스냅샷 API는 아직
- JSON: `json`/`jsonb` 계열 스칼라 함수, `->`/`->>` 연산자, `json_group_array`/`json_group_object`(윈도우 함수 포함), JSON5 입력과 JSONB 바이너리 형식, `json_each`/`json_tree`/`jsonb_each`/`jsonb_tree` 테이블 값 함수(경로 인자, 상관 인자, 조인). 결과를 sqlite3 3.54.1과 바이트 단위로 맞춤

## 검증

| 도구 | 확인하는 것 |
| --- | --- |
| `tools/interop-btree.sh`, `interop-sql.sh` | 서로 만든 DB 파일을 교차로 읽고 쓰고 `PRAGMA integrity_check` |
| `tools/interop-pragma.sh`, `interop-shell.sh` | PRAGMA 결과, 셸 출력·dot-command·오류, `.dump` 왕복 |
| `tools/interop-savepoint.sh`, `interop-hot-journal.sh` | 세이브포인트·문장 롤백, 핫 저널 복구 |
| `tools/interop-wal.sh` | WAL 파일 상호 읽기, 체크포인트, 크래시 복구, 두 엔진 프로세스 동시 접근 |
| `tools/planner/diff.py` | 쿼리 결과·`EXPLAIN QUERY PLAN`·바이트코드를 sqlite3와 비교 |
| `tools/slt/run.py` | sqllogictest |
| `xqlite fuzzcheck` | SQLite 퍼즈 코퍼스(`test/fuzzdata*.db`)에서 크래시·누수 |

실행 방법은 [README의 빌드](../README.md#빌드)를 보세요.

## 아직 하지 않은 것

- `locking_mode=EXCLUSIVE`(WAL), 스냅샷 API
- sqllogictest 전체 통과
- Windows VFS, sqlite3 호환 C ABI
