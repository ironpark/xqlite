# SQLite 호환: 지원 기능

xqlite SQLite 방언이 지원하는 코어 스토리지 엔진, SQL 구문 및 내장 모듈/가상 테이블 명세입니다.

---

## 1. 스토리지 및 저널링 기능

- **VFS (가상 파일 시스템)**:
  - POSIX 표준 파일 I/O 및 인메모리 VFS를 지원합니다.
  - 심볼릭 링크를 추적하는 전체 경로(`xFullPathname`) 정규화를 지원하여 `PRAGMA database_list`가 네이티브와 일치합니다.
- **Pager 및 트랜잭션**:
  - 표준 롤백 저널(Rollback Journal) 및 WAL(Write-Ahead Logging) 모드를 지원합니다.
  - 바이트 단위 호환 저널 형식을 통해 네이티브 SQLite3가 생성한 핫 저널을 복구할 수 있습니다.
  - 중첩 세이브포인트(`SAVEPOINT`, `RELEASE`, `ROLLBACK TO`) 및 문장 단위 트랜잭션을 지원합니다.
  - `journal_mode`의 여섯 모드(DELETE, TRUNCATE, PERSIST, MEMORY, OFF, WAL)를 모두 지원합니다. MEMORY는 저널을 메모리 저널(`pkg/storage/src/pager/memjournal.zig`, memjournal.c 포팅)에 둡니다.
  - `:memory:`(와 URI의 `mode=memory`, `temp_store=MEMORY`일 때의 임시 데이터베이스)는 파일이 없는 인메모리 데이터베이스입니다. 페이지는 페이지 캐시를 떠나지 않고, `journal_mode`는 `memory`이며 `off`로만 바뀝니다. 이름 없는 임시 데이터베이스(`''`, TEMP)는 페이지를 내보내야 할 때 처음 임시 파일을 열고, 저널은 64 KiB까지 메모리에 둡니다. 둘 다 잠금을 잡지 않는 exclusive 모드입니다.
  - `PRAGMA locking_mode=EXCLUSIVE`: 첫 읽기 뒤 SHARED, 첫 쓰기 뒤 EXCLUSIVE 잠금을 놓지 않아 다른 연결(sqlite3 프로세스 포함)은 `database is locked`가 됩니다. 스키마 없이 쓰면 붙인 데이터베이스와 나중에 붙일 데이터베이스에도 적용됩니다. 이 모드에서 연 WAL은 wal-index를 `-shm` 파일 대신 힙 메모리에 두고, WAL이 열려 있는 동안은 normal로 돌아가지 않습니다.
  - `PRAGMA mmap_size`: POSIX VFS가 데이터베이스 파일을 읽기 전용으로 mmap하고, 페이저가 읽기 트랜잭션의 페이지를 맵에서 바로 씁니다(`xFetch`/`xUnfetch`). 최대는 `SQLITE_MAX_MMAP_SIZE`(2147418112), 기본은 0이고 `sqlite3_config(SQLITE_CONFIG_MMAP_SIZE)`로 바꿉니다. 파일이 아직 없는 임시·인메모리 데이터베이스는 행이 없습니다(SQLite처럼 `SQLITE_FCNTL_MMAP_SIZE`가 `SQLITE_NOTFOUND`). WebAssembly에는 메모리 맵이 없어 `SQLITE_MAX_MMAP_SIZE=0`인 빌드처럼 늘 0입니다.
- **B-Tree 엔진**:
  - 테이블 B-Tree 및 인덱스 B-Tree의 읽기/쓰기를 완벽 지원합니다.
  - `auto_vacuum` (NONE, FULL, INCREMENTAL) 및 `VACUUM`, `VACUUM INTO` 백업 API를 지원합니다.
- **다중 데이터베이스**:
  - `ATTACH [DATABASE] expr AS name` 및 `DETACH [DATABASE] name` 구문을 지원합니다.
  - 여러 파일에 걸친 원자적 커밋과 슈퍼 저널(Super Journal) 복구를 지원합니다.
- **텍스트 인코딩**:
  - UTF-8과 UTF-16(le, be) 데이터베이스를 SQLite처럼 읽고 씁니다. `PRAGMA encoding = 'UTF-8' | 'UTF-16' | 'UTF-16le' | 'UTF-16be'`는 데이터베이스가 만들어지기 전에만 듣고, `sqlite3_open16()`은 새 데이터베이스를 네이티브 바이트 순서의 UTF-16으로 만듭니다.
  - UTF-16 데이터베이스에서는 레코드와 `sqlite_schema`의 텍스트가 UTF-16이고, BINARY는 저장된 바이트를 비교하므로 인덱스와 `ORDER BY`의 순서가 UTF-8과 다릅니다(UTF-16le에서 `'Ā' < 'a'`). NOCASE와 RTRIM은 UTF-8용이라 UTF-8 사본을 비교합니다.
  - 내장 함수는 인자를 UTF-8로 읽고 결과를 데이터베이스 인코딩으로 저장합니다. `hex()`와 `octet_length()`, BLOB으로 다루는 인자는 저장된 UTF-16 바이트를 봅니다(`hex('a')`는 `6100`).
  - `ATTACH`한 데이터베이스는 main과 같은 인코딩이어야 합니다(`attached databases must use the same text encoding as main database`). `VACUUM`, `VACUUM INTO`, 백업은 인코딩을 그대로 옮깁니다.
  - SQLite가 아닌 방언은 UTF-16 데이터베이스에서 문장을 컴파일하지 않습니다([차이와 제한](differences.md)).

---

## 2. 지원 SQL 문법 및 플래너

- **DDL (데이터 정의어)**:
  - `CREATE TABLE [IF NOT EXISTS]`: `PRIMARY KEY`, `AUTOINCREMENT`, `UNIQUE`, `NOT NULL`, `CHECK`, `DEFAULT`, `COLLATE`
  - `STRICT` 테이블 및 생성 열(`GENERATED ALWAYS AS ... STORED / VIRTUAL`)
  - `CREATE INDEX [IF NOT EXISTS]`: 부분 인덱스(`WHERE`), 식 인덱스, `DESC` 인덱스
  - `CREATE VIEW`, `CREATE TRIGGER` (BEFORE/AFTER/INSTEAD OF)
  - `ALTER TABLE`: `RENAME TO`, `RENAME COLUMN`, `ADD COLUMN`, `DROP COLUMN`
- **DML (데이터 조작어)**:
  - `SELECT`: `DISTINCT`, 서브쿼리, 조인, `GROUP BY`, `HAVING`, `WINDOW`
  - 집합 연산: `UNION [ALL]`, `INTERSECT`, `EXCEPT`
  - 공통 테이블 식: `WITH [RECURSIVE]`
  - `INSERT`: 다중 행 삽입, `INSERT OR REPLACE / IGNORE`, `UPSERT` (`ON CONFLICT ... DO UPDATE / NOTHING`), `RETURNING`
  - `UPDATE` 및 `DELETE`: `WHERE`, `ORDER BY` / `LIMIT` (컴파일 옵션), `RETURNING`
- **쿼리 플래너 (Cost-based Query Planner)**:
  - 인덱스 비용 추정, 스킵 스캔(Skip-scan), 자동 인덱스 생성, 커버링 인덱스 스캔을 지원합니다.
  - `ANALYZE` 통계 수집(`sqlite_stat1`) 및 `PRAGMA optimize`를 지원합니다.

---

## 3. 내장 모듈 및 가상 테이블

| 모듈 | 소스 경로 | 지원 내용 |
| --- | --- | --- |
| **수학 함수** | `src/sql/func/math.zig` | `SQLITE_ENABLE_MATH_FUNCTIONS`의 `ceil`/`ceiling`, `floor`, `trunc`, `ln`, `log(x)`, `log(b, x)`, `log10`, `log2`, `exp`, `pow`/`power`, `mod`, `sin`·`cos`·`tan`과 역함수(`asin`, `acos`, `atan`, `atan2`), `sinh`·`cosh`·`tanh`과 역함수, `sqrt`, `radians`, `degrees`, `pi`. 결과 타입, NULL(정의역 밖, 숫자가 아닌 인자), `PRAGMA function_list`는 SQLite와 같고, 마지막 비트는 musl의 libm 값입니다([differences.md](differences.md)). SQLite 방언에만 있습니다. |
| **`pragma_*` 테이블 함수** | `src/sql/pragma.zig` | `SELECT * FROM pragma_table_info('tbl')` 등 모든 PRAGMA를 테이블 함수로 질의 가능. |
| **JSON 모듈** | `src/sql/func/json.zig` | `json_each()`, `json_tree()`, `jsonb_each()`, `jsonb_tree()` 및 JSONB 바이너리 함수군. |
| **디버깅 가상 테이블** | `src/vdbe/vdbevtab.zig` | `bytecode()`, `tables_used()`를 통한 런타임 바이트코드 및 사용 객체 분석. |
| **`generate_series()`** | `src/ext/series.zig` | 수열 생성 테이블 값 함수 (`generate_series(1, 10)`). |
| **`vtablog`** | `src/ext/vtablog.zig` | 가상 테이블 메서드 호출 로깅 모듈 (`XQ_VTABLOG` 환경변수 활성화 시 동작). |

---

## 4. sqlite3 연동 확장 라이브러리 (`libxqlite_ext`)

xqlite의 다른 방언(PostgreSQL, MariaDB, MSSQL, Oracle)으로 생성된 데이터베이스 파일은 방언 고유의 엔진 함수(`xq_*`)와 정렬 규칙(Collation)을 포함하고 있습니다.
- `zig build ext`로 빌드되는 `libxqlite_ext` 동적 라이브러리를 표준 `sqlite3` CLI 또는 Python `sqlite3` 모듈에 `.load`하여 올리면, 순수 SQLite 환경에서도 xqlite 방언 데이터베이스를 완벽하게 조회하고 조작할 수 있습니다.
