# MariaDB 호환

xqlite의 MariaDB(MySQL) 방언이 지원하는 문법과 의미, 그리고 MariaDB와 다른 점입니다. 방언 구조와 프론트엔드 계약은 [방언 아키텍처](../architecture.md)를 보세요.

## 목차

- [구조](structure.md)
- [저장 방식](storage.md)
- [데이터베이스](databases.md)
- [`sql_mode`](sql-mode.md)
- [지원 문법](syntax.md)
- [MariaDB와 다른 점](differences.md)
- [아직 하지 않은 것](todo.md)
- [검증](testing.md)

## 켜는 법

| 어디서 | 어떻게 |
| --- | --- |
| SQL | `PRAGMA xq_dialect = 'mariadb'`(또는 `'mysql'`) |
| 셸 | `.dialect mariadb` |
| Zig API | `db.setDialect(.mariadb)` |
| MySQL/MariaDB 클라이언트 | 와이어 프로토콜 서버의 세션([MySQL 프로토콜](../server.md#mysql-프로토콜)) |

- SQLite로 돌아갈 때도 `PRAGMA xq_dialect = 'sqlite'`를 그대로 씁니다.
- `PRAGMA`, `ATTACH`, `DETACH`, `VACUUM`, `REINDEX`는 MariaDB 방언에서도 SQLite 문장으로 넘깁니다. `VACUUM`과 `VACUUM INTO`는 SQLite와 같이 동작합니다([SQLite 호환](../sqlite/features.md#vacuum과-백업-api)).

```sql
PRAGMA xq_dialect = 'mariadb';
CREATE TABLE `users` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `email` varchar(190) NOT NULL,
  `status` enum('active','banned') NOT NULL DEFAULT 'active',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_email` (`email`)
) ENGINE=InnoDB AUTO_INCREMENT=100 DEFAULT CHARSET=utf8mb4;
INSERT INTO users (email) VALUES ('a@x.org'), ('b@x.org');
INSERT INTO users (email) VALUES ('A@X.ORG') ON DUPLICATE KEY UPDATE status = 'banned';
SELECT id, email, status FROM users ORDER BY id LIMIT 0, 10;   -- 100, 101
SET sql_mode = '';                                -- 엄격 모드 끄기
INSERT INTO users (email, status) VALUES ('c@x.org', 'nope');  -- '' + 경고
SHOW WARNINGS;
```
