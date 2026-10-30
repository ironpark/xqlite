# C API (sqlite3 호환)

xqlite는 SQLite 3.54.1의 `sqlite3.h`를 그대로 구현하는 C ABI를 제공합니다. `libsqlite3`에 링크하던 C 프로그램은 헤더와 라이브러리만 바꿔 xqlite를 쓸 수 있고, URI 파라미터 `?dialect=`로 PostgreSQL·MariaDB·MSSQL·Oracle 방언을 고를 수 있습니다. SQLite의 셸(`shell.c`)을 고치지 않고 `libxqlite3`에 링크해 돌리는 것까지 확인합니다.

## 목차

- [빌드와 링크](#빌드와-링크)
- [사용 예](#사용-예)
- [방언](#방언)
- [구조](#구조)
- [지원 범위](#지원-범위)
- [확장](#확장)
- [메모리 데이터베이스와 스냅숏](#메모리-데이터베이스와-스냅숏)
- [SQLite와 다른 점](#sqlite와-다른-점)
- [문장 정보](#문장-정보)
- [preupdate 훅](#preupdate-훅)
- [스레드](#스레드)
- [테스트](#테스트)

## 빌드와 링크

`zig build`가 라이브러리와 헤더를 설치합니다.

| 파일 | 내용 |
| --- | --- |
| `zig-out/lib/libxqlite3.a` | 정적 라이브러리 (compiler-rt 포함) |
| `zig-out/lib/libxqlite3.so.0.8.6` / `libxqlite3.0.8.6.dylib` | 공유 라이브러리 (`.so.0`, `.so` 심볼릭 링크) |
| `zig-out/include/sqlite3.h` | SQLite 3.54.1의 공개 헤더 그대로 (`include/sqlite3.h`, 퍼블릭 도메인) |
| `zig-out/include/sqlite3ext.h` | SQLite 3.54.1의 확장용 헤더 그대로 (`include/sqlite3ext.h`, 로드 가능한 확장을 빌드할 때) |
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
include/sqlite3ext.h   SQLite 3.54.1 확장용 헤더 (맨 위 주석만 추가)
include/xqlite.h       xqlite 확장
src/capi.zig           라이브러리 루트
src/capi/common.zig    C 타입, 연결별 상태(Ext), 프로세스 전역 상태, UTF-16 변환
src/capi/library.zig   버전, sqlite3_initialize/config, 메모리, 문자열 도구, 키워드
src/capi/conn.zig      open/close, exec, get_table, 오류, 설정, 훅 등록, 백업, 스텁
src/capi/stmt.zig      prepare, step, bind, column(UTF-16, 메타데이터), expanded/normalized_sql, scanstatus
src/capi/func.zig      사용자 함수·집계·윈도우 함수, collation, value_*, result_*
src/capi/vtab.zig      C sqlite3_module을 엔진 Module로 감싸는 다리
src/capi/vfs.zig       VFS 등록부, 기본 VFS의 C 뷰, C VFS의 엔진 뷰
src/capi/filename.zig  sqlite3_filename 배치와 uri_parameter 계열, database_file_object
src/capi/hooks.zig     commit/rollback/update 훅, 진행 처리기
src/capi/callbacks.zig 권한 검사기, collation_needed, autovacuum_pages, 트레이스
src/capi/blob.zig      증분 BLOB I/O (엔진의 vdbe/blob.zig 위)
src/capi/testctrl.zig  sqlite3_test_control()
src/capi/printf.zig    mprintf 계열과 sqlite3_str (엔진의 printf 위)
src/capi/varargs.c     가변 인자 함수(printf, config, db_config ...)와 sqlite3_mutex
src/capi/loadext.zig   load_extension, enable_load_extension, 기본 VFS의 xDlOpen/xDlSym/xDlError/xDlClose
src/capi/loadext.c     확장에 넘기는 sqlite3_api_routines 표 (loadext.c의 표 그대로)
src/capi/carray.zig    carray_bind(_v2)
src/ext/carray.zig     carray() 테이블 값 함수 (엔진 가상 테이블)
```

- `sqlite3*`, `sqlite3_stmt*`, `sqlite3_value*`, `sqlite3_context*`는 엔진의 `Sqlite3`, `Vdbe`, `Mem`, `Context` 그 자체입니다. C ABI가 연결마다 따로 두는 상태(C 콜백, 파일 이름, 트레이스 설정 등)는 `Sqlite3.capi`에 매답니다.
- 엔진이 부르는 콜백은 Zig 모양(슬라이스 인자)이라, C 함수·collation·가상 테이블은 트램펄린 뒤에 등록합니다. 사용자 데이터 자리에 C 콜백과 `pApp`을 담은 구조체를 두고, `sqlite3_user_data()`는 `pApp`을 돌려줍니다.
- Zig는 모든 타깃에서 C 가변 인자 함수를 정의하지 못하므로(aarch64-linux의 LLVM 백엔드 등), 가변 인자 함수는 `varargs.c`에 있습니다. `sqlite3_mprintf()`는 형식 문자열을 엔진의 `vappendf()`와 같은 방식으로 읽어 인자를 `va_list`에서 꺼낸 뒤 Zig 쪽에 배열로 넘깁니다.
- 엔진에 추가한 것은 C ABI가 꼭 필요로 하는 것뿐입니다: 연결별 상태 칸, URI의 `vfs=`를 호출자가 처리했다는 플래그와 `ATTACH`의 `vfs=`를 C ABI의 VFS 등록부에서 찾는 자리(`global.find_vfs`), NUL로 끝나는 매개변수 이름, commit/rollback/update 훅, 진행 처리기, 권한 검사기(`auth.c`), collation-needed 콜백, autovacuum-pages 콜백, 트레이스·프로파일 콜백(SQLite C 코드의 포팅; 엔진은 이 콜백들을 Zig 모양으로 부르고 C ABI가 트램펄린으로 C 콜백에 이으며, 콜백이 없으면 널 포인터 검사 하나만 함), SQL 함수 `load_extension()`이 C ABI의 로더를 부르는 자리(`global.load_extension`), `carray()`(연결별 `enable_carray`), 그리고 SQLite의 선택 기능(UTF-16 변환 `sqlite3VdbeMemTranslate()`, 열 출처 `columnType()`, `sqlite3Normalize()`, 스캔 상태, `sqlite3_test_control()`의 엔진 쪽 손잡이, `sqlite3_temp_directory`)의 포팅입니다. 선택 기능은 쓰지 않으면 비용이 없습니다([문장 정보](#문장-정보)).

## 지원 범위

`sqlite3.h`가 선언한 함수 308개 가운데 297개를 내보냅니다. 내보내지 않는 11개는 SQLite의 기본 빌드에도 없는 것입니다(`sqlite3_win32_*` 3개, `sqlite3_rtree_*` 2개, `SQLITE_ENABLE_PREUPDATE_HOOK`의 `sqlite3_preupdate_*` 6개, [아래](#preupdate-훅)). 내보내는 함수 가운데 약 10개는 아래 표처럼 일부만 되거나 깔끔하게 실패하고, 나머지는 SQLite와 같게 동작합니다. 전역 변수 `sqlite3_version`, `sqlite3_temp_directory`, `sqlite3_data_directory`도 내보냅니다.

### 구현된 것

| 분류 | 함수 |
| --- | --- |
| 라이브러리 | `libversion`, `libversion_number`, `sourceid`(헤더의 `SQLITE_SOURCE_ID`와 같음), `threadsafe`, `compileoption_used/get`, `initialize`, `shutdown`, `os_init/end`, `config`(아래), `extended_result_codes` |
| 연결 | `open`, `open_v2`(플래그, URI, `zVfs`, `SQLITE_OPEN_EXRESCODE`), `open16`, `close`, `close_v2`(좀비: 마지막 문장·백업이 끝나면 닫힘), `exec`, `get_table`/`free_table`, `db_config`(아래), `limit`, `busy_timeout`, `busy_handler`, `interrupt`, `is_interrupted`, `get_autocommit`, `txn_state`, `db_filename`(페이저가 VFS에 준 바로 그 이름: URI 파라미터를 포함한 `sqlite3_filename`. memdb·임시 DB는 `""`), `db_readonly`, `db_name`, `db_handle`, `next_stmt`, `changes(64)`, `total_changes(64)`, `last_insert_rowid`, `set_last_insert_rowid`, `table_column_metadata`, `get/set_clientdata`, `file_control`(`VFS_POINTER`는 그 데이터베이스의 VFS, `FILE_POINTER`는 C VFS의 파일, 그 밖의 연산은 C VFS 파일의 `xFileControl`이나 memdb의 `SIZE_LIMIT`·`VFSNAME`; 엔진의 다른 파일은 `SQLITE_NOTFOUND`) |
| 오류 | `errcode`, `extended_errcode`, `errmsg`, `errmsg16`, `errstr`, `error_offset`, `set_errmsg` |
| 문장 | `prepare`, `prepare_v2`, `prepare_v3`(플래그), `prepare16(_v2/_v3)`, `step`, `reset`, `finalize`, `clear_bindings`, `sql`, `expanded_sql`, `normalized_sql`, `stmt_readonly`, `stmt_isexplain`, `stmt_explain`, `stmt_busy`, `stmt_status`, `stmt_scanstatus(_v2/_reset)`([아래](#문장-정보)), `data_count`, `expired`, `transfer_bindings` |
| 바인딩 | `bind_null/int/int64/double/text/text16/text64/blob/blob64/zeroblob/zeroblob64/value/pointer`, `bind_parameter_count/name/index` |
| 열 | `column_count/type/int/int64/double/text/text16/blob/bytes/bytes16/value/name/name16/decltype/decltype16`, `column_database_name/table_name/origin_name(16)`([아래](#문장-정보)) |
| 함수 | `create_function(_v2)`, `create_function16`, `create_window_function`, `overload_function`, `user_data`, `context_db_handle`, `aggregate_context`, `get/set_auxdata`, `value_*`(`value_text16/16le/16be` 포함), `value_dup/free`, `result_*`(UTF-16 입력 포함), `result_pointer`, `result_subtype`, `result_str` |
| collation | `create_collation(_v2)`, `create_collation16` (교체 시 이전 `xDestroy` 호출, `xCompare`가 NULL이면 삭제) |
| 가상 테이블 | `create_module(_v2)`, `drop_modules`, `declare_vtab`, `vtab_config`, `vtab_on_conflict`, `vtab_nochange`, `vtab_collation`, `vtab_distinct`, `vtab_in`, `vtab_in_first/next`, `vtab_rhs_value` (모듈 버전 1~4: 쓰기, 트랜잭션, 세이브포인트, `xShadowName`, `xIntegrity`) |
| 훅 | `commit_hook`, `rollback_hook`, `update_hook`, `progress_handler`, `trace_v2`(`STMT`, `PROFILE`, `ROW`, `CLOSE`), `trace`, `profile`, `wal_hook` (트레이스와 진행 처리기는 SQLite처럼 엔진 안에서 부름: `OP_Init`·`OP_Trace`의 `STMT`, 트리거와 중첩 문장의 `-- ` 주석, `OP_ResultRow`의 `ROW`, 실행이 끝날 때의 `PROFILE`과 진행 처리기의 마지막 호출) |
| 권한 검사 | `set_authorizer` (`auth.c`의 포팅: 모든 검사 지점, `SQLITE_DENY`는 `SQLITE_AUTH` 오류, `SQLITE_IGNORE`는 열을 NULL로 읽거나 그 동작을 건너뜀, 트리거·뷰 이름의 6번째 인자, 바꾸면 준비된 문장을 만료. 방언 프론트엔드가 낮춘 문장에도 같게 적용되고, 방언 카탈로그(`xq_catalog`)의 내부 문장은 보이지 않음) |
| 콜백 | `collation_needed`, `collation_needed16`(없는 collation을 쓸 때 불러 정의할 기회를 줌), `autovacuum_pages`(FULL 자동 vacuum 커밋이 돌려줄 빈 페이지 수), 가상 테이블의 `xFindFunction`(함수 오버로드와 `SQLITE_INDEX_CONSTRAINT_FUNCTION`) |
| WAL·백업 | `wal_autocheckpoint`, `wal_checkpoint`, `wal_checkpoint_v2`(NOOP~TRUNCATE), `backup_init/step/finish/remaining/pagecount` |
| 직렬화·스냅숏 | `serialize`(`SQLITE_SERIALIZE_NOCOPY`), `deserialize`(`FREEONCLOSE`, `RESIZEABLE`, `READONLY`), memdb VFS(`"memdb"`, `file:/이름?vfs=memdb` 공유), `snapshot_get/open/cmp/free/recover` ([메모리 데이터베이스와 스냅숏](#메모리-데이터베이스와-스냅숏)) |
| BLOB | `blob_open/read/write/bytes/close/reopen` (vdbeblob.c의 포팅: 커서로 행의 페이로드를 바로 읽고 씀. 쓰기는 트리거·업데이트 훅을 부르지 않고 `changes()`에 잡히지 않으며, 행이 바뀌거나 지워지면 핸들이 만료되어 `SQLITE_ABORT`) |
| VFS | `vfs_find`, `vfs_register`, `vfs_unregister` (기본 VFS `"unix"`의 C 메서드가 동작하므로 기본 VFS를 감싸는 C VFS도 동작). C VFS의 `xOpen`은 SQLite와 같은 배치의 이름(데이터베이스·저널·WAL)을 받으므로 `uri_parameter()`가 URI 파라미터를 읽고, `ATTACH`도 자기 URI의 `vfs=`를 씀 |
| 파일 이름 | `uri_parameter/boolean/int64/key`, `filename_database/journal/wal`(저널·WAL 이름에서도 데이터베이스 이름으로 거슬러 감), `create_filename`, `free_filename`, `database_file_object`(C VFS로 연 데이터베이스의 `sqlite3_file`) |
| 메모리 | `malloc(64)`, `realloc(64)`, `free`, `msize`, `soft/hard_heap_limit64`, `soft_heap_limit`, `release_memory`, `db_release_memory`, `db_cacheflush`, `memory_used`, `memory_highwater`, `status(64)` ([메모리 통계](#메모리-통계)) |
| 문자열 | `mprintf`, `vmprintf`, `snprintf`, `vsnprintf`, `str_*` 전부, `log`, `complete`, `complete16`, `incomplete`, `stricmp`, `strnicmp`, `strglob`, `strlike`, `keyword_count/name/check`, `randomness`, `sleep` |
| 확장 | `load_extension`, `enable_load_extension`, `SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION`, SQL 함수 `load_extension()`, `carray_bind(_v2)`와 테이블 값 함수 `carray()` ([확장](#확장)) |
| 기타 | `mutex_alloc/free/enter/try/leave/held/notheld`(POSIX 스레드), `db_mutex`([스레드](#스레드)), `test_control`([아래](#문장-정보)), `auto_extension`(`pApi`로 `sqlite3_api_routines` 표를 줌), `cancel_auto_extension`, `reset_auto_extension`, `enable_shared_cache`(무시), `db_status(64)`([메모리 통계](#메모리-통계)) |

`sqlite3_config()`는 `SINGLETHREAD`, `MULTITHREAD`, `SERIALIZED`([스레드](#스레드)), `MALLOC`(C 메모리 함수를 엔진 할당자로), `GETMALLOC`, `LOOKASIDE`, `LOG`, `URI`, `PCACHE_HDRSZ`, `MEMSTATUS`, `MEMDB_MAXSIZE`를 처리하고, 성능 조정용 옵션(`PAGECACHE`, `MMAP_SIZE` 등)은 받고 무시합니다. `GETMUTEX`, `GETPCACHE(2)`는 `SQLITE_ERROR`입니다. SQLite처럼 `sqlite3_initialize()`(첫 `open`이 자동으로 부름) 뒤에는 `LOG`, `PCACHE_HDRSZ` 말고는 `SQLITE_MISUSE`입니다. `sqlite3_db_config()`는 `MAINDBNAME`, `LOOKASIDE`, 1002~1022의 플래그 전부, `FP_DIGITS`를 처리합니다.

### 지원하지 않는 것

| 함수 | 동작 |
| --- | --- |
| `database_file_object` | 기본 VFS나 memdb로 연 데이터베이스는 NULL (엔진의 파일은 `sqlite3_file`이 아님). C VFS가 받은 이름이면 그 데이터베이스의 `sqlite3_file` |
| `db_status`의 `SCHEMA_USED`, `TEMPBUF_SPILL` | 0 ([메모리 통계](#메모리-통계)) |
| `unlock_notify` | 공유 캐시가 없어 막히는 일이 없으므로 콜백을 바로 부름 |
| `activate_cerod` | 아무 일도 하지 않음 |
| 내보내지 않음 | `sqlite3_win32_*`, `sqlite3_rtree_*`, `sqlite3_preupdate_*` |

## 확장

**로드 가능한 확장.** `sqlite3_load_extension()`은 SQLite의 `loadext.c`를 옮긴 것입니다.

- 연결의 VFS의 `xDlOpen`/`xDlSym`/`xDlError`/`xDlClose`로 공유 라이브러리를 엽니다. 기본 VFS는 `dlopen(RTLD_NOW|RTLD_GLOBAL)`, C VFS는 그 VFS의 메서드입니다. 이름 그대로 열리지 않으면 `.dylib`(macOS)나 `.so`를 붙여 다시 해 봅니다.
- 진입점을 주지 않으면 `sqlite3_extension_init`, 그다음 파일 이름에서 만든 `sqlite3_<이름>_init`을 찾습니다(`libExample5.so` → `sqlite3_example_init`, 그다음 `sqlite3_example5_init`).
- 진입점은 SQLite와 같은 순서의 `sqlite3_api_routines` 표(`src/capi/loadext.c`)를 받으므로, `sqlite3ext.h`로 빌드한 확장이 고치지 않고 동작합니다. SQLite 기본 빌드가 NULL로 두는 칸(`SQLITE_ENABLE_COLUMN_METADATA`의 `column_database_name` 등, `unlock_notify`, `normalized_sql`)은 NULL입니다. `sqlite3_auto_extension()`의 진입점도 같은 표를 받습니다.
- 오류 메시지는 SQLite와 같습니다: 꺼져 있으면 `not authorized`, 열지 못하거나 진입점이 없으면 동적 로더의 메시지(`dlerror()`; 없으면 `unable to open shared library [X]`, `no entry point [X] in shared library [Y]`), 진입점이 실패하면 `error during initialization: ...`. SQLite처럼 `sqlite3_errmsg()`에는 남기지 않습니다.
- `sqlite3_enable_load_extension()`은 C 함수와 SQL 함수 `load_extension()`을 함께 켜고, `SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION`은 C 함수만 켭니다.
- 진입점이 `SQLITE_OK_LOAD_PERMANENTLY`를 돌려주면 라이브러리를 닫지 않습니다. 나머지는 연결을 닫을 때(그 함수·collation·모듈을 모두 정리한 뒤) `xDlClose`로 닫습니다.
- WebAssembly에는 동적 로더가 없어 `xDlOpen`이 늘 실패합니다. Zig API(엔진만 쓸 때)의 SQL 함수 `load_extension()`은 넘길 표가 없으므로, 켜져 있어도 "extension loading is not supported"로 실패합니다.

**carray.** C ABI는 `SQLITE_ENABLE_CARRAY`로 빌드한 SQLite처럼 테이블 값 함수 `carray()`와 `sqlite3_carray_bind()`/`sqlite3_carray_bind_v2()`를 갖습니다. `carray()`는 SQLite 3.54의 `carray.c`를 옮긴 엔진 가상 테이블(`src/ext/carray.zig`)이고, SQLite처럼 문장이 처음 `carray`라는 이름을 쓸 때 등록합니다. 엔진에서는 연결별 `Sqlite3.enable_carray`로 켜고, C ABI가 여는 연결은 켜져 있습니다. Zig API의 연결은 기본 빌드처럼 꺼져 있습니다.

- `carray(PTR, N [, TYPE])`: `PTR`은 `sqlite3_bind_pointer(..., "carray", ...)`로 묶은 배열입니다. `TYPE`은 `'int32'`(기본), `'int64'`, `'double'`, `'char*'`, `'struct iovec'`이고, 모르는 타입이면 `unknown datatype: 'X'`입니다.
- `carray(?)`: `sqlite3_carray_bind_v2(stmt, i, aData, nData, SQLITE_CARRAY_*, xDestroy, pDestroy)`로 묶은 배열입니다. `SQLITE_TRANSIENT`면 배열을 복사하고(`char*`의 문자열, `struct iovec`의 내용까지), 아니면 바인딩이 사라질 때 `xDestroy(pDestroy)`를 부릅니다. 묶지 못하면 그 자리에서 부릅니다.
- `PRAGMA compile_options`에는 `ENABLE_CARRAY`가 나오지 않습니다(엔진의 목록은 기본 빌드의 것).

## 메모리 데이터베이스와 스냅숏

**memdb와 직렬화.** SQLite의 `memdb.c`를 옮겼습니다. VFS는 VFS 패키지의 `pkg/vfs/src/memdb.zig`(엔진이 `sqlite3_malloc()` 위에 만든 인스턴스는 `src/sql/memdb.zig`), `sqlite3_serialize()`/`sqlite3_deserialize()`는 `src/sql/serialize.zig`입니다.

- `sqlite3_vfs_find("memdb")`가 있고(SQLite처럼 기본 VFS 다음), 데이터베이스 하나가 연속된 메모리 한 덩어리입니다. 이름이 `/`로 시작하면(`file:/name?vfs=memdb`) 프로세스 안의 연결들이 같은 저장소를 공유하고 마지막 연결이 닫힐 때 사라집니다. 다른 이름은 그 핸들만의 저장소입니다.
- memdb 파일은 공유 메모리가 없어 WAL로 바꿀 수 없고(`journal_mode=wal`은 그대로), 페이저는 SQLite의 memVfs처럼 저널 모드를 `memory`로 시작해 저널도 memdb 파일에 둡니다. `pragma database_list`와 `sqlite3_db_filename()`의 이름은 `""`입니다.
- `sqlite3_serialize()`: memdb 데이터베이스는 저장소를 그대로(복사하거나 `NOCOPY`면 그 포인터), 다른 데이터베이스는 페이저로 페이지를 읽어 만듭니다(`NOCOPY`면 NULL, 크기는 알려 줌). 빈 파일이면 SQLite처럼 `BEGIN IMMEDIATE; COMMIT`으로 첫 페이지를 씁니다.
- `sqlite3_deserialize()`: SQLite처럼 `ATTACH x AS 이름`을 `db.init.reopen_memdb`로 돌려, 그 데이터베이스(main이나 붙인 것, TEMP는 `SQLITE_ERROR`)를 닫고 memdb로 다시 엽니다. 트랜잭션이 열려 있으면 `SQLITE_BUSY`입니다. `RESIZEABLE`이 없으면 버퍼 크기를 넘는 쓰기는 `SQLITE_FULL`, `READONLY`면 쓰기가 `SQLITE_READONLY`입니다.
- `SQLITE_FCNTL_SIZE_LIMIT`(최대 크기, 음수는 묻기), `SQLITE_FCNTL_VFSNAME`(`memdb(주소,크기)`), `SQLITE_CONFIG_MEMDB_MAXSIZE`(기본 1GiB)가 SQLite와 같습니다.
- Zig API: `db.serialize(gpa, "main")`, `db.deserialize("main", image, read_only)` ([Zig API](zig-api.md)).

**스냅숏.** `SQLITE_ENABLE_SNAPSHOT`의 `wal.c`·`pager.c`·`main.c` 부분을 옮겼습니다(`pkg/storage/src/pager/wal.zig`, `src/sql/snapshot.zig`). 스냅숏은 읽기 트랜잭션의 wal-index 헤더 사본(48바이트, `sqlite3_free()`로 해제)입니다.

- `snapshot_get`은 `BEGIN` 안에서, 그 데이터베이스에 쓰기 트랜잭션이 없을 때 읽기 트랜잭션을 열고(읽기 잠금 0은 피함) 그 헤더를 돌려줍니다. WAL 모드가 아니면 `SQLITE_ERROR`입니다.
- `snapshot_open`은 다음 읽기 트랜잭션을 그 스냅숏에서 엽니다. 이미 읽고 있으면(실행 중인 문장이 없을 때) 체크포인트 잠금을 잡고 스냅숏이 아직 있는지 본 뒤 옮깁니다. WAL이 다시 시작되었거나(솔트가 바뀜) 체크포인트가 스냅숏 너머의 프레임을 데이터베이스에 썼으면 `SQLITE_ERROR_SNAPSHOT`입니다. 스냅숏에서 쓰려 하면 SQLite처럼 `SQLITE_BUSY_SNAPSHOT`입니다.
- `snapshot_recover`는 `nBackfillAttempted`를 데이터베이스 파일에 아직 없는 첫 프레임까지 내려 오래된 스냅숏을 다시 열 수 있게 합니다. `snapshot_cmp`는 솔트와 `mxFrame`으로 비교합니다.
- 쓰지 않는 연결의 비용은 WAL 읽기 트랜잭션을 시작할 때 널 포인터 검사 두 번입니다. `PRAGMA compile_options`에는 `ENABLE_SNAPSHOT`이 나오지 않습니다(엔진의 목록은 기본 빌드의 것).

### 메모리 통계

`sqlite3_status()`와 `sqlite3_db_status()`는 status.c를 옮긴 `pkg/base/src/status.zig`와 페이저의 카운터로 셉니다.

- **켜고 끄기**: SQLite의 `SQLITE_CONFIG_MEMSTATUS`입니다. C ABI는 SQLite처럼 기본으로 켜서 `sqlite3_initialize()`(첫 `open`이나 `sqlite3_malloc()`이 부름) 때 시작하고, 그 전에 `sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0)`이면 끕니다. Zig API만 쓰면 꺼져 있어 할당마다 예측 가능한 분기 하나만 듭니다. 켜면 할당·해제마다 원자적 덧셈 두 번(SQLite는 뮤텍스)이 더해지는데, 30만 행 삽입 세 번(ReleaseFast)에서 켜고 끈 차이는 측정 잡음(약 1%) 안이었습니다. 할당 헤더에 센 것인지를 적어 두므로, 켜기 전에 할당한 메모리를 나중에 해제해도 값이 음수가 되지 않습니다.
- **`status(64)`**: `MEMORY_USED`(8바이트로 올린 크기의 합, SQLite의 mem1과 같음), `MALLOC_COUNT`, `MALLOC_SIZE`(가장 큰 요청)와 각 최고치, `PAGECACHE_OVERFLOW`/`PAGECACHE_SIZE`(`SQLITE_CONFIG_PAGECACHE` 버퍼가 없으므로 페이지마다 따로 할당한 크기). `PAGECACHE_USED`, `SCRATCH_*`, `PARSER_STACK`은 0입니다. SQLite의 pcache1은 처음 몇 페이지를 한 번에 할당해 `PAGECACHE_OVERFLOW`에 넣지 않으므로 값은 SQLite와 조금 다릅니다.
- **`db_status(64)`**: 룩어사이드 4가지, `CACHE_USED`(`sqlite3PagerMemUsed()`와 같은 식), `CACHE_USED_SHARED`(공유 캐시가 없어 같음), `CACHE_HIT/MISS/WRITE/SPILL`(페이저의 `aStat`, `reset`으로 0), `STMT_USED`(문장 객체와 그 아레나의 크기), `DEFERRED_FKS`. `SCHEMA_USED`와 `TEMPBUF_SPILL`은 0입니다: SQLite는 스키마를 "해제하는 척"하며 크기를 재는데(`pnBytesFreed`), 엔진의 해제 코드는 그렇게 돌 수 없습니다.

## SQLite와 다른 점

- **스레드**: 기본이 멀티스레드 모드(`sqlite3_threadsafe()` = 2)입니다. 직렬화 모드는 요청할 때만 씁니다. [스레드](#스레드)를 보세요.
- **스캔 상태**: `SQLITE_DBCONFIG_STMT_SCANSTATUS`가 기본으로 꺼져 있습니다(SQLite는 `SQLITE_ENABLE_STMT_SCANSTATUS`로 빌드하면 켜짐). [문장 정보](#문장-정보)를 보세요.
- **`sqlite3_compileoption_used()`**는 `ENABLE_COLUMN_METADATA`, `ENABLE_NORMALIZE`, `ENABLE_STMT_SCANSTATUS`를 보고하지 않습니다(목록은 기본 빌드의 것). 함수 자체는 그 옵션으로 빌드한 SQLite처럼 동작합니다.
- **`sqlite3_prepare()`(v1)**: v2와 같습니다. 문장의 SQL을 늘 보관하므로 스키마가 바뀌면 다시 컴파일하고, 오류 코드는 `step()`에서 바로 돌려줍니다.
- **바인딩 값은 늘 복사합니다**: `SQLITE_STATIC`도 복사하고, 사용자 소멸자는 복사한 직후 부릅니다(SQLite도 허용하는 시점). 결과값(`result_text` 등)은 `SQLITE_STATIC`과 `sqlite3_free`는 복사 없이, 다른 소멸자는 복사 후 바로 부릅니다.
- **BLOB 증분 I/O**는 공유 캐시가 없으므로 `OP_TableLock` 자리가 `OP_Noop`입니다(`SQLITE_OMIT_SHARED_CACHE` 빌드와 같음). 그 밖에는 SQLite와 같습니다.
- **트레이스의 프로파일 시간**은 SQLite처럼 VFS 시계(밀리초)로 재므로 나노초 값의 아래 여섯 자리는 0입니다.
- **VFS**: C VFS의 `xRead`가 `SQLITE_IOERR_SHORT_READ`를 돌려주면 읽은 길이를 모르므로 끝의 0 바이트를 읽지 않은 것으로 칩니다. `sqlite3_database_file_object()`는 데이터베이스 이름 앞(SQLite가 `Pager*`를 두는 자리)에 VFS 다리가 넣어 둔 `sqlite3_file`을 돌려주므로, C VFS로 연 데이터베이스에서만 NULL이 아닙니다.
- **`sqlite3_compileoption_get()`**은 엔진의 `PRAGMA compile_options` 목록에서 `THREADSAFE`만 C ABI의 값(2)으로 바꿔 보여 줍니다.
- `sqlite3_temp_directory`는 unix VFS가 임시 파일 디렉터리로 씁니다(SQLite의 `unixTempFileDir()`처럼 그다음은 `$SQLITE_TMPDIR`, `$TMPDIR`, `/var/tmp`, `/usr/tmp`, `/tmp`, `.`). `PRAGMA temp_store_directory`로도 정합니다. 변수 자체는 VFS 패키지의 `temp_directory`(`pkg/vfs/src/root.zig`)이고, C ABI가 이 이름으로 내보냅니다. `sqlite3_data_directory`는 SQLite에서도 Windows 전용이라 읽는 곳이 없고, `PRAGMA data_store_directory`는 아무 일도 하지 않습니다(Windows가 아닌 SQLite처럼).

## 문장 정보

- **UTF-16 결과**(`column_text16`, `value_text16/16le/16be`, `column_name16` 등): SQLite처럼 값을 그 자리에서 UTF-16으로 바꾸고(`sqlite3VdbeMemTranslate()`의 포팅, `src/vdbe/utf.zig`) 그 포인터를 돌려줍니다. 포인터는 SQLite와 같이 다음 형 변환·`step`·`reset`까지 유효합니다. 엔진은 UTF-8만 읽으므로, UTF-16을 한 번이라도 요청한 연결에서는 C ABI가 결과 행과 C 함수·가상 테이블 콜백의 인자를 엔진이 다시 읽기 전에 UTF-8로 되돌립니다. `column_int` 같은 수 변환은 UTF-16 텍스트를 바꾸지 않고 읽습니다.
- **열 메타데이터**(`SQLITE_ENABLE_COLUMN_METADATA`: `column_database_name/table_name/origin_name`): SQLite에서는 모든 문장이 열마다 이름 세 개를 컴파일해 두지만, 여기서는 처음 물을 때 문장의 SQL을 같은 방언으로 한 번 더 컴파일해(`columnType()`의 포팅이 출처를 기록) 이름만 옮겨 옵니다. 묻지 않는 문장은 비용이 없고, 연결의 오류 상태는 바뀌지 않으며, 스키마가 바뀌어 다시 컴파일된 문장은 다음에 물을 때 새로 구합니다. 결과는 `sqlite3_table_column_metadata()`에 그대로 넘길 수 있습니다.
- **`normalized_sql`**(`SQLITE_ENABLE_NORMALIZE`): SQLite처럼 처음 물을 때 `sqlite3Normalize()`의 포팅으로 만들어 문장에 둡니다. 큰따옴표 식별자를 문자열로 해석한 경우는 컴파일 때 기록합니다. 방언 문장도 SQLite 토크나이저로 정규화합니다.
- **`stmt_explain`**: SQLite처럼 모드를 바꾸고, 필요하면(레지스터가 모자라거나 EQP용 `OP_Explain`이 없으면) 다시 컴파일합니다. 실행 중이면 `SQLITE_BUSY`입니다.
- **`stmt_scanstatus(_v2/_reset)`**(`SQLITE_ENABLE_STMT_SCANSTATUS`): `sqlite3_db_config(db, SQLITE_DBCONFIG_STMT_SCANSTATUS, 1, 0)`을 켠 뒤 준비한 문장이 쿼리 계획의 줄마다 `OP_Explain`과 항목(루프·방문 카운터 주소, 사이클 범위, 예상 행 수, 이름)을 기록하고, 명령어별 실행 횟수와 사이클을 셉니다(x86의 `rdtsc`, ARM64의 `cntvct_el0`; 그 밖은 0). 이 문장들은 세는 코드가 들어간 별도의 인터프리터 루프에서 돌기 때문에, 옵션이 꺼진 문장은 SQLite 기본 빌드와 같은 바이트코드를 같은 루프로 돌립니다. 같은 옵션으로 빌드한 SQLite와 결과가 같습니다(기본값이 꺼짐인 것만 다름). `bytecode()` 가상 테이블의 `nexec`, `ncycle`도 이 값을 보여 줍니다. 트리거 프로그램의 명령어는 세지 않습니다.
- **`test_control`**: 릴리스 빌드 SQLite의 동작을 따릅니다. `PRNG_SAVE/RESTORE/SEED`, `LOCALTIME_FAULT`(`xAltLocaltime` 포함), `OPTIMIZATIONS`, `GETOPT`, `INTERNAL_FUNCTIONS`, `FK_NO_ACTION`, `IMPOSTER`, `RESULT_INTREAL`, `ONCE_RESET_THRESHOLD`, `BYTEORDER`, `ISINIT`, `LOGEST`, `ATOF`, `ALWAYS`, `ASSERT`(0), `PENDING_BYTE`(값을 돌려주지만 바꾸지는 못함), `SEEK_COUNT`(0), `FAULT_INSTALL`(콜백을 0으로 한 번 부를 뿐 엔진에 실패 주입 지점이 없음)이 동작합니다. `NEVER_CORRUPT`, `EXTRA_SCHEMA_CHECKS`, `SORTER_MMAP`, `BITVEC_TEST`, `BENIGN_MALLOC_HOOKS`와 디버그·커버리지 빌드 전용인 `TUNE`, `TRACEFLAGS`, `JSON_SELFCHECK`, `VDBE_COVERAGE`, `PARSER_COVERAGE`는 받고 무시하며 0을 돌려줍니다.

## preupdate 훅

`sqlite3_preupdate_hook()`과 `sqlite3_preupdate_old/new/count/depth/blobwrite()`는 내보내지 않습니다(SQLite 기본 빌드처럼). `SQLITE_ENABLE_PREUPDATE_HOOK`은 런타임 콜백만이 아니라 코드 생성을 바꿉니다: UPDATE와 REPLACE가 훅만 부르는 `OP_Delete`(`OPFLAG_ISNOOP`)를 넣고, WITHOUT ROWID 테이블의 REPLACE 지름길을 쓰지 않고 따로 훅 호출 코드를 만들며, 전송 최적화가 `OP_RowCell` 대신 `OP_RowData`를 쓰고, ANALYZE가 `sqlite_stat1` 쓰기를 따로 다룹니다. xqlite는 기본 빌드와 같은 바이트코드를 내는 것을 보장하므로, 이를 포팅하려면 훅이 있을 때만 그 코드를 생성하도록(그리고 훅을 바꾸면 문장을 만료하도록) 해야 하며 아직 하지 않았습니다.

## 스레드

C ABI는 `SQLITE_THREADSAFE=2`로 빌드한 SQLite와 같습니다: 뮤텍스가 들어 있고, 연결은 기본이 멀티스레드 모드이며 요청하면 직렬화 모드입니다.

- 서로 다른 연결은 서로 다른 스레드에서 동시에 써도 됩니다. 프로세스 전역 상태(설정, VFS 목록, 자동 확장, POSIX 잠금 표, 난수)는 잠금으로 보호합니다.
- **직렬화 모드**: `sqlite3_open_v2()`에 `SQLITE_OPEN_FULLMUTEX`를 주거나 `sqlite3_initialize()` 전에 `sqlite3_config(SQLITE_CONFIG_SERIALIZED)`를 부르면 연결이 재귀 뮤텍스를 갖고(`sqlite3_db_mutex()`), SQLite가 `db->mutex`를 잡는 API(prepare, step, reset, finalize, bind, column, errmsg, exec, 훅 등록, 함수 등록, blob, backup …)가 호출 내내 그 뮤텍스를 잡습니다. 그래서 한 연결을 여러 스레드가 함께 써도 됩니다. `SQLITE_OPEN_NOMUTEX`나 `SQLITE_CONFIG_MULTITHREAD`/`SINGLETHREAD`는 뮤텍스 없이 엽니다.
- 기본을 직렬화로 하지 않은 이유: 뮤텍스는 호출마다 잠금·해제를 더하므로 `step`/`column_*` 반복이 약 2배 느려집니다(macOS aarch64에서 100만 행 × 열 호출 4개가 61ms → 124ms, SQLite 자체도 55ms → 107ms로 같은 비율). 멀티스레드 모드의 연결은 뮤텍스 확인 한 번(null 검사)만 합니다.
- `sqlite3_interrupt()`는 어느 모드에서나 다른 스레드에서 불러도 됩니다(원자 변수).
- `sqlite3_mutex_*()`는 응용과 확장을 위해 POSIX 스레드로 구현합니다. wasm32에서는 스레드가 없으므로 `sqlite3_threadsafe()`는 0이고 직렬화 모드는 `SQLITE_ERROR`입니다.

## 테스트

| 명령 | 내용 |
| --- | --- |
| `zig build test-capi` | `tools/capi/capi_test.c`(검사 1294개)를 정적·공유 라이브러리에 각각 링크해 실행. 로드 가능한 확장 `tools/capi/ext_test.c`(`libxqexttest`)를 함께 빌드해 그 경로를 인자로 줌. `zig build check`에 포함 |
| `zig build capi-shell` | SQLite 3.54.1 아말감의 `shell.c`를 고치지 않고 `include/sqlite3.h`와 `libxqlite3`로 빌드해(`zig-out/bin/sqlite3-xqlite`) `tools/capi/shell_smoke.sql`을 돌리고 출력을 `shell_smoke.expected`와 비교 |
| `zig build capi-fast` | `-Doptimize`와 상관없이 ReleaseFast 정적 라이브러리에 `capi_test.c`와 삽입 벤치마크 `tools/capi/bench.c`(`:memory:`, 한 트랜잭션에 준비된 INSERT 30만 번)를 링크해 각각 8번 실행. ReleaseFast는 `undefined` 메모리를 채우지 않아 그 읽기가 실행마다 주소에 따라 가끔만 실패하므로 여러 번 돌림. `zig build check`에 포함 |

- `capi_test.c`는 `sqlite3.h`만 보고 쓴 평범한 C 프로그램입니다: 버전, 메모리, printf, 문장과 바인딩, 오류 코드, 사용자 함수·집계·윈도우 함수·auxdata·포인터 값, collation, UTF-16, 방언 URI, 파일·WAL·잠금·백업·BLOB, 트레이스(트리거·중첩 문장 포함), 훅과 진행 처리기, 권한 검사기(방언 포함), collation-needed, autovacuum-pages, C 가상 테이블과 `xFindFunction`, 기본 VFS를 감싸는 C VFS, 자동 확장, 인터럽트, 지원하지 않는 함수의 실패, 그리고 직렬화·memdb·스냅숏·메모리 통계·URI 파라미터를 받는 C VFS·`ATTACH`의 `vfs=`, 그룹 C의 UTF-16 결과·열 메타데이터·정규화 SQL·`stmt_explain`·직렬화 모드에서 연결 하나를 공유하는 스레드·`test_control`·임시 디렉터리·스캔 상태.
- 같은 파일을 SQLite 아말감(`sqlite3.c`)에 링크해 돌리면 xqlite 확장과 위 표의 차이(스레드 모드) 말고는 모두 통과합니다(carray와 스냅숏 검사는 `-DSQLITE_ENABLE_CARRAY -DSQLITE_ENABLE_SNAPSHOT`, 파일 끝의 그룹 C 검사는 `SQLITE_ENABLE_COLUMN_METADATA`, `SQLITE_ENABLE_NORMALIZE`, `SQLITE_ENABLE_STMT_SCANSTATUS`, `SQLITE_ENABLE_BYTECODE_VTAB`, `SQLITE_THREADSAFE=2`로 빌드한 아말감에서이며 스캔 상태의 기본값만 다름). 기대값이 xqlite에 맞춘 것이 아니라 SQLite의 동작이라는 확인입니다.
- `shell_smoke.sql`의 출력(`.mode box/csv/json`, `.schema`, `.dump`, 셸 내장 확장 `generate_series`·`sha3`·`decimal`, 오류)은 순정 sqlite3 3.54.1과 같고, 다른 것은 `PRAGMA xq_dialect` 부분뿐입니다.
