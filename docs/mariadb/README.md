# MariaDB (MySQL) 호환

xqlite의 MariaDB 및 MySQL 방언이 제공하는 문법, 동작 방식, 사용 방법 및 호환성 가이드입니다. MariaDB 11 / MySQL 8.0 표준을 기준으로 설계되었으며 SQLite 임베디드 코어 위에서 동작합니다.

---

## 1. 켜는 법 (사용 방법)

| 환경 | 활성화 방법 | 설명 |
| --- | --- | --- |
| **SQL 질의** | `PRAGMA xq_dialect = 'mariadb';`<br>*(또는 `'mysql'`)* | 세션의 현재 방언을 MariaDB로 변경합니다. 언제든 `PRAGMA xq_dialect = 'sqlite';`로 돌아올 수 있습니다. |
| **xqlite CLI 셸** | `.dialect mariadb` | 인터랙티브 셸 프롬프트에서 방언을 전환합니다. |
| **와이어 서버** | `xqlite serve --port 3306` | MySQL 와이어 프로토콜 v10 서버로 구동되어 `mariadb`/`mysql` CLI 클라이언트 및 각종 언어별 MySQL 드라이버로 접속할 수 있습니다. |
| **Zig API** | `db.setDialect(.mariadb);` | 애플리케이션 임베딩 시 연결 단위로 방언을 설정합니다. |

---

## 2. 빠른 시작 (Quickstart)

```sql
-- MariaDB 방언 활성화
PRAGMA xq_dialect = 'mariadb';

-- 다중 데이터베이스 생성 및 전환
CREATE DATABASE IF NOT EXISTS shop;
USE shop;

-- 테이블 생성 (백틱 식별자, AUTO_INCREMENT, ENGINE/CHARSET 구문 지원)
CREATE TABLE `users` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `email` varchar(190) NOT NULL,
  `status` enum('active','banned') NOT NULL DEFAULT 'active',
  `metadata` json,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_email` (`email`)
) ENGINE=InnoDB AUTO_INCREMENT=100 DEFAULT CHARSET=utf8mb4;

-- 데이터 일괄 삽입
INSERT INTO users (email, metadata) VALUES
  ('user1@example.com', '{"role": "admin"}'),
  ('user2@example.com', '{"role": "member"}');

-- 중복 키 처리 (ON DUPLICATE KEY UPDATE)
INSERT INTO users (email, status)
VALUES ('user1@example.com', 'banned')
ON DUPLICATE KEY UPDATE status = VALUES(status);

-- LIMIT offset, count 페이징 조회
SELECT id, email, status, metadata->>'$.role' AS role
FROM users
ORDER BY id
LIMIT 0, 10;

-- sql_mode 변경 및 경고 확인
SET sql_mode = '';
INSERT INTO users (email, status) VALUES ('user3@example.com', 'invalid_enum');
SHOW WARNINGS;

-- SQLite 방언으로 복귀
PRAGMA xq_dialect = 'sqlite';
```

---

## 3. 핵심 기능 요약

- **MySQL/MariaDB 전용 어휘 및 문법**: 백틱 식별자(`` `table` ``), 문자열 백슬래시 이스케이프(`\n`, `\t`), 주석 스타일(`#`, `/* */`, `/*!50100 */` 실행 주석)를 지원합니다.
- **다중 데이터베이스/스키마**: `CREATE DATABASE`, `USE db`, `SHOW DATABASES`, `db.table` 원격 정규화 접근을 지원합니다.
- **특화 DML**: `INSERT IGNORE`, `REPLACE INTO`, `INSERT ... ON DUPLICATE KEY UPDATE`, `AUTO_INCREMENT` 자동 증분을 지원합니다.
- **세션 제어 및 메타데이터**: `SET sql_mode`, `SHOW TABLES`, `SHOW CREATE TABLE`, `SHOW WARNINGS`, `DESCRIBE tbl`, `information_schema.*`를 완벽 지원합니다.

---

## 4. 문서 구성 안내

| 문서 | 핵심 내용 | 대상 |
| --- | --- | --- |
| **[지원 기능 (features.md)](features.md)** | 지원 데이터 타입, SQL 문장(DDL/DML), `sql_mode`, 다중 DB, 내장 함수 | 개발자, 사용자 |
| **[차이점 및 미지원 (differences.md)](differences.md)** | MariaDB 서버와의 동작 차이, 미지원 문법 목록, 제약 사항 및 대안 | 개발자, DBA |
| **[내부 기술 세부사항 (internals.md)](internals.md)** | 다중 DB의 SQLite 매핑 원리, AUTO_INCREMENT 구현, 스토리지 구조 | 기여자, 코어 개발자 |
| **[테스트 및 검증 (testing.md)](testing.md)** | `dialect-diff mariadb`, 실서버 비교 테스트 및 호환성 검증 | 기여자, QA |
