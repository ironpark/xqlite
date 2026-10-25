# xqlite

> SQLite를 Zig로 포팅하고, 그 위에 **SQLite / PostgreSQL / MariaDB(MySQL) / MSSQL** 호환 레이어를 얹은 임베디드 데이터베이스

> [!WARNING]
> 아주 초기 단계 프로젝트입니다. 아래 내용 대부분은 **목표와 설계**이며, 아직 구현되지 않았습니다. API와 파일 포맷은 예고 없이 바뀔 수 있습니다.

## 왜 xqlite인가

임베디드 DB가 필요할 때 사실상 선택지는 SQLite뿐입니다. 하지만 실제 서비스는 PostgreSQL, MariaDB, MSSQL 위에서 돌아가는 경우가 많고, 그래서 다음과 같은 문제가 반복됩니다.

- 테스트는 SQLite로, 운영은 PostgreSQL로 돌리다 보니 SQL 방언 차이로 버그가 생긴다.
- 서버 DB용으로 작성한 쿼리와 스키마를 로컬/엣지/데스크톱 앱에서 그대로 쓸 수 없다.
- 개발 환경에서 DB 서버 컨테이너를 띄우는 비용이 크다.

xqlite는 **하나의 임베디드 스토리지 엔진** 위에서 **여러 SQL 방언을 그 DB의 의미 그대로** 실행하는 것을 목표로 합니다.

## 목표

1. **SQLite의 Zig 포팅**: SQLite의 구조(Pager, B-Tree, VDBE)를 Zig로 다시 구현합니다. C 바인딩이 아니라 순수 Zig 구현입니다.
2. **SQLite 파일 포맷 호환**: 기존 `.sqlite` / `.db` 파일을 그대로 읽고 쓸 수 있어야 합니다.
3. **멀티 방언 SQL**: 연결(connection) 단위로 방언을 골라 PostgreSQL, MariaDB, MSSQL 문법과 의미를 따릅니다.
4. **임베디드 우선**: 별도 프로세스 없이 라이브러리로 링크해 씁니다. 필요하면 와이어 프로토콜 서버 모드를 켤 수 있습니다.
5. **Zig다운 설계**: 명시적 allocator, comptime을 활용한 방언 특화, 숨은 전역 상태 없음, 크로스 컴파일 지원.

## 비목표

- 분산, 복제, 클러스터링
- 각 서버 DB의 모든 기능을 100% 재현 (확장 모듈, 프로시저 언어 전체, 서버 관리 기능 등)
- 대규모 동시 쓰기 워크로드에서 서버 DB와 성능 경쟁

## 아키텍처

```
┌───────────────────────────────────────────────────────────────┐
│                         Public API                            │
│        Zig API  ·  C ABI (sqlite3 호환)  ·  Wire Server*      │
└───────────────────────────────┬───────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────┐
│                      Dialect Frontends                        │
│   ┌──────────┐  ┌────────────┐  ┌──────────┐  ┌───────────┐   │
│   │  SQLite  │  │ PostgreSQL │  │ MariaDB  │  │   MSSQL   │   │
│   │  parser  │  │   parser   │  │  parser  │  │  (T-SQL)  │   │
│   └────┬─────┘  └─────┬──────┘  └────┬─────┘  └─────┬─────┘   │
│        └──────────────┴──── AST ─────┴──────────────┘         │
│                 방언별 semantic analysis / 타입 해석          │
└───────────────────────────────┬───────────────────────────────┘
                                │  공통 IR (Logical Plan)
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
│              VFS (POSIX · Windows · Memory · WASI)            │
└───────────────────────────────────────────────────────────────┘
                                         * 선택 기능
```

### 계층별 설명

| 계층 | 역할 |
| --- | --- |
| **VFS** | 파일 I/O, 락, 시간, 난수를 추상화합니다. 플랫폼별 구현과 인메모리 구현을 제공합니다. |
| **Pager / WAL** | 페이지 캐시, 트랜잭션, 크래시 복구를 담당합니다. SQLite 파일 포맷과 호환됩니다. |
| **B-Tree** | 테이블(rowid / WITHOUT ROWID)과 인덱스를 저장합니다. |
| **VDBE** | SQLite와 같은 레지스터 기반 바이트코드 VM입니다. 방언별 타입과 비교 규칙을 지원하도록 확장합니다. |
| **Planner** | 공통 IR을 받아 인덱스 선택, 조인 순서 결정, 서브쿼리 평탄화 등을 수행합니다. |
| **Dialect Frontend** | 방언별 lexer/parser와 의미 분석기입니다. 식별자 인용 규칙, 타입 강제 변환, NULL/정렬 규칙, 함수 이름 해석이 여기서 결정됩니다. |
| **Catalog Emulation** | `sqlite_schema`, `information_schema`, `pg_catalog`, `sys.*` 등 메타데이터 뷰를 하나의 내부 카탈로그에서 생성합니다. |

## 방언 호환성

방언은 **연결 단위**로 고릅니다. 데이터는 하나의 파일에 저장되고, 방언은 해석 방식만 바꿉니다.

### 방언별 주요 차이와 처리 방식

| 항목 | SQLite | PostgreSQL | MariaDB | MSSQL |
| --- | --- | --- | --- | --- |
| 식별자 인용 | `"x"` `[x]` `` `x` `` | `"x"` | `` `x` `` (`ANSI_QUOTES` 시 `"x"`) | `[x]` `"x"` |
| 타입 시스템 | 동적 타입 (affinity) | 엄격한 정적 타입 | 정적 타입 + `sql_mode` 의존 | 엄격한 정적 타입 |
| 자동 증가 | `INTEGER PRIMARY KEY` | `SERIAL` / `IDENTITY` | `AUTO_INCREMENT` | `IDENTITY(1,1)` |
| 페이징 | `LIMIT/OFFSET` | `LIMIT/OFFSET`, `FETCH` | `LIMIT` | `TOP`, `OFFSET…FETCH` |
| UPSERT | `ON CONFLICT` | `ON CONFLICT` | `ON DUPLICATE KEY UPDATE` | `MERGE` |
| 반환 절 | `RETURNING` | `RETURNING` | `RETURNING` (MariaDB 10.5+) | `OUTPUT` |
| 문자열 연결 | `\|\|` | `\|\|` | `CONCAT()` (`\|\|` = OR) | `+` |
| 대소문자 비교 | 기본 구분 (ASCII) | 구분 | collation 의존 (기본 비구분) | collation 의존 (기본 비구분) |

### 타입 매핑

서버 DB의 엄격한 타입은 SQLite 레코드 포맷 위에 **카탈로그 메타데이터 + 런타임 검사**로 구현합니다. 표현할 수 없는 타입(예: `NUMERIC(38,10)`, `INTERVAL`, `UUID`, 배열)은 확장 레코드 인코딩을 씁니다. 이 인코딩을 쓰는 테이블은 순정 SQLite에서 읽기 전용으로 열리도록 표시합니다.

### 지원 범위 (계획)

| 기능 | SQLite | PostgreSQL | MariaDB | MSSQL |
| --- | :-: | :-: | :-: | :-: |
| DDL / DML 기본 | 🎯 | 🎯 | 🎯 | 🎯 |
| 트랜잭션 / 세이브포인트 | 🎯 | 🎯 | 🎯 | 🎯 |
| CTE / 재귀 CTE | 🎯 | 🎯 | 🎯 | 🎯 |
| 윈도우 함수 | 🎯 | 🎯 | 🎯 | 🎯 |
| JSON | 🎯 `json1` | 🎯 `json`/`jsonb` | 🎯 | 🎯 `JSON_VALUE` 등 |
| 시퀀스 | — | 🎯 | 🎯 | 🎯 |
| 스키마(네임스페이스) | `ATTACH` | 🎯 | 🎯 (database) | 🎯 |
| 저장 프로시저 / 함수 | — | 🔬 PL/pgSQL 일부 | 🔬 | 🔬 T-SQL 일부 |
| 트리거 | 🎯 | 🎯 | 🎯 | 🎯 |
| 메타데이터 카탈로그 | 🎯 | 🎯 `pg_catalog` | 🎯 `information_schema` | 🎯 `sys.*` |
| 와이어 프로토콜 | — | 🔬 pgwire v3 | 🔬 MySQL protocol | 🔬 TDS 7.4 |

🎯 목표 · 🔬 실험적 / 후순위 · — 해당 없음

## 사용 예시 (계획 중인 API)

```zig
const std = @import("std");
const xqlite = @import("xqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var db = try xqlite.open(gpa.allocator(), "app.db", .{
        .dialect = .postgres,
    });
    defer db.close();

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id    BIGSERIAL PRIMARY KEY,
        \\  email TEXT NOT NULL UNIQUE,
        \\  meta  JSONB DEFAULT '{}'::jsonb
        \\)
    , .{});

    var stmt = try db.prepare(
        "INSERT INTO users (email) VALUES ($1) RETURNING id",
    );
    defer stmt.deinit();

    const id = try stmt.one(i64, .{"hello@example.com"});
    std.debug.print("inserted id = {d}\n", .{id});
}
```

같은 파일을 다른 방언으로 열 수도 있습니다.

```zig
var mssql = try xqlite.open(alloc, "app.db", .{ .dialect = .mssql });
try mssql.exec("SELECT TOP 10 [id], [email] FROM [users] ORDER BY [id] DESC", .{});
```

### C ABI

`sqlite3_*` 호환 C ABI를 제공해서, 기존 SQLite 바인딩(Python `sqlite3`, Go `mattn/go-sqlite3` 등)에서 라이브러리만 바꿔 쓸 수 있게 하는 것이 목표입니다. 방언은 URI 파라미터로 지정합니다.

```
file:app.db?dialect=mariadb
```

### 서버 모드 (선택)

기존 클라이언트와 ORM을 그대로 붙일 수 있도록 와이어 프로토콜 서버를 선택적으로 제공합니다.

```sh
xqlite serve app.db --pg 5432 --mysql 3306 --tds 1433
```

## 빌드

Zig **0.17.0** 이상이 필요합니다.

```sh
zig build              # 라이브러리 + CLI 빌드
zig build run          # CLI 실행
zig build test         # 단위 테스트
```

포팅 기준 SQLite 소스(현재 3.54.1)는 `ref/sqlite`에 받아 두고 참고합니다. 이 디렉토리는 git에서 제외됩니다.

```sh
./tools/fetch-sqlite.sh
```

크로스 컴파일:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
```

## 테스트 전략

호환성은 주장이 아니라 테스트로 증명해야 합니다.

- **SQLite**: [sqllogictest](https://www.sqlite.org/sqllogictest/)와 SQLite TCL 테스트 스위트 일부를 포팅합니다.
- **파일 포맷**: 순정 SQLite와 xqlite가 서로 만든 DB 파일을 교차로 읽고 쓰고, `PRAGMA integrity_check`로 검증합니다.
- **PostgreSQL / MariaDB / MSSQL**: 같은 쿼리를 실제 서버와 xqlite에서 실행해 결과를 비교하는 differential testing을 합니다. 각 DB의 regression test에서 필요한 부분을 가져옵니다.
- **Fuzzing**: 파서, 레코드 디코더, B-Tree 페이지 디코더를 퍼징합니다.
- **크래시 복구**: 오류를 주입하는 VFS로 쓰기 도중 전원 차단을 시뮬레이션합니다.

## 로드맵

- [ ] **Phase 0 · 기반**: VFS, Pager, Rollback Journal, 파일 헤더 파싱
- [ ] **Phase 1 · 스토리지**: B-Tree 읽기/쓰기, 레코드 포맷, 기존 SQLite 파일 읽기
- [ ] **Phase 2 · SQLite SQL**: Lexer/Parser, VDBE, 기본 Planner, `sqlite3` 호환 셸
- [ ] **Phase 3 · 완성도**: WAL, 인덱스 최적화, 윈도우 함수, JSON, sqllogictest 통과
- [ ] **Phase 4 · 공통 IR**: 방언 독립적인 Logical Plan으로 프론트엔드 분리, 카탈로그 확장
- [ ] **Phase 5 · PostgreSQL 방언**: 파서, 엄격한 타입, `pg_catalog`, 시퀀스, `RETURNING`
- [ ] **Phase 6 · MariaDB 방언**: 파서, `sql_mode`, collation, `AUTO_INCREMENT`
- [ ] **Phase 7 · MSSQL 방언**: T-SQL 파서, `IDENTITY`, `TOP`, `OUTPUT`, `MERGE`
- [ ] **Phase 8 · 서버 모드**: pgwire, MySQL protocol, TDS

## 프로젝트 구조 (예정)

```
src/
├── root.zig            # 공개 Zig API
├── main.zig            # CLI
├── vfs/                # OS 추상화
├── pager/              # 페이지 캐시, 저널, WAL
├── btree/              # B-Tree, 레코드 포맷
├── vdbe/               # 바이트코드 VM, 내장 함수
├── planner/            # 공통 IR, 옵티마이저, 코드 생성
├── catalog/            # 스키마, 메타데이터 뷰
├── dialect/
│   ├── sqlite/
│   ├── postgres/
│   ├── mariadb/
│   └── mssql/
├── capi/               # sqlite3 호환 C ABI
└── server/             # 와이어 프로토콜 (선택)
```

## 기여

아직 설계가 자주 바뀌는 단계입니다. 큰 변경은 이슈에서 먼저 논의해 주세요.

## 감사의 말

xqlite는 D. Richard Hipp과 SQLite 팀이 만들고 퍼블릭 도메인으로 공개한 [SQLite](https://www.sqlite.org/)의 설계와 파일 포맷을 기반으로 합니다.

## 라이선스

TBD
