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
│        │              └─구문 트리 IR─┴──────────────┘         │
│        │       방언 의미를 명시한 노드 → lower / render       │
└────────┴──────────────────────┬───────────────────────────────┘
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

공통 IR은 두 층입니다. 아래층은 새로 만든 Logical Plan이 아니라 **SQLite의 파스 트리**(`Expr`, `ExprList`, `IdList`, `SrcList`, `Select`, `With`, `Window`, `Upsert`, `TriggerStep`)와, SQLite 문법의 reduce 액션이 부르는 **코드 생성기 진입점**(select, insert, CREATE TABLE ...)입니다(`src/ir/ir.zig`). SQLite 방언 프론트엔드가 이 인터페이스로 바로 내리기 때문에 SQLite 방언의 바이트코드는 sqlite3와 같고, 다른 방언도 같은 트리를 만들면 같은 플랜을 얻습니다.

위층은 방언 프론트엔드가 만드는 **구문 트리 IR**(`src/ir/tree.zig`)입니다. 방언마다 뜻이 다른 곳은 프론트엔드가 해석해 명시적인 의미 노드로 남기므로(아래 표) 트리 자체는 방언 중립이고, 이 트리를 쓰는 백엔드는 하나씩입니다.

- **lower**(`src/ir/lower.zig`): 트리 → SQLite 파스 트리. 빌더를 SQLite 문법과 같은 인자로 부르므로 방언 고유 노드가 없는 질의는 SQLite와 같은 바이트코드가 됩니다.
- **render**(`src/ir/render.zig`): 트리 → SQLite SQL 텍스트. `sqlite_schema`에 저장되는 것(CREATE TABLE/INDEX/VIEW, CHECK, DEFAULT, 생성 열, 뷰 질의)에 씁니다.

```
SQL 텍스트 ──▶ dialect.runParser()            연결의 방언(Sqlite3.xq.lang)으로 디스패치
                 ├─ dialect/sqlite    tokenize.zig + parser.zig (기준 구현) ─────────────┐
                 ├─ dialect/postgres  lexer → parser ─┐                                   │
                 └─ dialect/mariadb   lexer → parser ─┤                                   │
                                                      ▼                                   │
                                     구문 트리 IR (src/ir/tree.zig)                       │
                                       ├─ lower.zig  ─────────────────────────────────────┤ ir.*
                                       └─ render.zig ─▶ SQLite 텍스트 ─▶ lowerSqliteText ─┤
                                                         (sqlite_schema)                  ▼
                                                               파스 트리 + 빌더 ──▶ VDBE 바이트코드
                                                                          ▲
   방언 훅(dialect.Hooks): 함수 테이블 · 엔진 함수 · 추가 collation · 기본 collation
   카탈로그(src/catalog): xq_catalog · xq_sequence
```

**render ≡ lower.** render가 받아들이는 모든 트리 `t`에 대해, SQLite 프론트엔드가 `render(t)`를 컴파일한 결과는 `lower(t)`와 같은 뜻이어야 합니다. 같은 뜻이어야 하는 연결은 SQLite 방언, 그리고 `t`를 만든 프론트엔드의 방언입니다(스키마 텍스트는 언제나 SQLite 프론트엔드가 읽지만 읽는 연결의 방언은 다를 수 있음). 그래서 render는 다음처럼 씁니다.

- SQLite 문법이 있는 노드는 lower가 내리는 그대로의 SQLite 구문(식별자는 늘 인용, 연산은 전부 괄호).
- SQLite 문법이 없는 의미 노드는 lower와 같은 **엔진 함수** 호출(`xq_like()`, `xq_ilike()`, `xq_div()`, `xq_coerce()`, `xq_cast()`, `xq_pg_bool()` ...).
- 방언 함수 테이블의 함수는 **방언 한정 이름** `xq_<방언>_<이름>`(`xq_postgres_greatest(...)`), 연결 방언이 가린 SQLite 내장 함수는 `xq_sqlite_<이름>`(`lower.functionName()`이 둘 다 정함). 둘 다 모든 방언에서 보입니다.
- 예외는 `IdentityDefault`: PostgreSQL이 보여 주는 대로 `nextval('seq')`로 씁니다(identity 열은 lower가 직접 채움).

`src/ir/test.zig`가 손으로 만든 트리를 lower와 render 양쪽으로 모든 방언에서 실행해 같은 행이 나오는지 확인하고, 시드 퍼저 `ir_roundtrip`(`src/ir/fuzz.zig`, [빌드](#빌드))이 무작위 트리로 같은 것을 확인합니다.

| 의미 노드(`tree.Kind`) | 뜻 | lower / render |
| --- | --- | --- |
| `cast{target_type, mode}` | 변환 방식: `affinity`(CAST AS), `func`(f(x)), `truncate`, `round`, `typed`(f(x, 'type')) | CAST / 함수 |
| `concat{null_policy}` | `propagate`(NULL이면 NULL, `\|\|`), `skip`(NULL 건너뜀, `concat()`) | `\|\|` / `concat()` |
| `div{kind}` | `sqlite`(SQLite `/`), `real`(실수 나눗셈), `int`(MariaDB `DIV`) | `/`, `CAST(l AS REAL) / r`, `xq_div()` |
| `compare{op, collation}` | 비교와 그 collation(연결의 기본 collation과 무관) | 왼쪽 피연산자에 COLLATE |
| `like{case_sensitive, escape}` | 대소문자 구분, 이스케이프(`none`/`backslash`/식) | SQLite LIKE, `xq_like()`, `xq_ilike()` |
| `func{name, dialect}` | 이미 해석된 이름. `dialect`가 있으면 그 방언 함수 테이블의 함수 | 그 방언에선 이름 그대로, 아니면 `xq_<방언>_<이름>` |
| `coerce{decl_type, ...}` | MariaDB가 열에 저장하는 값의 변환 | `xq_coerce()` |
| `identity_default{sequence}` | identity 시퀀스의 다음 값 | `nextval('seq')` |
| `boolean`, `param`, `default` | TRUE/FALSE, `?N`(null이면 `?`), VALUES/SET의 DEFAULT | |

결과 열 이름(`ResultCol.name`), NULL 정렬(`SortItem.nulls`), DDL의 타입·검사·identity 열도 프론트엔드가 정해서 트리에 넣습니다. 노드와 문자열은 모두 문장의 arena(`Parse.arena`)나 SQL 텍스트에 있고(전역 없음), 위치(`pos`)는 lower/render에 넘긴 텍스트의 오프셋입니다(다른 텍스트에서 온 부분 트리는 `Select.src`).

**DML 공통 의미**(lower 한 곳): VALUES/SET의 `DEFAULT`(Coerce 안이어도)는 그 열의 기본값입니다. identity 시퀀스가 있으면 `nextval()`, 아니면 DEFAULT 식의 복사본, 없으면 NULL(그래서 identity 없는 INTEGER PRIMARY KEY, 즉 MariaDB의 `AUTO_INCREMENT`는 다음 rowid). identity 열은 `DEFAULT nextval(...)` 텍스트가 아니라 `xq_catalog`의 `identity`/`identity_kind` 키로 찾습니다. 열 목록이 있는 INSERT와 DEFAULT VALUES가 빠뜨린 identity 열은 `nextval()`로 채우고, `GENERATED ALWAYS` 열에 값을 주면 `Insert.overriding` 없이는 실패합니다. CREATE TABLE이 `tree.Identity` 열의 시퀀스를 만들고 키를 기록하며, DROP TABLE·`TRUNCATE ... RESTART IDENTITY`가 지우고 되돌립니다.

| 파일 | 내용 |
| --- | --- |
| `src/dialect/dialect.zig` | `Dialect`(`sqlite`, `postgres`, `mariadb`; 3은 MSSQL 자리), `Frontend`, `Hooks`, `Lang`, 연결별 상태(`ConnState`), 디스패치 |
| `src/dialect/func.zig` | 방언 함수 테이블을 만드는 생성자(`scalar`, `aggregate`) |
| `src/dialect/{sqlite,postgres,mariadb}/frontend.zig` | 방언마다 `frontend`와 `hooks` |
| `src/dialect/postgres/*.zig` | PostgreSQL 프론트엔드([PostgreSQL 호환](docs/postgres.md)) |
| `src/ir/ir.zig` | IR 빌더 파사드: `stmt`, `expr`, `list`, `from`, `select`, `with`, `window`, `dml`, `ddl`, `txn`, `admin`. 각 항목은 대응하는 C 함수(`sqlite3PExpr`, `sqlite3StartTable` ...)의 별칭이거나 parse.y에서 옮긴 도우미 |
| `src/ir/tree.zig` | 구문 트리 IR: 식, SELECT(복합, CTE, 윈도우, 조인, 서브쿼리, VALUES), INSERT/UPDATE/DELETE(RETURNING, upsert, UPDATE FROM, DELETE USING, ORDER BY ... LIMIT), 트랜잭션, DDL(CREATE/DROP TABLE/INDEX/VIEW/SEQUENCE, ALTER 일부)과 의미 노드 |
| `src/ir/lower.zig` | `Lowerer.init(p, src)`, `statement(stmt)`(DDL 포함), `expr()`, `select()`; DML 기본값·identity, DDL의 카탈로그 기록 |
| `src/ir/render.zig` | `render.select(p, src, s)`, `render.expr()`, `render.statement()`(CREATE TABLE/INDEX/VIEW, ALTER TABLE)와 `Renderer` |
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
3. 문장을 구문 트리 IR(`ir.tree`)로 파싱하고 `ir.lower.Lowerer.init(p, sql).statement(stmt)`로 내린 뒤 `ir.stmt.finishCoding(p)`로 끝냅니다. 식별자 인용·대소문자 접기, 스키마 이름(`public` → `main` ...), 방언 의미(위 표)는 프론트엔드가 트리를 만들 때 정합니다. 트리로 나타낼 수 없는 문장(MariaDB의 `SHOW` 같은 것)은 지금처럼 `ir.*` 빌더를 직접 불러도 됩니다.
4. 오류는 `ir.stmt.errorMsg()`/`syntaxError()`로 Parse에 남기고 `error.ParseFailed`로 실패합니다. Zig 오류는 할당 실패뿐입니다.
5. **스키마에 저장되는 것은 SQLite 텍스트여야 합니다.** `sqlite_schema`는 문장 텍스트를 그대로 저장하고 sqlite3가 다시 읽기 때문입니다. 트리의 DDL은 lower가 render로 SQLite 텍스트를 만들어 `ir.stmt.lowerSqliteText(p, text)`로 내리고 방언·선언 타입·identity를 같은 문장 안에서 `catalog.code*()`로 기록합니다. 방언 고유의 카탈로그 키는 프론트엔드가 같은 문장에서 더 기록합니다.
6. 프론트엔드가 지어낸 함수 호출은 트리의 `func` 노드로 만듭니다(트리를 쓰지 않는 곳은 `ir.expr.functionCall(p, "concat", args)`). 방언 함수 테이블의 이름이면 `Func.dialect`를 표시해야 render가 한정 이름으로 씁니다.

**새 프론트엔드 붙이기.** `src/dialect/<방언>/frontend.zig`에 `frontend`(`run`)와 `hooks`를 두고 `dialect.Dialect`와 `module()`에 추가합니다. `run`은 렉서·파서로 `ir.tree` 트리를 만들고(스키마가 필요한 해석은 `p`로 `ir.stmt.readSchema()` 뒤에), DDL의 방언 검사·카탈로그 키를 더한 뒤 `ir.lower`로 내립니다. SQLite 문법에 없는 의미가 필요하면 의미 노드를 쓰고, 노드가 부르는 엔진 함수가 없으면 `hooks.engine_functions`에 `xq_` 이름으로 등록합니다. 그러면 lower와 render가 같은 함수를 쓰므로 render ≡ lower가 유지됩니다.

**방언 훅** (`dialect.Hooks`, 모든 필드의 기본값이 SQLite 동작):

- `functions`: 방언 함수 테이블. 사용자 정의 함수 다음, SQLite 내장 함수 앞에서 찾으므로 함수를 더하거나(`version()`, `nextval()`) 같은 이름의 내장 함수를 가립니다(MariaDB `CONCAT()`은 인자 중 NULL이 있으면 NULL). 다른 방언과 엔진 내부 SQL(`PreferBuiltin`)에는 이름 그대로는 보이지 않고, 한정 이름 `xq_<방언>_<이름>`으로만 보입니다(가려진 내장 함수는 `xq_sqlite_<이름>`). `dfunc.scalar("name", n_arg, .{ .deterministic = true }, impl)`로 만들고 같은 이름의 오버로드는 붙여 둡니다(`dfunc.checkTable`이 컴파일 시점에 검사).
- `engine_functions`: IR의 의미 노드가 내려가는 **엔진 함수**. 이름은 `xq_`로 시작하고 모든 방언에서 유일해야 합니다(컴파일 시점에 검사). SQLite 방언, 엔진 내부 SQL을 포함해 **모든 방언에서 보이고** SQLite 내장 함수 다음에 찾습니다. render가 스키마에 쓰고 어느 방언의 연결이든 그 스키마를 읽기 때문입니다. 내장 함수처럼 `unsafe`가 아니면 `trusted_schema`가 꺼져 있어도 스키마에서 쓸 수 있으므로 부작용이 없어야 하고, 인덱스·CHECK·생성 열에 들어갈 수 있으면 `deterministic`이어야 합니다. 지금은 PostgreSQL의 `xq_like`/`xq_ilike`/`xq_pg_*`, MariaDB의 `xq_coerce`/`xq_div`/`xq_xor`/`xq_bitxor`/`xq_cast`와 파서가 MariaDB 문법·이름을 바꿔 쓰는 `xq_date_add`(`INTERVAL`)/`xq_extract`/`xq_timestampdiff`/`xq_bit_length`/`xq_stddev_*`/`xq_var_*`/`xq_rand`/`xq_uuid`.
- `collations`: 방언이 더하는 collation. 스키마에 쓰면 sqlite3에서 그 열을 쓸 수 없으므로 가능하면 내장(`BINARY`, `NOCASE`, `RTRIM`)으로 매핑합니다.
- `default_collation`: collation이 없는 값의 비교(C의 `db->pDfltColl`). MariaDB 방언은 `NOCASE`입니다. COLLATE 없는 열의 인덱스는 파일 호환을 위해 BINARY로 남으므로 DDL에서 텍스트 열마다 collation을 적어 두는 것이 좋습니다.

**엄격한 타입.** SQLite의 STRICT 테이블 기계를 그대로 씁니다. 프론트엔드는 선언 타입을 `ir.ddl.strictStorageType("varchar(20)")`(→ `TEXT`)로 저장 타입에 매핑해 `... ) STRICT`로 렌더링하고, 원래 선언 타입은 `catalog.Key.decl_type`에 기록합니다. 길이·정밀도 검사는 CHECK 제약으로 내립니다.

**카탈로그와 시퀀스.** `xq_catalog(tbl, col, key, value)`(WITHOUT ROWID)와 `xq_sequence(name, last_value, start_value, increment, min_value, max_value, cycle, is_called)`는 일반 테이블이라 sqlite3가 그대로 열고 검사합니다. 처음 필요할 때만 만들어지므로 방언 기능을 쓰지 않은 DB는 SQLite와 바이트 단위로 같습니다.

- 문장 안에서(코드 생성, 그 문장의 트랜잭션): `catalog.codeSet(p, "main", tbl, col, key, value)`, `codeDeleteTable`, `codeRenameTable`, `sequence.codeCreate(p, "main", name, .{ .start, .increment, .min, .max, .cycle }, if_not_exists)`, `sequence.codeDrop`, `sequence.nextvalExpr(p, name)`(identity 열의 DEFAULT나 INSERT 보완용)
- 지금 바로(열린 트랜잭션 안, 없으면 문장마다 autocommit): `catalog.set/get/deleteTable`, `sequence.create/drop/nextval/currval/setval/lastval`
- SQL 함수: PostgreSQL은 `nextval(name)`, `currval(name)`, `setval(name, v [, is_called])`, `lastval()`, MariaDB는 `nextval(name)`, `lastval(name)`, `setval(...)`. 의미는 PostgreSQL을 따르되 트랜잭션에 묶입니다(롤백된 값은 다시 나옴). `currval`/`lastval`은 연결 단위입니다.
- 키: `dialect`(테이블을 만든 방언), `type`(선언 타입), `identity`(번호를 매기는 시퀀스), `identity_kind`, `collation`, `default`. 방언 고유 키는 `pg.`, `mariadb.` 접두사를 씁니다.

**아직 하지 않은 것.** 방언별 문장 경계(`sqlite3_complete()`, 셸의 입력 분할), 시퀀스의 비트랜잭션 의미와 schema 한정 이름(지금은 `main`), `sequence.create()`의 중복 시 PostgreSQL 오류 메시지(PostgreSQL 프론트엔드의 `CREATE SEQUENCE`는 컴파일 시점에 검사), 방언 함수의 `PRAGMA function_list` 노출, C ABI URI 파라미터(`?dialect=`).

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

### 방언별 문서

- [SQLite 호환](docs/sqlite.md): 구현 범위, sqlite3와의 교차 검증 도구
- [PostgreSQL 호환](docs/postgres.md): 지원 문법, 타입과 의미, PostgreSQL과 다른 점
- [MariaDB 호환](docs/mariadb.md): 저장 방식, `sql_mode`, 지원 문법, MariaDB와 다른 점

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

퍼징 도구는 두 가지입니다.

```sh
zig-out/bin/xqlite fuzzcheck ref/sqlite/test/fuzzdata*.db  # SQLite fuzzcheck 포팅: 퍼즈 코퍼스를 돌려 크래시·메모리 누수·close 실패를 보고
zig build fuzz -Doptimize=ReleaseSafe -- btree_model [SEED]  # 시드 기반 퍼저 (btree_model, btree_corrupt, ir_roundtrip), 시드를 생략하면 무작위로 골라 출력
zig build fuzz -Doptimize=ReleaseSafe -- ir_roundtrip [SEED] [--events N]  # 구문 트리 IR의 render ≡ lower 검사
```

`fuzzcheck`는 크래시가 나면 케이스 번호를 출력하므로 `--start N`으로 그다음부터 이어 돌릴 수 있고, `-v`는 실행하는 케이스를 하나씩 출력합니다(세그폴트처럼 패닉 핸들러를 거치지 않는 크래시를 찾을 때 씁니다). 시드 퍼저는 같은 시드면 같은 동작을 재현하고 커밋 해시(40자리)도 시드로 받습니다. `zig build test`는 모든 시드 퍼저를 고정 시드로 짧게 돌립니다.

`ir_roundtrip`은 [render ≡ lower](#방언-아키텍처) 계약을 검사합니다. `src/ir/gen.zig`가 시드로 고정된 작은 스키마(INTEGER/REAL/TEXT/BLOB/타입 없는 열, NULL·0·-0.0·i64 최솟값/최댓값·1e308·빈 문자열·대소문자 섞인 문자열·비ASCII·블롭 같은 경계값 행) 위의 무작위 트리를 만듭니다. 모든 의미 노드(`cast` 모든 방식, `concat` 두 NULL 정책, `div` 세 종류, BINARY/NOCASE/RTRIM 비교, `like`의 대소문자·이스케이프, SQLite 내장·엔진·방언 함수, `coerce`, 불리언, 바인딩된 파라미터), CASE·IN·BETWEEN·서브쿼리·집계·GROUP BY·윈도우·`NULLS FIRST/LAST` 정렬·LIMIT/OFFSET·복합 질의·CTE를 만들고, 어떤 노드가 얼마나 자주 나올지는 실행마다 무작위로 정합니다(스웜 테스트, 64 이벤트마다 새로). 이벤트마다 새 메모리 DB에서, 방언 d마다

- lower(t)를 d에서 실행한 행(A)과
- d에서 렌더링한 render(t)를 SQLite 프론트엔드가 각 방언에서 컴파일해 실행한 행(B),
- 트리로 `CREATE VIEW`를 만들어 각 방언에서 `SELECT * FROM v`한 행(C, 기대값은 lower(`SELECT * FROM (t)`))

이 같아야 하고(값의 타입과 값이 정확히 같음, 실수는 비트 단위, ORDER BY가 없으면 다중집합으로 비교, 둘 다 오류면 결과 코드가 같아야 함), render를 두 번 하면 같은 텍스트여야 합니다. 파라미터는 lower에선 바인딩하고 render(파라미터를 받지 않음)에는 그 값의 리터럴로 넣습니다. 테이블 이벤트는 CHECK·DEFAULT·생성 열이 있는 테이블을 트리로 만들고, lower한 INSERT(`DEFAULT` 항목, 빠뜨린 열)와 SQLite 텍스트 INSERT로 행을 넣어, 저장된 행과 CHECK 결과가 같은 값으로 lower한 질의가 계산한 것과 같은지 봅니다. 불일치하면 시드·이벤트 번호·렌더링한 텍스트·재현 명령을 출력합니다.

일부러 검사하지 않는 것: `identity_default`(계약의 예외, 시퀀스는 읽을 때마다 증가), 결정적이지 않은 함수, 방언 d에서 렌더링한 텍스트를 제3의 방언 e가 읽는 경우 중 e가 가린 SQLite 내장 함수 이름이 텍스트에 그대로 있는 경우(계약은 SQLite 방언과 d만 다루고, e에서는 그 이름이 e의 함수를 뜻함. 예: PostgreSQL 뷰의 `concat()`은 MariaDB 연결에서 MariaDB의 `CONCAT()`), 상수가 파라미터와 다르게 해석되는 ORDER BY/GROUP BY가 있는 트리의 파라미터 비교(정수 상수는 열 번호), 뷰가 서브쿼리와 달리 실행 중 오류가 나는 식을 계산하지 않는 경우(sqlite3도 같음).

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
- [ ] **Phase 3 · 완성도**: WAL, 인덱스 최적화, 윈도우 함수, JSON, sqllogictest 통과 — 윈도우 함수·가상 테이블·WAL·JSON 완료 ([SQLite 호환](docs/sqlite.md))
- [x] **Phase 4 · 공통 IR**: 프론트엔드 분리와 카탈로그 확장. SQLite 파스 트리와 코드 생성기 진입점을 IR로 삼고(`src/ir/ir.zig`, SQLite 파서도 이 파사드로 내림), 연결 단위 방언 선택(`OpenOptions.dialect`, `PRAGMA xq_dialect`, `.dialect`)과 프론트엔드 디스패치, 방언 훅(함수 테이블, 추가·기본 collation), STRICT 기반 엄격한 타입, `xq_catalog`·`xq_sequence` 카탈로그와 시퀀스(nextval/currval/setval/lastval). PostgreSQL·MariaDB는 스텁 프론트엔드와 함수 테이블만. SQLite 방언의 결과와 바이트코드는 sqlite3 3.54.1과 그대로 같음 ([방언 아키텍처](#방언-아키텍처))
- [x] **Phase 5 · PostgreSQL 방언**: lexer·파서, SELECT·DML 전반과 `RETURNING`·`ON CONFLICT`, DDL과 엄격한 타입, `SERIAL`/`IDENTITY`, `information_schema`·`pg_catalog`. 실제 PostgreSQL 16과 차등 비교 ([PostgreSQL 호환](docs/postgres.md))
- [x] **Phase 6 · MariaDB 방언**: 토크나이저·파서, 연결 단위 `sql_mode`, `INSERT IGNORE`/`REPLACE`/`ON DUPLICATE KEY UPDATE`, `AUTO_INCREMENT`, MariaDB 타입과 collation, `SHOW`/`information_schema`. MariaDB 11.8과 차등 비교 ([MariaDB 호환](docs/mariadb.md))
- [x] **구문 트리 IR**: 방언 중립 구문 트리(`src/ir/tree.zig`)와 하나뿐인 lower·render, 모든 방언에서 보이는 엔진 함수와 방언 한정 함수 이름, 카탈로그 기반 identity·DEFAULT 처리. PostgreSQL(`ast.zig`/`lower.zig`/`render.zig` 삭제)과 MariaDB(직접 내리던 코드와 저장 텍스트의 토큰 단위 번역 삭제, 실행과 저장의 의미가 같아짐)를 옮김 ([방언 아키텍처](#방언-아키텍처))
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
├── ir/                 # 공통 IR: 빌더 파사드, 구문 트리, lower, render
├── catalog/            # 방언 메타데이터(xq_catalog), 시퀀스(xq_sequence)
├── dialect/
│   ├── sqlite/
│   ├── postgres/       # Phase 5: lexer, parser(→ 구문 트리 IR), DDL 검사, 카탈로그 뷰
│   ├── mariadb/        # Phase 6: 토크나이저, 파서(→ 구문 트리 IR), sql_mode, 타입 변환, 함수
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
