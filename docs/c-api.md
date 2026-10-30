# C API (sqlite3 호환)

xqlite는 SQLite 3.54.1의 `sqlite3.h`를 그대로 구현하는 C ABI를 제공합니다. `libsqlite3`에 링크하던 C 프로그램은 헤더와 라이브러리만 바꿔 xqlite를 쓸 수 있고, URI 파라미터 `?dialect=`로 PostgreSQL·MariaDB·MSSQL·Oracle 방언을 고를 수 있습니다. SQLite의 셸(`shell.c`)을 고치지 않고 `libxqlite3`에 링크해 돌리는 것까지 확인합니다.

## 목차

- [빌드와 링크](#빌드와-링크)
- [사용 예](#사용-예)
- [방언](#방언)
- [구조](#구조)
- [지원 범위](#지원-범위)
- [SQLite와 다른 점](#sqlite와-다른-점)
- [스레드](#스레드)
- [테스트](#테스트)

## 빌드와 링크

`zig build`가 라이브러리와 헤더를 설치합니다.

| 파일 | 내용 |
| --- | --- |
| `zig-out/lib/libxqlite3.a` | 정적 라이브러리 (compiler-rt 포함) |
| `zig-out/lib/libxqlite3.so.0.8.6` / `libxqlite3.0.8.6.dylib` | 공유 라이브러리 (`.so.0`, `.so` 심볼릭 링크) |
| `zig-out/include/sqlite3.h` | SQLite 3.54.1의 공개 헤더 그대로 (`include/sqlite3.h`, 퍼블릭 도메인) |
| `zig-out/include/xqlite.h` | xqlite 확장 (`xqlite_set_dialect()`, `xqlite_dialect()`) |
| `zig-out/lib/pkgconfig/xqlite3.pc` | pkg-config |

| 옵션 | 기본값 | 뜻 |
| --- | --- | --- |
| `-Dcapi-name=NAME` | `xqlite3` | 라이브러리 이름 `libNAME`. `sqlite3`이면 `libsqlite3.a`, `libsqlite3.so.0`(배포판과 같은 soname), `sqlite3.pc`가 되어 그대로 바꿔 끼울 수 있음 |
| `-Dcapi=false` | `true` | `zig build`에서 C 라이브러리를 빼기 |
| `-Dsqlite-shell-c=PATH` | `/tmp/xq-sqlite-build/shell.c` | `zig build capi-shell`이 빌드할 SQLite 아말감의 `shell.c` |

```sh
zig build -Doptimize=ReleaseFast                       # zig-out/lib/libxqlite3.*
cc app.c -Izig-out/include zig-out/lib/libxqlite3.a -lpthread -lm
cc app.c $(PKG_CONFIG_PATH=zig-out/lib/pkgconfig pkg-config --cflags --libs xqlite3)
zig build -Dcapi-name=sqlite3 -Doptimize=ReleaseFast    # libsqlite3.*: -lsqlite3로 링크하던 프로그램용
```

크기(macOS aarch64, `zig build` 결과)는 다음과 같습니다.

| 빌드 | 공유 라이브러리 | 정적 라이브러리 |
| --- | --- | --- |
| ReleaseFast | 5.3MiB | 36MiB (디버그 정보 포함) |
| ReleaseSmall | 2.3MiB | 4.1MiB |
| Debug | 13.5MiB | 32MiB |

크로스 컴파일도 됩니다(`-Dtarget=x86_64-linux-gnu`, `aarch64-linux`). `wasm32-wasi`에서는 정적 라이브러리만 만들고(기본 VFS 이름은 `"wasi"`, 뮤텍스는 아무 일도 하지 않음), `wasm32-freestanding`에서는 C 라이브러리를 만들지 않습니다.

## 사용 예

```c
#include "sqlite3.h"
#include "xqlite.h"

sqlite3 *db;
sqlite3_stmt *st;
sqlite3_open_v2("file:app.db?dialect=postgres", &db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL);
sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS users (id bigserial PRIMARY KEY, email text NOT NULL)", 0, 0, 0);
sqlite3_prepare_v2(db, "INSERT INTO users (email) VALUES ($1) RETURNING id", -1, &st, NULL);
sqlite3_bind_text(st, 1, "hello@example.com", -1, SQLITE_STATIC);
if (sqlite3_step(st) == SQLITE_ROW) printf("id = %lld\n", sqlite3_column_int64(st, 0));
sqlite3_finalize(st);
sqlite3_close(db);
```

## 방언

방언은 연결 단위이고, 세 가지로 고릅니다. 모두 그 뒤에 준비하는 문장부터 적용되고, 이미 준비한 문장은 자기 방언을 유지합니다.

| 방법 | 예 |
| --- | --- |
| URI 파라미터 (`SQLITE_OPEN_URI` 또는 `SQLITE_CONFIG_URI`) | `file:app.db?dialect=mariadb`, `file::memory:?dialect=oracle` |
| xqlite 확장 함수 | `xqlite_set_dialect(db, "pg")`, `xqlite_dialect(db)` → `"postgres"` |
| SQL | `PRAGMA xq_dialect = 'mssql'` |

이름은 `sqlite`, `postgres`, `mariadb`, `mssql`, `oracle`(대소문자 무시)과 별칭 `pg`, `postgresql`, `mysql`, `sqlserver`, `tsql`입니다. 모르는 이름이면 `sqlite3_open_v2()`는 `SQLITE_ERROR`와 "no such dialect: X"를 돌려주고(연결 객체는 SQLite 관례대로 돌려주므로 닫아야 함), `xqlite_set_dialect()`도 `SQLITE_ERROR`입니다. `SQLITE_OPEN_URI` 없이 `file:...?dialect=`을 주면 SQLite처럼 그냥 파일 이름입니다.

## 구조

```
include/sqlite3.h      SQLite 3.54.1 헤더 (맨 위 주석만 추가)
include/xqlite.h       xqlite 확장
src/capi.zig           라이브러리 루트
src/capi/common.zig    C 타입, 연결별 상태(Ext), 프로세스 전역 상태, UTF-16 변환
src/capi/library.zig   버전, sqlite3_initialize/config, 메모리, 문자열 도구, 키워드
src/capi/conn.zig      open/close, exec, get_table, 오류, 설정, 훅 등록, 백업, 스텁
src/capi/stmt.zig      prepare, step(트레이스), bind, column, expanded_sql
src/capi/func.zig      사용자 함수·집계·윈도우 함수, collation, value_*, result_*
src/capi/vtab.zig      C sqlite3_module을 엔진 Module로 감싸는 다리
src/capi/vfs.zig       VFS 등록부, 기본 VFS의 C 뷰, C VFS의 엔진 뷰
src/capi/filename.zig  sqlite3_filename 배치와 uri_parameter 계열
src/capi/hooks.zig     commit/rollback/update 훅, 진행 처리기
src/capi/blob.zig      증분 BLOB I/O (엔진의 vdbe/blob.zig 위)
src/capi/printf.zig    mprintf 계열과 sqlite3_str (엔진의 printf 위)
src/capi/varargs.c     가변 인자 함수(printf, config, db_config ...)와 sqlite3_mutex
```

- `sqlite3*`, `sqlite3_stmt*`, `sqlite3_value*`, `sqlite3_context*`는 엔진의 `Sqlite3`, `Vdbe`, `Mem`, `Context` 그 자체입니다. C ABI가 연결마다 따로 두는 상태(C 콜백, 파일 이름, 트레이스 설정 등)는 `Sqlite3.capi`에 매답니다.
- 엔진이 부르는 콜백은 Zig 모양(슬라이스 인자)이라, C 함수·collation·가상 테이블은 트램펄린 뒤에 등록합니다. 사용자 데이터 자리에 C 콜백과 `pApp`을 담은 구조체를 두고, `sqlite3_user_data()`는 `pApp`을 돌려줍니다.
- Zig는 모든 타깃에서 C 가변 인자 함수를 정의하지 못하므로(aarch64-linux의 LLVM 백엔드 등), 가변 인자 함수는 `varargs.c`에 있습니다. `sqlite3_mprintf()`는 형식 문자열을 엔진의 `vappendf()`와 같은 방식으로 읽어 인자를 `va_list`에서 꺼낸 뒤 Zig 쪽에 배열로 넘깁니다.
- 엔진에 추가한 것은 C ABI가 꼭 필요로 하는 것뿐입니다: 연결별 상태 칸, URI의 `vfs=`를 호출자가 처리했다는 플래그, NUL로 끝나는 매개변수 이름, 그리고 commit/rollback/update 훅과 진행 처리기(SQLite C 코드의 포팅).

## 지원 범위

`sqlite3.h`가 선언한 함수 308개 가운데 297개를 내보냅니다. 내보내지 않는 11개는 SQLite의 기본 빌드에도 없는 것입니다(`sqlite3_win32_*` 3개, `sqlite3_rtree_*` 2개, `SQLITE_ENABLE_PREUPDATE_HOOK`의 `sqlite3_preupdate_*` 6개). 내보내는 함수 가운데 약 30개는 아래 표처럼 일부만 되거나 깔끔하게 실패하고, 나머지는 SQLite와 같게 동작합니다. 전역 변수 `sqlite3_version`, `sqlite3_temp_directory`, `sqlite3_data_directory`도 내보냅니다.

### 구현된 것

| 분류 | 함수 |
| --- | --- |
| 라이브러리 | `libversion`, `libversion_number`, `sourceid`(헤더의 `SQLITE_SOURCE_ID`와 같음), `threadsafe`, `compileoption_used/get`, `initialize`, `shutdown`, `os_init/end`, `config`(아래), `extended_result_codes` |
| 연결 | `open`, `open_v2`(플래그, URI, `zVfs`, `SQLITE_OPEN_EXRESCODE`), `open16`, `close`, `close_v2`(좀비: 마지막 문장·백업이 끝나면 닫힘), `exec`, `get_table`/`free_table`, `db_config`(아래), `limit`, `busy_timeout`, `busy_handler`, `interrupt`, `is_interrupted`, `get_autocommit`, `txn_state`, `db_filename`(URI 파라미터 포함한 `sqlite3_filename`), `db_readonly`, `db_name`, `db_handle`, `next_stmt`, `changes(64)`, `total_changes(64)`, `last_insert_rowid`, `set_last_insert_rowid`, `table_column_metadata`, `get/set_clientdata`, `file_control`(`SQLITE_FCNTL_VFS_POINTER`만) |
| 오류 | `errcode`, `extended_errcode`, `errmsg`, `errmsg16`, `errstr`, `error_offset`, `set_errmsg` |
| 문장 | `prepare`, `prepare_v2`, `prepare_v3`(플래그), `prepare16(_v2/_v3)`, `step`, `reset`, `finalize`, `clear_bindings`, `sql`, `expanded_sql`, `stmt_readonly`, `stmt_isexplain`, `stmt_busy`, `stmt_status`, `data_count`, `expired`, `transfer_bindings` |
| 바인딩 | `bind_null/int/int64/double/text/text16/text64/blob/blob64/zeroblob/zeroblob64/value/pointer`, `bind_parameter_count/name/index` |
| 열 | `column_count/type/int/int64/double/text/blob/bytes/bytes16/value/name/decltype` |
| 함수 | `create_function(_v2)`, `create_function16`, `create_window_function`, `overload_function`, `user_data`, `context_db_handle`, `aggregate_context`, `get/set_auxdata`, `value_*`(UTF-16 결과 제외), `value_dup/free`, `result_*`(UTF-16 입력 포함), `result_pointer`, `result_subtype`, `result_str` |
| collation | `create_collation(_v2)`, `create_collation16` (교체 시 이전 `xDestroy` 호출, `xCompare`가 NULL이면 삭제) |
| 가상 테이블 | `create_module(_v2)`, `drop_modules`, `declare_vtab`, `vtab_config`, `vtab_on_conflict`, `vtab_nochange`, `vtab_collation`, `vtab_distinct`, `vtab_in`, `vtab_in_first/next`, `vtab_rhs_value` (모듈 버전 1~4: 쓰기, 트랜잭션, 세이브포인트, `xShadowName`, `xIntegrity`) |
| 훅 | `commit_hook`, `rollback_hook`, `update_hook`, `progress_handler`, `trace_v2`(`STMT`, `PROFILE`, `ROW`, `CLOSE`), `trace`, `profile`, `wal_hook` |
| WAL·백업 | `wal_autocheckpoint`, `wal_checkpoint`, `wal_checkpoint_v2`(NOOP~TRUNCATE), `backup_init/step/finish/remaining/pagecount` |
| BLOB | `blob_open/read/write/bytes/close/reopen` (vdbeblob.c의 포팅: 커서로 행의 페이로드를 바로 읽고 씀. 쓰기는 트리거·업데이트 훅을 부르지 않고 `changes()`에 잡히지 않으며, 행이 바뀌거나 지워지면 핸들이 만료되어 `SQLITE_ABORT`) |
| VFS | `vfs_find`, `vfs_register`, `vfs_unregister` (기본 VFS `"unix"`의 C 메서드가 동작하므로 기본 VFS를 감싸는 C VFS도 동작) |
| 파일 이름 | `uri_parameter/boolean/int64/key`, `filename_database/journal/wal`, `create_filename`, `free_filename` |
| 메모리 | `malloc(64)`, `realloc(64)`, `free`, `msize`, `soft/hard_heap_limit64`, `soft_heap_limit`, `release_memory`, `db_release_memory`, `db_cacheflush` |
| 문자열 | `mprintf`, `vmprintf`, `snprintf`, `vsnprintf`, `str_*` 전부, `log`, `complete`, `complete16`, `incomplete`, `stricmp`, `strnicmp`, `strglob`, `strlike`, `keyword_count/name/check`, `randomness`, `sleep` |
| 기타 | `mutex_alloc/free/enter/try/leave/held/notheld`(POSIX 스레드), `auto_extension`, `cancel_auto_extension`, `reset_auto_extension`, `enable_load_extension`(플래그만), `enable_shared_cache`(무시), `db_status(64)`(룩어사이드와 `DEFERRED_FKS`, 나머지는 0), `status(64)`(0) |

`sqlite3_config()`는 `SINGLETHREAD`, `MULTITHREAD`, `MALLOC`(C 메모리 함수를 엔진 할당자로), `GETMALLOC`, `LOOKASIDE`, `LOG`, `URI`, `PCACHE_HDRSZ`를 처리하고, 성능 조정용 옵션(`PAGECACHE`, `MMAP_SIZE`, `MEMSTATUS` 등)은 받고 무시합니다. `SERIALIZED`, `GETMUTEX`, `GETPCACHE(2)`는 `SQLITE_ERROR`입니다. SQLite처럼 `sqlite3_initialize()`(첫 `open`이 자동으로 부름) 뒤에는 `LOG`, `PCACHE_HDRSZ` 말고는 `SQLITE_MISUSE`입니다. `sqlite3_db_config()`는 `MAINDBNAME`, `LOOKASIDE`, 1002~1022의 플래그 전부, `FP_DIGITS`를 처리합니다.

### 지원하지 않는 것

| 함수 | 동작 |
| --- | --- |
| `set_authorizer` | 콜백을 주면 `SQLITE_ERROR`("xqlite does not support sqlite3_set_authorizer()"), NULL이면 `SQLITE_OK`. 엔진에 권한 검사가 없으므로, 받기만 하고 부르지 않으면 막으려던 것이 통과하기 때문 |
| `load_extension` | `SQLITE_ERROR`와 메시지. `xDlOpen`도 없음 |
| `serialize` / `deserialize` | NULL / `SQLITE_ERROR` (memdb VFS가 없음) |
| `snapshot_get/open/cmp/free/recover` | `SQLITE_ERROR` |
| `column_text16`, `column_name16`, `column_decltype16`, `value_text16(le/be)` | NULL. 엔진은 UTF-8만 다루고, 값만큼 사는 UTF-16 사본을 둘 곳이 없음. UTF-16 **입력**(`open16`, `prepare16*`, `bind_text16`, `result_text16*`, `create_function16`, `create_collation16`, `complete16`)과 `errmsg16`, `*_bytes16`은 됨 |
| `column_database_name`, `column_table_name`, `column_origin_name`(16 포함) | NULL (SQLite 기본 빌드처럼 `SQLITE_ENABLE_COLUMN_METADATA` 없음) |
| `normalized_sql` | NULL (`SQLITE_ENABLE_NORMALIZE` 없음) |
| `stmt_scanstatus(_v2/_reset)` | 보고할 루프 없음 (`SQLITE_ENABLE_STMT_SCANSTATUS` 없음) |
| `stmt_explain` | 지금 모드와 같으면 `SQLITE_OK`, 바꾸려 하면 `SQLITE_ERROR` |
| `carray_bind(_v2)` | `SQLITE_ERROR`, 소멸자는 부름 |
| `collation_needed(16)` | 등록은 되지만 엔진이 부르지 않음 |
| `autovacuum_pages` | 등록은 되지만 엔진이 부르지 않음(기본 동작) |
| `database_file_object` | NULL (엔진의 파일은 `sqlite3_file`이 아님) |
| `test_control` | 0 |
| `memory_used`, `memory_highwater`, `status(64)` | 0 (메모리를 세지 않음) |
| `unlock_notify` | 공유 캐시가 없어 막히는 일이 없으므로 콜백을 바로 부름 |
| `db_mutex` | NULL (멀티스레드 모드) |
| 가상 테이블의 `xFindFunction` | 부르지 않음(함수 오버로드 없음) |
| `activate_cerod` | 아무 일도 하지 않음 |
| 내보내지 않음 | `sqlite3_win32_*`, `sqlite3_rtree_*`, `sqlite3_preupdate_*` |

## SQLite와 다른 점

- **스레드**: 멀티스레드 모드(`sqlite3_threadsafe()` = 2)입니다. [스레드](#스레드)를 보세요.
- **`sqlite3_prepare()`(v1)**: v2와 같습니다. 문장의 SQL을 늘 보관하므로 스키마가 바뀌면 다시 컴파일하고, 오류 코드는 `step()`에서 바로 돌려줍니다.
- **바인딩 값은 늘 복사합니다**: `SQLITE_STATIC`도 복사하고, 사용자 소멸자는 복사한 직후 부릅니다(SQLite도 허용하는 시점). 결과값(`result_text` 등)은 `SQLITE_STATIC`과 `sqlite3_free`는 복사 없이, 다른 소멸자는 복사 후 바로 부릅니다.
- **BLOB 증분 I/O**는 공유 캐시가 없으므로 `OP_TableLock` 자리가 `OP_Noop`입니다(`SQLITE_OMIT_SHARED_CACHE` 빌드와 같음). 그 밖에는 SQLite와 같습니다.
- **트레이스**: `SQLITE_TRACE_STMT`/`PROFILE`/`ROW`는 C ABI의 `sqlite3_step()`에서 부르므로, 트리거 안의 문장(`--` 주석으로 오는 것)은 보고하지 않습니다. `sqlite3_exec()`도 같은 `step()`을 쓰므로 그 문장은 보고됩니다.
- **진행 처리기**는 SQLite처럼 N개 명령마다 점프 지점에서 부르지만, 문장이 끝날 때 남은 몫을 한 번 더 부르지는 않습니다.
- **VFS**: C VFS의 `xRead`가 `SQLITE_IOERR_SHORT_READ`를 돌려주면 읽은 길이를 모르므로 끝의 0 바이트를 읽지 않은 것으로 칩니다. C VFS가 받는 파일 이름에는 URI 파라미터가 없습니다(`sqlite3_uri_parameter()`는 NULL). URI에서 `vfs=`를 쓴 연결이 `ATTACH`하는 URI의 `vfs=`는 무시하고 연결의 VFS를 씁니다.
- **`sqlite3_compileoption_get()`**은 엔진의 `PRAGMA compile_options` 목록에서 `THREADSAFE`만 C ABI의 값(2)으로 바꿔 보여 줍니다.
- `sqlite3_temp_directory`, `sqlite3_data_directory`는 내보내지만 엔진이 읽지 않습니다.

## 스레드

C ABI는 멀티스레드 모드입니다(`SQLITE_THREADSAFE=2`와 같음).

- 서로 다른 연결은 서로 다른 스레드에서 동시에 써도 됩니다. 프로세스 전역 상태(설정, VFS 목록, 자동 확장, POSIX 잠금 표, 난수)는 잠금으로 보호합니다.
- 한 연결(과 그 문장)을 두 스레드가 동시에 쓰면 안 됩니다. 연결에 뮤텍스가 없으므로 `SQLITE_OPEN_FULLMUTEX`는 무시하고, `sqlite3_config(SQLITE_CONFIG_SERIALIZED)`는 `SQLITE_ERROR`입니다.
- `sqlite3_interrupt()`는 다른 스레드에서 불러도 됩니다(원자 변수).
- `sqlite3_mutex_*()`는 응용과 확장을 위해 POSIX 스레드로 구현합니다.

## 테스트

| 명령 | 내용 |
| --- | --- |
| `zig build test-capi` | `tools/capi/capi_test.c`(검사 546개)를 정적·공유 라이브러리에 각각 링크해 실행. `zig build check`에 포함 |
| `zig build capi-shell` | SQLite 3.54.1 아말감의 `shell.c`를 고치지 않고 `include/sqlite3.h`와 `libxqlite3`로 빌드해(`zig-out/bin/sqlite3-xqlite`) `tools/capi/shell_smoke.sql`을 돌리고 출력을 `shell_smoke.expected`와 비교 |

- `capi_test.c`는 `sqlite3.h`만 보고 쓴 평범한 C 프로그램입니다: 버전, 메모리, printf, 문장과 바인딩, 오류 코드, 사용자 함수·집계·윈도우 함수·auxdata·포인터 값, collation, UTF-16, 방언 URI, 파일·WAL·잠금·백업·BLOB, 트레이스, 훅과 진행 처리기, C 가상 테이블, 기본 VFS를 감싸는 C VFS, 자동 확장, 인터럽트, 지원하지 않는 함수의 실패.
- 같은 파일을 SQLite 아말감(`sqlite3.c`)에 링크해 돌리면 xqlite 확장과 위 표의 차이(스레드 모드, 권한 검사기, serialize) 말고는 모두 통과합니다. 기대값이 xqlite에 맞춘 것이 아니라 SQLite의 동작이라는 확인입니다.
- `shell_smoke.sql`의 출력(`.mode box/csv/json`, `.schema`, `.dump`, 셸 내장 확장 `generate_series`·`sha3`·`decimal`, 오류)은 순정 sqlite3 3.54.1과 같고, 다른 것은 `PRAGMA xq_dialect` 부분뿐입니다.
