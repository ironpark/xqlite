# PostgreSQL 호환

xqlite의 PostgreSQL 방언이 지원하는 문법과 의미, 그리고 PostgreSQL과 다른 점입니다. 방언 구조와 프론트엔드 계약은 [방언 아키텍처](architecture.md)를 보세요.

## 목차

- [켜는 법](#켜는-법)
- [구조](#구조)
- [지원 범위](#지원-범위)
- [타입 매핑](#타입-매핑)
- [PostgreSQL과 다른 점](#postgresql과-다른-점)
- [아직 하지 않은 것](#아직-하지-않은-것)
- [검증](#검증)

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

## 구조

프론트엔드는 `src/dialect/postgres/`에 있습니다. 문장을 구문 트리 IR(`src/ir/tree.zig`)로 파싱하고, 내림·렌더링·카탈로그 기록은 공용 `src/ir/lower.zig`와 `render.zig`가 합니다.

| 파일 | 내용 |
| --- | --- |
| `frontend.zig` | 진입점. 한 문장을 파싱해 IR로 내림. `PRAGMA`·`ATTACH`·`DETACH`·`VACUUM`·`REINDEX`는 SQLite 문법으로, `ANALYZE [VERBOSE] [[schema.]name]`는 같은 인자로 SQLite에 넘김(`public`은 `main`, `VERBOSE`는 무시; `VACUUM`은 [SQLite 호환](sqlite.md#vacuum과-백업-api)의 VACUUM) |
| `lexer.zig` | PostgreSQL 어휘(아래 [어휘](#어휘)) |
| `parser.zig` | 재귀 하강 파서. IR을 만들면서 PostgreSQL 의미를 해석함(캐스트, LIKE/ILIKE, 함수 이름과 특수 문법, 결과 열 이름, NULL 정렬, 스키마 이름과 카탈로그 뷰, 짧은 INSERT VALUES, DDL의 타입·검사·identity) |
| `ddl.zig` | DDL의 PostgreSQL 문구 검사, 이름 없는 인덱스의 이름 |
| `types.zig` | 타입 → STRICT 저장 타입·검사·`format_type()` 철자·캐스트 |
| `funcs.zig` | 방언 함수와 엔진 함수(`xq_like` 등) |
| `catalog_views.zig` | `information_schema`/`pg_catalog` 뷰 |
| `test.zig` | 종단 테스트 |

## 지원 범위

### 어휘

- 따옴표 없는 식별자는 소문자로 접고, `"Quoted"`는 그대로 둡니다.
- 문자열: `'...'`(`''`로 따옴표, 줄바꿈 사이 이어 붙이기), `E'...'` 이스케이프, `$$...$$`/`$tag$...$tag$`.
- 매개변수 `$1`은 `?1`이 됩니다.
- 주석: `--`, 중첩 `/* */`.
- 연산자: `::`. `a<-1`은 PostgreSQL처럼 `a < -1`입니다.
- 숫자: 16진(`0x1F`)·8진(`0o17`)·2진(`0b101`), `1_000`.
- 백틱과 `[x]`는 식별자가 아닙니다.

### SELECT

| 영역 | 지원 |
| --- | --- |
| 기본 | `DISTINCT`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW` |
| FROM | 테이블, 서브쿼리, `VALUES`, `generate_series()`; 서브쿼리 별칭의 열 이름 `AS t(a, b)` |
| JOIN | `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL`, `ON`/`USING`, 괄호 조인 |
| 정렬 | `ORDER BY ... [ASC\|DESC] [NULLS FIRST\|LAST]` |
| 행 수 제한 | `LIMIT`/`OFFSET`/`LIMIT ALL`, `OFFSET n ROWS FETCH FIRST n ROWS ONLY` |
| 집합 연산 | `UNION`/`INTERSECT`/`EXCEPT`(INTERSECT가 먼저 묶임) |
| CTE | `WITH [RECURSIVE]`, `[NOT] MATERIALIZED` |
| 그 밖 | 단독 `VALUES`, `TABLE t`, `FOR UPDATE/SHARE`(무시) |

### DML

- **INSERT**
  - 열 목록, 여러 행 `VALUES`와 `DEFAULT`, 열보다 적은 값
  - `INSERT ... SELECT`, `DEFAULT VALUES`
  - `OVERRIDING SYSTEM VALUE`
  - `ON CONFLICT (cols) [WHERE] DO NOTHING | DO UPDATE SET ... EXCLUDED.x [WHERE]`
- **UPDATE**: `SET a = ...`, `SET (a, b) = (...)`, `= DEFAULT`, `FROM`
- **DELETE**: `USING`
- **공통**: `RETURNING`(대상의 별칭으로 한정한 열 포함), 앞에 붙는 `WITH`
- **TRUNCATE** `[RESTART IDENTITY]`

### 트랜잭션

- `BEGIN`/`START TRANSACTION`(격리 수준 등은 파싱만 함)
- `COMMIT`/`END`, `ROLLBACK`/`ABORT`
- `SAVEPOINT`, `RELEASE [SAVEPOINT]`, `ROLLBACK TO [SAVEPOINT]`
- `EXPLAIN`(= SQLite의 `EXPLAIN QUERY PLAN`)

### DDL

- **CREATE TABLE** `[TEMP] [IF NOT EXISTS]`, `CREATE TABLE ... AS`
  - 열 제약: `NOT NULL`, `DEFAULT`, `PRIMARY KEY`, `UNIQUE`, `CHECK`, `REFERENCES ... ON DELETE/UPDATE`, `COLLATE "C"`
  - 생성 열: `GENERATED ALWAYS AS (...) STORED`
  - identity: `GENERATED {ALWAYS|BY DEFAULT} AS IDENTITY [(옵션)]`, `serial` 계열
  - 테이블 제약
- **CREATE INDEX**: `[UNIQUE] [CONCURRENTLY] [IF NOT EXISTS] [name] ON t [USING btree] (열·식 [DESC]) [WHERE]`. 이름이 없으면 PostgreSQL처럼 `t_col_idx`입니다.
- **CREATE VIEW**: `[OR REPLACE] [TEMP]`
- **CREATE SEQUENCE**: `[IF NOT EXISTS] ... START/INCREMENT/MINVALUE/MAXVALUE/[NO] CYCLE`
- **ALTER TABLE**: `RENAME TO`, `RENAME COLUMN`, `ADD COLUMN [IF NOT EXISTS]`, `DROP COLUMN [IF EXISTS]`
- **DROP**: `TABLE/VIEW/INDEX/SEQUENCE [IF EXISTS] [CASCADE]`

### 식과 연산자

| 영역 | 지원 |
| --- | --- |
| 캐스트 | `::type`, `CAST`, 타입 리터럴(`DATE '2024-01-01'`) |
| NULL·진리값 | `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN` |
| 술어 | `BETWEEN`, `IN (목록\|서브쿼리)`, `= ANY (서브쿼리)`/`<> ALL (서브쿼리)`, `EXISTS` |
| 패턴 | `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE` |
| 그 밖 | `CASE`, 행 값, `->`/`->>`, `\|\|`(피연산자가 NULL이면 NULL) |
| 집계 | `count(*)`, 집계의 `DISTINCT`/`ORDER BY`/`FILTER` |
| 윈도우 | `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS ... EXCLUDE ...)`, `OVER name` |

연산자 우선순위는 PostgreSQL의 것입니다(낮은 것부터).

`OR` < `AND` < `NOT` < `IS` < 비교 < `BETWEEN`/`IN`/`LIKE` < 기타 연산자(`||`, `->`) < `+ -` < `* / %` < `^` < 단항 < `::`

### 함수

SQLite 내장 함수에 더해 다음을 지원합니다. 같은 이름의 SQLite 내장(`random()`, `floor()` 등)은 이 방언에서 가려집니다.

| 분류 | 함수 |
| --- | --- |
| 날짜·시각 | `now()`, `current_timestamp`, `localtimestamp`, `current_date`, `extract(field FROM x)`/`date_part` |
| 문자열 특수 문법 | `substring(x FROM a FOR b)`, `position(a IN b)`, `trim([BOTH\|LEADING\|TRAILING] [c] FROM x)` |
| 문자열 | `strpos`, `left`/`right`, `concat`/`concat_ws`, `lpad`/`rpad`, `repeat`, `reverse`, `split_part`, `starts_with`, `btrim`, `char_length`, `ascii`/`chr` |
| 집계 | `string_agg`, `bool_and`/`bool_or`/`every` |
| 비교 | `greatest`/`least`(NULL은 건너뜀) |
| 수학 | `floor`, `ceil`, `sqrt`, `power`, `exp`, `ln`, `log`, `mod`, `trunc`, `sign`, `pi` |
| 난수·UUID | `random()`(0 이상 1 미만 실수), `gen_random_uuid()` |
| 시스템 | `version()`, `current_user`, `current_database()`, `current_schema` |
| 시퀀스 | 시퀀스 함수(`nextval()` 등) |

### 카탈로그

| 스키마 | 뷰 |
| --- | --- |
| `information_schema` | `tables`, `columns`(`xq_catalog`의 PostgreSQL 선언 타입, identity 여부), `views`, `schemata`, `sequences` |
| `pg_catalog` | `pg_tables`, `pg_views`, `pg_indexes`, `pg_sequences`(스키마 없이도 보임) |

- 뷰 정의는 PostgreSQL 텍스트로 쓰여 있고, 프론트엔드가 FROM 자리에서 파싱해 넣습니다. 저장되는 것은 없습니다.
- 모든 테이블은 catalog `main`, schema `public`입니다.
- `public.t`는 `main.t`, `pg_temp.t`는 `temp.t`입니다.
- `ATTACH`로 붙인 데이터베이스는 그 이름의 스키마입니다. 질의와 DML(`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `RETURNING`)에서 `aux.t`로 씁니다. 그 안의 DDL과 카탈로그 뷰는 아직 `main`만 다룹니다([아직 하지 않은 것](#아직-하지-않은-것)).

## 타입 매핑

| PostgreSQL | STRICT 저장 | 검사(이름이 PostgreSQL 메시지인 CHECK) |
| --- | --- | --- |
| `smallint`(`smallserial`) | `INTEGER` | 범위 → `CHECK constraint failed: smallint out of range` |
| `integer`(`serial`) | `INTEGER` | 범위 → `CHECK constraint failed: integer out of range` |
| `bigint`, `bigserial`, `oid` | `INTEGER` | |
| `real`, `double precision`, `float(p)` | `REAL` | |
| `numeric(p,s)`, `decimal` | `ANY` | 숫자만(`invalid input syntax for type numeric`) |
| `boolean` | `INTEGER` | 0/1만(`invalid input syntax for type boolean`) |
| `text` | `TEXT` | |
| `varchar(n)`, `char(n)` | `TEXT` | `length() <= n`(`value too long for type character varying(n)`, `character(n)`) |
| `bytea` | `BLOB` | |
| `date`, `time`, `timestamp[tz]`, `interval`, `uuid` | `TEXT` | |
| `json`, `jsonb` | `TEXT` | `json_valid()`(`invalid input syntax for type json`) |

- 선언 타입은 `xq_catalog`의 `type` 키에 `format_type()` 철자(`character varying(20)`, `timestamp with time zone`)로 남습니다.
- 다른 타입의 값을 넣으면 SQLite STRICT 오류(`cannot store TEXT value in INTEGER column t.a`)가 납니다.
- 배열과 모르는 타입은 `type "x" does not exist` 같은 오류입니다.

### 캐스트

| 캐스트 | xqlite | PostgreSQL과 다른 점 |
| --- | --- | --- |
| `::date`/`::timestamp`/`::time` | `date()`/`datetime()`/`time()` | |
| `::int` | 실수를 버림 | PostgreSQL은 반올림 |
| `::varchar(n)` | 자름 | |
| `::numeric(p,s)` | 반올림 | |
| `::boolean` | `'t'`/`'yes'`/`'on'` 같은 철자를 읽음 | |

## PostgreSQL과 다른 점

| 주제 | PostgreSQL | xqlite | 이유 |
| --- | --- | --- | --- |
| 불리언 | `true`/`false` | 정수 0/1. `SELECT true`는 `1`(SQLITE_INTEGER) | sqlite3 API로 돌아오는 결과의 타입을 바꿀 수 없음. 문자열 철자는 `::boolean` 캐스트만 읽음(INSERT에 문자열로 넣으면 STRICT 오류) |
| `numeric` | 고정 소수점 | SQLite 수(정수 또는 실수). `1.50`은 `1.5`로 나옴 | 저장 타입이 `ANY`. 문자열 상수 `'1.5'`는 숫자로 바꿔 넣지만 텍스트로 바인딩한 값은 거부 |
| NULL 정렬 | NULL이 가장 큰 값 | 같음(ASC면 마지막, DESC면 처음) | SQLite는 반대라 방언이 맞춤. NULL일 수 없는 열(NOT NULL, INTEGER PRIMARY KEY, 외부 조인의 NULL 쪽이 아닌 것)에는 붙이지 않아 인덱스 순서를 그대로 씀(그때 바이트코드는 SQLite와 같음) |
| `LIKE` | 대소문자 구분, 기본 이스케이프 `\` | 같음(엔진 함수 `xq_like()`). `ILIKE`는 ASCII 대소문자만 무시(`xq_ilike()`) | SQLite의 LIKE는 대소문자를 무시하고 기본 이스케이프가 없음 |
| identity·serial | 시퀀스 | 시퀀스 `<table>_<col>_seq`. 아래 [identity](#identity와-serial) | SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않음 |
| `now()`, `current_timestamp` | 시간대가 있는 타임스탬프 | 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음) | SQLite 날짜 함수가 그대로 읽음 |
| 이름의 대소문자 | `"Foo"`와 `foo`는 다른 이름 | 접기는 하지만 같은 이름 | SQLite의 이름 비교는 대소문자를 구분하지 않음 |
| 오류 문구 | PostgreSQL 문구 | 싼 곳에서만 PostgreSQL 문구(아래 [오류](#오류)). 실행 중 제약 위반은 SQLite 문구(`UNIQUE constraint failed: t.a`) | |
| 0으로 나누기 | 오류 | `/`는 NULL. `mod(x, 0)`은 `division by zero` 오류 | `/`는 SQLite의 것(정수끼리는 정수 나눗셈) |
| 정수 오버플로 | 오류 | 검사하지 않음 | |
| 외래 키 | 늘 강제 | `PRAGMA foreign_keys = ON`일 때만 강제 | SQLite와 같음 |
| 격리 수준 | 여러 수준 | 파싱만 함 | SQLite는 늘 직렬화 |
| 저장되는 식 | | IR이 SQLite 텍스트로 렌더링. PostgreSQL 함수는 `xq_postgres_greatest(...)`, LIKE는 `xq_like(...)`처럼 저장 | SQLite 방언이나 다른 방언의 연결에서 읽어도 같은 뜻. 단 sqlite3에서는 그런 식을 계산할 수 없음 |

저장되는 식은 CHECK, DEFAULT, 생성 열, 인덱스 식, 뷰입니다.

### identity와 serial

- `serial`과 `GENERATED ... AS IDENTITY`는 시퀀스 `<table>_<col>_seq`로 번호를 매깁니다(PostgreSQL과 같은 이름).
- 열은 `INTEGER NOT NULL DEFAULT (nextval('seq'))`이고, 키이면 SQLite의 INTEGER PRIMARY KEY(rowid)가 됩니다.
- `xq_catalog`에 `identity`/`identity_kind` 키가 남습니다.
- INSERT가 빠뜨린 identity 열(그리고 `DEFAULT`)은 공용 내림(`src/ir/lower.zig`)이 catalog의 `identity` 키를 보고 `nextval()`로 채웁니다. DEFAULT 텍스트에 기대지 않는 이유는 둘입니다.
  - SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않습니다.
  - `trusted_schema`가 꺼져 있으면 스키마의 `nextval()`은 unsafe use입니다.
- `GENERATED ALWAYS`는 명시한 값을 거부합니다(`cannot insert a non-DEFAULT value into column "id"`). `OVERRIDING SYSTEM VALUE`로 허용합니다.
- 테이블을 지우면 시퀀스도 지웁니다. `TRUNCATE ... RESTART IDENTITY`는 시퀀스를 다시 시작합니다.
- sqlite3에서 이 테이블에 키 없이 넣으면 rowid가 번호를 매깁니다.

### 결과 열 이름

PostgreSQL 규칙을 따릅니다: `?column?`, 함수 이름, 상수 캐스트면 `int4` 같은 타입 이름, `case`, `exists`.

### 오류

PostgreSQL 문구를 쓰는 오류입니다.

- `syntax error at or near "x"`, `syntax error at end of input`
- `relation "t" does not exist`, `column "c" does not exist`
- `column reference "a" is ambiguous`
- `relation "t" already exists`
- `cannot insert a non-DEFAULT value into column "id"`

## 아직 하지 않은 것

| 영역 | 항목 |
| --- | --- |
| 쿼리 | `DISTINCT ON`, `LATERAL`, `GROUPING SETS`/`ROLLUP`/`CUBE`, `EXCEPT ALL`/`INTERSECT ALL`, `FETCH ... WITH TIES`, 테이블·함수 별칭의 열 이름 |
| DML | 데이터를 바꾸는 CTE, `ON CONFLICT ON CONSTRAINT`, `COPY` |
| 타입 | 배열·`ARRAY[...]`, `ENUM`·`CREATE TYPE`·도메인, 시퀀스의 데이터 타입(언제나 `bigint`) |
| 식과 함수 | `SIMILAR TO`와 정규식 연산자(`~`), `AT TIME ZONE`, `interval` 산술, `to_char`/`date_trunc`/`age`, `U&'...'` |
| DDL | `public` 밖의 스키마(`CREATE SCHEMA`, 붙인 데이터베이스 안의 `CREATE`/`DROP`), `ALTER TABLE`의 `ALTER COLUMN`·`ADD/DROP CONSTRAINT`·identity 열 추가, 한 문장으로 여러 개체 `DROP`, 임시 테이블의 시퀀스(`main`에 남음) |
| 절차·서버 | PL/pgSQL·`CREATE FUNCTION`·트리거, `LISTEN`/`NOTIFY`, `SET`/`SHOW`, 격리 수준 |
| 오류 | 0으로 나누기·오버플로 오류, 실행 중 오류 메시지의 PostgreSQL화 |
| 카탈로그 | INTEGER PRIMARY KEY의 인덱스(`pg_indexes`에 `t_pkey`가 없음), 붙인 데이터베이스(`information_schema`·`pg_catalog` 뷰에 나오지 않음) |
| 셸 | dollar-quote 문장 분할(셸은 SQLite 규칙으로 문장을 나눔) |

## 검증

| 도구 | 하는 일 |
| --- | --- |
| `src/dialect/postgres/test.zig` | 종단 테스트 |
| `tools/dialect/pg-diff.sh` + `pg-cases.txt` | 실제 PostgreSQL과 차등 비교. 28개 케이스가 PostgreSQL 16과 같은 행·열 이름·오류를 냄(불리언 `t`/`f`는 1/0으로 맞춰 비교) |
| `tools/interop-pg.sh` | sqlite3 교차 검증. 이 방언으로 쓴 데이터베이스가 sqlite3 무결성 검사를 통과하고, sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 함 |

차등 비교는 PostgreSQL 컨테이너를 띄운 뒤 실행합니다. 두 스크립트 모두 먼저 `zig build`가 필요합니다.

```sh
podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
tools/dialect/pg-diff.sh
tools/interop-pg.sh
```
