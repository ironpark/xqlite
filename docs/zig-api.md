# Zig API 설계 노트

`xqlite.Db` / `xqlite.Stmt`는 엔진(SQLite 포팅) 위에 얹은 얇은 Zig 계층입니다. 이 문서는 계층 구조, 값의 수명 규칙, 오류 모델, C API와의 대응을 정리합니다. 사용 예는 README의 "Zig API" 절과 `examples/`를 보세요.

## 계층 구조

```
src/xqlite.zig          공개 이름의 유일한 목록 (모듈 루트 root.zig가 전부 다시 내보내고, comptime 검사로 확인)
src/api/Db.zig          연결: open/close, exec, prepare, 트랜잭션, 확장 등록
src/api/Stmt.zig        문장: bind, step, column/row, Iterator
src/api/value.zig       Zig 타입 <-> SQLite 값 comptime 매핑, Value, Blob, free()
src/api/errors.zig      오류 집합, ResultCode, ErrorInfo, Diagnostics
src/api/conn.zig        오류를 연결/Diagnostics에 기록하는 공용 도우미
src/api/func.zig        스칼라 함수, 집계(윈도우) 함수, collation 래퍼
src/api/module.zig      타입이 있는 가상 테이블 모듈 래퍼
src/api/engine.zig      엔진과의 유일한 접점 (아래 참고)
```

`engine.zig`만 엔진 내부(`sql/main.zig`, `sql/prepare.zig`, `vdbe/api.zig`, `sql/callback.zig`, `sql/coll.zig`, `sql/vtab.zig` ...)를 import합니다. 나머지 API 파일은 C API를 따르는 이 파일의 함수와 타입 별칭만 씁니다.

- 오류: 엔진 호출의 결과 코드는 이 경계에서 `int.check(rc)`로 엔진의 오류 집합(`int.Error`)이 되고, `errors.fromEngine()`의 망라적인 `switch` 하나가 이를 `xqlite.SqlError`로 바꿉니다(엔진에 오류가 추가되면 컴파일러가 알려 줍니다). 확장 코드와 메시지는 C처럼 연결에 남습니다. `ResultCode`의 값은 엔진의 `RC.*`에서 가져옵니다.
- API 계층이 직접 찾아낸 오류(`UsageError`, API 할당자의 메모리 부족)는 `Conn.raise()` 한 곳에서 코드와 메시지를 연결과 `Diagnostics`에 기록합니다.
- 콜백: 엔진이 부르는 함수·collation·모듈 콜백은 C 모양(`void*` 문맥)이지만, 엔진의 타입 있는 도우미(`destructor()`, `FuncDef.withUserData()`/`userDataFor()`, `Module.constructor()`/`auxFor()`, `aggContext()`, `thunk()`)로 만들므로 API 쪽에는 `void*`에서의 수동 캐스트가 없습니다.

## 연결과 메모리

```zig
var db = try xqlite.Db.open(gpa, io, "app.db", .{ .journal_mode = .wal, .busy_timeout_ms = 1000 });
defer db.close();
```

- 전역 초기화가 필요 없습니다. `Db.open()`이 필요한 것을 모두 인자로 받습니다.
  - `gpa`: API 계층이 직접 할당하는 것(.unix/.memory VFS 객체, 등록한 함수·모듈의 기록, 함수 호출마다 만드는 arena)을 담습니다.
  - `io`: VFS가 쓰는 `std.Io`입니다.
  - `options.vfs`: `.unix`(OS 파일 시스템), `.memory`(연결 전용 인메모리 파일 시스템), `.custom`(호출자가 소유한 `Vfs`, 예: 여러 연결이 공유하는 `MemVfs`).
- `execArgs`, `one`, `oneAlloc`, `all`은 호출마다 문장을 준비(prepare)하고 확정합니다. 같은 SQL을 반복 실행하는 루프에서는 `prepare()`로 `Stmt`를 한 번 만들어 `bind()`/`exec()`/`next()`로 재사용하세요.
- 엔진 자체의 메모리(페이지 캐시, 문장, 스키마)는 C의 `sqlite3_malloc()`처럼 라이브러리 할당자(`xqlite.malloc.configMalloc()`, 기본값 libc malloc, 테스트에서는 `std.testing.allocator`)에서 나옵니다. 이것은 엔진의 설정이며 API가 새로 만든 전역 상태가 아닙니다.
- 호출자에게 돌려주는 메모리는 언제나 호출자가 넘긴 할당자에서 나옵니다(`oneAlloc`, `all`, `rowAlloc`, `columnAlloc`, `Iterator.nextAlloc`). `xqlite.free(gpa, x)`가 구조체·옵셔널·배열을 따라 내려가며 문자열과 blob을 해제합니다.
- `Db`는 작은 값이라 복사·이동해도 됩니다(단, 닫는 것은 한 번만). `Stmt`와 `Savepoint`는 `Db`를 가리키지 않고 엔진 연결 핸들을 직접 들고 있습니다.
- `close()`는 확정되지 않은 문장이 남아 있으면 안전 빌드에서 panic합니다(누수와 같은 취급). 처리하고 싶으면 `tryClose()`가 `error.Busy`를 돌려주고 연결을 열어 둡니다.

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

빌린 값이 문장보다 오래 살 수 없다는 규칙은 타입으로도 일부 강제합니다. `Db.one(T, ...)`는 문장을 내부에서 확정하므로, `T`가 문자열·blob·`Value`를 담고 있으면 컴파일 오류를 내고 `oneAlloc()`을 쓰라고 알려 줍니다. 빌린 읽기로 `[]u8`(가변)을 요청해도 컴파일 오류입니다.

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

읽기는 SQLite의 변환 규칙을 따릅니다(TEXT `'42'`를 `i64`로 읽으면 42). Zig 쪽에서 추가한 규칙은 두 가지입니다: NULL을 옵셔널이 아닌 타입으로 읽으면 `error.UnexpectedNull`, 정수가 대상 타입에 들어가지 않으면 잘라 내지 않고 `error.IntegerOverflow`입니다.

`bind(args)`는 튜플이면 위치(`?1`, `?2` ...), 구조체면 이름(`:name`, `@name`, `$name`)으로 바인딩합니다. 값의 개수가 매개변수 개수와 다르거나, 필드가 어떤 매개변수와도 맞지 않으면 오류이고, 이때 모든 매개변수는 NULL이 됩니다. `bind()`는 먼저 문장을 reset하고 모든 매개변수에 새 값을 넣습니다. 하나씩 바인딩하려면 `bindAt(i, x)` / `bindName(":x", x)`를 씁니다.

`row(T)`는 일반 구조체면 필드 이름으로 열을 찾고(ASCII 대소문자 무시, 없으면 `error.ColumnNotFound`), 튜플·배열이면 위치로, 그 밖의 타입이면 0번 열을 읽습니다. 이름→열 매핑은 문장마다 캐시되어(`row`, `Stmt.next`, `Iterator`가 공유) 행마다 다시 찾지 않고, 스키마 변경으로 문장이 다시 컴파일되면 새로 계산합니다. 구조체 `bind()`의 필드→매개변수 매핑도 같은 방식으로 캐시합니다. `Iterator`는 문장이 끝난 뒤 `next()`를 불러도 문장을 다시 시작하지 않고 계속 null을 돌려주며, `Stmt.next(T)`는 `step()`처럼 다시 시작합니다.

## 오류 모델

- 엔진 오류는 기본 결과 코드(하위 바이트)마다 하나씩인 `xqlite.SqlError`(`error.Sql`, `error.Busy`, `error.Constraint`, `error.ReadOnly`, `error.Corrupt` ...)로 올라옵니다. 이름은 엔진의 `btree.Error`(`Busy`, `IoErr`, `DiskFull`, `CantOpen`, `NotADatabase` ...)와 맞췄습니다.
- API 자체의 오류는 `xqlite.UsageError`(`UnexpectedNull`, `IntegerOverflow`, `ParameterCountMismatch`, `ColumnNotFound`, `MultipleStatements` ...)이고, `xqlite.Error`가 둘의 합집합입니다.
- 확장 코드와 메시지는 두 방법으로 얻습니다.
  - `db.lastError() ?ErrorInfo`: `sqlite3_extended_errcode()`, `sqlite3_errmsg()`, `sqlite3_error_offset()`. 메시지는 빌린 값입니다.
  - `OpenOptions.diagnostics = &diag`: std.json의 Diagnostics처럼 호출자가 가진 구조체에, 그 연결과 문장의 모든 실패(그리고 연결 객체가 없는 `open()` 실패까지)를 복사해 둡니다. 할당 없이 메시지를 256바이트(`Diagnostics.max_message`)까지 저장합니다. 전체 메시지는 `lastError()`에 있습니다.
- API 오류도 연결의 오류로 기록되므로 `lastError()`로 볼 수 있습니다(코드는 SQLite가 비슷한 문제에 쓰는 `.range`, `.mismatch`, `.misuse`, API의 할당이 실패하면 `.nomem`과 "out of memory").
- 오류인 코드는 OK, ROW, DONE, NOTICE, WARNING을 뺀 모든 코드입니다(`ResultCode.isError()`). `lastError()`와 `ResultCode.toError()`가 이 규칙 하나를 씁니다.
- C와 다른 점 두 가지: `Stmt.finalize()`는 연결의 마지막 오류를 바꾸지 않으므로 `defer stmt.finalize()` 뒤에도 오류를 볼 수 있습니다. `transaction()`과 `Savepoint.rollback()`도 ROLLBACK을 실행한 뒤 원래 오류(코드, 잘리지 않은 메시지, 오프셋)를 연결에 되돌려 둡니다. 되돌릴 오류가 없었으면 정리 작업의 오류도 남기지 않습니다.

## 트랜잭션

- `begin(.deferred | .immediate | .exclusive)`, `commit()`, `rollback()`, `inTransaction()`.
- `transaction(mode, f, args)`: `@call(.auto, f, args)`를 BEGIN과 COMMIT 사이에서 실행합니다. `f`가 오류를 돌려주거나 COMMIT이 실패하면 ROLLBACK하고 그 오류를 돌려줍니다. 반환 타입은 `(xqlite.Error || f의 오류 집합)!f의 결과`입니다.
- `savepoint(name)`은 `Savepoint`를 돌려주고, `release()` 또는 `rollback()`(ROLLBACK TO + RELEASE)으로 끝냅니다. `errdefer sp.rollback();` 패턴을 쓰도록 `rollback()`은 오류를 돌려주지 않습니다.

## 확장 지점

모두 comptime으로 시그니처를 읽어 엔진 콜백 래퍼를 생성합니다. 사용자 데이터는 std.sort의 `context`처럼 넘깁니다(`{}` 또는 포인터).

- `createFunction(name, context, f, opts)`: 인자 수와 인자·반환 타입을 `f`의 시그니처에서 추론합니다. context가 `{}`가 아니면 첫 매개변수로 받습니다. `std.mem.Allocator` 매개변수는 호출이 끝나면 비워지는 arena, `xqlite.Args` 하나만 받으면 가변 인자 함수입니다. 오류를 돌려주면 오류 이름이 SQL 오류 메시지가 됩니다(`OutOfMemory`는 `SQLITE_NOMEM`). `opts`는 `deterministic`, `direct_only`, `innocuous`.
- `createAggregate(name, State, opts)`: 그룹마다의 상태 `State`를 엔진의 aggregate context(0으로 채워진 8바이트 정렬 메모리)에 둡니다. `step`, `final`이 필수이고 `init`, `deinit`, 그리고 윈도우 함수용 `value`·`inverse`는 선택입니다. `deinit`은 문장이 그룹 중간에 버려져도 엔진이 xFinal을 부르므로 항상 실행됩니다.
- `createCollation(name, context, cmp)`: `fn (a, b) std.math.Order` 또는 `fn (ctx, a, b) std.math.Order`.
- `createModule(name, T, context)`: 읽기 전용 가상 테이블. `T`는 `schema`, `connect`, `Cursor`(`open`, `filter`, `next`, `eof`, `column`, 선택적으로 `rowid`, `deinit`)를 선언합니다. `arg_columns`에 적은 HIDDEN 열의 `=` 제약은 `filter()`의 `FilterArgs`로 전달되어 테이블 값 함수(`SELECT * FROM fib(10)`)가 됩니다. 인자 제약이 있지만 그 플랜에서 쓸 수 없으면 `xBestIndex`가 `SQLITE_CONSTRAINT`를 돌려 그 플랜을 거부합니다(series.c와 같은 방식). 그 밖의 제약은 엔진이 행을 받은 뒤 걸러 냅니다. 같은 모듈을 `CREATE VIRTUAL TABLE t USING name(args)`로도, eponymous 테이블로도 쓸 수 있습니다.

## C API 대응

| C | Zig |
| --- | --- |
| `sqlite3_open_v2` | `Db.open(gpa, io, path, options)` |
| `sqlite3_close` | `Db.close()` / `Db.tryClose()` |
| `sqlite3_exec` | `Db.exec(sql)` (여러 문장), `Db.execArgs(sql, args)` (한 문장 + 바인딩) |
| `sqlite3_prepare_v2` | `Db.prepare(sql)` (한 문장만, 나머지가 있으면 `error.MultipleStatements`) |
| `sqlite3_bind_*` | `Stmt.bind(args)`, `bindAt`, `bindName`, `clearBindings` |
| `sqlite3_bind_parameter_count/name/index` | `parameterCount`, `parameterName`, `parameterIndex` |
| `sqlite3_step` | `Stmt.step() !bool`, `Stmt.next(T)`, `Iterator(T).next()` |
| `sqlite3_column_*` | `Stmt.column(T, i)`, `columnAlloc`, `row(T)`, `rowAlloc`, `columnKind` |
| `sqlite3_column_count/name/decltype` | `columnCount`, `columnName`, `columnDecltype`, `columnIndex` |
| `sqlite3_reset` / `sqlite3_finalize` | `Stmt.reset()` / `Stmt.finalize()` |
| `sqlite3_sql`, `sqlite3_stmt_readonly` | `Stmt.sql()`, `Stmt.isReadOnly()` |
| `sqlite3_errcode/extended_errcode/errmsg/error_offset` | 오류 집합 + `Db.lastError()`, `Diagnostics` |
| `sqlite3_errstr` | `ResultCode.description()` |
| `sqlite3_last_insert_rowid`, `sqlite3_changes64`, `sqlite3_total_changes64` | `lastInsertRowid`, `changes`, `totalChanges` |
| `sqlite3_get_autocommit` | `!inTransaction()` |
| `sqlite3_busy_timeout` | `OpenOptions.busy_timeout_ms`, `setBusyTimeout` |
| `sqlite3_create_function_v2` / `create_window_function` | `createFunction`, `createAggregate` |
| `sqlite3_create_collation` | `createCollation` |
| `sqlite3_create_module_v2` | `createModule` |
| (그 밖의 모든 것) | `db.raw()` / `stmt.raw()`로 엔진 핸들을 꺼내 `xqlite.sql.*` 저수준 API 사용 |

## 아직 없는 것

- 방언 선택(`.dialect`), BLOB 증분 I/O, 백업 API, 훅(commit/update/authorizer), `sqlite3_interrupt`.
- 가상 테이블의 쓰기(`xUpdate`), 일반 제약 푸시다운, 트랜잭션 메서드.
- 엔진 할당자를 연결별로 고르는 기능(현재는 `configMalloc()` 하나).
