# 아직 하지 않은 것

[SQLite 호환](README.md)의 일부입니다.

문장으로 쓰면 `not supported yet` 오류가 나는 것:

- `PRAGMA locking_mode=EXCLUSIVE`. 그래서 힙 메모리 WAL 모드도 없습니다.
- `PRAGMA journal_mode=MEMORY`
- `PRAGMA encoding=UTF-16`

그 밖에 없는 것:

- `sqlite_stat4`(`SQLITE_ENABLE_STAT4`). 기준 sqlite3 빌드도 끄므로 `ANALYZE`는 `sqlite_stat1`만 쓰고, `sqlite_stat4`·`sqlite_stat3`이 있으면 행을 지우기만 합니다.
- WAL 스냅샷 API
- 메모리 데이터베이스. `":memory:"`는 임시 파일이라 `journal_mode`가 `memory`가 아닌 `delete`입니다.
- VFS 등록과 이름. 그래서 URI의 `vfs=`는 늘 `no such vfs: %s`입니다.
- 공유 캐시. URI의 `cache=`는 검사만 하고 무시합니다.
- 권한 콜백(authorizer). `ATTACH`/`DETACH`도 검사하지 않습니다.
- 메모리 맵 I/O. `PRAGMA mmap_size`는 항상 0을 돌려줍니다.
- Windows VFS
- sqlite3 호환 C ABI
