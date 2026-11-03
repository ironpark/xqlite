# SQLite 호환

xqlite의 기본 방언은 SQLite 3.54.1입니다. 순수 Zig 포팅이지만 파일 포맷과 SQL 결과를 sqlite3와 같게 맞추고, 가능한 곳에서는 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`)까지 같게 맞춥니다. SQLite 방언은 다른 방언이 추가되어도 동작이 바뀌지 않습니다.

## 목차

- [구현된 기능](features.md)
- [내장 모듈과 확장](modules.md)
- [검증 도구](testing.md)
- [아직 하지 않은 것](todo.md)

## 호환 수준

| 보장하는 것 | 확인 방법 |
| --- | --- |
| 파일 포맷: 기존 SQLite 파일을 그대로 읽고 쓰고, 서로 만든 파일이 `PRAGMA integrity_check`를 통과 | `xqt interop` |
| 저널·WAL 호환: 서로의 핫 저널을 복구하고, 한 DB를 두 엔진 프로세스가 동시에 읽고 씀 | `xqt interop hot-journal`, `xqt interop wal` |
| 쿼리 결과 | `xqt planner`, sqllogictest(`xqt slt`) |
| 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`) | `xqt planner` |
| 셸 출력 | `xqt interop shell` |
