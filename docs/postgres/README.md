# PostgreSQL 호환

xqlite의 PostgreSQL 방언이 제공하는 문법, 동작 방식, 사용 방법 및 호환성 가이드입니다. PostgreSQL 18을 기준으로 설계되었으며 SQLite의 고성능 임베디드 코어 위에서 동작합니다.

---

## 1. 켜는 법 (사용 방법)

다양한 환경에서 PostgreSQL 방언을 활성화하고 사용할 수 있습니다.

| 환경 | 활성화 방법 | 설명 |
| --- | --- | --- |
| **SQL 질의** | `PRAGMA xq_dialect = 'postgres';` | 세션의 현재 방언을 PostgreSQL로 변경합니다. 언제든 `PRAGMA xq_dialect = 'sqlite';`로 돌아올 수 있습니다. |
| **xqlite CLI 셸** | `.dialect postgres` | 인터랙티브 셸 프롬프트에서 방언을 즉시 전환합니다. |
| **와이어 서버** | `xqlite serve --port 5432` | PostgreSQL v3 와이어 프로토콜 서버로 실행되어 `psql`, 언어별 PostgreSQL 드라이버(`pg`, `psycopg`, `npgsql` 등)로 직접 접속합니다. 세션은 자동으로 PostgreSQL 방언으로 시작합니다. |
| **Zig API** | `db.setDialect(.postgres);` | C/Zig 애플리케이션 임베딩 시 연결 단위로 방언을 설정합니다. |

---

## 2. 빠른 시작 (Quickstart)

```sql
-- PostgreSQL 방언 활성화
PRAGMA xq_dialect = 'postgres';

-- 테이블 생성 (PostgreSQL 전용 타입, 시퀀스, 제약 조건 지원)
CREATE TABLE app_user (
  id         bigserial PRIMARY KEY,
  email      varchar(100) NOT NULL UNIQUE,
  bio        text DEFAULT 'Hello',
  tags       text[] DEFAULT '{}',
  metadata   jsonb,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);

-- 데이터 삽입 및 RETURNING
INSERT INTO app_user (email, tags, metadata)
VALUES ('user1@example.com', ARRAY['zig', 'sql'], '{"plan": "pro", "level": 10}')
RETURNING id, created_at;

-- 충돌 시 처리 (ON CONFLICT DO UPDATE / DO NOTHING)
INSERT INTO app_user (email, bio)
VALUES ('user1@example.com', 'Updated bio')
ON CONFLICT (email) DO UPDATE SET
  bio = EXCLUDED.bio,
  active = true;

-- PostgreSQL 연산자 및 함수 질의
SELECT id, email,
       tags[1] AS first_tag,
       metadata->>'plan' AS current_plan,
       created_at + interval '7 days' AS renewal_date
FROM app_user
WHERE active = true
  AND 'zig' = ANY(tags)
  AND metadata @> '{"level": 10}';

-- 시스템 카탈로그 질의
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'app_user';

-- 필요 시 언제든 SQLite 방언으로 복귀 가능
PRAGMA xq_dialect = 'sqlite';
```

---

## 3. 핵심 기능 요약

- **엄격한 타입 시스템**: `boolean`, `integer`, `bigint`, `numeric`, `varchar`, `timestamptz`, `interval`, `uuid`, `jsonb`, 다차원 배열(`int[]` 등)을 완벽 지원합니다.
- **풍부한 SQL 문법**: `INSERT ... ON CONFLICT`, `RETURNING`, `TRUNCATE`, `GENERATE_SERIES`, `DO $$` 블록, 공통 테이블 식(`WITH RECURSIVE`)을 지원합니다.
- **고급 연산자 및 함수**: 배열 연산(`ANY`/`ALL`, `@>`, `<@`, `&&`), JSONB 연산자(`->`, `->>`, `@>`, `?`), 정규식 매칭(`~`, `~*`, `SIMILAR TO`), UUID v4/v7 생성을 지원합니다.
- **호환 카탈로그**: `pg_catalog.*` 및 `information_schema.*` 뷰를 제공하여 `psql`의 메타 명령(`\d`, `\dt`, `\di`, `\l` 등)과 ORM 메타데이터 조회가 정상 작동합니다.

---

## 4. 문서 구성 안내

관심사에 따라 아래의 전용 문서를 참고하세요.

| 문서 | 핵심 내용 | 대상 |
| --- | --- | --- |
| **[지원 기능 (features.md)](features.md)** | 지원하는 데이터 타입, SQL 문장, 연산자, 내장 함수, 시스템 카탈로그 상세 | 개발자, 사용자 |
| **[차이점 및 미지원 (differences.md)](differences.md)** | PostgreSQL 18과의 동작 차이, 미지원 기능 목록, 제약 사항 및 권장 대안 | 개발자, DBA |
| **[내부 기술 세부사항 (internals.md)](internals.md)** | 파서 및 IR 컴파일, 스토리지/바이너리 인코딩, OID 시스템, 타입 저장 규칙 | 기여자, 코어 개발자 |
| **[테스트 및 검증 (testing.md)](testing.md)** | `dialect-diff`, `wire-diff`, 실서버 비교 테스트 및 회귀 검증 방법 | 기여자, QA |
