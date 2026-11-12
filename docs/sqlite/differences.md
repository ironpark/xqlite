# SQLite 호환: 차이와 제한

xqlite의 SQLite 방언이 SQLite 3.54.1과 다른 점입니다. 기준은 옵션 없이 빌드한 SQLite이고, 비교에는 `zig build tools`가 만드는 `zig-out/bin/sqlite3-planner`(3.54.1, `SQLITE_ENABLE_MATH_FUNCTIONS` 등 몇 가지만 켬)를 씁니다.

## 같은 것

- 파일 형식, 저널·WAL 형식. sqlite3가 만든 핫 저널과 WAL을 복구합니다.
- 텍스트 인코딩. UTF-16le/be 데이터베이스(`PRAGMA encoding`, `sqlite3_open16()`)를 SQLite처럼 만들고, sqlite3가 만든 UTF-16 파일을 읽고 씁니다. 인덱스 순서, `hex()` 결과, collation의 변환까지 같습니다([features.md](features.md#1-스토리지-및-저널링-기능)).
- 결과와 오류 문구. sqllogictest 전체(스크립트 622개, 테스트 5,939,879개)와 SQLite의 퍼즈 코퍼스(fuzzcheck)를 통과합니다.
- C ABI: `sqlite3.h`의 함수 308개 중 297개([c-api.md](../c-api.md)). 스냅숏, `vfs_register`, 권한 검사기, 직렬화도 있습니다.

## 다른 것

| 항목 | SQLite | xqlite |
| --- | --- | --- |
| 수학 함수(`sin`, `exp`, `pow` ...)의 마지막 비트 | 플랫폼 C 라이브러리의 libm | 어느 플랫폼, 빌드 모드, WebAssembly에서나 musl의 libm(`src/dialect/libm.zig`). musl과 같고(`log2`는 musl 1.2의 Arm 코드가 아닌 FreeBSD의 것), `exp`·`ln`·`pow`는 같은 Arm 코드를 쓰는 glibc와도 대개 같음. macOS의 sqlite3와는 `exp`·`ln`·`pow`의 0.1% 안팎, 삼각·쌍곡 함수의 수 %(`tan`은 36%)가 1~3 ULP 다름 |
| `PRAGMA compile_options` | 빌드의 옵션 | `ATOMIC_INTRINSICS=1`, `COMPILER=zig-...`, `SYSTEM_MALLOC`, `THREADSAFE=1`. 수학 함수가 있어도 `ENABLE_MATH_FUNCTIONS`는 나오지 않음(목록은 기본 빌드의 것, [c-api.md](../c-api.md)) |
| `EXPLAIN`의 트리거 서브프로그램 | 메인 프로그램 뒤에 나열 | 메인 프로그램만 |
| Windows | win32 VFS | 없음(POSIX, WASI, 메모리 VFS) |

공유 캐시(`cache=shared`, `sqlite3_enable_shared_cache()`)는 SQLite와 같이 동작합니다: 연결들이 페이지 캐시와 스키마를 함께 쓰고 테이블 잠금(`OP_TableLock`)으로 서로를 막습니다([c-api.md](../c-api.md#공유-캐시)). SQLite도 권하지 않는 기능입니다.

`journal_mode=MEMORY`, `locking_mode=EXCLUSIVE`(WAL이면 힙 메모리의 wal-index), 파일 없는 `:memory:` 데이터베이스, `mmap_size`의 메모리 맵 읽기는 SQLite와 같습니다([지원 기능](features.md#1-스토리지-및-저널링-기능)).

SQLite가 아닌 방언(PostgreSQL, MariaDB, MSSQL, Oracle)은 UTF-8 데이터베이스에서만 씁니다. 방언 함수, 카탈로그, 값 표시가 텍스트를 UTF-8로 읽기 때문입니다. UTF-16 데이터베이스에서 그 방언으로 문장을 준비하면 `the postgres dialect does not support UTF-16 databases` 같은 오류입니다. 인코딩은 스키마를 읽어야 알 수 있으므로 문장을 컴파일하기 전과 후에 검사합니다. 방언과 상관없이 SQLite 문법으로 넘기는 명령(`PRAGMA`, `ATTACH`, `DETACH`, `VACUUM`, `REINDEX`)은 돌므로 `PRAGMA xq_dialect = 'sqlite'`로 돌아갈 수 있습니다.

수학 함수는 SQLite 방언에만 있습니다. 다른 방언의 연결은 같은 이름의 자기 함수를 부르거나(PostgreSQL의 `sin`), 전처럼 없는 함수로 다룹니다(PostgreSQL의 `log2`). 그래서 SQLite 방언에서 만든 CHECK, 생성 열, 식 인덱스, 뷰가 수학 함수를 부르면 다른 방언의 연결에서는 그 식을 계산하지 못하거나(`unknown function: log2()`) 그 방언의 함수로 계산합니다. 방언이 가린 다른 내장 함수에도 있는 제한입니다.

## 없는 확장

옵션 없는 SQLite 빌드에도 없는 것들입니다. 배포판의 sqlite3(예: macOS의 `/usr/bin/sqlite3`)는 대개 켜고 빌드하므로, 그런 셸과 비교하면 차이입니다.

- 전문 검색 FTS3/4/5, R*Tree, Geopoly, session, `dbstat`, `sqlite_dbpage`
- `median()`/`percentile()`(`SQLITE_ENABLE_PERCENTILE`), `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`의 `DELETE ... ORDER BY ... LIMIT`
- preupdate 훅(`SQLITE_ENABLE_PREUPDATE_HOOK`, [c-api.md](../c-api.md#preupdate-훅))

다른 확장은 `sqlite3_load_extension()`으로 올릴 수 있습니다([load-extension.md](../load-extension.md)).

## 내부 구현의 차이

결과는 같고 실행 방식이 다릅니다. 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`)은 v0.0.4까지 `tools/planner`의 모든 케이스에서 sqlite3와 같았지만, 앞으로는 맞추지 않습니다. `EXPLAIN`의 내용, `bytecode()` 가상 테이블, `sqlite3_stmt_status()`의 카운터가 SQLite와 달라질 수 있습니다.

- 메모리 맵(`PRAGMA mmap_size`)에서 페이지를 바로 읽는 것은 읽기 트랜잭션 안에서만입니다. SQLite는 쓰기 트랜잭션 안의 읽기 커서도 맵의 페이지를 받는데(`PAGER_GET_READONLY`), xqlite의 B-tree는 이 표시를 넘기지 않아 그때는 페이지 캐시로 읽습니다. 맵을 키우는 것은 SQLite처럼 기존 매핑 뒤에 이어 붙이거나(Linux는 `mremap()`) 안 되면 새로 매핑합니다.
- 메모리 저널(`memjournal.zig`)은 청크 목록을 SQLite처럼 두지만, 문장 저널(서브 저널)은 예전처럼 늘 메모리 버퍼입니다(`SQLITE_STMTJRNL_SPILL=-1`과 같음).
- 정렬기는 레코드마다 첫 정렬 열의 64비트 정규화 키를 함께 두고 먼저 비교합니다([internals.md](internals.md)).
- `ANALYZE`는 `sqlite_stat1`만 만듭니다. SQLite 기본 빌드처럼 `SQLITE_ENABLE_STAT4`가 꺼져 있습니다.
- collation은 SQLite처럼 이름마다 인코딩별 정의를 둡니다. 데이터베이스 인코딩의 정의가 없으면 다른 인코딩의 정의를 그대로 씁니다(UTF-16be, UTF-16le, UTF-8 순). SQLite의 `synthCollSeq()`는 그것을 인코딩 칸에 복사해 두지만, 고르는 정의와 비교할 때의 변환은 같습니다. 한 가지 다른 경우는 응용이 내장 collation(NOCASE 등)을 UTF-8로 지운 뒤 UTF-16 데이터베이스에서 쓰는 것입니다. SQLite는 정의가 없다는 오류를 내고 xqlite는 내장 정의를 씁니다.
- UTF-16 데이터베이스에서 `OP_String8`은 처음 실행될 때 UTF-16 사본을 프로그램의 arena에 만들어 P4로 바꿉니다(C는 `sqlite3DbMalloc()`한 버퍼를 `P4_DYNAMIC`으로).
- 검증 방법은 [testing.md](testing.md)에 있습니다. SQLite의 TCL 테스트 스위트(`xqt tcl`)에서 xqlite만 실패하는 테스트와 그 원인(공유 캐시, 몇 가지 패닉 등)은 [testing.md의 기준선](../testing.md#기준선)에 있습니다.
