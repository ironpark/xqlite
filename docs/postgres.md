# PostgreSQL 호환

xqlite의 PostgreSQL 방언이 지원하는 문법과 의미, 그리고 PostgreSQL과 다른 점입니다. 방언 구조와 프론트엔드 계약은 [README의 방언 아키텍처](../README.md#방언-아키텍처)를 보세요.

`PRAGMA xq_dialect = 'postgres'`(셸 `.dialect postgres`, Zig API `.dialect = .postgres`)로 켭니다. 프론트엔드는 `src/dialect/postgres/`에 있습니다.

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
PRAGMA xq_dialect = 'sqlite';   -- PRAGMA·VACUUM·ANALYZE는 SQLite 문법 그대로 통과
```

| 파일 | 내용 |
| --- | --- |
| `lexer.zig` | PostgreSQL 어휘: 따옴표 없는 식별자는 소문자로 접고 `"Quoted"`는 그대로, `'...'`(`''`, 줄바꿈 사이 이어 붙이기), `E'...'` 이스케이프, `$$...$$`/`$tag$...$tag$`, `$1` 매개변수(→ `?1`), `--`·중첩 `/* */` 주석, `::`, 연산자 규칙(`a<-1`은 `a < -1`), 16진/8진/2진·`1_000` 숫자. 백틱과 `[x]`는 식별자가 아님 |
| `parser.zig` | 재귀 하강 파서. 구문 트리 IR(`src/ir/tree.zig`)을 만들면서 PostgreSQL 의미를 해석함: 캐스트, LIKE/ILIKE, 함수 이름과 특수 문법, 결과 열 이름, NULL 정렬, 스키마 이름과 카탈로그 뷰, 짧은 INSERT VALUES, DDL의 타입·검사·identity. 연산자 우선순위는 PostgreSQL(OR < AND < NOT < IS < 비교 < BETWEEN/IN/LIKE < 기타 연산자(`\|\|`, `->`) < `+ -` < `* / %` < `^` < 단항 < `::`) |
| `ddl.zig` | DDL의 PostgreSQL 문구 검사와 이름 없는 인덱스의 이름. 내림·렌더링·카탈로그 기록은 `src/ir/lower.zig`, `render.zig` |
| `types.zig` | 타입 → STRICT 저장 타입·검사·`format_type()` 철자·캐스트 |
| `funcs.zig`, `catalog_views.zig` | 방언 함수, `information_schema`/`pg_catalog` 뷰 |
| `test.zig` | 종단 테스트. `tools/interop-pg.sh`(sqlite3 교차 검증), `tools/dialect/pg-diff.sh` + `pg-cases.txt`(실제 PostgreSQL과 차등 비교) |

## 지원하는 것


- SELECT: `DISTINCT`, FROM의 테이블·서브쿼리·`VALUES`·`generate_series()`, `JOIN`(`INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL`, `ON`/`USING`, 괄호 조인), 서브쿼리 별칭의 열 이름 `AS t(a, b)`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW`, `ORDER BY ... [ASC|DESC] [NULLS FIRST|LAST]`, `LIMIT`/`OFFSET`/`LIMIT ALL`, `OFFSET n ROWS FETCH FIRST n ROWS ONLY`, `UNION`/`INTERSECT`/`EXCEPT`(INTERSECT가 먼저 묶임), `WITH [RECURSIVE]`와 `[NOT] MATERIALIZED`, `VALUES`, `TABLE t`, `FOR UPDATE/SHARE`(무시)
- INSERT(열 목록, 여러 행 `VALUES`와 `DEFAULT`, 열보다 적은 값, `SELECT`, `DEFAULT VALUES`, `OVERRIDING SYSTEM VALUE`, `ON CONFLICT (cols) [WHERE] DO NOTHING | DO UPDATE SET ... EXCLUDED.x [WHERE]`), UPDATE(`SET a = ..., (a, b) = (...)`, `= DEFAULT`, `FROM`), DELETE(`USING`), 모두 `RETURNING`(대상의 별칭으로 한정한 열 포함)과 앞의 `WITH`. `TRUNCATE [RESTART IDENTITY]`
- `BEGIN`/`START TRANSACTION`(격리 수준 등은 파싱만), `COMMIT`/`END`, `ROLLBACK`/`ABORT`, `SAVEPOINT`, `RELEASE [SAVEPOINT]`, `ROLLBACK TO [SAVEPOINT]`, `EXPLAIN`(= SQLite의 EXPLAIN QUERY PLAN)
- DDL: `CREATE [TEMP] TABLE [IF NOT EXISTS]`(열 제약 `NOT NULL`·`DEFAULT`·`PRIMARY KEY`·`UNIQUE`·`CHECK`·`REFERENCES ... ON DELETE/UPDATE`·`GENERATED ALWAYS AS (...) STORED`·`GENERATED {ALWAYS|BY DEFAULT} AS IDENTITY [(옵션)]`·`COLLATE "C"`, 테이블 제약), `CREATE TABLE ... AS`, `DROP TABLE/VIEW/INDEX/SEQUENCE [IF EXISTS] [CASCADE]`, `CREATE [UNIQUE] INDEX [CONCURRENTLY] [IF NOT EXISTS] [name] ON t [USING btree] (열·식 [DESC]) [WHERE]`(이름이 없으면 PostgreSQL처럼 `t_col_idx`), `CREATE [OR REPLACE] [TEMP] VIEW`, `CREATE SEQUENCE [IF NOT EXISTS] ... START/INCREMENT/MINVALUE/MAXVALUE/[NO] CYCLE`, `ALTER TABLE ... RENAME TO / RENAME COLUMN / ADD COLUMN [IF NOT EXISTS] / DROP COLUMN [IF EXISTS]`
- 식: `::type`과 `CAST`, 타입 리터럴(`DATE '2024-01-01'`), `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN`, `BETWEEN`, `IN (목록|서브쿼리)`, `= ANY (서브쿼리)`/`<> ALL (서브쿼리)`, `EXISTS`, `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE`, `CASE`, 행 값, `->`/`->>`, `count(*)`, 집계의 `DISTINCT`/`ORDER BY`/`FILTER`, 윈도우 함수(`OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS ... EXCLUDE ...)`, `OVER name`)
- 함수: SQLite 내장에 더해 `now()`/`current_timestamp`/`localtimestamp`, `current_date`, `substring(x FROM a FOR b)`, `position(a IN b)`, `trim([BOTH|LEADING|TRAILING] [c] FROM x)`, `extract(field FROM x)`/`date_part`, `strpos`, `left`/`right`, `concat`/`concat_ws`, `string_agg`, `lpad`/`rpad`, `repeat`, `reverse`, `split_part`, `starts_with`, `btrim`, `char_length`, `ascii`/`chr`, `greatest`/`least`(NULL은 건너뜀), `bool_and`/`bool_or`/`every`, `floor`/`ceil`/`sqrt`/`power`/`exp`/`ln`/`log`/`mod`/`trunc`/`sign`/`pi`, `random()`(0..1 실수), `gen_random_uuid()`, `version()`, `current_user`/`current_database()`/`current_schema`, 시퀀스 함수
- 카탈로그: `information_schema.tables`/`columns`(`xq_catalog`의 PostgreSQL 선언 타입, identity 여부)/`views`/`schemata`/`sequences`, `pg_catalog.pg_tables`/`pg_views`/`pg_indexes`/`pg_sequences`(스키마 없이도 보임). PostgreSQL 텍스트로 쓴 정의를 이 프론트엔드가 FROM 자리에서 파싱해 넣으므로 저장되는 것은 없음. 모든 테이블은 catalog `main`, schema `public`이고 `public.t`는 `main.t`, `pg_temp.t`는 `temp.t`

## 타입과 의미(정한 방식)


| PostgreSQL | STRICT 저장 | 검사(이름이 PostgreSQL 메시지인 CHECK) |
| --- | --- | --- |
| `smallint`, `integer`(`smallserial`, `serial`) | `INTEGER` | 범위 → `CHECK constraint failed: integer out of range` |
| `bigint`, `bigserial`, `oid` | `INTEGER` | |
| `real`, `double precision`, `float(p)` | `REAL` | |
| `numeric(p,s)`, `decimal` | `ANY` | 숫자만(`invalid input syntax for type numeric`) |
| `boolean` | `INTEGER` | 0/1만 |
| `text`, `varchar(n)`, `char(n)` | `TEXT` | `length() <= n`(`value too long for type character varying(n)`) |
| `bytea` | `BLOB` | |
| `date`, `time`, `timestamp[tz]`, `interval`, `uuid` | `TEXT` | |
| `json`, `jsonb` | `TEXT` | `json_valid()` |

- 선언 타입은 `xq_catalog`의 `type` 키에 `format_type()` 철자(`character varying(20)`, `timestamp with time zone`)로 남고, 다른 타입을 넣으면 SQLite STRICT 오류(`cannot store TEXT value in INTEGER column t.a`)가 납니다. 배열과 모르는 타입은 `type "x" does not exist` 같은 오류입니다.
- **불리언은 정수 0/1입니다.** sqlite3 API로 돌아오는 결과의 타입을 바꿀 수 없으므로 `SELECT true`는 `1`(SQLITE_INTEGER)을 돌려주고 `'t'`/`'yes'`/`'on'` 같은 철자는 `::boolean` 캐스트가 읽습니다(INSERT에 문자열로 넣으면 STRICT 오류).
- `numeric`은 고정 소수점이 아니라 SQLite 수(정수 또는 실수)입니다: `1.50`은 `1.5`로 나오고, 문자열 상수 `'1.5'`는 숫자로 바꿔 넣지만 텍스트로 바인딩한 값은 거부합니다.
- SERIAL/IDENTITY는 Phase 4의 시퀀스(`<table>_<col>_seq`)로 번호를 매깁니다. 열은 `INTEGER NOT NULL DEFAULT (nextval('seq'))`이고 키이면 SQLite의 INTEGER PRIMARY KEY(rowid)가 됩니다. INSERT가 빠뜨린 identity 열(그리고 `DEFAULT`)은 프론트엔드가 `nextval()`로 채웁니다: SQLite는 INTEGER PRIMARY KEY의 DEFAULT를 쓰지 않고, `trusted_schema`가 꺼져 있으면 스키마의 `nextval()`은 unsafe use이기 때문입니다. `GENERATED ALWAYS`는 명시한 값을 거부합니다(`OVERRIDING SYSTEM VALUE`로 허용). `xq_catalog`에 `identity`/`identity_kind`가 남고, 테이블을 지우면 시퀀스도 지웁니다. sqlite3에서 이 테이블에 키 없이 넣으면 rowid가 번호를 매깁니다.
- ORDER BY는 PostgreSQL처럼 NULL을 가장 큰 값으로 칩니다(ASC면 마지막, DESC면 처음). NOT NULL 열과 INTEGER PRIMARY KEY에는 붙이지 않아서 인덱스 순서를 그대로 씁니다(그때 바이트코드는 SQLite와 같음).
- `LIKE`는 대소문자를 구분하고 기본 이스케이프가 `\`입니다(엔진 함수 `xq_like()`). `ILIKE`는 ASCII 대소문자를 무시합니다(`xq_ilike()`).
- 스키마에 저장되는 식(CHECK, DEFAULT, 생성 열, 인덱스 식, 뷰)은 IR이 렌더링하므로 SQLite 방언이나 다른 방언의 연결에서 읽어도 같은 뜻입니다. PostgreSQL 함수 테이블의 함수는 `xq_postgres_greatest(...)`처럼 저장됩니다(sqlite3에서는 그런 식을 계산할 수 없음).
- 결과 열 이름은 PostgreSQL 규칙(`?column?`, 함수 이름, 상수 캐스트면 `int4` 같은 타입 이름, `case`, `exists`)입니다.
- 식별자를 접지만 SQLite의 이름 비교는 대소문자를 구분하지 않으므로 `"Foo"`와 `foo`는 같은 이름입니다.
- `now()`와 `current_timestamp`는 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음)여서 SQLite 날짜 함수가 그대로 읽습니다. `::date`/`::timestamp`/`::time`은 `date()`/`datetime()`/`time()`, `::int`는 실수를 버림(PostgreSQL은 반올림), `::varchar(n)`은 자름, `::numeric(p,s)`는 반올림입니다.
- 오류는 싼 곳에서 PostgreSQL 문구를 씁니다: `syntax error at or near "x"`, `syntax error at end of input`, `relation "t" does not exist`, `column "c" does not exist`, `column reference "a" is ambiguous`, `relation "t" already exists`, `cannot insert a non-DEFAULT value into column "id"`. 실행 중 제약 위반은 SQLite 문구(`UNIQUE constraint failed: t.a`)입니다.
- 외래 키는 SQLite처럼 `PRAGMA foreign_keys = ON`일 때만 강제합니다. 0으로 나누면 NULL(PostgreSQL은 오류)이고, 정수 오버플로는 검사하지 않습니다.
- 차등 비교: `podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine` 뒤 `tools/dialect/pg-diff.sh`. 지금 28개 케이스가 PostgreSQL 16과 같은 행·열 이름·오류를 냅니다(불리언 `t`/`f`는 1/0으로 맞춰 비교).

## 아직 하지 않은 것

`DISTINCT ON`, 배열·`ARRAY[...]`, `ENUM`·`CREATE TYPE`·도메인, `public` 밖의 스키마(`CREATE SCHEMA`), `ALTER TABLE`의 `ALTER COLUMN`·`ADD/DROP CONSTRAINT`·identity 열 추가, PL/pgSQL·`CREATE FUNCTION`·트리거, `LISTEN`/`NOTIFY`, `COPY`, `SET`/`SHOW`, 격리 수준(파싱만 함; SQLite는 늘 직렬화), `LATERAL`, `GROUPING SETS`/`ROLLUP`/`CUBE`, `EXCEPT ALL`/`INTERSECT ALL`, `SIMILAR TO`와 정규식 연산자(`~`), `AT TIME ZONE`, `interval` 산술, `to_char`/`date_trunc`/`age`, 데이터를 바꾸는 CTE, `ON CONFLICT ON CONSTRAINT`, `FETCH ... WITH TIES`, `U&'...'`, 테이블·함수 별칭의 열 이름, 한 문장으로 여러 개체 `DROP`, 0으로 나누기·오버플로 오류, 실행 중 오류 메시지의 PostgreSQL화, INTEGER PRIMARY KEY의 인덱스(`pg_indexes`에 `t_pkey`가 없음), 시퀀스의 데이터 타입(언제나 `bigint`), 임시 테이블의 시퀀스(`main`에 남음), 셸의 dollar-quote 문장 분할(셸은 SQLite 규칙으로 문장을 나눔).

