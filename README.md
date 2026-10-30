# xqlite

> SQLite를 Zig로 포팅하고, 그 위에 **SQLite / PostgreSQL / MariaDB(MySQL) / MSSQL / Oracle** 호환 레이어를 얹은 임베디드 데이터베이스

> [!WARNING]
> 아주 초기 단계 프로젝트입니다. 아래 내용의 상당 부분은 **목표와 설계**이며, 아직 구현되지 않았습니다. API와 파일 포맷은 예고 없이 바뀔 수 있습니다. 지금 되는 것은 [로드맵](#로드맵)을 보세요.

## 왜 xqlite인가

임베디드 DB가 필요할 때 사실상 선택지는 SQLite뿐입니다. 하지만 실제 서비스는 PostgreSQL, MariaDB, MSSQL, Oracle 위에서 돌아가는 경우가 많아 다음 문제가 반복됩니다.

- 테스트는 SQLite로, 운영은 PostgreSQL로 돌리다 보니 SQL 방언 차이로 버그가 생깁니다.
- 서버 DB용으로 작성한 쿼리와 스키마를 로컬/엣지/데스크톱 앱에서 그대로 쓸 수 없습니다.
- 개발 환경에서 DB 서버 컨테이너를 띄우는 비용이 큽니다.

xqlite는 **하나의 임베디드 스토리지 엔진** 위에서 **여러 SQL 방언을 그 DB의 의미 그대로** 실행하는 것을 목표로 합니다.

## 목표

1. **SQLite의 Zig 포팅**: SQLite의 구조(Pager, B-Tree, VDBE)를 Zig로 다시 구현합니다. C 바인딩이 아니라 순수 Zig 구현입니다.
2. **SQLite 파일 포맷 호환**: 기존 `.sqlite` / `.db` 파일을 그대로 읽고 씁니다.
3. **멀티 방언 SQL**: 연결 단위로 방언을 골라 PostgreSQL, MariaDB, MSSQL, Oracle의 문법과 의미를 따릅니다.
4. **임베디드 우선**: 별도 프로세스 없이 라이브러리로 링크해 씁니다. 필요하면 와이어 프로토콜 서버 모드를 켤 수 있게 할 계획입니다.
5. **Zig다운 설계**: 명시적 allocator, comptime을 활용한 방언 특화, 숨은 전역 상태 없음, 크로스 컴파일 지원.

## 비목표

- 분산, 복제, 클러스터링
- 각 서버 DB의 모든 기능을 100% 재현 (확장 모듈, 프로시저 언어 전체, 서버 관리 기능 등)
- 대규모 동시 쓰기 워크로드에서 서버 DB와 성능 경쟁

## 아키텍처

```
┌───────────────────────────────────────────────────────────────┐
│                         Public API                            │
│        Zig API  ·  C ABI (sqlite3 호환)*  ·  Wire Server*     │
└───────────────────────────────┬───────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────┐
│                      Dialect Frontends                        │
│   ┌──────────┐  ┌────────────┐  ┌──────────┐  ┌───────────┐   │
│   │  SQLite  │  │ PostgreSQL │  │ MariaDB  │  │   MSSQL   │   │
│   │  parser  │  │   parser   │  │  parser  │  │  (T-SQL)  │   │
│   └────┬─────┘  └─────┬──────┘  └────┬─────┘  └─────┬─────┘   │
│        │              └─구문 트리 IR─┴──────────────┘         │
│        │       방언 의미를 명시한 노드 → lower / render       │
└────────┴──────────────────────┬───────────────────────────────┘
                                │  공통 IR (SQLite 파스 트리 + 빌더)
┌───────────────────────────────▼───────────────────────────────┐
│                  Planner / Optimizer → Codegen                │
└───────────────────────────────┬───────────────────────────────┘
                                │  bytecode
┌───────────────────────────────▼───────────────────────────────┐
│     VDBE (가상 머신)  ·  내장 함수 (방언별 함수 레지스트리)   │
└───────────────────────────────┬───────────────────────────────┘
┌───────────────────────────────▼───────────────────────────────┐
│     B-Tree  ·  Pager  ·  WAL / Rollback Journal  ·  Locking   │
└───────────────────────────────┬───────────────────────────────┘
┌───────────────────────────────▼───────────────────────────────┐
│              VFS (POSIX · Windows* · Memory · WASI*)          │
└───────────────────────────────────────────────────────────────┘
                                                  * 아직 없음
```

| 계층 | 역할 |
| --- | --- |
| **VFS** | 파일 I/O, 락, 시간, 난수를 추상화합니다. 플랫폼별 구현과 인메모리 구현을 제공합니다. |
| **Pager / WAL** | 페이지 캐시, 트랜잭션, 크래시 복구를 담당합니다. SQLite 파일 포맷과 호환됩니다. |
| **B-Tree** | 테이블(rowid / WITHOUT ROWID)과 인덱스를 저장합니다. |
| **VDBE** | SQLite와 같은 레지스터 기반 바이트코드 VM입니다. |
| **Planner** | 공통 IR을 받아 인덱스 선택, 조인 순서 결정, 서브쿼리 평탄화 등을 수행합니다. |
| **Dialect Frontend** | 방언별 lexer/parser입니다. 식별자 인용, 타입 변환, NULL/정렬 규칙, 함수 이름 해석을 정해 구문 트리 IR로 만듭니다. |
| **Catalog** | 방언 메타데이터(`xq_catalog`)와 시퀀스(`xq_sequence`)를 일반 테이블에 둡니다. `information_schema`, `pg_catalog`, MSSQL `sys.*`, Oracle의 `USER_TABLES` 같은 메타데이터 뷰가 이것을 읽습니다. |

방언 프론트엔드, 구문 트리 IR, lower/render 계약, 방언 훅, 카탈로그는 [방언 아키텍처](docs/architecture.md)에 자세히 정리했습니다.

## 방언 호환성

방언은 **연결 단위**로 고릅니다. 데이터는 하나의 SQLite 파일에 저장되고, 방언은 해석 방식만 바꿉니다.

### 방언별 주요 차이

| 항목 | SQLite | PostgreSQL | MariaDB | MSSQL | Oracle |
| --- | --- | --- | --- | --- | --- |
| 식별자 인용 | `"x"` `[x]` `` `x` `` | `"x"` | `` `x` `` (`ANSI_QUOTES` 시 `"x"`) | `[x]` `"x"` | `"x"` (인용 없으면 대문자) |
| 타입 시스템 | 동적 타입 (affinity) | 엄격한 정적 타입 | 정적 타입 + `sql_mode` 의존 | 엄격한 정적 타입 | 정적 타입, `''`는 NULL |
| 자동 증가 | `INTEGER PRIMARY KEY` | `SERIAL` / `IDENTITY` | `AUTO_INCREMENT` | `IDENTITY(1,1)` | `IDENTITY`, 시퀀스 `s.NEXTVAL` |
| 페이징 | `LIMIT/OFFSET` | `LIMIT/OFFSET`, `FETCH` | `LIMIT` | `TOP`, `OFFSET…FETCH` | `ROWNUM`, `OFFSET…FETCH` |
| UPSERT | `ON CONFLICT` | `ON CONFLICT` | `ON DUPLICATE KEY UPDATE` | `MERGE` | `MERGE` |
| 반환 절 | `RETURNING` | `RETURNING` | `RETURNING` (MariaDB 10.5+) | `OUTPUT` | `RETURNING … INTO` (PL/SQL) |
| 문자열 연결 | `\|\|` | `\|\|` | `CONCAT()` (`\|\|` = OR) | `+` | `\|\|` (NULL은 건너뜀) |
| 대소문자 비교 | 기본 구분 (ASCII) | 구분 | collation 의존 (기본 비구분) | collation 의존 (기본 비구분) | 구분 |

### 타입

서버 DB의 엄격한 타입은 SQLite `STRICT` 테이블 위에 구현합니다. 원래 선언 타입은 `xq_catalog`에 기록하고, 길이·범위 검사는 CHECK 제약으로 내립니다. 그래서 방언으로 만든 DB도 sqlite3가 그대로 열고 `PRAGMA integrity_check`를 통과합니다. 타입별 저장 방식은 방언 문서에 있습니다. SQLite 레코드로 표현할 수 없는 타입(정확한 `NUMERIC(38,10)`, 배열 등)을 위한 확장 레코드 인코딩은 계획만 있습니다.

### 지원 범위

| 기능 | SQLite | PostgreSQL | MariaDB | MSSQL | Oracle |
| --- | :-: | :-: | :-: | :-: | :-: |
| DDL / DML 기본 | ✅ | ✅ | ✅ | ✅ `MERGE`, `OUTPUT`, `TOP` | ✅ |
| 트랜잭션 / 세이브포인트 | ✅ | ✅ | ✅ | ✅ 중첩 `BEGIN TRAN`, `SAVE TRAN` | ✅ |
| CTE / 재귀 CTE | ✅ | ✅ | ✅ | ✅ | ✅ |
| 윈도우 함수 | ✅ | ✅ | ✅ | ✅ | ✅ |
| JSON | ✅ `json1` | 🚧 `json`/`jsonb` | ✅ `JSON_*`, `JSON_TABLE` | 🚧 `JSON_VALUE`, `ISJSON` | 🎯 |
| 시퀀스 | — | ✅ | ✅ | ✅ `IDENTITY`, `SEQUENCE` | ✅ |
| 스키마(네임스페이스) | ✅ `ATTACH` | ✅ `CREATE SCHEMA`, `search_path`, 붙인 DB | 🚧 (database, `ATTACH`) | 🚧 `dbo`, `#temp`, `db.dbo.t` | 🚧 현재 사용자 스키마 = `main` |
| 저장 프로시저 / 함수 | — | 🔬 PL/pgSQL 일부 | 🔬 | 🔬 T-SQL 일부 | 🔬 PL/SQL |
| 트리거 | ✅ | 🎯 | 🎯 | 🎯 | 🎯 |
| 메타데이터 카탈로그 | ✅ `sqlite_schema` | 🚧 `information_schema`, `pg_catalog` | 🚧 `information_schema`, `SHOW` | 🚧 `INFORMATION_SCHEMA`, `sys.*` 일부 | 🚧 `USER_*`/`ALL_*` 뷰 |
| 와이어 프로토콜 | — | 🔬 pgwire v3 | 🔬 MySQL protocol | 🔬 TDS 7.4 | — |

✅ 구현 · 🚧 일부 구현 · 🎯 목표 · 🔬 실험적 / 후순위 · — 해당 없음

### 방언별 문서

- [SQLite 호환](docs/sqlite.md): 구현 범위, sqlite3와의 교차 검증
- [PostgreSQL 호환](docs/postgres.md): 지원 문법, 타입과 의미, PostgreSQL과 다른 점
- [MariaDB 호환](docs/mariadb.md): 저장 방식, `sql_mode`, 지원 문법, MariaDB와 다른 점
- [MSSQL 호환](docs/mssql.md): T-SQL 문법, 타입과 값 변환, `+`·`MERGE`의 규칙, SQL Server와 다른 점
- [Oracle 호환](docs/oracle.md): 빈 문자열과 NULL, 날짜, `ROWNUM`·`MERGE`, 암묵적 트랜잭션, Oracle과 다른 점

## 빠른 시작

### 빌드

Zig **0.17.0** 이상이 필요합니다.

```sh
zig build              # 라이브러리 + CLI (zig-out/bin/xqlite)
zig build run          # CLI 실행
zig build test         # 단위 테스트
```

Linux 타깃으로 크로스 컴파일할 수 있습니다. WASI는 아직 컴파일되지 않습니다(WASI VFS가 없고, 64비트 원자 연산·스레드 같은 플랫폼 차이를 다루지 않음).

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast   # 됨
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall        # 아직 컴파일 오류
```

### 셸 실행

`xqlite sql`은 `sqlite3`와 호환되는 셸입니다.

```sh
zig-out/bin/xqlite sql test.db "CREATE TABLE t(a, b); INSERT INTO t VALUES(1, 'x');" ".mode box" "SELECT * FROM t"
zig-out/bin/xqlite sql test.db .dump > test.sql
```

- 파일을 생략하거나 `:memory:`를 주면 메모리 DB를 엽니다.
- 인자로 준 SQL·dot-command를 차례로 실행하고, 인자가 없으면 표준 입력에서 읽습니다(터미널이면 `sqlite> ` 프롬프트).
- 문장 경계는 `sqlite3_complete()` 포팅으로 판단하고, 출력 형식·오류 메시지·종료 코드는 SQLite 3.54 셸과 바이트 단위로 맞춥니다.
- `sqlite3` 셸처럼 defensive 모드를 켜고 `trusted_schema`를 끄며, `generate_series` 테이블 값 함수를 등록합니다.

| 종류 | 지원하는 것 |
| --- | --- |
| 출력 모드 | `list`, `csv`, `tabs`, `line`, `column`, `quote`, `insert`, `box`, `table`, `markdown`, `json` 등 |
| 출력 설정 | `.mode`, `.headers`, `.separator`, `.nullvalue` |
| 스키마 | `.tables`, `.schema`, `.indexes`, `.dump` |
| 실행 | `.read`, `.bail`, `.echo`, `.changes`, `.timeout`, `.dbconfig` |
| 그 밖 | `.dialect`, `.print`, `.show`, `.help`, `.quit`/`.exit` |

### 방언 고르기

기본 방언은 `sqlite`입니다. 방언은 연결마다 바꿀 수 있습니다.

```sh
zig-out/bin/xqlite sql app.db ".dialect postgres" \
  "CREATE TABLE users (id bigserial PRIMARY KEY, email text NOT NULL UNIQUE)" \
  "INSERT INTO users (email) VALUES ('hello@example.com') RETURNING id"
```

SQL에서는 `PRAGMA xq_dialect = 'mariadb'`(`'pg'`, `'mysql'` 별칭 허용, Oracle은 `'oracle'`), Zig API에서는 `.{ .dialect = .postgres }`나 `db.setDialect()`를 씁니다. 자세한 규칙은 [방언 고르기](docs/architecture.md#방언-고르기)에 있습니다.

### Zig API

```zig
const std = @import("std");
const xqlite = @import("xqlite");

pub fn main(init: std.process.Init) !void {
    var db = try xqlite.Db.open(init.gpa, init.io, "app.db", .{ .dialect = .postgres });
    defer db.close();

    try db.exec("CREATE TABLE IF NOT EXISTS users (id bigserial PRIMARY KEY, email text NOT NULL UNIQUE)");
    const id = (try db.one(i64, "INSERT INTO users (email) VALUES ($1) RETURNING id", .{"hello@example.com"})).?;

    var stmt = try db.prepare("SELECT id, email FROM users WHERE id >= $1");
    defer stmt.finalize();
    try stmt.bind(.{id});
    var it = stmt.iterator(struct { id: i64, email: []const u8 });
    while (try it.next()) |u| std.debug.print("{d} {s}\n", .{ u.id, u.email });
}
```

전체 API, 값의 수명 규칙, 오류 모델, 확장(사용자 함수, 집계, collation, 가상 테이블)은 [docs/zig-api.md](docs/zig-api.md)에 있습니다. 실행할 수 있는 예제는 `examples/`에 있습니다(`zig build example-basic`, `zig build example-extensions`).

## 테스트

호환성은 주장이 아니라 테스트로 증명합니다. 테스트 도구는 Zig로 쓴 `xqt` 하나입니다.

```sh
zig build tools                                # zig-out/bin/xqt, 크래시 shim, xqlite
SQ=/tmp/sqref/sqlite3 zig build check          # 단위 테스트, xqt interop, xqt planner, fuzzcheck를 병렬로
zig-out/bin/xqt interop                        # sqlite3 교차 검증 (모듈 이름을 주면 그것만)
zig-out/bin/xqt help                           # 모든 명령과 옵션
```

- **단위 테스트**: `zig build test`. 시드 퍼저의 짧은 실행과 문서·예제의 이름 검사도 함께 합니다.
- **sqlite3 교차 검증**: `xqt interop`이 서로 만든 DB 파일, SQL 결과, 셸 출력, PRAGMA, WAL, 크래시 복구를 순정 sqlite3와 비교합니다.
- **플래너 차등 테스트**: `xqt planner`가 쿼리 결과, `EXPLAIN QUERY PLAN`, 바이트코드를 sqlite3 3.54.1과 비교합니다.
- **sqllogictest**: `xqt slt`
- **퍼징**: `xqlite fuzzcheck`(SQLite 퍼즈 코퍼스)와 시드 퍼저(`btree_model`, `btree_corrupt`, `ir_roundtrip`)
- **방언 차등 테스트**: `xqt dialect-diff pg|mariadb|mssql|oracle`이 실제 PostgreSQL 16, MariaDB 11, SQL Server(Azure SQL Edge), Oracle Database 23ai와 결과를 비교합니다.

도구별 실행 방법과 필요한 기준 sqlite3 빌드는 [테스트와 검증](docs/testing.md)에 있습니다.

## 로드맵

- [x] **Phase 0 · 기반**: VFS(POSIX·메모리), 페이지 캐시, Pager(롤백 저널), 파일 헤더 파싱. Windows VFS는 아직 없음
- [x] **Phase 1 · 스토리지**: B-Tree 읽기/쓰기(auto-vacuum·incremental vacuum 포함), 레코드 포맷, 기존 SQLite 파일 읽기/수정
- [x] **Phase 2 · SQLite SQL**: Lexer/Parser, VDBE, 기본 Planner, `sqlite3` 호환 셸
- [x] **Phase 3 · 완성도**: 세이브포인트, WAL, 윈도우 함수, 가상 테이블, JSON, `ATTACH`/`DETACH`와 super journal, `ANALYZE`/`PRAGMA optimize`, `VACUUM`/`VACUUM INTO`와 백업 API. sqllogictest 전체(스크립트 622개, 테스트 5,939,879개)를 롤백 저널과 WAL 모드에서 모두 통과 ([SQLite 호환](docs/sqlite.md))
- [x] **Phase 4 · 공통 IR**: SQLite 파스 트리와 코드 생성기 진입점을 IR로 삼고 프론트엔드를 분리. 연결 단위 방언 선택, 방언 훅, STRICT 기반 엄격한 타입, `xq_catalog`·`xq_sequence`. SQLite 방언의 결과와 바이트코드는 sqlite3 3.54.1과 같음 ([방언 아키텍처](docs/architecture.md))
- [x] **Phase 5 · PostgreSQL 방언**: lexer·파서, SELECT·DML 전반, `RETURNING`·`ON CONFLICT`, DDL과 엄격한 타입, `SERIAL`/`IDENTITY`, `information_schema`·`pg_catalog`. PostgreSQL 16과 차등 비교 ([PostgreSQL 호환](docs/postgres.md))
- [x] **Phase 6 · MariaDB 방언**: 토크나이저·파서, 연결 단위 `sql_mode`, `INSERT IGNORE`/`REPLACE`/`ON DUPLICATE KEY UPDATE`, `AUTO_INCREMENT`, MariaDB 타입과 collation, `SHOW`/`information_schema`. MariaDB 11.8과 차등 비교 ([MariaDB 호환](docs/mariadb.md))
- [x] **구문 트리 IR**: 방언 중립 구문 트리와 하나뿐인 lower·render, 모든 방언에서 보이는 엔진 함수와 방언 한정 함수 이름, 카탈로그 기반 identity·DEFAULT. PostgreSQL과 MariaDB 프론트엔드를 옮겨 실행과 저장의 의미가 같아짐 ([방언 아키텍처](docs/architecture.md#render와-lower의-계약))
- [x] **Phase 7 · MSSQL 방언**: T-SQL 렉서·파서(`[x]`, `N'..'`, `@변수`, `GO`), `TOP`/`OFFSET…FETCH`, `+`의 타입별 해석, `OUTPUT`, `UPDATE/DELETE … FROM`, 한 문장의 `MERGE`, SQL Server 타입과 값 변환, `IDENTITY`/`IDENTITY_INSERT`, 변수, 중첩 트랜잭션, `INFORMATION_SCHEMA`·`sys.*`. SQL Server(Azure SQL Edge)와 차등 비교 ([MSSQL 호환](docs/mssql.md))
- [x] **Phase 8 · Oracle 방언**: 대문자로 접는 식별자, `''` = NULL 규칙(리터럴·`||`·문자열 함수·저장 변환), `DUAL`·`ROWNUM`·`(+)` 외부 조인, `NVL`/`DECODE`/`TO_CHAR`/`TO_DATE`와 날짜 연산, `MERGE`·`INSERT ALL`, Oracle 타입과 identity·시퀀스, BEGIN 없는 암묵적 트랜잭션, `USER_*` 뷰. Oracle Database 23ai와 차등 비교 ([Oracle 호환](docs/oracle.md))
- [ ] **Phase 9 · 서버 모드**: pgwire, MySQL protocol, TDS
- [ ] **C ABI**: `sqlite3_*` 호환 C ABI와 URI 파라미터 `?dialect=` ([계획](docs/zig-api.md#아직-없는-것))

## 프로젝트 구조

```
src/
├── root.zig            # 모듈 루트
├── xqlite.zig          # 공개 Zig API 이름 목록
├── main.zig            # CLI (sql, slt, fuzzcheck, 테스트 보조 명령)
├── shell.zig           # sqlite3 호환 셸
├── vfs/                # OS 추상화, 크래시 테스트용 VFS
├── pager/              # 페이지 캐시, 저널, WAL
├── btree/              # B-Tree, 레코드 포맷
├── vdbe/               # 바이트코드 VM
├── parse/              # SQLite tokenizer, LALR(1) 파서
├── sql/                # 코드 생성기, 플래너, 내장 함수 (SQLite C 포팅)
├── ir/                 # 공통 IR: 빌더 파사드, 구문 트리, lower, render
├── catalog/            # 방언 메타데이터(xq_catalog), 시퀀스(xq_sequence)
├── dialect/
│   ├── sqlite/
│   ├── postgres/       # lexer, parser(→ 구문 트리 IR), DDL 검사, 카탈로그 뷰
│   ├── mariadb/        # 토크나이저, 파서(→ 구문 트리 IR), sql_mode, 타입 변환, 함수
│   ├── mssql/          # T-SQL 렉서, 파서(→ 구문 트리 IR), MERGE, 타입 변환, 함수, 카탈로그 뷰
│   └── oracle/         # lexer, parser(→ 구문 트리 IR), 날짜·숫자 형식, 저장 변환, 데이터 사전 뷰
├── api/                # Zig API
├── ext/                # 셸용 확장 (generate_series, vtablog)
└── testing/            # 시드 퍼저 공용 도구
docs/                   # 설계·호환성 문서
examples/               # Zig API 예제
tools/                  # 테스트 도구 xqt(교차 검증·차등 테스트·코드 생성), 케이스 파일
```

C ABI(`capi/`), 서버(`server/`)는 아직 없습니다.

## 기여

아직 설계가 자주 바뀌는 단계입니다. 큰 변경은 이슈에서 먼저 논의해 주세요.

## 감사의 말

xqlite는 D. Richard Hipp과 SQLite 팀이 만들고 퍼블릭 도메인으로 공개한 [SQLite](https://www.sqlite.org/)의 설계와 파일 포맷을 기반으로 합니다.

## 라이선스

TBD
