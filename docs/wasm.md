# WebAssembly

xqlite를 WebAssembly로 빌드해 WASI 런타임(wasmtime 등)과 브라우저·Node.js에서 쓰는 방법입니다. 두 가지 타깃이 있습니다.

| 타깃 | 빌드 | 결과물 | 파일 | 용도 |
| --- | --- | --- | --- | --- |
| `wasm32-wasi` | `zig build -Dtarget=wasm32-wasi` | `zig-out/bin/xqlite.wasm` (셸), 라이브러리 | WASI VFS (preview 1) | wasmtime·wasmer, 서버 쪽 샌드박스 |
| `wasm32-freestanding` | `zig build wasm` | `zig-out/wasm/xqlite.wasm` (`xq_*` 내보내기) | 호스트 VFS 또는 메모리 | 브라우저, Node.js, 그 밖의 JavaScript 호스트 |

## 목차

- [크기](#크기)
- [WASI](#wasi)
- [브라우저와 JavaScript](#브라우저와-javascript)
- [내보내는 함수](#내보내는-함수)
- [호스트 import](#호스트-import)
- [잠금과 WAL](#잠금과-wal)
- [플랫폼 차이](#플랫폼-차이)
- [테스트](#테스트)
- [제한](#제한)

## 크기

ReleaseSmall 빌드입니다.

| 결과물 | 크기 | gzip -9 |
| --- | --- | --- |
| `wasm32-freestanding` 모듈 (`zig build wasm`) | 1,790,908 B (1.7MiB) | 697,513 B |
| `wasm32-wasi` 셸 (`-Doptimize=ReleaseSmall`) | 2,031,184 B (1.9MiB) | — |

`zig build wasm`은 `-Doptimize`와 상관없이 ReleaseSmall로 빌드합니다. 바꾸려면 `-Dwasm-optimize=debug`(또는 `safe`, `fast`)를 줍니다.

## WASI

```sh
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
wasmtime run --dir . zig-out/bin/xqlite.wasm sql app.db "CREATE TABLE t(a)" "INSERT INTO t VALUES(1)" "SELECT * FROM t"
wasmtime run --dir . zig-out/bin/xqlite.wasm sql app.db ".dialect postgres" "SELECT 7 / 2"
```

- 라이브러리와 `xqlite` CLI(`sql`, `dbinfo`, `check`, `recover` ...)가 모두 빌드됩니다. wasi-libc를 링크합니다.
- 프로그램은 런타임이 열어 준 디렉터리(`--dir`)만 볼 수 있습니다. 이름은 받은 그대로 쓰고(정규화 없음), 상대 경로는 그 디렉터리를 기준으로 풉니다.
- Zig API에서는 `Db.open(gpa, io, "app.db", .{})`의 기본 `.unix` VFS가 WASI에서는 WASI VFS(`xqlite.WasiVfs`)입니다. `xqlite.OsVfs`는 타깃의 파일 시스템 VFS(POSIX, WASI, 호스트)를 가리킵니다.
- 이름 없는 임시 파일(임시 DB, 서브저널, 정렬기 spill)은 메모리에 둡니다. WASI 프로그램에 쓸 수 있는 임시 디렉터리가 없을 수 있기 때문입니다.
- `sync`는 `fd_sync`입니다. `PRAGMA fullfsync`도 같습니다.

## 브라우저와 JavaScript

```sh
zig build wasm                                             # zig-out/wasm/xqlite.wasm
node examples/wasm/node.mjs zig-out/wasm/xqlite.wasm       # 또는 zig build wasm-example
```

```js
import { load } from "./xqlite.mjs";

const xq = await load(wasmBytes, { files });            // files를 빼면 메모리 DB만
const db = xq.open("app.db", { host: true });           // host: false(기본)는 메모리 파일 시스템
db.exec("CREATE TABLE IF NOT EXISTS t(a, b)");
db.query("INSERT INTO t VALUES (?, ?)", [1, "x"]);
db.query("SELECT * FROM t WHERE a > ?", [0]);           // [{ a: 1, b: "x" }]
db.exec("PRAGMA xq_dialect = 'postgres'");              // 또는 db.setDialect("postgres")
db.close();
```

| 파일 | 내용 |
| --- | --- |
| `examples/wasm/xqlite.mjs` | 연결 코드: import를 채우고 `xq_*`를 `Database` 클래스(`exec`, `query`, `setDialect`, `close`)로 감쌉니다. Node와 브라우저 공용 |
| `examples/wasm/node.mjs` | node:fs 위의 호스트 VFS(`nodeFiles()`)와 검사: 메모리 DB, 방언 넷, 롤백 저널, WAL, 같은 인스턴스의 두 번째 연결, 다시 열기, `integrity_check` |
| `examples/wasm/browser/` | Web Worker에서 OPFS 동기 접근 핸들로 DB를 두는 예제(`opfsFiles()`). `python3 -m http.server`로 저장소 루트를 띄우고 `/examples/wasm/browser/`를 엽니다 |

- `xq_open`의 플래그 2(`host: true`)를 주면 호스트 VFS, 아니면 인스턴스 안의 연결이 함께 쓰는 메모리 파일 시스템입니다. 호스트가 시계와 난수만 줘도 메모리 DB는 그대로 동작합니다.
- OPFS의 `createSyncAccessHandle()`은 비동기인데 호스트 VFS는 동기입니다. 그래서 브라우저 예제는 DB, `-journal`, `-wal` 파일의 핸들을 DB를 열기 전에 미리 열고, "삭제"는 길이를 0으로 줄이는 것으로 대신합니다. IndexedDB로 하려면 페이지를 메모리에 올려 두고 `sync`에서 비동기로 내보내는 식이 됩니다.
- 브라우저 예제는 아직 실제 브라우저에서 돌려 보지 않았습니다. Node 예제는 `zig build wasm-example`이 돌립니다.

## 내보내는 함수

`src/wasm/api.zig`가 Zig API(`Db`, `Stmt`) 위에 얇게 얹은 C 모양의 함수입니다. 핸들은 선형 메모리의 포인터(u32), 문자열은 포인터와 바이트 길이(UTF-8)입니다. 실패할 수 있는 호출은 결과 코드(0 OK, 100 ROW, 101 DONE, 그 밖에는 SQLite 결과 코드)를 돌려주고, 메시지는 `xq_errmsg()`에 있습니다. `sqlite3_*` 이름은 내보내지 않습니다. 그것은 C ABI의 몫입니다.

| 함수 | 하는 일 |
| --- | --- |
| `xq_malloc(n)`, `xq_free(p, n)` | 문자열을 넘길 메모리 |
| `xq_open(path, len, flags) → conn` | 플래그 1 읽기 전용, 2 호스트 파일. 실패해도 연결을 돌려주므로 `xq_errcode()`를 보고 `xq_close()`합니다(메모리 부족이면 0) |
| `xq_close(conn) → rc` | 문장이 남아 있으면 5(BUSY) |
| `xq_errcode(conn)`, `xq_errmsg(conn)` | 마지막 실패의 확장 결과 코드, NUL로 끝나는 메시지 |
| `xq_exec(conn, sql, len) → rc` | 모든 문장 실행, 행은 버림 |
| `xq_set_dialect(conn, name, len) → rc` | `sqlite`, `postgres`, `mariadb`, `mssql`, `oracle`. `PRAGMA xq_dialect`와 같음 |
| `xq_changes(conn) → f64`, `xq_last_insert_rowid(conn) → i64` | |
| `xq_prepare(conn, sql, len) → stmt` | 문장 하나. 실패하면 0 |
| `xq_bind_null/int64/double/text(stmt, i, ...)` | 1부터 셉니다. 값은 복사됩니다 |
| `xq_step(stmt) → rc` | 100 행, 101 끝, 그 밖에는 오류 |
| `xq_column_count`, `xq_column_name`, `xq_column_type` | 타입: 1 정수, 2 실수, 3 텍스트, 4 BLOB, 5 NULL |
| `xq_column_int64`, `xq_column_double`, `xq_column_text`, `xq_column_bytes` | 텍스트·BLOB은 다음 step/reset/finalize까지 유효 |
| `xq_reset(stmt)`, `xq_finalize(stmt)` | |

`i64` 값은 JavaScript에서 BigInt입니다. 연결 코드는 안전한 범위의 정수를 Number로 바꿉니다.

## 호스트 import

모듈은 `env`에서 다음을 가져옵니다. WebAssembly는 모든 import를 인스턴스를 만들 때 요구하므로 파일을 쓰지 않는 호스트도 채워야 합니다. `xqlite.mjs`는 `files`가 없으면 열기를 -2로 거절하는 대역을 넣습니다.

| import | 하는 일 |
| --- | --- |
| `xq_host_now_ms() → f64` | 현재 시각(`Date.now()`): `datetime('now')`, `CURRENT_TIMESTAMP` |
| `xq_host_random(ptr, len)` | 난수(`crypto.getRandomValues()`). 임시 이름, `random()`, `randomblob()` |
| `xq_host_open(path, len, flags) → h` | 비트 0 읽기·쓰기, 1 만들기, 2 이미 있으면 실패, 3 닫을 때 삭제, 8..15 파일 종류(0 DB, 1 저널, ... 7 WAL). 핸들(0 이상) 또는 음수 |
| `xq_host_close(h)` | |
| `xq_host_read(h, ptr, len, offset) → n` | 읽은 바이트 수. 파일 끝이면 더 적게 |
| `xq_host_write(h, ptr, len, offset) → rc` | 전부 씀. 파일을 늘림 |
| `xq_host_truncate(h, size)`, `xq_host_sync(h, flags)` | sync 플래그: 1 full, 2 데이터만 |
| `xq_host_size(h) → f64` | 파일 크기 또는 음수 |
| `xq_host_delete(path, len)` | 없는 파일은 오류가 아님 |
| `xq_host_access(path, len, mode) → 0/1` | mode 0 존재, 1 쓰기 가능, 2 읽기 가능 |
| `xq_host_lock(h, level) → rc` | 핸들의 잠금이 `level`(0 없음, 1 SHARED, 2 RESERVED, 4 EXCLUSIVE)로 바뀜. 더 강한 잠금을 5(BUSY)로 거절할 수 있음 |

오프셋과 크기는 f64(2^53까지 정확)로 넘깁니다. 음수 결과는 오류입니다: -1 I/O, -2 열 수 없음, -3 읽기 전용, -4 디스크 가득, -5 BUSY.

## 잠금과 WAL

WASI에는 권고 잠금(`fcntl(F_SETLK)`, `flock`)이 없고, 브라우저에는 동기 잠금이 없습니다. 그래서 두 VFS 모두 잠금을 프로세스(인스턴스) 안에서 중재합니다(`pkg/vfs/src/inproc.zig`).

- 같은 파일의 핸들은 연결이나 VFS 객체가 달라도 잠금 상태 하나를 나눠 씁니다. WASI VFS는 파일을 장치·inode 번호(`fd_filestat_get`)로, 호스트 VFS는 이름으로 구별합니다. 유닉스 VFS의 inode 표와 같은 방식입니다. 같은 인스턴스의 두 연결은 유닉스에서처럼 서로를 막고(`SQLITE_BUSY`), 한쪽이 쓰는 동안 다른 쪽이 읽습니다.
- **다른 프로세스는 보이지 않습니다.** 두 WASI 프로세스(또는 WASI 프로세스와 sqlite3)가 같은 파일을 동시에 쓰면 DB가 깨질 수 있습니다. 한 DB 파일은 한 번에 한 프로세스만 써야 합니다. 차례로 여는 것은 괜찮습니다.
- 호스트 VFS는 인스턴스 안의 중재를 통과한 잠금을 `xq_host_lock`으로 호스트에 다시 묻습니다. 여러 탭이나 워커를 막으려면 호스트가 여기서 거절하면 됩니다. 연결 코드의 기본값은 모두 허용합니다.
- **WAL**: wal-index(공유 메모리)는 `-shm` 파일이 아니라 같은 파일의 핸들이 함께 쓰는 힙 메모리입니다. 같은 인스턴스의 연결끼리는 WAL이 그대로 동작합니다. 마지막 핸들이 닫히면 사라지므로, 다음에 여는 쪽(xqlite든 sqlite3든)이 크래시 뒤처럼 WAL 파일에서 다시 만듭니다. 남아 있는 `-shm` 파일은 읽지 않습니다. `locking_mode=EXCLUSIVE` 없이도 WAL을 쓸 수 있지만, 프로세스 사이의 공유는 위와 같이 없습니다.
- 롤백 저널과 핫 저널 복구는 POSIX와 같습니다. WASI에서 커밋 도중 죽은 프로세스의 저널은 sqlite3가 되돌리고, 그 반대도 됩니다.

## 플랫폼 차이

엔진은 거의 그대로이고, 다른 점은 comptime에 타깃으로 고릅니다. 네이티브 빌드에는 런타임 비용이 없습니다.

| 차이 | 처리 |
| --- | --- |
| 스레드 | 둘 다 단일 스레드 빌드(`SQLITE_THREADSAFE=0`에 해당). 뮤텍스는 그대로 두지만 경합이 없음. `xqlite fuzzcheck`는 감시 스레드 없이 돎 |
| 64비트 원자 연산 | wasm32에는 atomics 기능 없이는 없음. 힙 한도(`soft_heap_limit`)는 단일 스레드 빌드에서 일반 변수(`src/util/platform.zig`의 `Atomic`) |
| 메모리 | WASI는 wasi-libc의 `malloc`, freestanding은 `std.heap.wasm_allocator`(memory.grow) |
| 시계 | WASI는 `clock_gettime`, freestanding은 `xq_host_now_ms` |
| 시간대 | 둘 다 UTC뿐. `'localtime'` 수정자는 UTC를 돌려줌(wasi-libc의 `localtime_r`과 같음) |
| 환경 변수 | freestanding에는 없음(`XQ_WHERETRACE` 등은 꺼짐) |
| mmap | 쓰지 않음. 데이터 파일 mmap은 원래 없고, `-shm`은 힙 메모리 |
| 확장 로드 | `load_extension()`은 네이티브에서도 언제나 거절하므로(dlopen 없음) 차이 없음 |
| `PATH_MAX` | freestanding은 4096(`vfs.max_path_bytes`) |
| 32비트 | 포인터가 4바이트이므로 페이지 블록 정렬, 레코드 길이 등에서 `usize` 가정을 고침 |

## 테스트

```sh
brew install wasmtime                # 또는 https://wasmtime.dev
zig build test-wasi                  # 단위 테스트 + xqt wasi
zig build wasm-example               # Node.js 예제(검사 포함)
zig-out/bin/xqt wasi --wasm PATH     # WASI 빌드 하나를 따로
```

`zig build test-wasi`는 다음을 돌립니다. `zig build check`에는 들어 있지 않습니다(wasmtime이 필요하므로).

- 모듈, CLI, VFS·스토리지·공용 패키지(`pkg/vfs`, `pkg/storage`, `pkg/base`)의 단위 테스트를 wasm32-wasi로 빌드해 wasmtime에서 실행합니다. POSIX VFS와 `-shm` 파일, 파일 권한에 기대는 세 개만 건너뜁니다.
- `xqt wasi`: ReleaseSafe로 빌드한 WASI `xqlite`를 sqlite3, 네이티브 xqlite와 비교합니다. 자세한 검사 목록은 [테스트와 검증](testing.md#webassembly)에 있습니다.

## 제한

- 프로세스 사이의 잠금이 없습니다([잠금과 WAL](#잠금과-wal)).
- 시간대는 UTC뿐입니다.
- 스레드를 쓰는 빌드(wasm32 + atomics + shared memory)는 시도하지 않았습니다.
- 내보내는 API는 최소한입니다. BLOB 바인딩, 사용자 함수, 백업은 없습니다. C ABI가 생기면 그것을 내보낼 계획입니다.
- 브라우저 예제(OPFS)는 실제 브라우저에서 확인하지 않았습니다. 여러 탭에서 같은 DB를 쓰는 잠금(Web Locks)은 없습니다.
- wasm64는 시도하지 않았습니다.
