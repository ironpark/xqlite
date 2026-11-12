# xqlite

> SQLite를 Zig로 포팅하고, 그 위에 **SQLite / PostgreSQL / MariaDB(MySQL) / MSSQL / Oracle** 호환 레이어를 얹은 임베디드 데이터베이스

> [!WARNING]
> 초기 단계 프로젝트입니다. API와 파일 포맷은 예고 없이 바뀔 수 있습니다. 지금 되는 것과 없는 것은 [현재 상태](#현재-상태)에 있습니다.

## 왜 xqlite인가

임베디드 DB가 필요할 때 사실상 선택지는 SQLite뿐입니다. 하지만 실제 서비스는 PostgreSQL, MariaDB, MSSQL, Oracle 위에서 돌아가는 경우가 많아 다음 문제가 반복됩니다.

- 테스트는 SQLite로, 운영은 PostgreSQL로 돌리다 보니 SQL 방언 차이로 버그가 생깁니다.
- 서버 DB용으로 작성한 쿼리와 스키마를 로컬/엣지/데스크톱 앱에서 그대로 쓸 수 없습니다.
- 개발 환경에서 DB 서버 컨테이너를 띄우는 비용이 큽니다.

xqlite는 **하나의 임베디드 스토리지 엔진** 위에서 **여러 SQL 방언을 그 DB의 의미 그대로** 실행합니다.

## 특징

1. **SQLite의 Zig 포팅**: SQLite의 구조(Pager, B-Tree, VDBE)를 Zig로 다시 구현했습니다. C 바인딩이 아니라 순수 Zig 구현입니다.
2. **SQLite 파일 포맷 호환**: 기존 `.sqlite` / `.db` 파일을 그대로 읽고 씁니다. SQLite 방언의 결과는 sqlite3 3.54.1과 같습니다.
3. **멀티 방언 SQL**: 연결 단위로 방언을 골라 PostgreSQL, MariaDB, MSSQL, Oracle의 문법과 의미를 따릅니다.
4. **임베디드 우선**: 별도 프로세스 없이 라이브러리(Zig API, sqlite3 호환 C ABI, WebAssembly)로 씁니다. 와이어 프로토콜 서버(`xqlite serve`)로 띄울 수도 있습니다.
5. **Zig다운 설계**: 명시적 allocator, comptime을 활용한 방언 특화, 숨은 전역 상태 없음, 크로스 컴파일 지원.

## 비목표

- 분산, 복제, 클러스터링
- 각 서버 DB의 모든 기능을 100% 재현 (확장 모듈, 프로시저 언어 전체, 서버 관리 기능 등)
- 대규모 동시 쓰기 워크로드에서 서버 DB와 성능 경쟁

## 아키텍처

```
┌───────────────────────────────────────────────────────────────┐
│                         Public API                            │
│        Zig API  ·  C ABI (sqlite3 호환)  ·  Wire Server       │
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
│    VFS (POSIX · Windows* · Memory · WASI · Host(wasm))        │
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
| **Catalog** | 방언 메타데이터(`xq_catalog`)와 시퀀스(`xq_sequence`)를 일반 테이블에 둡니다. 연결은 카탈로그를 메모리에 읽어 두므로 문장을 컴파일할 때 질의하지 않습니다. `information_schema`, `pg_catalog`, MSSQL `sys.*`, Oracle의 `USER_TABLES` 같은 메타데이터 뷰가 이것을 읽습니다. |

방언 프론트엔드, 구문 트리 IR, lower/render 계약, 방언 훅, 카탈로그는 [방언 아키텍처](docs/architecture.md)에 자세히 정리했습니다.

## 방언 호환성

방언은 **연결 단위**로 고릅니다. 데이터는 하나의 SQLite 파일에 저장되고, 방언은 해석 방식만 바꿉니다.

### 타입

서버 DB의 엄격한 타입은 SQLite `STRICT` 테이블 위에 구현합니다. 원래 선언 타입은 `xq_catalog`에 기록하고, 길이·범위 검사는 CHECK 제약으로 내립니다. 그래서 방언으로 만든 DB도 sqlite3가 그대로 열고 `PRAGMA integrity_check`를 통과합니다. 타입별 저장 방식은 방언 문서에 있습니다.

### 지원 범위

| 기능 | SQLite | PostgreSQL | MariaDB | MSSQL | Oracle |
| --- | :-: | :-: | :-: | :-: | :-: |
| DDL / DML 기본 | [x] | [x] | [x] | [x] | [x] |
| 트랜잭션 / 세이브포인트 | [x] | [x] | [x] | [x] | [x] |
| CTE / 재귀 CTE | [x] | [x] | [x] | [x] | [x] |
| 윈도우 함수 | [x] | [x] | [x] | [x] | [x] |
| JSON | [x] | [x] | [x] | [x] | [x] |
| 시퀀스 | [ ] | [x] | [x] | [x] | [x] |
| 스키마(네임스페이스) | [x] | [x] | [x] | [x] | [x] |
| 메타데이터 카탈로그 | [x] | 🚧 | 🚧 | 🚧 | 🚧 |
| 트리거 | [x] | [ ] | [ ] | [ ] | [ ] |
| 저장 프로시저 / 함수 | [ ] | [ ] | [ ] | [ ] | [ ] |
| 와이어 프로토콜 | [ ] | 🚧 | 🚧 | [ ] | [ ] |

[x] 구현 · 🚧 일부 구현 · [ ] 없음. 방언마다 무엇이 되고 무엇이 다른지는 방언별 문서에 있습니다.

### 방언별 문서

방언마다 사용 방법, 지원 기능, 차이점, 내부 구현, 검증 문서가 있습니다.

- [SQLite 호환](docs/sqlite/README.md): 호환 수준 및 사용법, 코어 기능, 미지원 제약, 순수 Zig 구현 원리, 교차 검증 도구
- [PostgreSQL 호환](docs/postgres/README.md): 사용법, 지원 기능 및 카탈로그, PostgreSQL 18과의 차이점, 내부 아키텍처 및 직렬화, 차등 검증
- [MariaDB 호환](docs/mariadb/README.md): 사용법, `sql_mode` 및 지원 문법, MariaDB 11과의 차이점, 다중 DB 매핑 원리, 실서버 검증
- [MSSQL 호환](docs/mssql/README.md): 사용법, T-SQL 지원 기능 및 식 규칙, SQL Server와의 차이점, `MERGE`/`OUTPUT` IR 변환, 교차 검증
- [Oracle 호환](docs/oracle/README.md): 사용법, 대문자·빈문자열·날짜 등 Oracle 시맨틱, Oracle 23ai와의 차이점, 암묵적 트랜잭션 구현, 실서버 검증
- [sqlite3용 확장](docs/extension.md): 방언으로 만든 데이터베이스의 엔진 함수와 collation을 sqlite3·Python·Datasette에 올리는 `libxqlite_ext`, 함수 목록, ABI 규칙
- [확장 로드와 사용](docs/load-extension.md): sqlite-regex 같은 SQLite용 로더블 확장을 셸(`.load`), Zig API, C API에서 올려 쓰는 방법과 예제

## 빠른 시작

### 내려받기

[Releases](https://github.com/ironpark/xqlite/releases)에 Linux(x86_64, aarch64), macOS(Apple Silicon, Intel), WebAssembly용 아카이브가 있습니다. 아카이브마다 CLI `bin/xqlite`, C 라이브러리 `lib/libxqlite3`(정적·공유)와 헤더, sqlite3용 확장 `lib/libxqlite_ext`가 들어 있습니다.

```sh
tar xzf xqlite-v0.0.4-linux-x86_64.tar.gz
xqlite-v0.0.4-linux-x86_64/bin/xqlite --version    # xqlite 0.0.4 (SQLite 3.54.1)
```

### 빌드

Zig **0.17.0** 이상이 필요합니다.

```sh
zig build              # 라이브러리 + CLI (zig-out/bin/xqlite) + C 라이브러리 (zig-out/lib/libxqlite3.*, zig-out/include/sqlite3.h)
zig build run          # CLI 실행
zig build test         # 단위 테스트 (pkg/ 아래 패키지의 테스트 포함)
zig build test-pkg     # 패키지 테스트만 (엔진을 빌드하지 않아 빠름)
zig build test-capi    # C API 테스트
zig build ext          # sqlite3용 확장 (zig-out/lib/libxqlite_ext.*, docs/extension.md)
zig build -Ddialects=postgres,mariadb -Dext=none   # 넣을 방언·확장만 (기본 all)
zig build -Doptimize=ReleaseFast -Dstrip=true      # 릴리스 아카이브와 같은 빌드 (디버그 정보 없음)
```

`-Ddialects`로 뺀 방언은 고르면 `dialect not built in` 오류가 나고, SQLite만 넣으면 브라우저 wasm이 2.3MB에서 0.95MB로 줄어듭니다([빌드에 넣을 방언과 확장](docs/architecture.md#빌드에-넣을-방언과-확장)).

VFS와 스토리지 층(페이저, B-tree), 둘이 엔진과 함께 쓰는 도우미, PostgreSQL 방언이 쓰는 UUID, 방언들의 렉서(SQL 토큰, 선언형 렉서, 키워드 표), 방언들의 파서가 쓰는 토큰 커서와 우선순위 파서, 방언들의 라이브러리(십진 수, 날짜와 interval, JSON과 JSONB, PostgreSQL 정규식과 배열 텍스트)는 따로 빌드되는 Zig 패키지(`pkg/vfs`의 `xqlite_vfs`, `pkg/storage`의 `xqlite_storage`, `pkg/base`의 `xqlite_base`, `std`만 쓰는 `pkg/uuid`의 `uuid`와 `pkg/sql/lexer`의 `sql/lexer`, `pkg/decimal`·`pkg/datetime`·`pkg/json`·`pkg/regex`·`pkg/pgtext`의 `decimal`·`datetime`·`json`·`regex`·`pgtext`, 그 위의 `pkg/sql/parse`의 `sql/parse`)이고 루트 빌드가 경로 의존성으로 가져옵니다. 각 디렉터리에서 `zig build test`를 하면 그 패키지의 테스트만 돕니다([VFS 패키지](docs/architecture.md#vfs-패키지), [스토리지 패키지](docs/architecture.md#스토리지-패키지), [uuid 패키지](docs/architecture.md#uuid-패키지), [sqllex 패키지](docs/architecture.md#sqllex-패키지), [decimal, datetime, json, regex, pgtext 패키지](docs/architecture.md#decimal-datetime-json-regex-pgtext-패키지), [sqlparse 패키지](docs/sqlparse.md)).

Linux 타깃과 WebAssembly로 크로스 컴파일할 수 있습니다.

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast   # Linux
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall        # WASI: 라이브러리와 셸 (zig-out/bin/xqlite.wasm, 약 1.9MiB)
zig build wasm                                                # 브라우저·Node: zig-out/wasm/xqlite.wasm (약 2.2MiB)
```

- **WASI** (`wasm32-wasi`): 셸을 `wasmtime run --dir . zig-out/bin/xqlite.wasm sql app.db`처럼 돌립니다. 파일은 WASI preview 1로 엽니다. WASI에는 권고 잠금이 없어서 잠금은 프로세스 안에서만 중재하므로, 한 DB 파일은 한 번에 한 프로세스만 써야 합니다. WAL의 wal-index는 `-shm` 파일 대신 힙 메모리에 둡니다.
- **브라우저·JavaScript** (`wasm32-freestanding`): `xq_*` 함수를 내보내고, 파일 연산은 호스트가 import로 줍니다(OPFS, IndexedDB, node:fs ...). 호스트가 파일을 주지 않으면 메모리 DB로 돕니다. JavaScript 연결 코드와 Node 예제는 `examples/wasm/`에 있습니다(`zig build wasm-example`).
- 둘 다 단일 스레드 빌드이고 시간대는 UTC뿐입니다. 자세한 내용은 [WebAssembly](docs/wasm.md)에 있습니다.

### C API

`libxqlite3`는 SQLite 3.54.1의 `sqlite3.h`를 구현하는 C 라이브러리(정적·공유)입니다. `-Dcapi-name=sqlite3`로 빌드하면 `libsqlite3`라는 이름이 되어 기존 프로그램에 그대로 바꿔 끼울 수 있고, SQLite의 셸(`shell.c`)도 고치지 않고 링크해 돌아갑니다(`zig build capi-shell`). 방언은 URI 파라미터로 고릅니다.

```c
sqlite3_open_v2("file:app.db?dialect=postgres", &db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL);
```

```sh
cc app.c -Izig-out/include zig-out/lib/libxqlite3.a -lpthread -lm
```

지원하는 함수와 SQLite와 다른 점(멀티스레드 모드, 권한 검사기·serialize 미지원 등)은 [C API](docs/c-api.md)에 있습니다.

### sqlite3에서 읽기

방언으로 만든 데이터베이스는 SQLite 파일이지만, 스키마의 CHECK·생성 열·식 인덱스·뷰가 엔진 함수(`xq_pg_jsonb_get_text()`, `xq_like()` ...)와 collation(`xq_pg_jsonb` ...)을 부릅니다. 평범한 sqlite3는 그 식에서 `no such function`으로 실패하므로, 같은 소스로 만든 로더블 확장을 올립니다.

```sh
zig build ext
sqlite3 app.db -cmd '.load ./zig-out/lib/libxqlite_ext' 'PRAGMA integrity_check'
```

Python은 `con.enable_load_extension(True); con.load_extension("./zig-out/lib/libxqlite_ext")`입니다. 뜻이 xqlite와 같고(같은 구현), 스키마가 부르는 함수는 이름이 바뀌지 않는 한 뜻도 바뀌지 않습니다([sqlite3용 확장](docs/extension.md)).

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
| 확장 | `.load FILE ?ENTRY?` (SQLite용 로더블 확장, [확장 로드와 사용](docs/load-extension.md)) |
| 그 밖 | `.dialect`, `.print`, `.show`, `.help`, `.quit`/`.exit` |

### 서버 실행

`xqlite serve`는 DB 파일 하나를 와이어 프로토콜로 내놓습니다. PostgreSQL 프로토콜(v3, `--pg`, 세션은 PostgreSQL 방언)과 MySQL/MariaDB 프로토콜(`--mysql`, 세션은 MariaDB 방언)이 있고, 둘을 함께 띄울 수 있습니다.

```sh
XQLITE_PASSWORD=secret zig-out/bin/xqlite serve app.db --pg 5432 --mysql 3306
psql "host=127.0.0.1 port=5432 user=app dbname=app sslmode=disable"
mariadb -h 127.0.0.1 -P 3306 -u app -psecret --skip-ssl
```

- PostgreSQL: 단순 질의, 확장 질의(Parse/Bind/Describe/Execute, 이진 형식), 취소 요청, trust·cleartext·MD5·SCRAM-SHA-256 인증. TLS와 COPY는 없습니다.
- MySQL: `COM_QUERY`(여러 문장), 준비된 문장(이진 프로토콜), `KILL`, `mysql_native_password` 인증. SSL과 커서는 없습니다.
- 기본으로 `127.0.0.1`에서 받습니다. `--host 0.0.0.0`, `--max-connections N`, `--user`, `--auth`(PostgreSQL의 인증 방법), `--database`는 `xqlite serve --help`에 있습니다. 자세한 것은 [서버](docs/server.md#xqlite-serve)에 있습니다.

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

전체 API, 값의 수명 규칙, 오류 모델, 확장(사용자 함수, 집계, collation, 가상 테이블)은 [docs/zig-api.md](docs/zig-api.md)에 있습니다. 실행할 수 있는 예제는 `examples/`에 있습니다(`zig build example-basic`, `zig build example-extensions`). SQLite용 로더블 확장([sqlite-regex](https://github.com/asg017/sqlite-regex) 등)은 `db.loadExtension("./regex0", null)`로 올리고, 예제는 `examples/extension/`에 Zig와 C로 있습니다([확장 로드와 사용](docs/load-extension.md)).

## 테스트

호환성은 주장이 아니라 테스트로 증명합니다. 테스트 도구는 Zig로 쓴 `xqt` 하나입니다.

```sh
zig build tools                                # zig-out/bin/xqt, 크래시 shim, xqlite, 기준 sqlite3 셸
zig build check                                # 단위 테스트, xqt interop, xqt planner, fuzzcheck를 병렬로
zig-out/bin/xqt interop                        # sqlite3 교차 검증 (모듈 이름을 주면 그것만)
zig-out/bin/xqt help                           # 모든 명령과 옵션
```

- **단위 테스트**: `zig build test`. 시드 퍼저의 짧은 실행과 문서·예제의 이름 검사도 함께 합니다.
- **sqlite3 교차 검증**: `xqt interop`이 서로 만든 DB 파일, SQL 결과, 셸 출력, PRAGMA, WAL, 크래시 복구를 순정 sqlite3와 비교합니다.
- **플래너 차등 테스트**: `xqt planner`가 쿼리 결과를 sqlite3 3.54.1과 비교하고, `EXPLAIN QUERY PLAN`과 바이트코드는 xqlite의 기록과 비교해 의도하지 않은 변화를 잡습니다.
- **sqllogictest**: `xqt slt`
- **C API**: `zig build test-capi`가 C 프로그램으로 `libxqlite3`를 검사하고, `zig build capi-shell`이 SQLite의 `shell.c`를 링크해 돌립니다.
- **퍼징**: `xqlite fuzzcheck`(SQLite 퍼즈 코퍼스)와 시드 퍼저(`btree_model`, `btree_corrupt`, `btree_sqlite3`, `ir_roundtrip`)
- **방언 차등 테스트**: `xqt dialect-diff pg|mariadb|mssql|oracle`이 실제 PostgreSQL 18, MariaDB 11, SQL Server(Azure SQL Edge), Oracle Database 23ai와 결과를 비교합니다.
- **WebAssembly**: `zig build test-wasi`가 단위 테스트를 wasm32-wasi로 빌드해 wasmtime에서 돌리고, `xqt wasi`로 WASI 빌드를 sqlite3·네이티브 빌드와 비교합니다.

도구별 실행 방법과 필요한 기준 sqlite3 빌드는 [테스트와 검증](docs/testing.md)에 있습니다.

## 현재 상태

- **엔진**: SQLite 3.54.1의 SQL(세이브포인트, WAL, 윈도우 함수, 가상 테이블, JSON, `ATTACH`, `VACUUM`, 백업 API ...). sqllogictest 전체(스크립트 622개, 테스트 5,939,879개)를 롤백 저널과 WAL 모드에서 통과합니다. SQLite의 TCL 테스트(`xqt tcl`)는 같은 하네스의 SQLite 3.54.1과 비교해 테스트 이름 200만여 개 중 84개가 xqlite에서만 실패합니다([기준선](docs/testing.md#기준선)).
- **방언**: PostgreSQL, MariaDB, MSSQL, Oracle. PostgreSQL은 PostgreSQL 18의 기록과, 나머지는 실제 서버와 차등 비교합니다.
- **인터페이스**: Zig API, sqlite3 호환 C ABI(`libxqlite3`), WebAssembly(WASI, 브라우저·Node), sqlite3용 확장(`libxqlite_ext`), `sqlite3` 호환 셸.
- **서버**: PostgreSQL 프로토콜 v3와 MySQL 프로토콜(`xqlite serve`). TLS와 PostgreSQL의 COPY는 없습니다.
- **없는 것**: Windows VFS, TDS(SQL Server 프로토콜), 방언의 저장 프로시저·트리거(PL/pgSQL, T-SQL, PL/SQL).

## 프로젝트 구조

```
src/
├── root.zig            # 모듈 루트
├── xqlite.zig          # 공개 Zig API 이름 목록
├── cli/                # CLI xqlite (main.zig: sql, slt, fuzzcheck, serve, 테스트 보조 명령; shell.zig: sqlite3 호환 셸)
├── vdbe/               # 바이트코드 VM
├── sql/                # 코드 생성기 (SQLite C 포팅)
│   ├── where/          # 플래너 (where.c, wherecode.c, whereexpr.c ...)
│   └── func/           # 내장 함수 (func.c, date.c, json.c)
├── ir/                 # 공통 IR: 빌더 파사드, 구문 트리, lower, render
├── catalog/            # 방언 메타데이터(xq_catalog)와 메모리의 카탈로그(meta.zig), 시퀀스(xq_sequence)
├── dialect/
│   ├── sqlite/         # 렉서(sqllex), 재귀 하강 파서(sqlite3RunParser), sqlite3_normalized_sql()
│   ├── postgres/       # lexer, parser(→ 구문 트리 IR), DDL 검사, 카탈로그 뷰
│   ├── mariadb/        # 토크나이저, 파서(→ 구문 트리 IR), sql_mode, 타입 변환, 함수
│   ├── mssql/          # T-SQL 렉서, 파서(→ 구문 트리 IR), MERGE, 타입 변환, 함수, 카탈로그 뷰
│   └── oracle/         # lexer, parser(→ 구문 트리 IR), 날짜·숫자 형식, 저장 변환, 데이터 사전 뷰
├── api/                # Zig API
├── capi/               # sqlite3 호환 C ABI (루트는 capi.zig)
├── loadable/           # sqlite3용 로더블 확장 libxqlite_ext (루트는 loadable.zig, docs/extension.md)
├── ext/                # 셸용 확장 (generate_series, vtablog)
├── server/             # 와이어 프로토콜 서버 xqlite_server (리스너, 세션, 타입·오류 분류; pg/: PostgreSQL 프로토콜, mysql/: MySQL 프로토콜)
└── wasm/               # 브라우저·JavaScript용 wasm 모듈 (xq_* 내보내기)
pkg/
├── vfs/                # VFS 패키지 xqlite_vfs: OS 추상화(POSIX·WASI·호스트·메모리·memdb), 크래시 테스트용 VFS
├── storage/            # 스토리지 패키지 xqlite_storage: pager/(페이지 캐시, 저널, WAL), btree/, 레코드 포맷
├── base/               # 공용 패키지 xqlite_base: 콜백 클로저, sqlite3_status() 카운터, 퍼저 도구
├── uuid/               # RFC 9562 UUID 패키지 uuid (std만 씀)
└── sql/
    ├── lexer/          # 방언 렉서 패키지 sqllex: 토큰, 선언형 렉서, 키워드 표, 스캐너 (std만 씀)
    └── parse/          # 방언 파서가 쓰는 토큰 커서·오류 기록·우선순위 파서 패키지 sqlparse (std, sqllex)
docs/                   # 설계·호환성 문서
examples/               # Zig API 예제, extension/ (남의 SQLite 확장을 올리는 C·Zig 예제), wasm/ (JavaScript 연결 코드, Node·브라우저 예제)
tools/                  # 테스트 도구 xqt(교차 검증·차등 테스트·코드 생성), 케이스 파일
```

와이어 프로토콜은 PostgreSQL의 것(`src/server/pg/`)과 MySQL의 것(`src/server/mysql/`)이 있고, TDS는 아직 없습니다. 프로토콜과 상관없는 기반은 `src/server/`에 있습니다([서버](docs/server.md)).

## 기여

아직 설계가 자주 바뀌는 단계입니다. 큰 변경은 이슈에서 먼저 논의해 주세요.

## 감사의 말

xqlite는 D. Richard Hipp과 SQLite 팀이 만들고 퍼블릭 도메인으로 공개한 [SQLite](https://www.sqlite.org/)의 설계와 파일 포맷을 기반으로 합니다.

## 라이선스

[BSD 3-Clause](LICENSE). SQLite 자체는 퍼블릭 도메인이며, 테스트에 쓰는 `ref/`의 SQLite 소스와 sqllogictest는 이 저장소에 포함되지 않고 각자의 조건을 따릅니다.
