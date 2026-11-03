# PostgreSQL 호환

xqlite의 PostgreSQL 방언이 지원하는 문법과 의미, 그리고 PostgreSQL과 다른 점입니다. 방언 구조와 프론트엔드 계약은 [방언 아키텍처](../architecture.md)를 보세요.

## 목차

- [구조](structure.md)
- [지원 범위](#지원-범위)
  - [문장과 스키마](statements.md)
  - [식, 함수, 정규식](expressions.md)
  - [uuid](uuid.md)
  - [JSON](json.md)
  - [배열](arrays.md)
  - [형식 함수](formatting.md)
  - [interval](interval.md)
  - [numeric](numeric.md)
  - [카탈로그](catalog.md)
- [타입 매핑](types.md)
- [PostgreSQL과 다른 점](differences.md)
- [아직 하지 않은 것](todo.md)
- [검증](testing.md)

## 켜는 법

| 어디서 | 방법 |
| --- | --- |
| SQL | `PRAGMA xq_dialect = 'postgres'` |
| 셸 | `.dialect postgres` |
| Zig API | `.dialect = .postgres` |

```sql
PRAGMA xq_dialect = 'postgres';
CREATE TABLE app_user (
  id         bigserial PRIMARY KEY,
  email      varchar(100) NOT NULL UNIQUE,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);
INSERT INTO app_user (email) VALUES ($1) RETURNING id;
INSERT INTO app_user (email) VALUES ('a@x') ON CONFLICT (email) DO UPDATE SET active = EXCLUDED.active;
SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'app_user';
PRAGMA xq_dialect = 'sqlite';   -- PRAGMA는 SQLite 문법 그대로 통과
```

## 지원 범위

- [문장과 스키마](statements.md)
- [식, 함수, 정규식](expressions.md)
- [uuid](uuid.md)
- [JSON](json.md)
- [배열](arrays.md)
- [형식 함수](formatting.md)
- [interval](interval.md)
- [numeric](numeric.md)
- [카탈로그](catalog.md)
