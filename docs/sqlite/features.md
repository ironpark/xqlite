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
- **B-Tree 엔진**:
  - 테이블 B-Tree 및 인덱스 B-Tree의 읽기/쓰기를 완벽 지원합니다.
  - `auto_vacuum` (NONE, FULL, INCREMENTAL) 및 `VACUUM`, `VACUUM INTO` 백업 API를 지원합니다.
- **다중 데이터베이스**:
  - `ATTACH [DATABASE] expr AS name` 및 `DETACH [DATABASE] name` 구문을 지원합니다.
  - 여러 파일에 걸친 원자적 커밋과 슈퍼 저널(Super Journal) 복구를 지원합니다.

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
| **`pragma_*` 테이블 함수** | `src/sql/pragma.zig` | `SELECT * FROM pragma_table_info('tbl')` 등 모든 PRAGMA를 테이블 함수로 질의 가능. |
| **JSON 모듈** | `src/sql/func/json.zig` | `json_each()`, `json_tree()`, `jsonb_each()`, `jsonb_tree()` 및 JSONB 바이너리 함수군. |
| **디버깅 가상 테이블** | `src/vdbe/vdbevtab.zig` | `bytecode()`, `tables_used()`를 통한 런타임 바이트코드 및 사용 객체 분석. |
| **`generate_series()`** | `src/ext/series.zig` | 수열 생성 테이블 값 함수 (`generate_series(1, 10)`). |
| **`vtablog`** | `src/ext/vtablog.zig` | 가상 테이블 메서드 호출 로깅 모듈 (`XQ_VTABLOG` 환경변수 활성화 시 동작). |

---

## 4. sqlite3 연동 확장 라이브러리 (`libxqlite_ext`)

xqlite의 다른 방언(PostgreSQL, MariaDB, MSSQL, Oracle)으로 생성된 데이터베이스 파일은 방언 고유의 엔진 함수(`xq_*`)와 정렬 규칙(Collation)을 포함하고 있습니다.
- `zig build ext`로 빌드되는 `libxqlite_ext` 동적 라이브러리를 표준 `sqlite3` CLI 또는 Python `sqlite3` 모듈에 `.load`하여 올리면, 순수 SQLite 환경에서도 xqlite 방언 데이터베이스를 완벽하게 조회하고 조작할 수 있습니다.
