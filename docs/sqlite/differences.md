# SQLite 호환: 차이와 제한

xqlite의 SQLite 방언이 SQLite 3.54.1과 다른 점입니다. 기준은 옵션 없이 빌드한 SQLite이고, 비교에는 `zig build tools`가 만드는 `zig-out/bin/sqlite3-planner`(3.54.1, `SQLITE_ENABLE_MATH_FUNCTIONS` 등 몇 가지만 켬)를 씁니다.

## 같은 것

- 파일 형식, 저널·WAL 형식. sqlite3가 만든 핫 저널과 WAL을 복구합니다.
- 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`). `tools/planner`의 케이스 4,170개가 sqlite3와 같고 알려진 차이는 없습니다([testing.md](../testing.md#known-failureslist)).
- 결과와 오류 문구. sqllogictest 전체(스크립트 622개, 테스트 5,939,879개)와 SQLite의 퍼즈 코퍼스(fuzzcheck)를 통과합니다.
- C ABI: `sqlite3.h`의 함수 308개 중 297개([c-api.md](../c-api.md)). 스냅숏, `vfs_register`, 권한 검사기, 직렬화도 있습니다.

## 다른 것

| 항목 | SQLite | xqlite |
| --- | --- | --- |
| `:memory:` 데이터베이스의 저널 | `journal_mode`는 `memory`이고 바꿀 수 없음 | 임시 파일 저널. `journal_mode`는 `delete`이고 `persist`, `truncate`, `wal`로 바뀜 |
| `PRAGMA journal_mode = MEMORY` | 저널을 메모리에 둠 | `not supported yet` 오류 |
| `PRAGMA locking_mode = EXCLUSIVE` | 첫 읽기·쓰기 뒤 잠금을 놓지 않음 | `not supported yet` 오류 |
| `PRAGMA encoding = 'UTF-16...'` | UTF-16 데이터베이스를 만듦 | `not supported yet` 오류. UTF-8만. UTF-16 데이터베이스 파일은 열지 못함 |
| `PRAGMA mmap_size` | 메모리 맵 I/O의 크기 | 늘 0. 메모리 맵을 쓰지 않음 |
| 수학 함수(`sin`, `pow`, `log` ...) | `SQLITE_ENABLE_MATH_FUNCTIONS` 빌드에 있음(배포판 셸은 대개 켬) | 없음 |
| `PRAGMA compile_options` | 빌드의 옵션 | `ATOMIC_INTRINSICS=1`, `COMPILER=zig-...`, `SYSTEM_MALLOC`, `THREADSAFE=1` |
| `EXPLAIN`의 트리거 서브프로그램 | 메인 프로그램 뒤에 나열 | 메인 프로그램만 |
| Windows | win32 VFS | 없음(POSIX, WASI, 메모리 VFS) |

공유 캐시(`cache=shared`)는 받고 무시합니다. SQLite도 기본 빌드에서 권하지 않는 기능입니다.

## 없는 확장

옵션 없는 SQLite 빌드에도 없는 것들입니다. 배포판의 sqlite3(예: macOS의 `/usr/bin/sqlite3`)는 대개 켜고 빌드하므로, 그런 셸과 비교하면 차이입니다.

- 전문 검색 FTS3/4/5, R*Tree, Geopoly, session, `dbstat`, `sqlite_dbpage`
- `median()`/`percentile()`(`SQLITE_ENABLE_PERCENTILE`), `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`의 `DELETE ... ORDER BY ... LIMIT`
- preupdate 훅(`SQLITE_ENABLE_PREUPDATE_HOOK`, [c-api.md](../c-api.md#preupdate-훅))

다른 확장은 `sqlite3_load_extension()`으로 올릴 수 있습니다([load-extension.md](../load-extension.md)).

## 내부 구현의 차이

결과와 바이트코드는 같고, 실행 방식만 다릅니다.

- 정렬기는 레코드마다 첫 정렬 열의 64비트 정규화 키를 함께 두고 먼저 비교합니다([internals.md](internals.md)).
- `ANALYZE`는 `sqlite_stat1`만 만듭니다. SQLite 기본 빌드처럼 `SQLITE_ENABLE_STAT4`가 꺼져 있습니다.
- 검증 방법은 [testing.md](testing.md)에 있습니다. SQLite의 TCL 테스트 스위트는 아직 돌리지 않습니다.
