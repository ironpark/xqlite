# Zig API

`xqlite.Db` / `xqlite.Stmt`는 엔진(SQLite 포팅) 위에 얹은 얇은 Zig 계층입니다. 이 문서는 사용법, 값의 수명 규칙, 오류 모델, C API와의 대응, 그리고 아직 없는 것을 정리합니다.

## 목차

- [현재 상태](#현재-상태)
- [예제](#예제)
- [계층 구조](#계층-구조)
- [연결과 메모리](#연결과-메모리)
- [방언](#방언)
- [값의 수명 규칙](#값의-수명-규칙)
- [타입 매핑](#타입-매핑)
- [바인딩과 행 매핑](#바인딩과-행-매핑)
- [오류 모델](#오류-모델)
- [트랜잭션](#트랜잭션)
- [백업](#백업)
- [BLOB 증분 I/O](#blob-증분-io)
- [직렬화](#직렬화)
- [확장 지점](#확장-지점)
- [C API 대응](#c-api-대응)
- [아직 없는 것](#아직-없는-것)

## 현재 상태

| 상태 | 무엇 |
| --- | --- |
| 있음 | 연결(`Db.open`, VFS 선택, 저널 모드, busy timeout, 외래 키, 방언), 실행과 질의(`exec`, `execArgs`, `one`, `oneAlloc`, `all`), 문장(`Stmt`, `Iterator`), comptime 바인딩·행 매핑, 오류 집합과 `Diagnostics`, 트랜잭션·세이브포인트, 백업(`Db.backup`), BLOB 증분 I/O(`Db.openBlob`), 직렬화(`Db.serialize`, `Db.deserialize`), 사용자 함수·집계(윈도우) 함수·collation·읽기 전용 가상 테이블 |
| 계획 | 훅, 가상 테이블 쓰기, 서버 모드 ([아직 없는 것](#아직-없는-것)) |

설계 원칙은 다음과 같습니다.

- 전역 초기화가 없습니다. 할당자와 `std.Io`를 명시적으로 넘깁니다.
- 바인딩, 결과 매핑, 사용자 함수의 타입은 comptime으로 결정합니다.
- 오류는 정수 코드가 아니라 Zig 오류 집합(`error.Constraint`, `error.Busy` ...)으로 올라옵니다. 확장 코드와 메시지는 `db.lastError()`나 `Diagnostics`로 확인합니다.

## 예제

```zig
const std = @import("std");
const xqlite = @import("xqlite");

const User = struct { id: i64, name: []const u8, email: ?[]const u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var db = try xqlite.Db.open(gpa, init.io, "app.db", .{ .journal_mode = .wal, .busy_timeout_ms = 1000 });
    defer db.close();

    try db.exec("CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE)");

    // 튜플은 위치(?1, ?2), 구조체는 이름(:name, @name, $name)으로 바인딩
    try db.execArgs("INSERT INTO users(name, email) VALUES(?, ?)", .{ "Ada", "ada@example.com" });
    try db.execArgs("INSERT INTO users(name, email) VALUES(:name, :email)", .{ .name = "Linus", .email = null });
    std.debug.print("last id = {d}\n", .{db.lastInsertRowid()});

    // 행을 구조체로 매핑 (필드 이름 = 열 이름). 문자열은 다음 next()까지 유효
    var stmt = try db.prepare("SELECT id, name, email FROM users WHERE id > ?");
    defer stmt.finalize();
    try stmt.bind(.{0});
    var it = stmt.iterator(User);
    while (try it.next()) |u| std.debug.print("{d} {s} {?s}\n", .{ u.id, u.name, u.email });

    // 문장보다 오래 살아야 하는 값은 할당자로 복사
    const name = (try db.oneAlloc([]const u8, gpa, "SELECT name FROM users WHERE id = ?", .{1})).?;
    defer gpa.free(name);

    // 오류는 Zig 오류 집합, 자세한 내용은 lastError()
    db.execArgs("INSERT INTO users(name, email) VALUES(?, ?)", .{ "Eve", "ada@example.com" }) catch |err| {
        const e = db.lastError().?;
        std.debug.print("{s}: {s} ({t})\n", .{ @errorName(err), e.message, e.code }); // Constraint: UNIQUE constraint failed: users.email (constraint_unique)
    };

    // 트랜잭션: 함수가 오류를 돌려주면 ROLLBACK, 아니면 COMMIT
    try db.transaction(.immediate, renameAll, .{ &db, "user" });
}

fn renameAll(db: *xqlite.Db, prefix: []const u8) !void {
    try db.execArgs("UPDATE users SET name = ? || '-' || id", .{prefix});
}
```

`examples/`에 실행할 수 있는 예제가 있습니다. `zig build test`가 예제를 빌드하므로 예제가 쓰는 이름은 늘 실제 API와 맞습니다.

```sh
zig build example-basic                # examples/basic.zig, 메모리 DB
zig build example-basic -- notes.db    # 파일 DB
zig build example-extensions           # examples/extensions.zig
zig build examples                     # 예제 빌드만
```

| 예제 | 다루는 것 |
| --- | --- |
| `examples/basic.zig` | open, DDL, 바인딩한 INSERT, 타입 있는 질의, 트랜잭션, `Diagnostics`와 오류 정보 |
| `examples/extensions.zig` | 스칼라 함수, 집계(윈도우) 함수, collation, 테이블 값 함수 |

## 계층 구조

```
src/xqlite.zig          공개 이름의 유일한 목록 (모듈 루트 root.zig가 전부 다시 내보내고, comptime 검사로 확인)
src/api/Db.zig          연결: open/close, exec, prepare, 트랜잭션, 방언, 확장 등록
src/api/Stmt.zig        문장: bind, step, column/row, Iterator
src/api/value.zig       Zig 타입 <-> SQLite 값 comptime 매핑, Value, Blob, free()
src/api/errors.zig      오류 집합, ResultCode, ErrorInfo, Diagnostics
src/api/conn.zig        오류를 연결/Diagnostics에 기록하는 공용 도우미
src/api/func.zig        스칼라 함수, 집계(윈도우) 함수, collation 래퍼
src/api/module.zig      타입이 있는 가상 테이블 모듈 래퍼
src/api/engine.zig      엔진과의 유일한 접점 (아래 참고)
```

`engine.zig`만 엔진 내부(`sql/main.zig`, `sql/prepare.zig`, `vdbe/api.zig`, `sql/callback.zig`, `sql/coll.zig`, `sql/vtab.zig` ...)를 import합니다. 나머지 API 파일은 C API를 따르는 이 파일의 함수와 타입 별칭만 씁니다.

- **오류**: 엔진 호출의 결과 코드는 이 경계에서 `int.check(rc)`로 엔진의 오류 집합(`int.Error`)이 됩니다. `errors.fromEngine()`의 망라적인 `switch` 하나가 이를 `xqlite.SqlError`로 바꿉니다. 엔진에 오류가 추가되면 컴파일러가 알려 줍니다.
- 확장 코드와 메시지는 C처럼 연결에 남습니다. `ResultCode`의 값은 엔진의 `RC.*`에서 가져옵니다.
- API 계층이 직접 찾아낸 오류(`UsageError`, API 할당자의 메모리 부족)는 `Conn.raise()` 한 곳에서 코드와 메시지를 연결과 `Diagnostics`에 기록합니다.
- **콜백**: 엔진이 부르는 함수·collation·모듈 콜백은 C 모양(`void*` 문맥)입니다. 하지만 엔진의 타입 있는 도우미(`destructor()`, `FuncDef.withUserData()`/`userDataFor()`, `Module.constructor()`/`auxFor()`, `aggContext()`, `thunk()`)로 만들므로 API 쪽에는 `void*`에서의 수동 캐스트가 없습니다.

`docs/names_test.zig`는 이 문서가 쓰는 한정 이름(`xqlite.Value`, `Db.lastError` ...)이 모듈에 있는지 `zig build test`에서 검사합니다.

## 연결과 메모리

```zig
var db = try xqlite.Db.open(gpa, io, "app.db", .{ .journal_mode = .wal, .busy_timeout_ms = 1000 });
defer db.close();
```

`Db.open()`이 필요한 것을 모두 인자로 받으므로 전역 초기화가 필요 없습니다. 경로가 `":memory:"`나 `""`이면 연결 전용 임시 메모리 DB를 엽니다.

| 인자 | 뜻 |
| --- | --- |
| `gpa` | API 계층이 직접 할당하는 것: .unix/.memory VFS 객체, 등록한 함수·모듈의 기록, 함수 호출마다 만드는 arena |
| `io` | VFS가 쓰는 `std.Io` |
| `options` | `xqlite.OpenOptions` (아래) |

| `OpenOptions` 필드 | 기본값 | 뜻 |
| --- | --- | --- |
| `read_only` | `false` | 읽기 전용으로 엶(`SQLITE_OPEN_READONLY`) |
| `create` | `true` | 파일이 없으면 만듦(`SQLITE_OPEN_CREATE`). `read_only`면 무시 |
| `vfs` | `.unix` | `.unix`(OS 파일 시스템), `.memory`(연결 전용 인메모리 파일 시스템), `.custom`(호출자가 소유한 `Vfs`, 예: 여러 연결이 공유하는 `MemVfs`). `Vfs`, `MemVfs`, `OsVfs`는 VFS 패키지(`pkg/vfs`, [아키텍처](architecture.md#vfs-패키지))의 타입을 `xqlite`가 다시 내보낸 것 |
| `journal_mode` | `null` | 연 뒤 `PRAGMA journal_mode` 설정. 엔진이 다른 모드를 고르면(`:memory:`는 WAL 불가) `error.UnsupportedJournalMode` |
| `busy_timeout_ms` | `0` | 잠겨 있을 때 다시 시도하는 시간. 0이면 바로 `error.Busy` |
| `foreign_keys` | `false` | 외래 키 제약 강제(`PRAGMA foreign_keys`) |
| `dialect` | `.sqlite` | 연결의 SQL 방언([방언](#방언)) |
| `diagnostics` | `null` | 실패한 호출의 자세한 내용을 받을 `Diagnostics`. 연결보다 오래 살아야 함 |

메모리 규칙은 다음과 같습니다.

- `execArgs`, `one`, `oneAlloc`, `all`은 호출마다 문장을 준비(prepare)하고 확정합니다. 같은 SQL을 반복 실행하는 루프에서는 `prepare()`로 `Stmt`를 한 번 만들어 `bind()`/`exec()`/`next()`로 재사용하세요.
- 엔진 자체의 메모리(페이지 캐시, 문장, 스키마)는 C의 `sqlite3_malloc()`처럼 라이브러리 할당자에서 나옵니다.
  - 설정은 `xqlite.malloc.configMalloc()`이고, 기본값은 libc malloc, 테스트에서는 `std.testing.allocator`입니다.
  - 이것은 엔진의 설정이며 API가 새로 만든 전역 상태가 아닙니다.
- 호출자에게 돌려주는 메모리는 언제나 호출자가 넘긴 할당자에서 나옵니다(`oneAlloc`, `all`, `rowAlloc`, `columnAlloc`, `Iterator.nextAlloc`).
- `xqlite.free(gpa, x)`가 구조체·옵셔널·배열을 따라 내려가며 문자열과 blob을 해제합니다.
- `Db`는 작은 값이라 복사·이동해도 됩니다. 단, 닫는 것은 한 번만 합니다.
- `Stmt`와 `Savepoint`는 `Db`를 가리키지 않고 엔진 연결 핸들을 직접 들고 있습니다.
- `close()`는 확정되지 않은 문장이 남아 있으면 안전 빌드에서 panic합니다(누수와 같은 취급). 처리하고 싶으면 `tryClose()`가 `error.Busy`를 돌려주고 연결을 열어 둡니다.

연 뒤에 바꿀 수 있는 설정도 있습니다: `setBusyTimeout(ms)`, `setJournalMode(mode)`, `setDialect(d)`.

## 방언

방언은 연결 단위로 고릅니다. 방언은 SQL을 해석하는 방식만 바꾸고, 데이터는 같은 SQLite 파일에 저장됩니다.

```zig
var db = try xqlite.Db.open(gpa, io, "app.db", .{ .dialect = .postgres });
defer db.close();

try db.exec(
    \\CREATE TABLE IF NOT EXISTS users (
    \\  id    bigserial PRIMARY KEY,
    \\  email text NOT NULL UNIQUE,
    \\  meta  jsonb DEFAULT '{}'::jsonb
    \\)
);
const id = (try db.one(i64, "INSERT INTO users (email) VALUES ($1) RETURNING id", .{"hello@example.com"})).?;

db.setDialect(.mariadb);            // 이후에 준비하는 문장부터 MariaDB 문법
std.debug.print("{d} {t}\n", .{ id, db.dialect() });
```

- `xqlite.Dialect`는 `.sqlite`, `.postgres`, `.mariadb`, `.oracle`입니다. MSSQL은 아직 없습니다.
- `setDialect()`는 그 뒤에 준비하는 문장에만 적용됩니다. 이미 준비한 문장은 자기 방언을 유지합니다(`PRAGMA xq_dialect`와 같음).
- 방언의 구조는 [방언 아키텍처](architecture.md), 방언별 문법은 [PostgreSQL 호환](postgres.md), [MariaDB 호환](mariadb.md), [Oracle 호환](oracle.md)에 있습니다.

## 값의 수명 규칙

| 무엇 | 언제까지 유효한가 |
| --- | --- |
| `bind()`에 넘긴 값 | 호출이 끝나면 필요 없음 (엔진이 복사, `SQLITE_TRANSIENT`) |
| `column([]const u8, i)`, `Blob`, `Value.text/.blob`, 이들을 담은 `row(T)` / `Iterator.next()` 결과 | 같은 문장의 다음 `step()` / `reset()` / `bind()` / `finalize()` 전까지 |
| 같은 열을 다른 타입으로 다시 읽은 경우 | C와 같이 값이 제자리에서 변환될 수 있으므로, 앞서 빌린 슬라이스는 무효 |
| `*Alloc` 결과 | 호출자 소유, `xqlite.free()`로 해제 |
| `columnName()` | 문장이 확정(finalize)될 때까지 |
| `Db.lastError().message` | 그 연결(또는 그 연결의 문장)에 대한 다음 호출 전까지 |
| `Diagnostics` | 호출자 소유 복사본, 연결보다 오래 살아도 됨 |
| 함수 인자로 받은 `[]const u8` / `Blob` / `Args.get()` | 그 함수 호출 동안 |
| 함수의 반환값 | 반환 즉시 엔진이 복사 |
| 스칼라 함수의 `std.mem.Allocator` 인자 | 함수마다 arena 하나, 결과를 복사한 뒤 비움(64KiB까지 버퍼 유지). 함수가 실행한 SQL이 같은 함수를 다시 부르는 중첩 호출은 자기 arena를 따로 씀 |
| 집계 함수의 `std.mem.Allocator` 인자 | `Db`의 `gpa` 그대로, 상태는 `deinit()`에서 해제 |
| `createFunction`/`createCollation`/`createModule`의 context 포인터 | 등록이 살아 있는 동안(보통 연결이 닫힐 때까지) |

빌린 값이 문장보다 오래 살 수 없다는 규칙은 타입으로도 일부 강제합니다.

- `Db.one(T, ...)`는 문장을 내부에서 확정합니다. 그래서 `T`가 문자열·blob·`Value`를 담고 있으면 컴파일 오류를 내고 `oneAlloc()`을 쓰라고 알려 줍니다.
- 빌린 읽기로 `[]u8`(가변)을 요청해도 컴파일 오류입니다.

## 타입 매핑

| Zig 타입 | 바인딩 / 결과 | 읽기 |
| --- | --- | --- |
| 모든 정수 타입, `comptime_int` | INTEGER. i64 범위 밖이면 `error.IntegerOverflow` (리터럴은 컴파일 오류) | `sqlite3_column_int64()` 뒤 범위 검사, 넘치면 `error.IntegerOverflow` |
| `f16`..`f128`, `comptime_float` | REAL | `sqlite3_column_double()` |
| `bool` | 0 / 1 | 0이 아니면 true |
| `[]const u8`, `[:0]const u8`, 문자열 리터럴 | TEXT | `sqlite3_column_text()` |
| `xqlite.Blob` | BLOB | `sqlite3_column_blob()` (빈 blob은 `""`) |
| `xqlite.ZeroBlob{ .len = n }` | n바이트 zeroblob | — |
| `?T`, `null` | NULL | NULL이면 null |
| enum | 태그 이름(TEXT). `pub const xqlite_storage: xqlite.EnumStorage = .integer;`를 선언했거나 non-exhaustive면 INTEGER | 정수·문자열 둘 다 받음, 없는 값은 `error.InvalidEnum` |
| `xqlite.Value` | 태그대로 | 열의 실제 타입대로 |

읽기는 SQLite의 변환 규칙을 따릅니다(TEXT `'42'`를 `i64`로 읽으면 42). Zig 쪽에서 추가한 규칙은 두 가지입니다.

- NULL을 옵셔널이 아닌 타입으로 읽으면 `error.UnexpectedNull`입니다.
- 정수가 대상 타입에 들어가지 않으면 잘라 내지 않고 `error.IntegerOverflow`입니다.

## 바인딩과 행 매핑

**바인딩.** `bind(args)`는 먼저 문장을 reset하고 모든 매개변수에 새 값을 넣습니다.

- 튜플이면 위치(`?1`, `?2` ...), 구조체면 이름(`:name`, `@name`, `$name`)으로 바인딩합니다.
- 값의 개수가 매개변수 개수와 다르거나, 필드가 어떤 매개변수와도 맞지 않으면 오류입니다. 이때 모든 매개변수는 NULL이 됩니다.
- 하나씩 바인딩하려면 `bindAt(i, x)` / `bindName(":x", x)`를 씁니다.

**행 매핑.** `row(T)`는 `T`에 따라 열을 찾습니다.

| `T` | 열을 찾는 방법 |
| --- | --- |
| 일반 구조체 | 필드 이름(ASCII 대소문자 무시). 없으면 `error.ColumnNotFound` |
| 튜플, 배열 | 위치 |
| 그 밖의 타입 | 0번 열 |

- 이름→열 매핑은 문장마다 캐시되어 행마다 다시 찾지 않습니다. `row`, `Stmt.next`, `Iterator`가 캐시를 공유합니다.
- 스키마 변경으로 문장이 다시 컴파일되면 매핑을 새로 계산합니다.
- 구조체 `bind()`의 필드→매개변수 매핑도 같은 방식으로 캐시합니다.

**반복.** `Iterator`는 문장이 끝난 뒤 `next()`를 불러도 문장을 다시 시작하지 않고 계속 null을 돌려줍니다. `Stmt.next(T)`는 `step()`처럼 다시 시작합니다.

## 오류 모델

| 오류 집합 | 내용 |
| --- | --- |
| `xqlite.SqlError` | 엔진 오류. 기본 결과 코드(하위 바이트)마다 하나: `error.Sql`, `error.Busy`, `error.Constraint`, `error.ReadOnly`, `error.Corrupt` ... 이름은 엔진의 `btree.Error`(`Busy`, `IoErr`, `DiskFull`, `CantOpen`, `NotADatabase` ...)와 맞춤 |
| `xqlite.UsageError` | API 자체의 오류: `UnexpectedNull`, `IntegerOverflow`, `ParameterCountMismatch`, `ColumnNotFound`, `MultipleStatements` ... |
| `xqlite.Error` | 둘의 합집합 |

확장 코드와 메시지는 두 방법으로 얻습니다.

- `db.lastError() ?ErrorInfo`: `sqlite3_extended_errcode()`, `sqlite3_errmsg()`, `sqlite3_error_offset()`에 해당합니다. 메시지는 빌린 값입니다.
- `OpenOptions.diagnostics = &diag`: std.json의 Diagnostics처럼 호출자가 가진 구조체에 실패를 복사해 둡니다.
  - 그 연결과 문장의 모든 실패, 그리고 연결 객체가 없는 `open()` 실패까지 기록합니다.
  - 할당 없이 메시지를 256바이트(`Diagnostics.max_message`)까지 저장합니다. 전체 메시지는 `lastError()`에 있습니다.

그 밖의 규칙은 다음과 같습니다.

- API 오류도 연결의 오류로 기록되므로 `lastError()`로 볼 수 있습니다. 코드는 SQLite가 비슷한 문제에 쓰는 `.range`, `.mismatch`, `.misuse`이고, API의 할당이 실패하면 `.nomem`과 "out of memory"입니다.
- 오류인 코드는 OK, ROW, DONE, NOTICE, WARNING을 뺀 모든 코드입니다(`ResultCode.isError()`). `lastError()`와 `ResultCode.toError()`가 이 규칙 하나를 씁니다.

C와 다른 점이 두 가지 있습니다.

- `Stmt.finalize()`는 연결의 마지막 오류를 바꾸지 않습니다. 그래서 `defer stmt.finalize()` 뒤에도 오류를 볼 수 있습니다.
- `transaction()`과 `Savepoint.rollback()`은 ROLLBACK을 실행한 뒤 원래 오류(코드, 잘리지 않은 메시지, 오프셋)를 연결에 되돌려 둡니다. 되돌릴 오류가 없었으면 정리 작업의 오류도 남기지 않습니다.

## 트랜잭션

- `begin(.deferred | .immediate | .exclusive)`, `commit()`, `rollback()`, `inTransaction()`.
- `transaction(mode, f, args)`: `@call(.auto, f, args)`를 BEGIN과 COMMIT 사이에서 실행합니다.
  - `f`가 오류를 돌려주거나 COMMIT이 실패하면 ROLLBACK하고 그 오류를 돌려줍니다.
  - 반환 타입은 `(xqlite.Error || f의 오류 집합)!f의 결과`입니다.
- `savepoint(name)`은 `Savepoint`를 돌려줍니다. `release()` 또는 `rollback()`(ROLLBACK TO + RELEASE)으로 끝냅니다.
  - `errdefer sp.rollback();` 패턴을 쓰도록 `rollback()`은 오류를 돌려주지 않습니다.

## 백업

`db.backup(dest_name, &src, src_name)`은 `src`의 데이터베이스 `src_name`("main", "temp", 붙인 이름)을 `db`의 `dest_name`에 페이지 단위로 복사하는 `Backup`을 돌려줍니다(`sqlite3_backup_init`).

```zig
var b = try dest.backup("main", &src, "main");
defer b.finish() catch {};
while (!try b.step(100)) {}          // 100페이지씩, step(null)이면 한 번에 전부
```

- `Backup.step(n)`은 복사가 끝나 대상에 커밋되면 true입니다. `error.Busy`·`error.Locked`(원본에 쓰는 중이거나 대상이 잠김)이면 다시 부를 수 있고, 다른 오류는 백업을 끝냅니다. 오류는 대상 연결에 기록됩니다.
- `Backup.remaining()`, `Backup.pageCount()`는 마지막 `step()` 때의 남은 페이지와 원본 페이지 수입니다.
- `Backup.finish()`는 백업을 해제하고, 다 복사하지 않았으면 대상을 롤백합니다. 백업을 끝낸 오류가 있으면 그 오류를 돌려줍니다.
- 두 연결은 달라야 하고, 대상에는 트랜잭션이 없어야 합니다. 백업 중에도 원본을 읽고 쓸 수 있습니다(복사한 뒤 바뀐 페이지는 다시 복사). `finish()` 전에는 두 연결 모두 닫을 수 없습니다(`tryClose()`가 `error.Busy`).
- 같은 일을 하는 SQL은 `VACUUM INTO 'file'`입니다(빈 페이지를 버린 사본).

## BLOB 증분 I/O

`db.openBlob(database, table, column, rowid, writable)`은 테이블 한 행의 한 값(BLOB 또는 TEXT)을 SQL 없이 조금씩 읽고 쓰는 `Db.BlobHandle`을 돌려줍니다(`sqlite3_blob_open`, 엔진의 `vdbe/blob.zig`). `database`가 null이면 main입니다.

```zig
try db.exec("INSERT INTO files(id, data) VALUES(1, zeroblob(1000000))");
var b = try db.openBlob(null, "files", "data", 1, true);
defer b.close() catch {};
try b.write(chunk, 4096);            // 오프셋 4096부터 덮어씀
try b.read(&buf, 0);
```

- `bytes()`는 값의 크기입니다. 쓰기로 크기를 바꿀 수는 없으므로 먼저 `zeroblob(N)`으로 자리를 만듭니다. 끝을 넘는 읽기·쓰기는 `error.Sql`, 읽기 전용으로 연 `BlobHandle`에 쓰면 `error.ReadOnly`입니다.
- 쓰기는 행의 페이로드를 바로 고칩니다. 트리거와 업데이트 훅이 돌지 않고 `changes()`에 잡히지 않습니다.
- 다른 문장이 그 행을 바꾸거나 지우면 `BlobHandle`이 만료됩니다. 그 뒤의 호출은 `error.Abort`이고 `bytes()`는 0입니다.
- `reopen(rowid)`는 같은 테이블·열의 다른 행으로 옮깁니다. 실패하면 `BlobHandle`이 만료됩니다.
- 쓰기용으로는 인덱스에 든 열을 열 수 없고, 외래 키가 켜져 있으면 외래 키 열도 열 수 없습니다. 뷰, 가상 테이블, WITHOUT ROWID 테이블, 생성 열이 있는 테이블도 열 수 없습니다.
- 열린 `BlobHandle`은 실행 중인 문장이라서 `close()` 전에는 연결을 닫을 수 없고(`tryClose()`가 `error.Busy`), 자동 커밋 모드면 `close()`가 그 트랜잭션을 끝냅니다.

## 직렬화

`db.serialize(gpa, schema)`는 데이터베이스 `schema`("main", "temp", 붙인 이름)의 파일 이미지를 `gpa`로 할당해 돌려주고(`sqlite3_serialize`), 없는 이름이면 `error.NotFound`입니다. `db.deserialize(schema, image, read_only)`는 그 데이터베이스(TEMP는 안 됨)를 닫고 `image`의 사본을 담은 메모리 데이터베이스(memdb VFS, VFS 패키지의 `pkg/vfs/src/memdb.zig`)로 다시 엽니다(`sqlite3_deserialize`). 쓰면 메모리가 늘어나고, `read_only`면 쓰기가 `error.ReadOnly`, 트랜잭션이 열려 있으면 `error.Busy`입니다.

```zig
const image = try src.serialize(gpa, "main");
defer gpa.free(image);
try db.deserialize("main", image, false);
```

## 확장 지점

모두 comptime으로 시그니처를 읽어 엔진 콜백 래퍼를 생성합니다. 사용자 데이터는 std.sort의 `context`처럼 넘깁니다(`{}` 또는 포인터).

```zig
fn gcd(a: i64, b: i64) i64 { ... }                       // 인자 2개, INTEGER -> INTEGER
try db.createFunction("gcd", {}, gcd, .{ .deterministic = true });

const Sum = struct {                                       // 그룹마다의 상태
    total: i64 = 0,
    pub fn step(self: *Sum, x: ?i64) void { self.total += x orelse 0; }
    pub fn final(self: *Sum) i64 { return self.total; }
};
try db.createAggregate("my_sum", Sum, .{});

try db.createCollation("bylength", {}, byLength);         // fn ([]const u8, []const u8) std.math.Order
try db.createModule("fib", Fib, {});                      // SELECT * FROM fib(10)
```

전체 코드는 `examples/extensions.zig`에 있습니다.

### `createFunction(name, context, f, opts)`

- 인자 수와 인자·반환 타입을 `f`의 시그니처에서 추론합니다.
- context가 `{}`가 아니면 첫 매개변수로 받습니다.
- `std.mem.Allocator` 매개변수는 호출이 끝나면 비워지는 arena입니다.
- `xqlite.Args` 하나만 받으면 가변 인자 함수입니다.
- 오류를 돌려주면 오류 이름이 SQL 오류 메시지가 됩니다(`OutOfMemory`는 `SQLITE_NOMEM`).
- `opts`는 `deterministic`, `direct_only`, `innocuous`입니다.

### `createAggregate(name, State, opts)`

- 그룹마다의 상태 `State`를 엔진의 aggregate context(0으로 채워진 8바이트 정렬 메모리)에 둡니다.
- `step`, `final`이 필수입니다.
- `init`, `deinit`, 그리고 윈도우 함수용 `value`·`inverse`는 선택입니다.
- `deinit`은 항상 실행됩니다. 문장이 그룹 중간에 버려져도 엔진이 xFinal을 부르기 때문입니다.

### `createCollation(name, context, cmp)`

`cmp`는 `fn (a, b) std.math.Order` 또는 `fn (ctx, a, b) std.math.Order`입니다.

### `createModule(name, T, context)`

읽기 전용 가상 테이블을 등록합니다.

- `T`는 `schema`, `connect`, `Cursor`를 선언합니다. `Cursor`는 `open`, `filter`, `next`, `eof`, `column`과 선택적으로 `rowid`, `deinit`을 가집니다.
- `arg_columns`에 적은 HIDDEN 열의 `=` 제약은 `filter()`의 `FilterArgs`로 전달됩니다. 그래서 테이블 값 함수(`SELECT * FROM fib(10)`)가 됩니다.
- 인자 제약이 있지만 그 플랜에서 쓸 수 없으면 `xBestIndex`가 `SQLITE_CONSTRAINT`를 돌려 그 플랜을 거부합니다(series.c와 같은 방식).
- 그 밖의 제약은 엔진이 행을 받은 뒤 걸러 냅니다.
- 같은 모듈을 `CREATE VIRTUAL TABLE t USING name(args)`로도, eponymous 테이블로도 쓸 수 있습니다.

## C API 대응

| C | Zig |
| --- | --- |
| `sqlite3_open_v2` | `Db.open(gpa, io, path, options)` |
| `sqlite3_close` | `Db.close()` / `Db.tryClose()` |
| `sqlite3_exec` | `Db.exec(sql)` (여러 문장), `Db.execArgs(sql, args)` (한 문장 + 바인딩) |
| `sqlite3_prepare_v2`의 `pzTail` 반복 | `Db.script(sql)`, `Script.next()`, `Script.deinit()` (문장마다 결과를 읽는 스크립트) |
| `sqlite3_prepare_v2` | `Db.prepare(sql)` (한 문장만, 나머지가 있으면 `error.MultipleStatements`) |
| `sqlite3_bind_*` | `Stmt.bind(args)`, `bindAt`, `bindName`, `clearBindings` |
| `sqlite3_bind_parameter_count/name/index` | `parameterCount`, `parameterName`, `parameterIndex` |
| `sqlite3_step` | `Stmt.step() !bool`, `Stmt.next(T)`, `Iterator(T).next()` |
| `sqlite3_column_*` | `Stmt.column(T, i)`, `columnAlloc`, `row(T)`, `rowAlloc`, `columnKind` |
| `sqlite3_column_count/name/decltype` | `columnCount`, `columnName`, `columnDecltype`, `columnIndex` |
| `sqlite3_column_database/table/origin_name` | `Stmt.columnOrigin(i)` (`OpenOptions.column_metadata`면 다시 컴파일하지 않음) |
| (방언의 선언 타입, `xq_catalog`) | `Stmt.columnTypeAlloc(gpa, i)` (`character varying(20)`과 그 방언 ...) |
| (`Vdbe.changeCntOn`) | `Stmt.countsChanges()` |
| `PRAGMA schema_version` (파일을 읽지 않음) | `Db.schemaVersion(name)` |
| `sqlite3_reset` / `sqlite3_finalize` | `Stmt.reset()` / `Stmt.finalize()` |
| `sqlite3_sql`, `sqlite3_stmt_readonly` | `Stmt.sql()`, `Stmt.isReadOnly()` |
| `sqlite3_errcode/extended_errcode/errmsg/error_offset` | 오류 집합 + `Db.lastError()`, `Diagnostics` |
| `sqlite3_errstr` | `ResultCode.description()` |
| `sqlite3_last_insert_rowid`, `sqlite3_changes64`, `sqlite3_total_changes64` | `lastInsertRowid`, `changes`, `totalChanges` |
| `sqlite3_get_autocommit` | `!inTransaction()` |
| `sqlite3_interrupt` | `Db.interrupt()` (다른 스레드에서 불러도 됨) |
| `sqlite3_busy_timeout` | `OpenOptions.busy_timeout_ms`, `setBusyTimeout` |
| `sqlite3_create_function_v2` / `create_window_function` | `createFunction`, `createAggregate` |
| `sqlite3_create_collation` | `createCollation` |
| `sqlite3_create_module_v2` | `createModule` |
| `sqlite3_backup_init/step/finish` | `Db.backup`, `Backup.step`, `Backup.finish` |
| `sqlite3_backup_remaining/pagecount` | `Backup.remaining`, `Backup.pageCount` |
| `sqlite3_blob_open/read/write/bytes/reopen/close` | `Db.openBlob`, `BlobHandle.read`, `write`, `bytes`, `reopen`, `close` |
| `sqlite3_serialize`, `sqlite3_deserialize` | `Db.serialize`, `Db.deserialize` |
| (그 밖의 모든 것) | `db.raw()` / `stmt.raw()`로 엔진 핸들을 꺼내 `xqlite.sql.*` 저수준 API 사용 |

진짜 C 함수가 필요하면 [C API](c-api.md)(`libxqlite3`)를 링크하세요. 위 표는 Zig API가 무엇에 해당하는지를 보여 줍니다.

## 아직 없는 것

Zig API에 아직 없는 것입니다.

- 훅(commit/update/authorizer)
- 가상 테이블의 쓰기(`xUpdate`), 일반 제약 푸시다운, 트랜잭션 메서드
- 엔진 할당자를 연결별로 고르는 기능(지금은 `configMalloc()` 하나)
- MSSQL 방언

훅(commit/rollback/update, 진행 처리기, 트레이스), 권한 검사기, collation-needed·autovacuum-pages 콜백은 엔진에 있고 C ABI에서 쓸 수 있습니다([C API](c-api.md)). Zig API에는 아직 감싸지 않았습니다.

Zig API 밖의 인터페이스입니다.

- **C ABI**: 있습니다. `sqlite3_*` 호환 C ABI(`libxqlite3`)로 기존 SQLite 바인딩에서 라이브러리만 바꿔 쓸 수 있고, 방언은 URI 파라미터(`file:app.db?dialect=mariadb`)나 `xqlite_set_dialect()`로 고릅니다. [C API](c-api.md)를 보세요.

- **서버 모드(선택, 기반만 있음)**: 기존 클라이언트와 ORM을 그대로 붙일 수 있도록 와이어 프로토콜 서버(pgwire, MySQL protocol, TDS)를 선택적으로 제공할 계획입니다. 프로토콜과 상관없는 부분(리스너, 세션, 타입·오류 분류)은 `xqlite_server` 모듈에 있습니다([서버](server.md)).

  ```sh
  xqlite serve app.db --pg 5432 --mysql 3306 --tds 1433
  ```
