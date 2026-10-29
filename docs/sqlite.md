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
| 파일 포맷: 기존 SQLite 파일을 그대로 읽고 쓰고, 서로 만든 파일이 `PRAGMA integrity_check`를 통과 | `xqt interop` |
| 저널·WAL 호환: 서로의 핫 저널을 복구하고, 한 DB를 두 엔진 프로세스가 동시에 읽고 씀 | `xqt interop hot-journal`, `xqt interop wal` |
| 쿼리 결과 | `xqt planner`, sqllogictest(`xqt slt`) |
| 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`) | `xqt planner` |
| 셸 출력 | `xqt interop shell` |

## 구현된 기능

### 스토리지

- VFS는 POSIX와 메모리 두 가지입니다.
- 페이지 캐시와 Pager(롤백 저널)가 있습니다. 저널 형식이 SQLite와 바이트 단위로 같아서 서로의 핫 저널을 복구합니다.
- 세이브포인트와 그 위의 문장 트랜잭션을 지원합니다.
- B-Tree 읽기/쓰기와 레코드 포맷을 구현했습니다.
- auto-vacuum과 incremental vacuum을 지원합니다.
- 기존 SQLite 파일을 그대로 읽고 씁니다.
- 파일은 sqlite3처럼 전체 경로(`xFullPathname`, 심볼릭 링크를 따라감)로 부릅니다. 그래서 `PRAGMA database_list`가 같은 이름을 보여 줍니다.

### SQL

- Lexer와 LALR(1) 파서는 SQLite의 `parse.y`에서 생성합니다.
- VDBE와 쿼리 플래너를 포팅했습니다.
- `xqlite sql`은 `sqlite3` 호환 셸입니다. 출력 모드와 자주 쓰는 dot-command(`.dump`, `.schema`, `.tables`, `.mode` 등)를 지원하며, 목록은 `.help`로 볼 수 있습니다.

### ATTACH와 여러 데이터베이스

- `ATTACH [DATABASE] expr AS name [KEY expr]`와 `DETACH [DATABASE] name`은 attach.c 포팅입니다. sqlite3처럼 내부 함수 `sqlite_attach()`/`sqlite_detach()`를 부르는 `OP_Function`과 `OP_Expire`를 만들므로 바이트코드가 같습니다.
- 오류 메시지가 같습니다: `too many attached databases - max %d`(`SQLITE_LIMIT_ATTACHED`, 최대 10), `database %s is already in use`, `no such database: %s`, `cannot detach database %s`, `database %s is locked`, `unable to open database: %s`.
- 트랜잭션 안에서도 붙이고, 읽거나 쓰는 중인 데이터베이스는 떼지 못합니다. `DETACH` 전에 준비된 문장은 다시 컴파일됩니다.
- `":memory:"`와 `""`는 연결 전용 임시 데이터베이스입니다.
- `SQLITE_DBCONFIG_ENABLE_ATTACH_CREATE`/`_WRITE`가 꺼져 있으면 새 파일을 만들지 않거나 읽기 전용으로 붙입니다.
- URI 파일 이름(`file:x.db?mode=ro`)은 `OpenFlags.uri`로 연 연결에서 받습니다. `xqlite sql` 셸은 sqlite3 셸처럼 켜 둡니다. `mode`, `cache`와 `%HH`를 처리합니다.
- 붙인 데이터베이스에서도 스키마 읽기, `name.sqlite_schema`, WAL 모드, `PRAGMA name.xxx`, 스키마 인자를 받는 `pragma_*` 테이블 값 함수, 뷰·트리거의 DbFixer 검사, 붙인 테이블에 거는 TEMP 트리거가 sqlite3와 같게 동작합니다.
- 롤백 저널 모드에서 두 개 이상의 파일에 쓰는 트랜잭션은 super journal(`<main>-mjXXXXXX9XX`)로 커밋합니다. 그래서 커밋 도중에 죽어도 모든 파일이 함께 되돌아가거나 함께 커밋됩니다. 형식이 sqlite3와 같아서 서로 남긴 super journal을 복구합니다.
- 엔진 쪽 API: `sql.main.dbName()`, `dbFilename()`, `dbReadonly()`(`sqlite3_db_name`, `sqlite3_db_filename`, `sqlite3_db_readonly`). 엔진 코드가 데이터베이스를 붙였다 뗄 때는 `ATTACH` 문장을 실행하고 `sql.attach.closeDb()`로 뗍니다(VACUUM이 쓰는 방식).

### VACUUM과 백업 API

- `VACUUM [schema]`와 `VACUUM [schema] INTO expr`는 vacuum.c 포팅입니다. `OP_Vacuum` 하나를 만드는 바이트코드가 sqlite3와 같습니다.
  - sqlite3처럼 임시 데이터베이스를 `vacuum_XXXXXXXXXXXXXXXX`로 붙이고, 같은 스키마를 만든 뒤 테이블마다 `INSERT INTO ... SELECT * FROM ...`으로 옮깁니다. 행은 전송 최적화(insert.c의 `xferOptimization()`, `OP_RowCell`)로 레코드째 rowid 순서대로, 인덱스도 인덱스 순서대로 옮기므로 페이지 배치가 sqlite3와 같습니다.
  - 그다음 백업 API로 원래 파일에 페이지 단위로 덮어씁니다(`sqlite3BtreeCopyFile()`). 그래서 같은 입력을 VACUUM한 파일은 sqlite3가 VACUUM한 파일과 바이트 단위로 같습니다(빈 freelist, 헤더 필드 포함).
  - schema cookie는 1 오르고, `default_cache_size`, 텍스트 인코딩, `user_version`, `application_id`는 그대로입니다.
  - `PRAGMA page_size`와 `PRAGMA auto_vacuum`(켜기, 끄기, FULL과 INCREMENTAL 사이 전환)은 VACUUM에서 적용됩니다. WAL 데이터베이스는 페이지 크기를 바꾸지 않습니다(`VACUUM INTO`는 바꿉니다). `":memory:"`, `""` 같은 임시 데이터베이스도 sqlite3(`sqlite3PagerIsMemdb()`)처럼 페이지 크기를 바꾸지 않습니다.
  - `VACUUM INTO`의 대상이 URI(`file:out.db?reserve=N`)이면 `reserve=N`이 페이지 끝 예약 바이트 수가 됩니다.
  - 오류 메시지가 같습니다: `cannot VACUUM from within a transaction`, `cannot VACUUM - SQL statements in progress`, `output file already exists`, `non-text filename`, `unknown database %s`. `VACUUM temp`는 아무것도 하지 않습니다.
  - VACUUM이 붙이는 임시 데이터베이스는 `PRAGMA temp_store=MEMORY`여도 임시 파일입니다(sqlite3는 메모리에 둡니다). 결과 파일은 같습니다.
- 전송 최적화는 VACUUM이 아니어도 `INSERT INTO t1 SELECT * FROM t2`(호환되는 두 테이블)에 쓰입니다. 대상이 비어 있어야 하는 경우의 실행 시 검사까지 바이트코드가 sqlite3와 같습니다.
- 백업 API는 backup.c 포팅입니다(`src/sql/backup.zig`): `init()`, `step()`, `remaining()`, `pagecount()`, `finish()`(`sqlite3_backup_*`). 원본 pager에 등록해서, 원본 연결이 복사한 페이지를 바꾸면 다시 복사하고 다른 연결이 바꾸면 처음부터 다시 복사합니다. 페이지 크기가 다른 대상, WAL이나 임시 데이터베이스인 대상(페이지 크기가 다르면 `SQLITE_READONLY`), 오류(`source and destination must be distinct`, `destination database is in use`, `unknown database %s`)도 sqlite3와 같습니다. 백업 중에는 원본을 `DETACH`하거나 연결을 닫을 수 없습니다.
- Zig API는 `Db.backup()`과 `Backup`입니다([Zig API](zig-api.md#백업)). `xqlite sql` 셸에는 `.backup`, `.save`, `.restore`가 있습니다(`--append`는 없음).

### 통계(ANALYZE)

- `ANALYZE`, `ANALYZE schema`, `ANALYZE [schema.]table`, `ANALYZE [schema.]index`를 지원합니다. 이름 없는 `ANALYZE`는 TEMP만 빼고 모든 데이터베이스를 분석합니다.
- `sqlite_stat1`을 만들고 채웁니다. 같은 데이터면 행(rowid 포함)이 sqlite3와 바이트 단위로 같습니다.
  - 부분 인덱스, WITHOUT ROWID 테이블, `PRAGMA analysis_limit`을 지원합니다. 뷰, 가상 테이블, `sqlite_` 테이블은 건너뜁니다.
  - 테이블을 sqlite3의 스키마 해시 순서(`src/sql/hash.zig`)로 돌아서 바이트코드와 행 순서가 같습니다.
- 분석이 끝나면 `OP_LoadAnalysis`가 통계를 다시 읽으므로 같은 연결의 다음 쿼리부터 플래너가 씁니다. 다른 연결은 스키마를 읽을 때 `sqlite_stat1`을 읽습니다. 직접 쓴 `unordered`, `sz=N`, `noskipscan` 표시도 읽습니다.
- `PRAGMA [schema.]optimize[(MASK)]`는 pragma.c 3.54.1과 같은 기준으로 분석할 테이블을 고릅니다. 마스크 `0x01`(실행하지 않고 문장만 출력), `0x02`, `0x10`(analysis_limit), `0x10000`을 지원합니다.
- 결과와 바이트코드를 sqlite3 3.54.1과 맞췄습니다.

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
| `xqt interop btree`, `sql` | 서로 만든 DB 파일을 교차로 읽고 쓰고 `PRAGMA integrity_check` |
| `xqt interop pragma`, `shell` | PRAGMA 결과, 셸 출력·dot-command·오류, `.dump` 왕복 |
| `xqt interop savepoint`, `hot-journal` | 세이브포인트·문장 롤백, 핫 저널 복구 |
| `xqt interop wal` | WAL 파일 상호 읽기, 체크포인트, 크래시 복구, 두 엔진 프로세스 동시 접근 |
| `xqt interop attach` | 서로의 파일을 붙여 읽고 쓰기, 여러 파일 트랜잭션, 커밋 도중 크래시와 super journal 복구 |
| `xqt interop analyze` | 같은 데이터의 `sqlite_stat1` 행, 서로 분석한 DB의 실행 계획과 `PRAGMA optimize` |
| `xqt interop vacuum` | 같은 DB를 두 엔진이 `VACUUM`/`VACUUM INTO`한 파일의 바이트 비교, 셸의 `.backup`/`.restore`, VACUUM 도중 크래시 복구 |
| `xqt planner` | 쿼리 결과·`EXPLAIN QUERY PLAN`·바이트코드를 sqlite3와 비교 |
| `xqt slt` | sqllogictest. 스크립트 622개, 테스트 5,939,879개를 롤백 저널과 WAL 모드에서 모두 통과합니다([tools/slt/README.md](../tools/slt/README.md)). |
| `xqlite fuzzcheck` | SQLite 퍼즈 코퍼스(`test/fuzzdata*.db`)에서 크래시·누수 |

실행 방법은 [테스트 문서](testing.md)를 보세요.

## 아직 하지 않은 것

문장으로 쓰면 `not supported yet` 오류가 나는 것:

- `PRAGMA locking_mode=EXCLUSIVE`. 그래서 힙 메모리 WAL 모드도 없습니다.
- `PRAGMA journal_mode=MEMORY`
- `PRAGMA encoding=UTF-16`

그 밖에 없는 것:

- `sqlite_stat4`(`SQLITE_ENABLE_STAT4`). 기준 sqlite3 빌드도 끄므로 `ANALYZE`는 `sqlite_stat1`만 쓰고, `sqlite_stat4`·`sqlite_stat3`이 있으면 행을 지우기만 합니다.
- WAL 스냅샷 API
- 메모리 데이터베이스. `":memory:"`는 임시 파일이라 `journal_mode`가 `memory`가 아닌 `delete`입니다.
- VFS 등록과 이름. 그래서 URI의 `vfs=`는 늘 `no such vfs: %s`입니다.
- 공유 캐시. URI의 `cache=`는 검사만 하고 무시합니다.
- 권한 콜백(authorizer). `ATTACH`/`DETACH`도 검사하지 않습니다.
- 메모리 맵 I/O. `PRAGMA mmap_size`는 항상 0을 돌려줍니다.
- Windows VFS
- sqlite3 호환 C ABI
