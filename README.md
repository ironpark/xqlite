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
                 ├─ dialect/postgres  (Phase 5, 지금은 스텁)
                 └─ dialect/mariadb   (Phase 6, 재귀 하강 파서)
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
- `default_collation`: collation이 없는 값의 비교(C의 `db->pDfltColl`). MariaDB 방언은 `NOCASE`입니다. COLLATE 없는 열의 인덱스는 파일 호환을 위해 BINARY로 남으므로 DDL에서 텍스트 열마다 collation을 적어 두는 것이 좋습니다.

**엄격한 타입.** SQLite의 STRICT 테이블 기계를 그대로 씁니다. 프론트엔드는 선언 타입을 `ir.ddl.strictStorageType("varchar(20)")`(→ `TEXT`)로 저장 타입에 매핑해 `... ) STRICT`로 렌더링하고, 원래 선언 타입은 `catalog.Key.decl_type`에 기록합니다. 길이·정밀도 검사는 CHECK 제약으로 내립니다.

**카탈로그와 시퀀스.** `xq_catalog(tbl, col, key, value)`(WITHOUT ROWID)와 `xq_sequence(name, last_value, start_value, increment, min_value, max_value, cycle, is_called)`는 일반 테이블이라 sqlite3가 그대로 열고 검사합니다. 처음 필요할 때만 만들어지므로 방언 기능을 쓰지 않은 DB는 SQLite와 바이트 단위로 같습니다.

- 문장 안에서(코드 생성, 그 문장의 트랜잭션): `catalog.codeSet(p, "main", tbl, col, key, value)`, `codeDeleteTable`, `codeRenameTable`, `sequence.codeCreate(p, "main", name, .{ .start, .increment, .min, .max, .cycle }, if_not_exists)`, `sequence.codeDrop`, `sequence.nextvalExpr(p, name)`(identity 열의 DEFAULT나 INSERT 보완용)
- 지금 바로(열린 트랜잭션 안, 없으면 문장마다 autocommit): `catalog.set/get/deleteTable`, `sequence.create/drop/nextval/currval/setval/lastval`
- SQL 함수: PostgreSQL은 `nextval(name)`, `currval(name)`, `setval(name, v [, is_called])`, `lastval()`, MariaDB는 `nextval(name)`, `lastval(name)`, `setval(...)`. 의미는 PostgreSQL을 따르되 트랜잭션에 묶입니다(롤백된 값은 다시 나옴). `currval`/`lastval`은 연결 단위입니다.
- 키: `dialect`(테이블을 만든 방언), `type`(선언 타입), `identity`(번호를 매기는 시퀀스), `identity_kind`, `collation`, `default`. 방언 고유 키는 `pg.`, `mariadb.` 접두사를 씁니다.

**아직 하지 않은 것.** PostgreSQL 파서(스텁은 공백 외 모든 문장을 "parser not implemented"로 거부), 방언별 문장 경계(`sqlite3_complete()`, 셸의 입력 분할), 시퀀스의 비트랜잭션 의미와 schema 한정 이름(지금은 `main`), `CREATE SEQUENCE` 중복 시 PostgreSQL 오류 메시지(지금은 `xq_sequence.name`의 UNIQUE 위반), `pg_catalog` 뷰, 방언 함수의 `PRAGMA function_list` 노출, C ABI URI 파라미터(`?dialect=`).

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

### MariaDB 방언

`PRAGMA xq_dialect = 'mariadb'`(또는 `'mysql'`), 셸의 `.dialect mariadb`, Zig API의 `db.setDialect(.mariadb)`로 켭니다. SQLite로 돌아갈 때는 MariaDB 방언에서도 `PRAGMA xq_dialect = 'sqlite'`를 그대로 씁니다(`PRAGMA`, `ATTACH`, `DETACH`, `VACUUM`, `REINDEX`는 SQLite 문장으로 넘김).

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

**구조.** `src/dialect/mariadb/`의 토크나이저(`lexer.zig`)와 재귀 하강 파서(`parser.zig`, `functions.zig`, `dml.zig`, `ddl.zig`, `session.zig`)가 문장을 `ir.*`로 바로 내립니다. 세션 상태(`sql_mode`, 경고, 사용자 변수)는 연결의 `ConnState.mariadb`(`state.zig`)에 있고, MariaDB 의미가 SQLite와 다른 연산·함수는 방언 함수 테이블(`runtime.zig`, `xq_div`, `xq_coerce` ...)로 구현합니다.

**저장 방식.** DDL은 SQLite 텍스트로 렌더링해 `ir.stmt.lowerSqliteText()`로 내리므로 sqlite3가 그대로 열고 `PRAGMA integrity_check`를 통과합니다.

- 테이블은 `STRICT`이고 열은 저장 타입(`INTEGER`/`REAL`/`TEXT`/`BLOB`)으로, MariaDB 선언 타입(`int(10) unsigned`, `varchar(20)`, `enum('a','b')` ...)·기본값·`AUTO_INCREMENT`·`ON UPDATE CURRENT_TIMESTAMP`는 같은 문장 안에서 `xq_catalog`에 기록합니다(`SHOW COLUMNS`, `DESCRIBE`, `SHOW CREATE TABLE`, `information_schema`가 읽음).
- 문자열 열에는 언제나 명시적 `COLLATE`를 적습니다. 기본·`*_ci` collation은 `NOCASE`, `*_bin`·`binary`·`*_cs`는 `BINARY`이고, 날짜·JSON 열은 `BINARY`입니다. 그래서 `UNIQUE` 키도 MariaDB처럼 대소문자를 구분하지 않습니다. `NOCASE`는 ASCII만 접습니다(`'é' = 'É'`는 거짓).
- `AUTO_INCREMENT`는 SQLite의 `INTEGER PRIMARY KEY AUTOINCREMENT`(sqlite_sequence)입니다. NULL과 0(`NO_AUTO_VALUE_ON_ZERO`가 아니면)은 다음 값을 만들고, 더 큰 값을 직접 넣으면 카운터가 따라가며, 지운 값은 다시 쓰지 않습니다. `AUTO_INCREMENT=n`은 sqlite_sequence를 미리 채우고 `TRUNCATE`는 되돌립니다. 열은 PRIMARY KEY(또는 PRIMARY KEY 없는 테이블의 유일한 UNIQUE 키)여야 합니다. `LAST_INSERT_ID()`는 `last_insert_rowid()`입니다.
- MariaDB 인덱스 이름은 테이블마다, SQLite는 스키마마다 유일하므로 테이블 `t`의 인덱스 `i`는 SQLite 인덱스 `"t$i"`입니다. `KEY`/`INDEX`/`UNIQUE` 정의는 테이블을 만든 직후 같은 문장 안에서(`OP_SqlExec`) 만듭니다.
- `JSON`은 `longtext` + `CHECK(json_valid(...))`, `BOOL`은 `tinyint(1)`, `SERIAL`은 `bigint unsigned NOT NULL AUTO_INCREMENT UNIQUE`입니다.

**`sql_mode`.** 연결 단위이고 기본값은 MariaDB 10.2+의 `STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION`입니다. `SET [SESSION] sql_mode = ...`, `SET @@sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')`, `SET sql_mode = DEFAULT`로 바꾸고 `SELECT @@sql_mode`로 읽습니다(조합 모드 `ANSI`, `TRADITIONAL`, `POSTGRESQL` ... 는 MariaDB처럼 펼쳐 보임). `SET`은 문장이 실행될 때 적용되고, 문법에 영향을 주는 모드는 그 뒤에 컴파일되는 문장부터 적용됩니다.

- `ANSI_QUOTES`: `"x"`가 식별자(아니면 문자열). `PIPES_AS_CONCAT`: `||`가 연결(아니면 `OR`). `NO_BACKSLASH_ESCAPES`: 문자열의 `\`가 보통 문자. `EMPTY_STRING_IS_NULL`, `NO_AUTO_VALUE_ON_ZERO`도 지원합니다.
- 엄격 모드(`STRICT_TRANS_TABLES`/`STRICT_ALL_TABLES`, 모든 테이블이 트랜잭션 테이블이라 같은 뜻): INSERT/UPDATE가 저장하는 값마다 `xq_coerce(value, type, ...)`를 거칩니다. 엄격 모드에서는 범위 밖·너무 긴 값·잘못된 날짜가 MariaDB 메시지(`Out of range value for column 'i' at row 1`, `Data too long ...`, `Incorrect date value ...`)로 문장을 실패시키고, 아니면(또는 `INSERT/UPDATE IGNORE`) 잘라 저장하고 경고를 남깁니다(`SHOW WARNINGS`, `@@warning_count`). `NOT NULL` 열의 NULL, 기본값 없는 `NOT NULL` 열 생략(`Field 'c' doesn't have a default value`)도 MariaDB와 같습니다. `NO_ZERO_DATE`, `NO_ZERO_IN_DATE`, `ALLOW_INVALID_DATES`는 날짜 변환에 반영합니다. 실행 시점의 모드를 읽으므로 준비된 문장도 현재 모드를 따릅니다.
- `ONLY_FULL_GROUP_BY`, `ERROR_FOR_DIVISION_BY_ZERO`(0으로 나누기는 언제나 NULL), `HIGH_NOT_PRECEDENCE`, `PAD_CHAR_TO_FULL_LENGTH`, `IGNORE_SPACE`, `REAL_AS_FLOAT`는 받아들이지만 효과가 없습니다.

**지원 문법.**

- 토큰: `` `a``b` ``, `'...'`/`"..."`와 백슬래시 이스케이프(`\%`, `\_`는 LIKE용으로 유지), `#`·`-- `·`/* */` 주석, 실행 주석 `/*! */`·`/*!50100 */`·`/*M!100100 */`(버전이 11.8 이하면 코드), `X'..'`/`0x..`, `b'..'`/`0b..`, `N'..'`, `_utf8mb4'..'`, 인접 문자열 연결, `?`, `@var`, `@@[session.]var`.
- 식: MariaDB 우선순위, `||`/`&&`/`!`/`XOR`/`<=>`/`DIV`/`MOD`/`^`/`<<`/`>>`, `/`는 실수 나눗셈(7/2 = 3.5), `LIKE`(기본 escape `\`, 대소문자 무시), `IN`, `BETWEEN`, `IS [NOT] TRUE/FALSE/NULL/UNKNOWN`, `CASE`, `CAST/CONVERT(... AS SIGNED/UNSIGNED/CHAR(n)/DECIMAL(p,s)/DATE/DATETIME/TIME/BINARY)`, `BINARY x`, `COLLATE`, `x + INTERVAL n DAY`, `NEXT VALUE FOR s`, 윈도우 함수. 함수: `IFNULL`, `IF`, `CONCAT`(NULL이면 NULL), `CONCAT_WS`, `GROUP_CONCAT([DISTINCT] ... ORDER BY ... SEPARATOR ...)`, `NOW()`/`CURDATE()`/`CURTIME()`(UTC), `LAST_INSERT_ID()`, `LENGTH`(바이트)/`CHAR_LENGTH`, `SUBSTRING(... FROM ... FOR ...)`, `TRIM(LEADING ... FROM ...)`, `LOCATE`, `POSITION`, `LPAD`/`RPAD`, `LEFT`/`RIGHT`, `REPEAT`, `REVERSE`, `HEX`, `FORMAT`, `FIND_IN_SET`, `FIELD`, `ELT`, `FLOOR`/`CEIL`/`ROUND`/`TRUNCATE`/`POW`/`SQRT`/`LOG` ..., `DATE_ADD`/`DATE_SUB`, `DATEDIFF`, `TIMESTAMPDIFF`, `DATE_FORMAT`, `STR_TO_DATE`, `YEAR`/`MONTH`/`DAY`/`HOUR`/`DAYOFWEEK`/`DAYNAME` ..., `EXTRACT`, `UUID()`, `RAND()`, `STDDEV`/`VARIANCE`, `JSON_UNQUOTE`(그 밖의 `JSON_*`는 SQLite의 json 함수).
- `SELECT`: `DISTINCT`, 조인(`STRAIGHT_JOIN`은 순서 고정), `LIMIT n` / `LIMIT off, n` / `LIMIT n OFFSET m` / `OFFSET ... FETCH`, `GROUP BY`(ASC/DESC 무시), `HAVING`, `WINDOW`, `UNION [ALL|DISTINCT]`/`EXCEPT`/`INTERSECT`와 괄호 친 항, 서브쿼리, `WITH [RECURSIVE]`, `FROM DUAL`, 인덱스 힌트·`FOR UPDATE`·`LOCK IN SHARE MODE`·`SQL_NO_CACHE` 등은 무시, 테이블 값 함수.
- DML: `INSERT [IGNORE]`(`VALUES`/`VALUE` 여러 행, `SET a=1`, `SELECT`, `DEFAULT`, `ON DUPLICATE KEY UPDATE col = VALUES(col)`, `RETURNING`), `REPLACE`, `UPDATE [IGNORE] ... [ORDER BY] [LIMIT n]`, `DELETE ... [ORDER BY] [LIMIT n] [RETURNING]`, `TRUNCATE`.
- DDL: `CREATE [TEMPORARY] TABLE [IF NOT EXISTS]`(타입, `NOT NULL`/`NULL`, `DEFAULT`, `AUTO_INCREMENT`, `PRIMARY KEY`, `UNIQUE [KEY]`, `KEY`/`INDEX`(접두 길이 무시), `CHECK`, `FOREIGN KEY ... ON DELETE/UPDATE`, 생성 열 `AS (...) VIRTUAL/STORED`, `COMMENT`·`CHARACTER SET`·`COLLATE`, 테이블 옵션 `ENGINE=`·`DEFAULT CHARSET=`·`COLLATE=`·`AUTO_INCREMENT=n` ...), `CREATE TABLE ... AS SELECT`, `DROP TABLE [IF EXISTS]`, `CREATE [UNIQUE] INDEX`, `DROP INDEX i ON t`, `CREATE [OR REPLACE] VIEW`, `DROP VIEW`, `CREATE/DROP SEQUENCE`, `ALTER TABLE` 한 가지 변경(`ADD [COLUMN]`, `DROP [COLUMN]`, `RENAME COLUMN`, `RENAME TO`, `ADD/DROP INDEX`, `DISABLE/ENABLE KEYS`·테이블 옵션은 무시), `RENAME TABLE`.
- 그 밖: `START TRANSACTION`/`BEGIN [WORK]`/`COMMIT`/`ROLLBACK [TO SAVEPOINT]`/`SAVEPOINT`/`RELEASE SAVEPOINT`, `SET`(시스템 변수, `@사용자 변수`, `NAMES`, `CHARACTER SET`, `TRANSACTION`, `foreign_key_checks`는 `PRAGMA foreign_keys`), `SHOW [FULL] TABLES [LIKE]`, `SHOW COLUMNS/FIELDS`, `DESCRIBE`/`DESC`, `SHOW INDEX`, `SHOW CREATE TABLE`, `SHOW WARNINGS/ERRORS/COUNT(*) WARNINGS`, `SHOW VARIABLES [LIKE]`, `SHOW DATABASES`, `EXPLAIN`(= `EXPLAIN QUERY PLAN`), `USE db`(존재 확인만, 기본 스키마는 `main`), `LOCK/UNLOCK TABLES`(무시), `information_schema.TABLES/COLUMNS/SCHEMATA`. mysqldump 출력을 그대로 불러올 수 있습니다.
- 이름: 쓴 대소문자를 그대로 저장하고 대소문자 없이 비교합니다(MariaDB `lower_case_table_names=2`와 같은 동작이라 `@@lower_case_table_names`는 2). 데이터베이스는 SQLite 스키마(`main`, `ATTACH`한 이름)입니다.

**MariaDB와 다른 점 / 하지 않은 것.** 저장 프로시저·함수, MySQL 문법의 트리거·이벤트, 다중 테이블 `UPDATE`/`DELETE`, `ALTER TABLE`의 `CHANGE`/`MODIFY`와 여러 변경, `PARTITION`, `FULLTEXT`(보통 인덱스로 만듦)·`MATCH ... AGAINST`, `REGEXP`(SQLite처럼 `regexp()` 함수가 있어야 함), `WITH ROLLUP`, `SELECT ... INTO`, `LOAD DATA`, `CREATE TABLE ... LIKE`, `CREATE OR REPLACE TABLE`, `INVISIBLE` 열, utf8 밖의 문자 집합, `ONLY_FULL_GROUP_BY` 검사, 셸의 문장 분할(SQLite 규칙이라 `'it\'s'` 같은 문자열이 있으면 파일 끝까지 한 덩어리로 실행됨). 또한:
- `DECIMAL`은 `REAL`(scale 0이면 `INTEGER`)로 저장되어 반올림은 되지만 정확한 십진 연산이 아니고 `220.00`이 `220.0`으로 보입니다. 정수형 실수(`POW(2,10)`)도 `1024.0`처럼 SQLite 형식으로 보입니다.
- `BIGINT UNSIGNED`와 `CAST(... AS UNSIGNED)`는 부호 있는 64비트 범위입니다. `TIMESTAMP`는 시간대 변환이 없고 범위도 `DATETIME`과 같습니다(시간대는 UTC).
- PAD SPACE 비교가 없어 `'x' = 'x  '`는 거짓입니다. UPDATE의 대입은 모두 이전 행 값을 봅니다(`SIMULTANEOUS_ASSIGNMENT`와 같음). `LAST_INSERT_ID()`는 여러 행 INSERT에서 마지막 행 id이고 직접 넣은 id에도 바뀝니다. `ON DUPLICATE KEY UPDATE`의 affected rows는 SQLite 방식(행마다 1)입니다.
- `SHOW WARNINGS`는 문장을 컴파일할 때(보통 직전 문장 실행 직후) 기록된 경고를 보여 주고, 경고는 다음 문장을 컴파일할 때 지워집니다(최대 8개 저장, 개수는 전부 셈). 엔진 오류(`no such table`, `UNIQUE constraint failed` ...)는 SQLite 메시지 그대로입니다.
- 저장되는 식(`DEFAULT (...)`, `CHECK`, 생성 열, 뷰)은 토큰 단위로 SQLite 텍스트로 옮기므로 `DIV`, `XOR`, `^`, `INTERVAL`, 변수는 쓸 수 없습니다.

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
- [ ] **Phase 5 · PostgreSQL 방언**: 파서, 엄격한 타입, `pg_catalog`, 시퀀스, `RETURNING`
- [x] **Phase 6 · MariaDB 방언**: 토크나이저(백틱, 백슬래시 이스케이프, `#`/`-- `/실행 주석)와 재귀 하강 파서가 `ir.*`로 바로 내림. 연결 단위 `sql_mode`(`ANSI_QUOTES`, `PIPES_AS_CONCAT`, `NO_BACKSLASH_ESCAPES`, `NO_AUTO_VALUE_ON_ZERO`, `EMPTY_STRING_IS_NULL`, 엄격/관대 모드의 값 변환과 MariaDB 오류·경고, 조합 모드), `SELECT`(조인, 세 가지 `LIMIT`, `UNION`, CTE, 윈도우), `INSERT [IGNORE]`/`REPLACE`/`ON DUPLICATE KEY UPDATE`/`RETURNING`, `UPDATE`/`DELETE ... LIMIT`, STRICT 테이블 + 명시적 collation으로 렌더링하는 DDL과 `xq_catalog`, `AUTO_INCREMENT`(`INTEGER PRIMARY KEY AUTOINCREMENT`), MariaDB 타입(정수 범위, `DECIMAL`, 문자열 길이, `ENUM`/`SET`, 날짜/시간), 기본 대소문자 무시 비교(`IN` 포함), `SHOW`/`DESCRIBE`/`information_schema`, 시스템·사용자 변수, 시퀀스, MariaDB 함수. MariaDB 11.8 서버와 차등 비교로 확인. 저장 프로시저·트리거·다중 테이블 DML·`ALTER TABLE CHANGE/MODIFY`·정확한 `DECIMAL`·PAD SPACE·셸의 방언별 문장 분할은 아직 ([MariaDB 방언](#mariadb-방언))
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
│   ├── postgres/       # Phase 5 (스텁)
│   ├── mariadb/        # Phase 6: 토크나이저, 파서, sql_mode, 타입 변환, 함수
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
