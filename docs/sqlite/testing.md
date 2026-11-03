# 검증 도구

[SQLite 호환](README.md)의 일부입니다.

| 도구 | 확인하는 것 |
| --- | --- |
| `xqt interop btree`, `sql` | 서로 만든 DB 파일을 교차로 읽고 쓰고 `PRAGMA integrity_check` |
| `xqt interop pragma`, `shell` | PRAGMA 결과, 셸 출력·dot-command·오류, `.dump` 왕복 |
| `xqt interop savepoint`, `hot-journal` | 세이브포인트·문장 롤백, 핫 저널 복구 |
| `xqt interop wal` | WAL 파일 상호 읽기, 체크포인트, 크래시 복구, 두 엔진 프로세스 동시 접근 |
| `xqt interop attach` | 서로의 파일을 붙여 읽고 쓰기, 여러 파일 트랜잭션, 커밋 도중 크래시와 super journal 복구 |
| `xqt interop analyze` | 같은 데이터의 `sqlite_stat1` 행, 서로 분석한 DB의 실행 계획과 `PRAGMA optimize` |
| `xqt interop vacuum` | 같은 DB를 두 엔진이 `VACUUM`/`VACUUM INTO`한 파일의 바이트 비교, 셸의 `.backup`/`.restore`, VACUUM 도중 크래시 복구 |
| `xqt planner` | 쿼리 결과·`EXPLAIN QUERY PLAN`·바이트코드를 sqlite3와 비교 |
| `xqt slt` | sqllogictest. 스크립트 622개, 테스트 5,939,879개를 롤백 저널과 WAL 모드에서 모두 통과합니다([tools/slt/README.md](../../tools/slt/README.md)). |
| `xqlite fuzzcheck` | SQLite 퍼즈 코퍼스(`test/fuzzdata*.db`)에서 크래시·누수 |
| `xqt interop ext` | 방언으로 만든 DB를 확장을 올린 sqlite3가 검사·읽기·쓰기, 엔진 함수의 결과를 xqlite와 비교(기록된 ABI 케이스, 생성한 호출) ([sqlite3용 확장](../extension.md#검증)) |

실행 방법은 [테스트 문서](../testing.md)를 보세요.
