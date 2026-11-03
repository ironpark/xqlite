# SQLite 호환: 차이점 및 제한 사항

xqlite SQLite 방언과 C 언어로 작성된 표준 SQLite 3.54.1 간의 세부 차이점, 미지원 PRAGMA 및 제약 사항입니다.

---

## 1. 세부 동작 차이점

| 항목 | 표준 SQLite 3.54.1 (C) | xqlite SQLite 방언 (Zig) | 설명 및 이유 |
| --- | --- | --- | --- |
| **정렬기 성능 최적화** | vdbesort 기반 레코드 전체 비교 | 64비트 정규화 정렬 키(Normalized Key) 선행 비교 후 레코드 비교 | 정렬 및 `ORDER BY` 시 첫 번째 열의 64비트 정규화 키를 먼저 비교하여 대부분의 레코드 디코딩 비용을 건너뜁니다. 결과 행 순서와 바이트코드는 네이티브와 100% 동일합니다. |
| **인메모리 DB 임시 파일** | 힙 메모리 전용 구조 | 임시 파일 기반 저널링 사용 | `":memory:"` 지정 시 임시 파일 기반으로 구동되어 기본 `journal_mode`가 `memory`가 아닌 `delete`로 설정될 수 있습니다. |
| **`ANALYZE` 통계 테이블** | `sqlite_stat1` 및 `sqlite_stat4` 수집 | `sqlite_stat1` 전용 수집 | 대부분의 임베디드 배포 환경과 동일하게 `SQLITE_ENABLE_STAT4`는 비활성화되어 있습니다. |

---

## 2. 미지원 PRAGMA 및 옵션

현재 실행 시 `not supported yet` 오류를 반환하거나 지원되지 않는 기능 목록입니다.

- **잠금 및 저널 모드**:
  - `PRAGMA locking_mode = EXCLUSIVE`: 미지원 (기본 `NORMAL` 공유 잠금 사용).
  - `PRAGMA journal_mode = MEMORY`: 미지원 (`DELETE`, `TRUNCATE`, `PERSIST`, `WAL`, `OFF` 지원).
- **텍스트 인코딩**:
  - `PRAGMA encoding = 'UTF-16'`: 미지원 (xqlite는 고성능 UTF-8 인코딩만 지원).
- **고급 I/O 및 메모리 맵**:
  - `PRAGMA mmap_size`: 항상 0을 돌려주며 mmap I/O는 사용하지 않습니다.
  - WAL 스냅샷 API (`sqlite3_snapshot_*`): 미지원.
- **가상 파일 시스템 및 캐시**:
  - 커스텀 VFS 등록 (`sqlite3_vfs_register`): URI의 `vfs=` 파라미터는 `no such vfs` 오류를 반환합니다.
  - 공유 캐시(Shared Cache): URI의 `cache=shared`는 검사 후 무시됩니다.
  - 작성자 인가 콜백(Authorizer Callback): 미지원.
- **운영체제 대상**:
  - Windows VFS (`win32`): 현재 POSIX 및 WASI 대상 우선 지원.

---

## 3. 권장 대응책

1. **UTF-8 인코딩 사용**:
   - 데이터베이스 생성 시 항상 표준인 `UTF-8` 인코딩을 사용하세요.
2. **동시성 설정**:
   - 높은 동시성 읽기/쓰기가 필요한 환경에서는 `PRAGMA journal_mode = WAL;`을 적용하여 쓰기 중에도 읽기 트래픽을 차단하지 않도록 설정하는 것이 좋습니다.
