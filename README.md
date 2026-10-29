# xqlite

> SQLite를 Zig로 포팅하고, 그 위에 **SQLite / PostgreSQL / MariaDB(MySQL) / MSSQL** 호환 레이어를 얹은 임베디드 데이터베이스

> [!WARNING]
> 아주 초기 단계 프로젝트입니다. 아래 내용 대부분은 **목표와 설계**이며, 아직 구현되지 않았습니다. API와 파일 포맷은 예고 없이 바뀔 수 있습니다.

## 왜 xqlite인가

임베디드 DB가 필요할 때 사실상 선택지는 SQLite뿐입니다. 하지만 실제 서비스는 PostgreSQL, MariaDB, MSSQL 위에서 돌아가는 경우가 많고, 그래서 다음과 같은 문제가 반복됩니다.

- 테스트는 SQLite로, 운영은 PostgreSQL로 돌리다 보니 SQL 방언 차이로 버그가 생긴다.
- 서버 DB용으로 작성한 쿼리와 스키마를 로컬/엣지/데스크톱 앱에서 그대로 쓸 수 없다.
- 개발 환경에서 DB 서버 컨테이너를 띄우는 비용이 크다.

xqlite는 **하나의 임베디드 스토리지 엔진** 위에서 **여러 SQL 방언을 그 DB의 의미 그대로** 실행하는 것을 목표로 합니다.

## 목표

1. **SQLite의 Zig 포팅**: SQLite의 구조(Pager, B-Tree, VDBE)를 Zig로 다시 구현합니다. C 바인딩이 아니라 순수 Zig 구현입니다.
2. **SQLite 파일 포맷 호환**: 기존 `.sqlite` / `.db` 파일을 그대로 읽고 쓸 수 있어야 합니다.
3. **멀티 방언 SQL**: 연결(connection) 단위로 방언을 골라 PostgreSQL, MariaDB, MSSQL 문법과 의미를 따릅니다.
4. **임베디드 우선**: 별도 프로세스 없이 라이브러리로 링크해 씁니다. 필요하면 와이어 프로토콜 서버 모드를 켤 수 있습니다.
5. **Zig다운 설계**: 명시적 allocator, comptime을 활용한 방언 특화, 숨은 전역 상태 없음, 크로스 컴파일 지원.

## 비목표

- 분산, 복제, 클러스터링
- 각 서버 DB의 모든 기능을 100% 재현 (확장 모듈, 프로시저 언어 전체, 서버 관리 기능 등)
- 대규모 동시 쓰기 워크로드에서 서버 DB와 성능 경쟁

## 아키텍처

```
┌───────────────────────────────────────────────────────────────┐
│                         Public API                            │
│        Zig API  ·  C ABI (sqlite3 호환)  ·  Wire Server*      │
└───────────────────────────────┬───────────────────────────────┘
                                │
┌───────────────────────────────▼───────────────────────────────┐
│                      Dialect Frontends                        │
│   ┌──────────┐  ┌────────────┐  ┌──────────┐  ┌───────────┐   │
│   │  SQLite  │  │ PostgreSQL │  │ MariaDB  │  │   MSSQL   │   │
│   │  parser  │  │   parser   │  │  parser  │  │  (T-SQL)  │   │
│   └────┬─────┘  └─────┬──────┘  └────┬─────┘  └─────┬─────┘   │
│        └──────────────┴──── AST ─────┴──────────────┘         │
│                 방언별 semantic analysis / 타입 해석          │
└───────────────────────────────┬───────────────────────────────┘
                                │  공통 IR (SQLite 파스 트리 + 빌더)
┌───────────────────────────────▼───────────────────────────────┐
│                  Planner / Optimizer → Codegen                │
└───────────────────────────────┬───────────────────────────────┘
                                │  bytecode
┌───────────────────────────────▼───────────────────────────────┐
│     VDBE (가상 머신)  ·  내장 함수 (방언별 함수 레지스트리)   │
└───────────────────────────────┬───────────────────────────────┘
┌───────────────────────────────▼───────────────────────────────┐
│     B-Tree  ·  Pager  ·  WAL / Rollback Journal  ·  Locking   │
└───────────────────────────────┬───────────────────────────────┘
┌───────────────────────────────▼───────────────────────────────┐
│              VFS (POSIX · Windows · Memory · WASI)            │
└───────────────────────────────────────────────────────────────┘
                                         * 선택 기능
```

### 계층별 설명

| 계층 | 역할 |
| --- | --- |
| **VFS** | 파일 I/O, 락, 시간, 난수를 추상화합니다. 플랫폼별 구현과 인메모리 구현을 제공합니다. |
| **Pager / WAL** | 페이지 캐시, 트랜잭션, 크래시 복구를 담당합니다. SQLite 파일 포맷과 호환됩니다. |
| **B-Tree** | 테이블(rowid / WITHOUT ROWID)과 인덱스를 저장합니다. |
| **VDBE** | SQLite와 같은 레지스터 기반 바이트코드 VM입니다. 방언별 타입과 비교 규칙을 지원하도록 확장합니다. |
| **Planner** | 공통 IR을 받아 인덱스 선택, 조인 순서 결정, 서브쿼리 평탄화 등을 수행합니다. |
| **Dialect Frontend** | 방언별 lexer/parser와 의미 분석기입니다. 식별자 인용 규칙, 타입 강제 변환, NULL/정렬 규칙, 함수 이름 해석이 여기서 결정됩니다. |
| **Catalog Emulation** | `sqlite_schema`, `information_schema`, `pg_catalog`, `sys.*` 등 메타데이터 뷰를 하나의 내부 카탈로그에서 생성합니다. |

### 방언 아키텍처

공통 IR은 새로 만든 Logical Plan이 아니라 **SQLite의 파스 트리**(`Expr`, `ExprList`, `IdList`, `SrcList`, `Select`, `With`, `Window`, `Upsert`, `TriggerStep`)와, SQLite 문법의 reduce 액션이 부르는 **코드 생성기 진입점**(select, insert, CREATE TABLE ...)입니다. SQLite 방언 프론트엔드가 이 인터페이스로 내리기 때문에 SQLite 방언의 바이트코드는 sqlite3와 같고, 다른 방언도 같은 트리를 만들면 같은 플랜을 얻습니다.

```
SQL 텍스트 ──▶ dialect.runParser()            연결의 방언(Sqlite3.xq.lang)으로 디스패치
                 ├─ dialect/sqlite    tokenize.zig + parser.zig (기준 구현)
                 ├─ dialect/postgres  lexer → parser → AST → ir.* (DDL은 SQLite 텍스트)
                 └─ dialect/mariadb   (Phase 6, 지금은 스텁)
                          │ ir.*  (src/ir/ir.zig)
                          ▼
               파스 트리 + 빌더 ──▶ VDBE 바이트코드
                          ▲
   방언 훅(dialect.Hooks): 함수 테이블 · 추가 collation · 기본 collation
   카탈로그(src/catalog): xq_catalog · xq_sequence
```

| 파일 | 내용 |
| --- | --- |
| `src/dialect/dialect.zig` | `Dialect`(`sqlite`, `postgres`, `mariadb`; 3은 MSSQL 자리), `Frontend`, `Hooks`, `Lang`, 연결별 상태(`ConnState`), 디스패치 |
| `src/dialect/func.zig` | 방언 함수 테이블을 만드는 생성자(`scalar`, `aggregate`) |
| `src/dialect/{sqlite,postgres,mariadb}/frontend.zig` | 방언마다 `frontend`와 `hooks` |
| `src/dialect/postgres/*.zig` | PostgreSQL 프론트엔드([PostgreSQL 방언](#postgresql-방언)) |
| `src/ir/ir.zig` | IR 빌더 파사드: `stmt`, `expr`, `list`, `from`, `select`, `with`, `window`, `dml`, `ddl`, `txn`, `admin`. 각 항목은 대응하는 C 함수(`sqlite3PExpr`, `sqlite3StartTable` ...)의 별칭이거나 parse.y에서 옮긴 도우미 |
| `src/catalog/catalog.zig`, `sequence.zig` | 방언 메타데이터와 시퀀스 |

**방언 고르기.** 연결 단위입니다. 기본값은 `sqlite`이고, 이때 동작과 바이트코드는 이전과 바이트 단위로 같습니다.

- Zig API: `Db.open(..., .{ .dialect = .postgres })`, `db.setDialect(.mariadb)`, `db.dialect()`
- SQL: `PRAGMA xq_dialect`, `PRAGMA xq_dialect = 'postgres'` (SQLite의 pragma 표 밖에 있어 `pragma_list`에 나오지 않음. 준비 시점에 적용)
- 셸: `.dialect`, `.dialect postgres`
- 엔진 내부: `sql.main.setDialect()`, 문법만 바꾸는 `sql.main.setFrontend()`(다른 방언의 훅으로 SQLite 문법을 돌릴 때, 테스트·개발용)

문장은 컴파일된 언어(`Vdbe.xq_lang`)를 기억해서 스키마 변경 뒤 재컴파일도 같은 방언으로 합니다. 엔진이 스스로 파싱하는 텍스트(스키마, nested parse, `OP_SqlExec`, ALTER TABLE 재작성, pragma 가상 테이블, `sqlite_stat1`, 카탈로그 SQL)는 언제나 SQLite 텍스트이고 SQLite 프론트엔드로 갑니다.

**프론트엔드 계약** (`dialect.Frontend.run(p: *Parse, sql: [:0]const u8) (Oom || ParseError)!void`, `sqlite3RunParser()` 자리):

1. 시작할 때 `p.rc = OK`, `p.tail = sql`로 둡니다(토큰 오프셋이 `p.tail` 기준).
2. `sql`의 **첫 문장**만 컴파일하고, 끝나면 `p.tail`을 그 뒤 텍스트(`sql`의 접미사)로 둡니다. 공백·주석뿐이면 아무 코드도 만들지 않습니다.
3. `ir.*`로 파스 트리를 만들고 문장 빌더를 부른 뒤 `ir.stmt.finishCoding(p)`로 끝냅니다. 식별자 인용·대소문자 접기는 프론트엔드가 합니다.
4. 오류는 `ir.stmt.errorMsg()`/`syntaxError()`로 Parse에 남기고 `error.ParseFailed`로 실패합니다. Zig 오류는 할당 실패뿐입니다.
5. **스키마에 저장되는 것은 SQLite 텍스트여야 합니다.** `sqlite_schema`는 문장 텍스트를 그대로 저장하고 sqlite3가 다시 읽기 때문입니다. CREATE TABLE/INDEX/VIEW/TRIGGER는 SQLite 텍스트로 렌더링해서 `ir.stmt.lowerSqliteText(p, text)`로 내리고, 방언 정보는 같은 문장 안에서 `catalog.code*()`로 기록한 뒤 `finishCoding()`합니다.
6. 프론트엔드가 지어낸 함수 호출은 `ir.expr.functionCall(p, "concat", args)`로 만듭니다.

**방언 훅** (`dialect.Hooks`, 모든 필드의 기본값이 SQLite 동작):

- `functions`: 방언 함수 테이블. 사용자 정의 함수 다음, SQLite 내장 함수 앞에서 찾으므로 함수를 더하거나(`version()`, `nextval()`) 같은 이름의 내장 함수를 가립니다(MariaDB `CONCAT()`은 인자 중 NULL이 있으면 NULL). 다른 방언과 엔진 내부 SQL(`PreferBuiltin`)에는 보이지 않습니다. `dfunc.scalar("name", n_arg, .{ .deterministic = true }, impl)`로 만들고 같은 이름의 오버로드는 붙여 둡니다(`dfunc.checkTable`이 컴파일 시점에 검사).
- `collations`: 방언이 더하는 collation. 스키마에 쓰면 sqlite3에서 그 열을 쓸 수 없으므로 가능하면 내장(`BINARY`, `NOCASE`, `RTRIM`)으로 매핑합니다.
- `default_collation`: collation이 없는 값의 비교(C의 `db->pDfltColl`). MariaDB 스텁은 `NOCASE`입니다. COLLATE 없는 열의 인덱스는 파일 호환을 위해 BINARY로 남으므로 DDL에서 텍스트 열마다 collation을 적어 두는 것이 좋습니다.

**엄격한 타입.** SQLite의 STRICT 테이블 기계를 그대로 씁니다. 프론트엔드는 선언 타입을 `ir.ddl.strictStorageType("varchar(20)")`(→ `TEXT`)로 저장 타입에 매핑해 `... ) STRICT`로 렌더링하고, 원래 선언 타입은 `catalog.Key.decl_type`에 기록합니다. 길이·정밀도 검사는 CHECK 제약으로 내립니다.

**카탈로그와 시퀀스.** `xq_catalog(tbl, col, key, value)`(WITHOUT ROWID)와 `xq_sequence(name, last_value, start_value, increment, min_value, max_value, cycle, is_called)`는 일반 테이블이라 sqlite3가 그대로 열고 검사합니다. 처음 필요할 때만 만들어지므로 방언 기능을 쓰지 않은 DB는 SQLite와 바이트 단위로 같습니다.

- 문장 안에서(코드 생성, 그 문장의 트랜잭션): `catalog.codeSet(p, "main", tbl, col, key, value)`, `codeDeleteTable`, `codeRenameTable`, `sequence.codeCreate(p, "main", name, .{ .start, .increment, .min, .max, .cycle }, if_not_exists)`, `sequence.codeDrop`, `sequence.nextvalExpr(p, name)`(identity 열의 DEFAULT나 INSERT 보완용)
- 지금 바로(열린 트랜잭션 안, 없으면 문장마다 autocommit): `catalog.set/get/deleteTable`, `sequence.create/drop/nextval/currval/setval/lastval`
- SQL 함수: PostgreSQL은 `nextval(name)`, `currval(name)`, `setval(name, v [, is_called])`, `lastval()`, MariaDB는 `nextval(name)`, `lastval(name)`, `setval(...)`. 의미는 PostgreSQL을 따르되 트랜잭션에 묶입니다(롤백된 값은 다시 나옴). `currval`/`lastval`은 연결 단위입니다.
- 키: `dialect`(테이블을 만든 방언), `type`(선언 타입), `identity`(번호를 매기는 시퀀스), `identity_kind`, `collation`, `default`. 방언 고유 키는 `pg.`, `mariadb.` 접두사를 씁니다.

**아직 하지 않은 것.** MariaDB 파서(스텁은 공백 외 모든 문장을 "parser not implemented"로 거부), 방언별 문장 경계(`sqlite3_complete()`, 셸의 입력 분할), 시퀀스의 비트랜잭션 의미와 schema 한정 이름(지금은 `main`), `sequence.create()`의 중복 시 PostgreSQL 오류 메시지(PostgreSQL 프론트엔드의 `CREATE SEQUENCE`는 컴파일 시점에 검사), MariaDB의 `information_schema`, 방언 함수의 `PRAGMA function_list` 노출, C ABI URI 파라미터(`?dialect=`).

## 방언 호환성

방언은 **연결 단위**로 고릅니다. 데이터는 하나의 파일에 저장되고, 방언은 해석 방식만 바꿉니다.

### 방언별 주요 차이와 처리 방식

| 항목 | SQLite | PostgreSQL | MariaDB | MSSQL |
| --- | --- | --- | --- | --- |
| 식별자 인용 | `"x"` `[x]` `` `x` `` | `"x"` | `` `x` `` (`ANSI_QUOTES` 시 `"x"`) | `[x]` `"x"` |
| 타입 시스템 | 동적 타입 (affinity) | 엄격한 정적 타입 | 정적 타입 + `sql_mode` 의존 | 엄격한 정적 타입 |
| 자동 증가 | `INTEGER PRIMARY KEY` | `SERIAL` / `IDENTITY` | `AUTO_INCREMENT` | `IDENTITY(1,1)` |
| 페이징 | `LIMIT/OFFSET` | `LIMIT/OFFSET`, `FETCH` | `LIMIT` | `TOP`, `OFFSET…FETCH` |
| UPSERT | `ON CONFLICT` | `ON CONFLICT` | `ON DUPLICATE KEY UPDATE` | `MERGE` |
| 반환 절 | `RETURNING` | `RETURNING` | `RETURNING` (MariaDB 10.5+) | `OUTPUT` |
| 문자열 연결 | `\|\|` | `\|\|` | `CONCAT()` (`\|\|` = OR) | `+` |
| 대소문자 비교 | 기본 구분 (ASCII) | 구분 | collation 의존 (기본 비구분) | collation 의존 (기본 비구분) |

### 타입 매핑

서버 DB의 엄격한 타입은 SQLite 레코드 포맷 위에 **카탈로그 메타데이터 + 런타임 검사**로 구현합니다. 표현할 수 없는 타입(예: `NUMERIC(38,10)`, `INTERVAL`, `UUID`, 배열)은 확장 레코드 인코딩을 씁니다. 이 인코딩을 쓰는 테이블은 순정 SQLite에서 읽기 전용으로 열리도록 표시합니다.

### 지원 범위 (계획)

| 기능 | SQLite | PostgreSQL | MariaDB | MSSQL |
| --- | :-: | :-: | :-: | :-: |
| DDL / DML 기본 | 🎯 | 🎯 | 🎯 | 🎯 |
| 트랜잭션 / 세이브포인트 | 🎯 | 🎯 | 🎯 | 🎯 |
| CTE / 재귀 CTE | 🎯 | 🎯 | 🎯 | 🎯 |
| 윈도우 함수 | 🎯 | 🎯 | 🎯 | 🎯 |
| JSON | 🎯 `json1` | 🎯 `json`/`jsonb` | 🎯 | 🎯 `JSON_VALUE` 등 |
| 시퀀스 | — | 🎯 | 🎯 | 🎯 |
| 스키마(네임스페이스) | `ATTACH` | 🎯 | 🎯 (database) | 🎯 |
| 저장 프로시저 / 함수 | — | 🔬 PL/pgSQL 일부 | 🔬 | 🔬 T-SQL 일부 |
| 트리거 | 🎯 | 🎯 | 🎯 | 🎯 |
| 메타데이터 카탈로그 | 🎯 | 🎯 `pg_catalog` | 🎯 `information_schema` | 🎯 `sys.*` |
| 와이어 프로토콜 | — | 🔬 pgwire v3 | 🔬 MySQL protocol | 🔬 TDS 7.4 |

🎯 목표 · 🔬 실험적 / 후순위 · — 해당 없음

### PostgreSQL 방언

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
| `parser.zig`, `ast.zig` | 재귀 하강 파서와 구문 트리. 연산자 우선순위는 PostgreSQL(OR < AND < NOT < IS < 비교 < BETWEEN/IN/LIKE < 기타 연산자(`\|\|`, `->`) < `+ -` < `* / %` < `^` < 단항 < `::`) |
| `lower.zig` | 질의·DML·트랜잭션을 `ir.*`로 내림(SQLite 문법이 부르는 빌더를 같은 인자로) |
| `render.zig`, `ddl.zig` | DDL을 SQLite 텍스트로 렌더링해 `lowerSqliteText()`로 내리고 같은 문장에서 카탈로그 기록 |
| `types.zig` | 타입 → STRICT 저장 타입·검사·`format_type()` 철자·캐스트 |
| `funcs.zig`, `catalog_views.zig` | 방언 함수, `information_schema`/`pg_catalog` 뷰 |
| `test.zig` | 종단 테스트. `tools/interop-pg.sh`(sqlite3 교차 검증), `tools/dialect/pg-diff.sh` + `pg-cases.txt`(실제 PostgreSQL과 차등 비교) |

**지원하는 것.**

- SELECT: `DISTINCT`, FROM의 테이블·서브쿼리·`VALUES`·`generate_series()`, `JOIN`(`INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL`, `ON`/`USING`, 괄호 조인), 서브쿼리 별칭의 열 이름 `AS t(a, b)`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW`, `ORDER BY ... [ASC|DESC] [NULLS FIRST|LAST]`, `LIMIT`/`OFFSET`/`LIMIT ALL`, `OFFSET n ROWS FETCH FIRST n ROWS ONLY`, `UNION`/`INTERSECT`/`EXCEPT`(INTERSECT가 먼저 묶임), `WITH [RECURSIVE]`와 `[NOT] MATERIALIZED`, `VALUES`, `TABLE t`, `FOR UPDATE/SHARE`(무시)
- INSERT(열 목록, 여러 행 `VALUES`와 `DEFAULT`, 열보다 적은 값, `SELECT`, `DEFAULT VALUES`, `OVERRIDING SYSTEM VALUE`, `ON CONFLICT (cols) [WHERE] DO NOTHING | DO UPDATE SET ... EXCLUDED.x [WHERE]`), UPDATE(`SET a = ..., (a, b) = (...)`, `= DEFAULT`, `FROM`), DELETE(`USING`), 모두 `RETURNING`(대상의 별칭으로 한정한 열 포함)과 앞의 `WITH`. `TRUNCATE [RESTART IDENTITY]`
- `BEGIN`/`START TRANSACTION`(격리 수준 등은 파싱만), `COMMIT`/`END`, `ROLLBACK`/`ABORT`, `SAVEPOINT`, `RELEASE [SAVEPOINT]`, `ROLLBACK TO [SAVEPOINT]`, `EXPLAIN`(= SQLite의 EXPLAIN QUERY PLAN)
- DDL: `CREATE [TEMP] TABLE [IF NOT EXISTS]`(열 제약 `NOT NULL`·`DEFAULT`·`PRIMARY KEY`·`UNIQUE`·`CHECK`·`REFERENCES ... ON DELETE/UPDATE`·`GENERATED ALWAYS AS (...) STORED`·`GENERATED {ALWAYS|BY DEFAULT} AS IDENTITY [(옵션)]`·`COLLATE "C"`, 테이블 제약), `CREATE TABLE ... AS`, `DROP TABLE/VIEW/INDEX/SEQUENCE [IF EXISTS] [CASCADE]`, `CREATE [UNIQUE] INDEX [CONCURRENTLY] [IF NOT EXISTS] [name] ON t [USING btree] (열·식 [DESC]) [WHERE]`(이름이 없으면 PostgreSQL처럼 `t_col_idx`), `CREATE [OR REPLACE] [TEMP] VIEW`, `CREATE SEQUENCE [IF NOT EXISTS] ... START/INCREMENT/MINVALUE/MAXVALUE/[NO] CYCLE`, `ALTER TABLE ... RENAME TO / RENAME COLUMN / ADD COLUMN [IF NOT EXISTS] / DROP COLUMN [IF EXISTS]`
- 식: `::type`과 `CAST`, 타입 리터럴(`DATE '2024-01-01'`), `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN`, `BETWEEN`, `IN (목록|서브쿼리)`, `= ANY (서브쿼리)`/`<> ALL (서브쿼리)`, `EXISTS`, `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE`, `CASE`, 행 값, `->`/`->>`, `count(*)`, 집계의 `DISTINCT`/`ORDER BY`/`FILTER`, 윈도우 함수(`OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS ... EXCLUDE ...)`, `OVER name`)
- 함수: SQLite 내장에 더해 `now()`/`current_timestamp`/`localtimestamp`, `current_date`, `substring(x FROM a FOR b)`, `position(a IN b)`, `trim([BOTH|LEADING|TRAILING] [c] FROM x)`, `extract(field FROM x)`/`date_part`, `strpos`, `left`/`right`, `concat`/`concat_ws`, `string_agg`, `lpad`/`rpad`, `repeat`, `reverse`, `split_part`, `starts_with`, `btrim`, `char_length`, `ascii`/`chr`, `greatest`/`least`(NULL은 건너뜀), `bool_and`/`bool_or`/`every`, `floor`/`ceil`/`sqrt`/`power`/`exp`/`ln`/`log`/`mod`/`trunc`/`sign`/`pi`, `random()`(0..1 실수), `gen_random_uuid()`, `version()`, `current_user`/`current_database()`/`current_schema`, 시퀀스 함수
- 카탈로그: `information_schema.tables`/`columns`(`xq_catalog`의 PostgreSQL 선언 타입, identity 여부)/`views`/`schemata`/`sequences`, `pg_catalog.pg_tables`/`pg_views`/`pg_indexes`/`pg_sequences`(스키마 없이도 보임). PostgreSQL 텍스트로 쓴 정의를 이 프론트엔드가 FROM 자리에서 파싱해 넣으므로 저장되는 것은 없음. 모든 테이블은 catalog `main`, schema `public`이고 `public.t`는 `main.t`, `pg_temp.t`는 `temp.t`

**타입과 의미(정한 방식).**

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
- `LIKE`는 대소문자를 구분하고 기본 이스케이프가 `\`입니다(방언의 `like()`가 SQLite의 것을 가림). `ILIKE`는 ASCII 대소문자를 무시합니다.
- 결과 열 이름은 PostgreSQL 규칙(`?column?`, 함수 이름, 상수 캐스트면 `int4` 같은 타입 이름, `case`, `exists`)입니다.
- 식별자를 접지만 SQLite의 이름 비교는 대소문자를 구분하지 않으므로 `"Foo"`와 `foo`는 같은 이름입니다.
- `now()`와 `current_timestamp`는 문장 시각의 `'YYYY-MM-DD HH:MM:SS.SSS'`(UTC, 시간대 표기 없음)여서 SQLite 날짜 함수가 그대로 읽습니다. `::date`/`::timestamp`/`::time`은 `date()`/`datetime()`/`time()`, `::int`는 실수를 버림(PostgreSQL은 반올림), `::varchar(n)`은 자름, `::numeric(p,s)`는 반올림입니다.
- 오류는 싼 곳에서 PostgreSQL 문구를 씁니다: `syntax error at or near "x"`, `syntax error at end of input`, `relation "t" does not exist`, `column "c" does not exist`, `column reference "a" is ambiguous`, `relation "t" already exists`, `cannot insert a non-DEFAULT value into column "id"`. 실행 중 제약 위반은 SQLite 문구(`UNIQUE constraint failed: t.a`)입니다.
- 외래 키는 SQLite처럼 `PRAGMA foreign_keys = ON`일 때만 강제합니다. 0으로 나누면 NULL(PostgreSQL은 오류)이고, 정수 오버플로는 검사하지 않습니다.
- 차등 비교: `podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine` 뒤 `tools/dialect/pg-diff.sh`. 지금 28개 케이스가 PostgreSQL 16과 같은 행·열 이름·오류를 냅니다(불리언 `t`/`f`는 1/0으로 맞춰 비교).

**아직 하지 않은 것.** `DISTINCT ON`, 배열·`ARRAY[...]`, `ENUM`·`CREATE TYPE`·도메인, `public` 밖의 스키마(`CREATE SCHEMA`), `ALTER TABLE`의 `ALTER COLUMN`·`ADD/DROP CONSTRAINT`·identity 열 추가, PL/pgSQL·`CREATE FUNCTION`·트리거, `LISTEN`/`NOTIFY`, `COPY`, `SET`/`SHOW`, 격리 수준(파싱만 함; SQLite는 늘 직렬화), `LATERAL`, `GROUPING SETS`/`ROLLUP`/`CUBE`, `EXCEPT ALL`/`INTERSECT ALL`, `SIMILAR TO`와 정규식 연산자(`~`), `AT TIME ZONE`, `interval` 산술, `to_char`/`date_trunc`/`age`, 데이터를 바꾸는 CTE, `ON CONFLICT ON CONSTRAINT`, `FETCH ... WITH TIES`, `U&'...'`, 테이블·함수 별칭의 열 이름, 한 문장으로 여러 개체 `DROP`, 0으로 나누기·오버플로 오류, 실행 중 오류 메시지의 PostgreSQL화, INTEGER PRIMARY KEY의 인덱스(`pg_indexes`에 `t_pkey`가 없음), 시퀀스의 데이터 타입(언제나 `bigint`), 임시 테이블의 시퀀스(`main`에 남음), 셸의 dollar-quote 문장 분할(셸은 SQLite 규칙으로 문장을 나눔).

## Zig API

엔진 위에 얇은 Zig 계층(`xqlite.Db`, `xqlite.Stmt`)을 제공합니다. 전역 초기화 없이 할당자와 `std.Io`를 명시적으로 넘기고, 바인딩·결과 매핑·사용자 함수의 타입은 comptime으로 결정합니다. 오류는 정수 코드가 아니라 Zig 오류 집합(`error.Constraint`, `error.Busy` ...)으로 올라오며, 확장 코드와 메시지는 `db.lastError()`나 `Diagnostics`로 확인합니다.

```zig
const std = @import("std");
const xqlite = @import("xqlite");

const User = struct { id: i64, name: []const u8, email: ?[]const u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var db = try xqlite.Db.open(gpa, init.io, "app.db", .{ .journal_mode = .wal, .busy_timeout_ms = 1000 });
    defer db.close();

    try db.exec("CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE)");

    // 튜플은 위치(?1, ?2), 구조체는 이름(:name, @name, $name)으로 바인딩
    try db.execArgs("INSERT INTO users(name, email) VALUES(?, ?)", .{ "Ada", "ada@example.com" });
    try db.execArgs("INSERT INTO users(name, email) VALUES(:name, :email)", .{ .name = "Linus", .email = null });
    std.debug.print("last id = {d}\n", .{db.lastInsertRowid()});

    // 행을 구조체로 매핑 (필드 이름 = 열 이름). 문자열은 다음 next()까지 유효
    var stmt = try db.prepare("SELECT id, name, email FROM users WHERE id > ?");
    defer stmt.finalize();
    try stmt.bind(.{0});
    var it = stmt.iterator(User);
    while (try it.next()) |u| std.debug.print("{d} {s} {?s}\n", .{ u.id, u.name, u.email });

    // 문장보다 오래 살아야 하는 값은 할당자로 복사
    const name = (try db.oneAlloc([]const u8, gpa, "SELECT name FROM users WHERE id = ?", .{1})).?;
    defer gpa.free(name);

    // 오류는 Zig 오류 집합, 자세한 내용은 lastError()
    db.execArgs("INSERT INTO users(name, email) VALUES(?, ?)", .{ "Eve", "ada@example.com" }) catch |err| {
        const e = db.lastError().?;
        std.debug.print("{s}: {s} ({t})\n", .{ @errorName(err), e.message, e.code }); // Constraint: UNIQUE constraint failed: users.email (constraint_unique)
    };

    // 트랜잭션: 함수가 오류를 돌려주면 ROLLBACK, 아니면 COMMIT
    try db.transaction(.immediate, renameAll, .{ &db, "user" });
}

fn renameAll(db: *xqlite.Db, prefix: []const u8) !void {
    try db.execArgs("UPDATE users SET name = ? || '-' || id", .{prefix});
}
```

사용자 함수, 집계(윈도우) 함수, collation, 가상 테이블도 Zig 함수와 타입에서 시그니처를 추론해 등록합니다.

```zig
fn gcd(a: i64, b: i64) i64 { ... }                       // 인자 2개, INTEGER -> INTEGER
try db.createFunction("gcd", {}, gcd, .{ .deterministic = true });

const Sum = struct {                                       // 그룹마다의 상태
    total: i64 = 0,
    pub fn step(self: *Sum, x: ?i64) void { self.total += x orelse 0; }
    pub fn final(self: *Sum) i64 { return self.total; }
};
try db.createAggregate("my_sum", Sum, .{});

try db.createCollation("bylength", {}, byLength);         // fn ([]const u8, []const u8) std.math.Order
try db.createModule("fib", Fib, {});                      // SELECT * FROM fib(10)
```

| Zig 타입 | SQLite 값 |
| --- | --- |
| 정수(모든 폭), `comptime_int` | INTEGER (범위를 넘으면 `error.IntegerOverflow`) |
| `f32`, `f64` ... | REAL |
| `bool` | INTEGER 0/1 |
| `[]const u8`, 문자열 리터럴 | TEXT |
| `xqlite.Blob`, `xqlite.ZeroBlob` | BLOB |
| `?T`, `null` | NULL (옵셔널이 아닌 타입으로 NULL을 읽으면 `error.UnexpectedNull`) |
| enum | 태그 이름(TEXT), `xqlite_storage = .integer`를 선언하면 INTEGER |
| `xqlite.Value` | 동적 타입 |

수명 규칙, 오류 모델, C API와의 대응은 [docs/zig-api.md](docs/zig-api.md)에 정리했습니다. 예제는 `examples/`에 있습니다.

```sh
zig build example-basic                # examples/basic.zig (인자: -- notes.db)
zig build example-extensions           # examples/extensions.zig
zig build examples                     # 예제 빌드만
```

## 사용 예시 (계획 중인 API)

```zig
const std = @import("std");
const xqlite = @import("xqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var db = try xqlite.open(gpa.allocator(), "app.db", .{
        .dialect = .postgres,
    });
    defer db.close();

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id    BIGSERIAL PRIMARY KEY,
        \\  email TEXT NOT NULL UNIQUE,
        \\  meta  JSONB DEFAULT '{}'::jsonb
        \\)
    , .{});

    var stmt = try db.prepare(
        "INSERT INTO users (email) VALUES ($1) RETURNING id",
    );
    defer stmt.deinit();

    const id = try stmt.one(i64, .{"hello@example.com"});
    std.debug.print("inserted id = {d}\n", .{id});
}
```

같은 파일을 다른 방언으로 열 수도 있습니다.

```zig
var mssql = try xqlite.open(alloc, "app.db", .{ .dialect = .mssql });
try mssql.exec("SELECT TOP 10 [id], [email] FROM [users] ORDER BY [id] DESC", .{});
```

### C ABI

`sqlite3_*` 호환 C ABI를 제공해서, 기존 SQLite 바인딩(Python `sqlite3`, Go `mattn/go-sqlite3` 등)에서 라이브러리만 바꿔 쓸 수 있게 하는 것이 목표입니다. 방언은 URI 파라미터로 지정합니다.

```
file:app.db?dialect=mariadb
```

### 서버 모드 (선택)

기존 클라이언트와 ORM을 그대로 붙일 수 있도록 와이어 프로토콜 서버를 선택적으로 제공합니다.

```sh
xqlite serve app.db --pg 5432 --mysql 3306 --tds 1433
```

## 빌드

Zig **0.17.0** 이상이 필요합니다.

```sh
zig build              # 라이브러리 + CLI 빌드
zig build run          # CLI 실행
zig build test         # 단위 테스트
```

`sql` 명령은 `sqlite3`와 호환되는 셸입니다. 파일을 생략하거나 `:memory:`를 주면 메모리 DB를 엽니다. 인자로 준 SQL·dot-command를 차례로 실행하고, 인자가 없으면 표준 입력에서 읽습니다(터미널이면 `sqlite> ` 프롬프트를 띄웁니다). 문장 경계는 `sqlite3_complete()` 포팅으로 판단하고, 출력 형식·오류 메시지·종료 코드는 SQLite 3.54 셸과 바이트 단위로 맞춥니다. 출력 모드는 `list`, `csv`, `tabs`, `line`, `column`, `quote`, `insert`, `box`, `table`, `markdown`, `json` 등을 지원하고, dot-command는 `.mode`, `.headers`, `.separator`, `.nullvalue`, `.tables`, `.schema`, `.indexes`, `.dump`, `.read`, `.bail`, `.echo`, `.changes`, `.dbconfig`, `.print`, `.show`, `.timeout`, `.help`, `.quit`/`.exit`를 지원합니다. `sqlite3` 셸처럼 연결을 연 뒤 defensive 모드를 켜고 `trusted_schema`를 끄며, `generate_series` 테이블 값 함수를 등록합니다.

```sh
zig-out/bin/xqlite sql test.db "CREATE TABLE t(a, b); INSERT INTO t VALUES(1, 'x');" ".mode box" "SELECT * FROM t"
zig-out/bin/xqlite sql test.db .dump > test.sql
```

`sqlite3`가 설치되어 있으면 순정 SQLite와의 상호 검증 스크립트를 돌릴 수 있습니다(`zig build` 후 실행).

```sh
./tools/interop-btree.sh        # 서로 쓴 테이블·인덱스를 읽고 수정, integrity_check 비교
./tools/interop-sql.sh          # 같은 SQL을 xqlite와 sqlite3로 실행, 결과·integrity_check 비교
./tools/interop-hot-journal.sh  # 서로 남긴 핫 저널 복구
./tools/interop-shell.sh        # `xqlite sql` 셸과 sqlite3 셸의 출력(모드·dot-command·오류) 비교, .dump 왕복 검증
./tools/interop-pragma.sh       # PRAGMA 결과를 sqlite3 3.54.1과 비교 (SQLITE3로 경로 지정)
./tools/interop-savepoint.sh    # SAVEPOINT·문장 롤백을 저널 모드·캐시 크기별로 sqlite3와 비교
./tools/interop-wal.sh          # WAL: 서로 남긴 -wal 읽기·체크포인트, 크래시 복구, 두 엔진 프로세스 동시 접근과 스트레스 (SQLITE3로 3.54.1 셸 지정)
./tools/gen-fixtures.sh         # src/testdata의 테스트용 DB 재생성
./tools/planner/diff.py CASES   # 쿼리 결과·EXPLAIN QUERY PLAN·바이트코드를 sqlite3와 비교 (tools/planner/README.md)
./tools/slt/run.py ref/sqllogictest/test  # sqllogictest 실행, 실패를 원인별로 묶음 (tools/slt/README.md)
```

포팅 기준 SQLite 소스(현재 3.54.1)는 `ref/sqlite`에 받아 두고 참고합니다. 이 디렉토리는 git에서 제외됩니다.

```sh
./tools/fetch-sqlite.sh
```

크로스 컴파일:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
```

## 테스트 전략

호환성은 주장이 아니라 테스트로 증명해야 합니다.

- **SQLite**: [sqllogictest](https://www.sqlite.org/sqllogictest/)와 SQLite TCL 테스트 스위트 일부를 포팅합니다.
- **파일 포맷**: 순정 SQLite와 xqlite가 서로 만든 DB 파일을 교차로 읽고 쓰고, `PRAGMA integrity_check`로 검증합니다.
- **PostgreSQL / MariaDB / MSSQL**: 같은 쿼리를 실제 서버와 xqlite에서 실행해 결과를 비교하는 differential testing을 합니다. 각 DB의 regression test에서 필요한 부분을 가져옵니다.
- **Fuzzing**: 파서, 레코드 디코더, B-Tree 페이지 디코더를 퍼징합니다.
- **크래시 복구**: 오류를 주입하는 VFS로 쓰기 도중 전원 차단을 시뮬레이션합니다.

## 로드맵

- [x] **Phase 0 · 기반**: VFS(POSIX·메모리), 페이지 캐시, Pager(롤백 저널), 파일 헤더 파싱 — Windows VFS·WAL·세이브포인트는 이후 단계
- [x] **Phase 1 · 스토리지**: B-Tree 읽기/쓰기(auto-vacuum·incremental vacuum 포함), 레코드 포맷, 기존 SQLite 파일 읽기/수정
- [x] **Phase 2 · SQLite SQL**: Lexer/Parser, VDBE, 기본 Planner, `sqlite3` 호환 셸
- [ ] **Phase 3 · 완성도**: WAL, 인덱스 최적화, 윈도우 함수, JSON, sqllogictest 통과
  - [x] 윈도우 함수: `OVER`/`WINDOW`/`FILTER`, ROWS·RANGE·GROUPS 프레임과 `EXCLUDE`, 내장 윈도우 함수(`row_number`, `rank`, `ntile`, `lead`/`lag`, `nth_value` 등). 결과와 바이트코드를 sqlite3 3.54.1과 맞춤
  - [x] 가상 테이블: `CREATE VIRTUAL TABLE`, 모듈 등록(`sql.vtab.createModule`, `sqlite3_module`에 대응하는 Zig 구조체), `xBestIndex` 기반 플래너(제약·ORDER BY·IN·LIMIT/OFFSET 전달), `xUpdate`로 INSERT/UPDATE/DELETE, `xBegin`~`xRollbackTo` 트랜잭션·세이브포인트, `xRename`, `xFindFunction` 오버로드, eponymous 테이블과 테이블 값 함수. 내장 모듈로 `pragma_*` 테이블 값 함수, `bytecode()`/`tables_used()`, 셸의 `generate_series`. 결과와 바이트코드를 sqlite3 3.54.1과 맞춤
  - [x] WAL: `PRAGMA journal_mode=WAL`과 다른 모드로 되돌리기(헤더의 파일 포맷 버전 18/19바이트 포함), `-wal`·`-shm` 파일 형식과 잠금 프로토콜(shm 바이트 락, dead-man switch)을 SQLite 3.54.1과 같게 맞춰 xqlite와 sqlite3 프로세스가 한 DB를 동시에 읽고 씀. 읽기 스냅샷과 read mark, `walIndexRecover`로 크래시 뒤 wal-index 재구성, 캐시 스필과 세이브포인트·롤백, 체크포인트(PASSIVE/FULL/RESTART/TRUNCATE/NOOP, `wal_autocheckpoint`, `sqlite3_wal_checkpoint_v2`, WAL 훅), `journal_size_limit`, 읽기 전용 shm(heap wal-index). unix VFS는 `-shm`을 mmap하고 메모리 VFS는 공유 메모리를 힙에 둠. `busy_timeout`이 실제 바쁜 핸들러(`sqliteDefaultBusyCallback`)로 동작. 결과와 바이트코드를 sqlite3 3.54.1과 맞춤. `locking_mode=EXCLUSIVE`, 스냅샷 API는 아직
  - [x] JSON: `json`/`jsonb` 계열 스칼라 함수, `->`/`->>` 연산자, `json_group_array`/`json_group_object`(윈도우 함수 포함), JSON5 입력과 JSONB 바이너리 형식, `json_each`/`json_tree`/`jsonb_each`/`jsonb_tree` 테이블 값 함수(경로 인자, 상관 인자, 조인). 결과를 sqlite3 3.54.1과 바이트 단위로 맞춤
- [x] **Phase 4 · 공통 IR**: 프론트엔드 분리와 카탈로그 확장. SQLite 파스 트리와 코드 생성기 진입점을 IR로 삼고(`src/ir/ir.zig`, SQLite 파서도 이 파사드로 내림), 연결 단위 방언 선택(`OpenOptions.dialect`, `PRAGMA xq_dialect`, `.dialect`)과 프론트엔드 디스패치, 방언 훅(함수 테이블, 추가·기본 collation), STRICT 기반 엄격한 타입, `xq_catalog`·`xq_sequence` 카탈로그와 시퀀스(nextval/currval/setval/lastval). PostgreSQL·MariaDB는 스텁 프론트엔드와 함수 테이블만. SQLite 방언의 결과와 바이트코드는 sqlite3 3.54.1과 그대로 같음 ([방언 아키텍처](#방언-아키텍처))
- [x] **Phase 5 · PostgreSQL 방언**: PostgreSQL 어휘 규칙의 lexer와 재귀 하강 파서(구문 트리 → `ir.*`), SELECT 전반(조인, 서브쿼리, 집합 연산, `WITH [RECURSIVE]`, 윈도우, `OFFSET/FETCH`, PostgreSQL식 NULL 정렬), INSERT/UPDATE/DELETE와 `RETURNING`·`ON CONFLICT`·`UPDATE FROM`·`DELETE USING`, 트랜잭션·세이브포인트, DDL(SQLite 텍스트 + `xq_catalog`), STRICT 기반 엄격한 타입과 PostgreSQL 메시지 이름의 CHECK, `SERIAL`/`IDENTITY`(시퀀스), `CREATE SEQUENCE`, `information_schema`·`pg_catalog` 뷰, PostgreSQL 함수와 오류 문구. 실제 PostgreSQL 16과 차등 비교(`tools/dialect/pg-diff.sh`), sqlite3 교차 검증(`tools/interop-pg.sh`). `DISTINCT ON`, 배열, ENUM, 스키마, PL/pgSQL 등은 아직 ([PostgreSQL 방언](#postgresql-방언))
- [ ] **Phase 6 · MariaDB 방언**: 파서, `sql_mode`, collation, `AUTO_INCREMENT`
- [ ] **Phase 7 · MSSQL 방언**: T-SQL 파서, `IDENTITY`, `TOP`, `OUTPUT`, `MERGE`
- [ ] **Phase 8 · 서버 모드**: pgwire, MySQL protocol, TDS

## 프로젝트 구조

```
src/
├── root.zig            # 공개 Zig API
├── main.zig            # CLI
├── vfs/                # OS 추상화
├── pager/              # 페이지 캐시, 저널, WAL
├── btree/              # B-Tree, 레코드 포맷
├── vdbe/               # 바이트코드 VM
├── parse/              # SQLite tokenizer, LALR(1) 파서
├── sql/                # 코드 생성기, 플래너, 내장 함수 (SQLite C 포팅)
├── ir/                 # 공통 IR 빌더 파사드
├── catalog/            # 방언 메타데이터(xq_catalog), 시퀀스(xq_sequence)
├── dialect/
│   ├── sqlite/
│   ├── postgres/       # Phase 5: lexer, parser, AST, IR 내림, DDL, 카탈로그 뷰
│   ├── mariadb/        # Phase 6 (스텁)
│   └── mssql/          # 예정
├── api/                # Zig API
├── capi/               # sqlite3 호환 C ABI (예정)
└── server/             # 와이어 프로토콜 (선택, 예정)
```

## 기여

아직 설계가 자주 바뀌는 단계입니다. 큰 변경은 이슈에서 먼저 논의해 주세요.

## 감사의 말

xqlite는 D. Richard Hipp과 SQLite 팀이 만들고 퍼블릭 도메인으로 공개한 [SQLite](https://www.sqlite.org/)의 설계와 파일 포맷을 기반으로 합니다.

## 라이선스

TBD
