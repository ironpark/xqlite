# SQLite 호환

xqlite의 기본 방언은 SQLite 3.54.1입니다. 순수 Zig 0.17로 새롭게 구현되었으며, 파일 포맷과 SQL 쿼리 결과뿐만 아니라 가능한 모든 영역에서 바이트코드(`EXPLAIN`)와 실행 계획(`EXPLAIN QUERY PLAN`)까지 SQLite와 100% 동일하게 호환됩니다.

---

## 1. 켜는 법 (사용 방법)

SQLite 방언은 xqlite의 **기본(Default) 방언**입니다. 별도의 설정 없이 실행하면 즉시 SQLite 모드로 동작합니다.

| 환경 | 활성화 방법 | 설명 |
| --- | --- | --- |
| **SQL 질의** | `PRAGMA xq_dialect = 'sqlite';` | 다른 방언(PostgreSQL, MariaDB 등)에서 SQLite 기본 방언으로 복귀할 때 사용합니다. |
| **xqlite CLI 셸** | `.dialect sqlite` | 인터랙티브 셸 프롬프트에서 SQLite 방언으로 전환합니다. |
| **셸 실행** | `xqlite sql my.db` | 표준 `sqlite3` CLI와 완벽히 호환되는 대화형 셸이 기본 실행됩니다. |
| **Zig API** | `db.setDialect(.sqlite);` | 기본 설정값입니다 (`typing.active(db) == false`). |

---

## 2. 빠른 시작 (Quickstart)

```sql
-- SQLite 기본 방언 (별도 설정 불필요)
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  points REAL DEFAULT 0.0,
  created_at TEXT DEFAULT (datetime('now'))
);

-- 데이터 삽입
INSERT INTO users (name, points) VALUES ('Alice', 100.5), ('Bob', 80.0);

-- 집계 및 윈도우 함수 조회
SELECT id, name, points,
       rank() OVER (ORDER BY points DESC) as rk
FROM users;

-- 쿼리 실행 계획 및 바이트코드 분석
EXPLAIN QUERY PLAN SELECT * FROM users WHERE name = 'Alice';
EXPLAIN SELECT * FROM users WHERE id = 1;
```

---

## 3. 호환성 보장 수준

| 보장 영역 | 검증 도구 | 보장 내용 |
| --- | --- | --- |
| **파일 포맷** | `xqt interop` | 기존 SQLite 데이터베이스 파일을 그대로 읽고 쓰며, 서로 교차 수정한 파일이 `PRAGMA integrity_check`를 완벽 통과합니다. |
| **저널 및 WAL** | `xqt interop hot-journal`, `wal` | 충돌 복구(Crash Recovery), 핫 저널 복구, WAL 체크포인트를 상호 수행하며, 한 DB를 SQLite3와 xqlite가 동시 읽기/쓰기합니다. |
| **쿼리 결과** | `xqt slt` (sqllogictest) | SQLite 공식 sqllogictest 622개 스크립트, 5,939,879개 테스트를 저널 및 WAL 모드에서 100% 통과합니다. |
| **바이트코드 & 실행 계획** | `xqt planner` | VDBE opcode 시퀀스와 쿼리 플래너의 비용 추정/인덱스 선택 결과가 일치합니다. |
| **셸 도구 호환** | `xqt interop shell` | `.dump`, `.schema`, `.tables`, `.mode` 등 주요 점-명령어(dot commands)를 지원합니다. |

---

## 4. 문서 구성 안내

| 문서 | 핵심 내용 | 대상 |
| --- | --- | --- |
| **[지원 기능 (features.md)](features.md)** | 스토리지, SQL 구문, 윈도우 함수, 가상 테이블, FTS, 내장 모듈 명세 | 개발자, 사용자 |
| **[차이점 및 미지원 (differences.md)](differences.md)** | SQLite 3.54.1 대비 차이점, 미지원 PRAGMA 및 옵션, 제약 사항 | 개발자, DBA |
| **[내부 기술 세부사항 (internals.md)](internals.md)** | Zig 포팅 아키텍처, VDBE 엔진, 정규화 키 정렬기 최적화 기법 | 기여자, 코어 개발자 |
| **[테스트 및 검증 (testing.md)](testing.md)** | `xqt interop`, `xqt slt`, `xqt planner`, 퍼징 테스트 실행 가이드 | 기여자, QA |
