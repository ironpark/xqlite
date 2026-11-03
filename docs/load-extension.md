# 확장 로드와 사용

SQLite용으로 나온 로더블 확장(sqlite-regex, sqlite-vec, sqlean ...)을 xqlite에서 그대로 쓸 수 있습니다. 확장을 다시 빌드할 필요는 없고, 확장이 등록한 함수와 가상 테이블은 모든 방언에서 씁니다.

xqlite가 직접 가진 확장(sqlite3에 올리는 `libxqlite_ext`, 내장 `carray()` 등)은 [sqlite3용 확장](extension.md)과 [C API의 확장](c-api.md#확장)에 있습니다.

## 목차

- [빠른 시작: 셸](#빠른-시작-셸)
- [확장 구하기](#확장-구하기)
- [Zig에서](#zig에서)
- [C에서](#c에서)
- [예제](#예제)
- [알아 둘 것](#알아-둘-것)
- [동작](#동작)

## 빠른 시작: 셸

[sqlite-regex](https://github.com/asg017/sqlite-regex)를 예로 듭니다.

```sh
gh release download -R asg017/sqlite-regex -p '*loadable-macos-aarch64.tar.gz'   # Linux: '*loadable-linux-x86_64*'
tar xzf sqlite-regex-*.tar.gz                                                      # regex0.dylib (Linux: regex0.so)
zig-out/bin/xqlite sql app.db
```

```
sqlite> .load ./regex0
sqlite> SELECT regex_find('[0-9]{3}-[0-9]{4}', 'call 555-1234');
555-1234
sqlite> SELECT rowid, item FROM regex_split(',\s*', 'a, b,c');
0|a
1|b
2|c
sqlite> .dialect postgres
sqlite> SELECT regex_replace_all('o', 'foo', '0') AS r, 'xq' ~ '^x' AS m;
f00|t
```

- `.load FILE ?ENTRY?`는 sqlite3 셸의 것과 같습니다. 확장자(`.dylib`, `.so`)는 생략해도 되고, 진입점은 보통 생략합니다.
- 명령줄에서 한 번에: `xqlite sql app.db ".load ./regex0" "SELECT regex_find('a+', 'baaa')"`

## 확장 구하기

대부분의 확장은 릴리스에 플랫폼별 공유 라이브러리를 올려 둡니다. 운영체제와 CPU에 맞는 것을 받습니다(macOS는 `.dylib`, Linux는 `.so`).

진입점은 이 순서로 찾으므로 보통 이름을 주지 않아도 됩니다.

1. 준 이름(`.load FILE ENTRY`, `loadExtension(path, "entry")`)
2. `sqlite3_extension_init`
3. 파일 이름에서 만든 `sqlite3_<이름>_init`: 앞의 `lib`와 첫 `.`부터를 떼고 영문자만 소문자로(`regex0.dylib` → `sqlite3_regex_init`), 그것도 없으면 숫자까지 넣어서(`sqlite3_regex0_init`)

## Zig에서

`Db.loadExtension(path, entry)`로 올립니다. 연결을 닫을 때까지 올라가 있습니다.

```zig
var db = try xqlite.Db.open(gpa, io, "app.db", .{});
defer db.close();
db.loadExtension("./regex0", null) catch |err| {
    std.debug.print("{s}\n", .{db.lastError().?.message});
    return err;
};
const m = try db.oneAlloc([]const u8, gpa, "SELECT regex_find(?, ?)", .{ "[0-9]+", "abc 123" });
```

- 실패하면 `error.Sql`이고, 이유(라이브러리를 열지 못함, 진입점 없음, 초기화 실패)는 `db.lastError()`의 메시지에 있습니다.
- 확장은 sqlite3 C API로 xqlite를 부르므로, `loadExtension()`을 쓰는 프로그램에는 C ABI가 함께 빌드됩니다(macOS aarch64 Debug에서 약 0.6MB). 쓰지 않는 프로그램에는 들어가지 않습니다.

## C에서

`libxqlite3`는 sqlite3 C API와 같습니다.

```c
char *err = NULL;
sqlite3_enable_load_extension(db, 1);
if (sqlite3_load_extension(db, "./regex0", NULL, &err) != SQLITE_OK) {
    fprintf(stderr, "%s\n", err);
    sqlite3_free(err);
}
sqlite3_enable_load_extension(db, 0);
```

`sqlite3_enable_load_extension()`으로 켠 뒤의 SQL 함수 `SELECT load_extension('./regex0')`, 모든 연결에 올리는 `sqlite3_auto_extension()`도 됩니다.

## 예제

`examples/extension/`에 sqlite-regex를 올려 쓰는 예제가 있습니다. 받은 라이브러리의 경로를 넘깁니다.

| 파일 | 실행 | 내용 |
| --- | --- | --- |
| `sqlite_regex.zig` | `zig build example-sqlite-regex -- ./regex0` | Zig API: `loadExtension()`, 인자를 바인딩한 호출, 테이블 값 함수를 구조체로 읽기, CHECK와 식 인덱스, PostgreSQL 방언 |
| `sqlite_regex.c` | `zig build example-sqlite-regex-c -- ./regex0` | C API: `sqlite3_load_extension()`, 같은 질의, URI `?dialect=postgres` |

라이브러리는 저장소에 없으므로 `zig build examples`는 예제를 빌드만 합니다. sqlite-regex v0.2.3, macOS aarch64에서 확인했습니다.

## 알아 둘 것

- **연결마다 올립니다.** 새 연결을 열거나 셸을 다시 띄우면 다시 올립니다.
- **스키마가 확장에 기대면** 그 DB는 확장 없이 쓸 수 없습니다. `CHECK (email REGEXP ...)`나 `regex_find()` 식 인덱스가 있는 테이블에 쓰는 연결은 모두 확장을 올려야 합니다(sqlite3와 같음).
- **믿을 수 있는 라이브러리만 올립니다.** 확장은 프로세스 안에서 도는 네이티브 코드입니다. 그래서 SQL 함수 `load_extension()`은 Zig API와 셸에서 꺼져 있고(`not authorized`), C에서도 켜야 씁니다.
- **안 되는 곳**: WebAssembly(동적 로더 없음), 와이어 서버(`xqlite serve`)의 연결, `zig build capi-shell`의 `sqlite3-xqlite`(`SQLITE_OMIT_LOAD_EXTENSION`으로 빌드).

## 동작

- 로더는 SQLite의 `loadext.c`를 옮긴 것입니다(`src/capi/loadext.zig`). 기본 VFS의 `xDlOpen`(`dlopen(RTLD_NOW|RTLD_GLOBAL)`)으로 열고, 이름 그대로 열리지 않으면 `.dylib`(macOS)나 `.so`를 붙여 다시 해 봅니다. 진입점에는 SQLite와 같은 순서의 `sqlite3_api_routines` 표(`src/capi/loadext.c`)를 넘기므로 `sqlite3ext.h`로 빌드한 확장이 고치지 않고 동작합니다. SQLite 기본 빌드가 NULL로 두는 칸(`column_database_name` 등, `unlock_notify`, `normalized_sql`)은 NULL입니다.
- Zig API와 셸의 연결은 C ABI가 연 것이 아니므로, 처음 올릴 때 C ABI의 연결별 상태(올린 라이브러리, C가 등록한 collation 등)를 붙이고 닫을 때 뗍니다(`src/capi/bridge.zig`, 루트의 `xqlite.loadext`). 빌드는 C ABI의 C 부분(`varargs.c`, `loadext.c`)을 엔진 모듈에 정적 라이브러리로 링크하므로, 쓰지 않으면 링크되지 않습니다.
- 라이브러리는 연결을 닫을 때, 그 함수·collation·모듈을 모두 정리한 뒤에 닫습니다. 진입점이 `SQLITE_OK_LOAD_PERMANENTLY`를 돌려주면 닫지 않습니다.
- 오류 메시지는 SQLite와 같습니다: 꺼져 있으면 `not authorized`, 열지 못하거나 진입점이 없으면 동적 로더의 메시지(없으면 `unable to open shared library [X]`, `no entry point [X] in shared library [Y]`), 진입점이 실패하면 `error during initialization: ...`.
- 검사: `zig build test-capi`가 `tools/capi/ext_test.c`로 만든 확장을 C(`capi_test.c`)와 Zig API(`tools/capi/zig_load_test.zig`)로 올립니다.
