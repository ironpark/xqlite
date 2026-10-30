# 방언 아키텍처

xqlite가 하나의 SQLite 엔진 위에서 여러 SQL 방언을 실행하는 구조를 설명합니다. 방언 선택, 프론트엔드 계약, 구문 트리 IR과 그 두 백엔드(lower, render), 방언 훅, 카탈로그를 다룹니다.

방언별 지원 범위는 [SQLite 호환](sqlite.md), [PostgreSQL 호환](postgres.md), [MariaDB 호환](mariadb.md), [MSSQL 호환](mssql.md), [Oracle 호환](oracle.md)에 있습니다.

## 목차

- [개요](#개요)
- [방언 고르기](#방언-고르기)
- [공통 IR의 두 층](#공통-ir의-두-층)
- [의미 노드](#의미-노드)
- [render와 lower의 계약](#render와-lower의-계약)
- [DML 공통 의미](#dml-공통-의미)
- [프론트엔드 계약](#프론트엔드-계약)
- [새 프론트엔드 붙이기](#새-프론트엔드-붙이기)
- [방언 훅](#방언-훅)
- [엄격한 타입](#엄격한-타입)
- [카탈로그와 시퀀스](#카탈로그와-시퀀스)
- [VFS](#vfs)
- [스토리지 패키지](#스토리지-패키지)
- [공용 패키지](#공용-패키지)
- [소스 파일](#소스-파일)
- [아직 하지 않은 것](#아직-하지-않은-것)

## 개요

방언은 두 가지로 이루어집니다.

- **프론트엔드**: 방언의 문법을 읽어 공통 IR로 내리는 렉서·파서입니다.
- **훅**: 방언이 엔진의 동작을 바꾸는 지점(함수 테이블, 엔진 함수, collation)입니다.

데이터는 하나의 SQLite 파일에 저장되고, 방언은 SQL을 해석하는 방식만 바꿉니다. 스키마에 저장되는 텍스트는 언제나 SQLite SQL이므로 sqlite3가 그 파일을 그대로 열 수 있습니다.

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
   카탈로그(src/catalog): xq_catalog · xq_sequence · 이름 붙은 스키마(schema.zig)
```

## 방언 고르기

방언은 연결 단위로 고릅니다. 기본값은 `sqlite`이고, 이때 동작과 바이트코드는 방언 기능이 생기기 전과 바이트 단위로 같습니다.

| 어디서 | 방법 |
| --- | --- |
| Zig API | `Db.open(..., .{ .dialect = .postgres })`, `db.setDialect(.mariadb)`, `db.dialect()` |
| SQL | `PRAGMA xq_dialect`, `PRAGMA xq_dialect = 'postgres'` |
| 셸 | `.dialect`, `.dialect postgres` |
| C API | URI 파라미터 `file:app.db?dialect=postgres`(`SQLITE_OPEN_URI`), `xqlite_set_dialect(db, "mariadb")`, `xqlite_dialect(db)` ([C API](c-api.md)) |
| 엔진 내부 | `sql.main.setDialect()`, 문법만 바꾸는 `sql.main.setFrontend()` |

- 방언 이름은 대소문자를 구분하지 않고, `pg`, `postgresql`, `mysql`을 별칭으로 받습니다.
- `PRAGMA xq_dialect`는 SQLite의 pragma 표 밖에 있어 `pragma_list`에 나오지 않습니다. 문장을 준비하는 시점에 적용됩니다.
- `sql.main.setFrontend()`는 다른 방언의 훅으로 SQLite 문법을 돌릴 때 씁니다(테스트·개발용).
- 문장은 컴파일된 언어(`Vdbe.xq_lang`)를 기억합니다. 그래서 스키마 변경 뒤의 재컴파일도 같은 방언으로 합니다.
- 엔진이 스스로 파싱하는 텍스트는 언제나 SQLite 텍스트이고 SQLite 프론트엔드로 갑니다. 스키마, nested parse, `OP_SqlExec`, ALTER TABLE 재작성, pragma 가상 테이블, `sqlite_stat1`, 카탈로그 SQL이 여기에 해당합니다.

## 공통 IR의 두 층

### 아래층: SQLite 파스 트리와 빌더

아래층은 새로 만든 Logical Plan이 아니라 SQLite 자체의 구조입니다(`src/ir/ir.zig`).

- **SQLite의 파스 트리**: `Expr`, `ExprList`, `IdList`, `SrcList`, `Select`, `With`, `Window`, `Upsert`, `TriggerStep`
- **코드 생성기 진입점**: SQLite 문법의 reduce 액션이 부르는 함수(select, insert, CREATE TABLE ...)

SQLite 방언 프론트엔드는 이 인터페이스로 바로 내립니다. 그래서 SQLite 방언의 바이트코드는 sqlite3와 같고, 다른 방언도 같은 트리를 만들면 같은 플랜을 얻습니다.

### 위층: 구문 트리 IR

위층은 방언 프론트엔드가 만드는 **구문 트리 IR**(`src/ir/tree.zig`)입니다. 방언마다 뜻이 다른 곳은 프론트엔드가 해석해 명시적인 [의미 노드](#의미-노드)로 남깁니다. 그래서 트리 자체는 방언 중립이고, 이 트리를 쓰는 백엔드는 둘뿐입니다.

| 백엔드 | 변환 | 용도 |
| --- | --- | --- |
| **lower** (`src/ir/lower.zig`) | 트리 → SQLite 파스 트리 | 컴파일하는 문장. 빌더를 SQLite 문법과 같은 인자로 부르므로, 방언 고유 노드가 없는 질의는 SQLite와 같은 바이트코드가 됩니다. |
| **render** (`src/ir/render.zig`) | 트리 → SQLite SQL 텍스트 | `sqlite_schema`에 저장되는 것: CREATE TABLE/INDEX/VIEW, CHECK, DEFAULT, 생성 열, 뷰 질의 |

트리에는 의미 노드 말고도 프론트엔드가 정한 다음 값이 들어갑니다.

- 결과 열 이름(`ResultCol.name`)
- NULL 정렬(`SortItem.nulls`)
- DDL의 타입·검사·identity 열

메모리와 위치 규칙은 다음과 같습니다.

- 노드와 문자열은 모두 문장의 arena(`Parse.arena`)나 SQL 텍스트에 있습니다. 전역 상태는 없습니다.
- 위치(`pos`)는 lower/render에 넘긴 텍스트의 바이트 오프셋입니다. 다른 텍스트에서 온 부분 트리는 `Select.src`가 그 텍스트를 가리킵니다.

## 의미 노드

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
| `named_param` | 이름으로 바인딩하는 매개변수(`:name`, SQLite 철자 그대로) | 그 이름의 변수 / render는 거부(`param`과 같음) |

## render와 lower의 계약

**render ≡ lower.** render가 받아들이는 모든 트리 `t`에 대해, SQLite 프론트엔드가 `render(t)`를 컴파일한 결과는 `lower(t)`와 같은 뜻이어야 합니다.

같은 뜻이어야 하는 연결은 둘입니다.

- SQLite 방언의 연결
- `t`를 만든 프론트엔드의 방언의 연결

스키마 텍스트는 언제나 SQLite 프론트엔드가 읽지만, 읽는 연결의 방언은 다를 수 있기 때문입니다.

이 계약을 지키려고 render는 다음 규칙으로 씁니다.

| 노드 | render가 쓰는 텍스트 |
| --- | --- |
| SQLite 문법이 있는 노드 | lower가 내리는 그대로의 SQLite 구문. 식별자는 늘 인용하고 연산은 전부 괄호로 묶습니다. |
| SQLite 문법이 없는 의미 노드 | lower와 같은 **엔진 함수** 호출: `xq_like()`, `xq_ilike()`, `xq_div()`, `xq_coerce()`, `xq_cast()`, `xq_pg_bool()` ... |
| 방언 함수 테이블의 함수 | **방언 한정 이름** `xq_<방언>_<이름>`(예: `xq_postgres_greatest(...)`) |
| 연결 방언이 가린 SQLite 내장 함수 | `xq_sqlite_<이름>` |
| `IdentityDefault` (예외) | PostgreSQL이 보여 주는 대로 `nextval('seq')`. identity 열은 lower가 직접 채웁니다. |

- 한정 이름은 `lower.functionName()`이 정합니다.
- 한정 이름은 모든 방언에서 보입니다.

검증은 두 곳에서 합니다.

- `src/ir/test.zig`: 손으로 만든 트리를 lower와 render 양쪽으로 모든 방언에서 실행해 같은 행이 나오는지 확인합니다.
- 시드 퍼저 `ir_roundtrip`(`src/ir/fuzz.zig`): 무작위 트리로 같은 것을 확인합니다. 자세한 내용은 [테스트와 검증](testing.md#ir_roundtrip)에 있습니다.

## DML 공통 의미

DML의 기본값과 identity는 lower 한 곳에서 처리합니다.

- VALUES/SET의 `DEFAULT`는 그 열의 기본값입니다(`Coerce` 안에 있어도 같음). 기본값은 다음 순서로 정합니다.
  1. identity 시퀀스가 있으면 `nextval()`
  2. 아니면 DEFAULT 식의 복사본
  3. 둘 다 없으면 NULL. 그래서 identity 없는 INTEGER PRIMARY KEY(MariaDB의 `AUTO_INCREMENT`)는 다음 rowid가 됩니다.
- identity 열은 `DEFAULT nextval(...)` 텍스트가 아니라 `xq_catalog`의 `identity`/`identity_kind` 키로 찾습니다.
- 열 목록이 있는 INSERT와 DEFAULT VALUES가 빠뜨린 identity 열은 `nextval()`로 채웁니다.
- `GENERATED ALWAYS` 열에 값을 주면 `Insert.overriding` 없이는 실패합니다.
- CREATE TABLE이 `tree.Identity` 열의 시퀀스를 만들고 키를 기록합니다.
- DROP TABLE은 시퀀스와 키를 지우고, `TRUNCATE ... RESTART IDENTITY`는 시퀀스를 되돌립니다.

## 프론트엔드 계약

프론트엔드는 `sqlite3RunParser()` 자리에 들어가는 함수 하나입니다.

```zig
dialect.Frontend.run(p: *Parse, sql: [:0]const u8) (Oom || ParseError)!void
```

1. 시작할 때 `p.rc = OK`, `p.tail = sql`로 둡니다. 토큰 오프셋은 `p.tail` 기준입니다.
2. `sql`의 **첫 문장**만 컴파일합니다. 끝나면 `p.tail`을 그 뒤 텍스트(`sql`의 접미사)로 둡니다. 공백·주석뿐이면 아무 코드도 만들지 않습니다.
3. 문장을 구문 트리 IR(`ir.tree`)로 파싱하고 `ir.lower.Lowerer.init(p, sql).statement(stmt)`로 내린 뒤 `ir.stmt.finishCoding(p)`로 끝냅니다.
   - 식별자 인용·대소문자 접기, 스키마 이름(`public` → `main` ...), 방언 의미([의미 노드](#의미-노드))는 프론트엔드가 트리를 만들 때 정합니다.
   - 트리로 나타낼 수 없는 문장(MariaDB의 `SHOW` 같은 것)은 `ir.*` 빌더를 직접 불러도 됩니다.
4. 오류는 `ir.stmt.errorMsg()`/`syntaxError()`로 Parse에 남기고 `error.ParseFailed`로 실패합니다. Zig 오류는 할당 실패뿐입니다.
5. **스키마에 저장되는 것은 SQLite 텍스트여야 합니다.** `sqlite_schema`는 문장 텍스트를 그대로 저장하고 sqlite3가 다시 읽기 때문입니다.
   - 트리의 DDL은 lower가 render로 SQLite 텍스트를 만들어 `ir.stmt.lowerSqliteText(p, text)`로 내립니다.
   - 방언·선언 타입·identity는 같은 문장 안에서 `catalog.code*()`로 기록합니다.
   - 방언 고유의 카탈로그 키는 프론트엔드가 같은 문장에서 더 기록합니다.
6. 프론트엔드가 지어낸 함수 호출은 트리의 `func` 노드로 만듭니다.
   - 트리를 쓰지 않는 곳에서는 `ir.expr.functionCall(p, "concat", args)`를 씁니다.
   - 방언 함수 테이블의 이름이면 `Func.dialect`를 표시해야 render가 한정 이름으로 씁니다.

## 새 프론트엔드 붙이기

1. `src/dialect/<방언>/frontend.zig`에 `frontend`(`run`)와 `hooks`를 둡니다.
2. `dialect.Dialect`와 `module()`에 추가합니다. `Dialect`의 값 3은 MSSQL 자리로 남겨 두었습니다.
3. `run`은 렉서·파서로 `ir.tree` 트리를 만듭니다. 스키마가 필요한 해석은 `p`로 `ir.stmt.readSchema()`를 부른 뒤에 합니다.
4. DDL의 방언 검사와 카탈로그 키를 더한 뒤 `ir.lower`로 내립니다.
5. SQLite 문법에 없는 의미가 필요하면 의미 노드를 씁니다. 노드가 부르는 엔진 함수가 없으면 `hooks.engine_functions`에 `xq_` 이름으로 등록합니다.

그러면 lower와 render가 같은 함수를 쓰므로 render ≡ lower가 유지됩니다.

## 방언 훅

`dialect.Hooks`의 모든 필드는 기본값이 SQLite 동작입니다.

| 필드 | 내용 |
| --- | --- |
| `functions` | 방언 함수 테이블 |
| `engine_functions` | IR의 의미 노드가 내려가는 엔진 함수(`xq_*`) |
| `collations` | 방언이 더하는 collation |
| `default_collation` | collation이 없는 값의 비교에 쓰는 collation(C의 `db->pDfltColl`) |
| `engine_modules` | 엔진 테이블 값 함수(`xq_*` 이포니머스 가상 테이블). 엔진 함수처럼 모든 방언에서 보이고, 문장이 처음 그 이름을 쓸 때 연결에 등록합니다(MariaDB `JSON_TABLE`의 `xq_maria_json_table`, Oracle `JSON_TABLE`의 `xq_ora_json_table`). |
| `table_function` | 이름이 고정되지 않은 엔진 테이블 값 함수를 찾는 함수. `engine_modules`에 없는 `xq_*` 테이블을 만나면 부르고, 맞으면 모듈을 등록해 돌려줍니다(T-SQL `OPENJSON`은 `WITH` 열 목록을 이름에 담음). |

### 방언 함수 테이블 (`functions`)

- 사용자 정의 함수 다음, SQLite 내장 함수 앞에서 찾습니다.
  - 그래서 함수를 더하거나(`version()`, `nextval()`) 같은 이름의 내장 함수를 가립니다.
  - 예: MariaDB `CONCAT()`은 인자 중 NULL이 있으면 NULL입니다.
- 다른 방언과 엔진 내부 SQL(`PreferBuiltin`)에는 이름 그대로 보이지 않습니다.
  - 한정 이름 `xq_<방언>_<이름>`으로만 보입니다.
  - 가려진 내장 함수는 `xq_sqlite_<이름>`으로 보입니다.
- `dfunc.scalar("name", n_arg, .{ .deterministic = true }, impl)`로 만듭니다(`src/dialect/func.zig`, 집계는 `aggregate`).
- 같은 이름의 오버로드는 붙여 둡니다. `dfunc.checkTable`이 컴파일 시점에 검사합니다.

### 엔진 함수 (`engine_functions`)

엔진 함수는 IR의 의미 노드가 내려가는 함수입니다.

- 이름은 `xq_`로 시작하고 모든 방언에서 유일해야 합니다(컴파일 시점에 검사).
- SQLite 방언과 엔진 내부 SQL을 포함해 **모든 방언에서 보입니다**. render가 스키마에 쓰고, 어느 방언의 연결이든 그 스키마를 읽기 때문입니다.
- SQLite 내장 함수 다음에 찾습니다.
- 내장 함수처럼 `unsafe`가 아니면 `trusted_schema`가 꺼져 있어도 스키마에서 쓸 수 있습니다. 그래서 부작용이 없어야 합니다.
- 인덱스·CHECK·생성 열에 들어갈 수 있으면 `deterministic`이어야 합니다.

지금 있는 엔진 함수는 다음과 같습니다.

| 방언 | 엔진 함수 |
| --- | --- |
| PostgreSQL | `xq_like`, `xq_ilike`, `xq_pg_*` |
| MariaDB (의미 노드) | `xq_coerce`, `xq_div`, `xq_xor`, `xq_bitxor`, `xq_cast` |
| MariaDB (파서가 문법·이름을 바꿔 씀) | `xq_date_add`(`INTERVAL`), `xq_extract`, `xq_timestampdiff`, `xq_bit_length`, `xq_stddev_*`, `xq_var_*`, `xq_rand`, `xq_uuid` |
| MariaDB (JSON) | `xq_maria_json_col`, `xq_maria_json_bool`, `xq_maria_json_cmp`([MariaDB 호환](mariadb.md#json)) |
| MSSQL | `xq_tsql_add`(`+`), `xq_tsql_like`, `xq_tsql_cast`, `xq_tsql_try_cast`, `xq_tsql_store`, `xq_tsql_newid`, `xq_tsql_avg`([MSSQL 호환](mssql.md)) |
| Oracle | `xq_ora_coerce`(열에 저장하는 값의 변환, `func` 노드), `xq_ora_cast`(`CAST`, `cast{typed}`), `xq_ora_autocommit`(암묵적 트랜잭션), `xq_ora_data_*`(`USER_TAB_COLUMNS`) |

### collation

- `collations`: 방언이 더하는 collation입니다. 스키마에 쓰면 sqlite3에서 그 열을 쓸 수 없으므로, 가능하면 내장 collation(`BINARY`, `NOCASE`, `RTRIM`)으로 매핑합니다.
- `default_collation`: MariaDB 방언은 `NOCASE`입니다.
  - COLLATE 없는 열의 인덱스는 파일 호환을 위해 BINARY로 남습니다.
  - 그래서 DDL에서 텍스트 열마다 collation을 적어 두는 것이 좋습니다.

## 엄격한 타입

SQLite의 STRICT 테이블 기계를 그대로 씁니다.

1. 프론트엔드는 선언 타입을 `ir.ddl.strictStorageType("varchar(20)")`(→ `TEXT`)로 저장 타입에 매핑합니다.
2. 테이블은 `... ) STRICT`로 렌더링합니다.
3. 원래 선언 타입은 `catalog.Key.decl_type`에 기록합니다.
4. 길이·정밀도 검사는 CHECK 제약으로 내립니다.

## 카탈로그와 시퀀스

방언 메타데이터와 시퀀스는 두 개의 일반 테이블에 있습니다. 그래서 sqlite3가 그대로 열고 검사합니다.

| 테이블 | 열 |
| --- | --- |
| `xq_catalog` (WITHOUT ROWID) | `tbl`, `col`, `key`, `value` |
| `xq_sequence` | `name`, `last_value`, `start_value`, `increment`, `min_value`, `max_value`, `cycle`, `is_called` |

두 테이블은 처음 필요할 때만 만들어집니다. 방언 기능을 쓰지 않은 DB는 SQLite와 바이트 단위로 같습니다.

### 카탈로그 키

| 키 | 뜻 |
| --- | --- |
| `dialect` | 테이블을 만든 방언 |
| `type` | 선언 타입 |
| `identity` | 번호를 매기는 시퀀스 |
| `identity_kind` | identity 종류 |
| `collation` | collation |
| `default` | 기본값 |

방언 고유 키는 `pg.`, `mariadb.`, `oracle.` 접두사를 씁니다.

### 엔진 쪽 API

| 언제 실행되나 | 함수 |
| --- | --- |
| 문장 안에서(코드 생성, 그 문장의 트랜잭션) | `catalog.codeSet(p, "main", tbl, col, key, value)`, `codeDeleteTable`, `codeRenameTable`, `sequence.codeCreate(p, "main", name, .{ .start, .increment, .min, .max, .cycle }, if_not_exists)`, `sequence.codeDrop`, `sequence.nextvalExpr(p, name)` |
| 지금 바로(열린 트랜잭션 안, 없으면 호출마다 autocommit) | `catalog.set/get/deleteTable`, `sequence.create/drop/nextval/currval/setval/lastval` |

`sequence.nextvalExpr()`는 identity 열의 DEFAULT나 INSERT 보완에 씁니다.

### 시퀀스 SQL 함수

| 방언 | 함수 |
| --- | --- |
| PostgreSQL | `nextval(name)`, `currval(name)`, `setval(name, v [, is_called])`, `lastval()` |
| MariaDB | `nextval(name)`, `lastval(name)`, `setval(...)` |
| Oracle | `s.NEXTVAL`, `s.CURRVAL`(파서가 `nextval('S')`, `currval('S')`로 바꿈) |

- 의미는 PostgreSQL을 따르되 트랜잭션에 묶입니다. 롤백된 값은 다시 나옵니다.
- `currval`/`lastval`은 연결 단위입니다.

### 스키마(네임스페이스)

SQLite 데이터베이스(main, temp, `ATTACH`)가 아닌 이름 붙은 스키마(PostgreSQL의 `CREATE SCHEMA` ...)는 **main 데이터베이스 안**에 있습니다. 공용 구현은 `src/catalog/schema.zig`(`catalog.schemas`)입니다.

- 스키마 `sales`의 개체는 이름이 `sales.orders`인 main의 개체입니다. 그 인덱스, 트리거, 시퀀스도 같은 식으로 이름을 붙입니다(`sales.orders_id_seq`). 파일 하나, 트랜잭션 하나이고, sqlite3는 `"sales.orders"`로 읽고 씁니다.
- 스키마 목록은 `xq_catalog`의 행입니다: `tbl = ''`, `col` = 스키마, `key = 'schema'`(값은 소유자)와 `key = 'dialect'`. 어떤 방언도 길이 0인 이름을 받지 않으므로 테이블의 항목(`codeDeleteTable` ...)과 겹치지 않습니다.
- 스키마 이름에는 `.`이 없습니다. 그래서 개체 이름은 첫 `.`에서 나뉩니다. 이름 비교는 SQLite처럼 대소문자를 무시합니다.
- 렌더링은 바뀌지 않습니다. 프론트엔드가 이름을 `"sales.orders"`로 바꿔 트리에 넣으면 lower와 render가 그대로 씁니다(뷰 텍스트도 `"sales.orders"`). 별칭이 없는 FROM 항목·DML 대상에는 원래 이름(`orders`)을 별칭으로 붙여 `orders.col`이 그대로 됩니다.

방언이 정하는 것은 셋입니다.

| 방언이 정하는 것 | PostgreSQL | T-SQL / Oracle / MariaDB |
| --- | --- | --- |
| 기본 스키마(그 개체는 main의 평범한 이름) | `public` | `dbo` / 현재 사용자 / 현재 데이터베이스 |
| 연결별 기본값(한정하지 않은 이름의 해석, DDL이 만드는 곳) | `search_path`(`dialect.ConnState.postgres`) | 각 방언의 세션 상태 |
| 오류 문구 | `schema "s" does not exist` ... | 각 방언의 문구 |

`schema.zig`의 API(자세한 것은 파일 머리말):

| 함수 | 하는 일 |
| --- | --- |
| `validName(name)`, `mangle(a, schema, name)`, `split(mangled)` | 이름 검사, `"<schema>.<name>"` 만들기·나누기(목록을 보지 않음) |
| `list(db, a)`, `find(list, name)`, `exists(db, name)` | 목록 읽기(지금, 문장 하나에 한 번 읽어 두고 씀) |
| `codeCreate(p, name, owner)` | 문장이 실행될 때 목록에 추가 |
| `objects(db, a, name)`, `codeDrop(p, name, objs)` | `DROP SCHEMA`가 지울 개체(뷰, 테이블, 소유자 없는 시퀀스)와 그 삭제(개체, 남은 시퀀스·카탈로그 항목, 목록의 행) |
| `resolve(db, a, schemas, cfg, schema, name)` | 한정한 이름 → SQLite (db, name). `Config{default_schema, temp_schema}`가 방언의 이름. SQLite 데이터베이스 이름이 먼저, 그다음 목록의 스키마(main과 바꾼 이름), 둘 다 아니면 `error.NoSuchSchema` |

카탈로그 뷰(`information_schema`, `pg_namespace` ...)는 개체 이름을 목록과 조인해 스키마와 이름으로 나누고, 기본 스키마에서는 감춥니다.

## VFS

방언과 상관없이 엔진 맨 아래에는 VFS(`pkg/vfs/src/vfs.zig`)가 있습니다. sqlite3_vfs·sqlite3_io_methods를 옮긴 타입 지운 인터페이스로, 파일 열기·삭제·존재 확인, 위치 지정 읽기·쓰기, 다섯 단계 잠금, WAL의 공유 메모리(`shmMap`, `shmLock`)를 정합니다.

| 구현 | 파일 | 잠금 | wal-index |
| --- | --- | --- | --- |
| POSIX | `unix.zig` | `fcntl` 바이트 범위 잠금. sqlite3와 같은 바이트라서 sqlite3 프로세스와 파일을 함께 씀 | mmap한 `-shm` 파일 |
| WASI | `wasi.zig` | 프로세스 안에서만(`inproc.zig`, 장치·inode 번호로) | 힙 메모리 |
| 호스트(wasm32-freestanding) | `host.zig` | 프로세스 안에서(이름으로) 중재한 뒤 호스트에 물음(`xq_host_lock`) | 힙 메모리 |
| 메모리 | `mem.zig` | `MemVfs` 객체 안에서 | 힙 메모리 |
| memdb | `memdb.zig` | 저장소 안에서(`/이름`은 프로세스 안에서 공유) | 없음(WAL 불가, 저널은 메모리) |
| 크래시 테스트 | `crash.zig` | 감싼 VFS의 것 | 감싼 VFS의 것 |

```
Db.open(.unix) ─▶ vfs.OsVfs ─┬─ POSIX     (네이티브)
                             ├─ WASI      (wasm32-wasi)
                             └─ 호스트    (wasm32-freestanding, env.xq_host_* import)
Db.open(.memory) ─▶ MemVfs
```

`vfs.OsVfs`는 타깃의 파일 시스템 VFS를 comptime에 고릅니다. 셋 모두 `init(gpa, io)`와 `interface()`가 있습니다. WASI와 호스트 VFS는 이름 없는 임시 파일을 메모리(`MemVfs`)에 둡니다. 잠금 표는 유닉스의 inode 표처럼 프로세스 전역이라서, 연결마다 VFS 객체가 따로 있어도 같은 파일의 잠금은 하나입니다. 다른 프로세스와의 잠금은 없습니다. 엔진이 VFS 밖에서 플랫폼에 묻는 것(시계, 환경 변수, 지역 시간, 64비트 원자 연산)은 `src/util/platform.zig` 한곳에 있습니다. 자세한 내용은 [WebAssembly](wasm.md)에 있습니다.

### VFS 패키지

VFS는 엔진과 따로 빌드되는 Zig 패키지(`pkg/vfs/`, 모듈 이름 `xqlite_vfs`)입니다. 위 표의 파일은 모두 `pkg/vfs/src/`에 있고, 패키지는 `std` 말고는 아무것도 import하지 않습니다. 루트 `build.zig.zon`이 경로 의존성(`.xqlite_vfs = .{ .path = "pkg/vfs" }`)으로 받고, `build.zig`의 `vfsImport()`가 타깃마다 `b.dependency("xqlite_vfs", .{ .target, .optimize })`로 모듈을 가져와 엔진 모듈(`src/root.zig`), C ABI 라이브러리(`src/capi.zig`), 퍼저에 `xqlite_vfs`라는 import로 붙입니다. 패키지 모듈은 최적화 모드를 가져다 쓰는 컴파일에서 물려받으므로(ReleaseSafe 빌드의 VFS도 ReleaseSafe), `optimize` 인자는 패키지 자체 테스트에만 쓰입니다.

패키지 루트(`pkg/vfs/src/root.zig`)가 내보내는 것이 엔진과의 경계입니다.

| 이름 | 내용 |
| --- | --- |
| `vfs` | 인터페이스: `Vfs`, `File`, `Error`, `LockLevel`, `OpenFlags`, `AccessMode`, `SyncFlags`, `ShmRegion`, `ShmLockTable`, `OsVfs` ... |
| `mem`, `memdb`, `inproc`, `crash` | 구현. `memdb`는 힙을 받는 제네릭 `Memdb(heap)` |
| `unix`, `wasi`, `host` | 타깃의 OS VFS. 타깃이 아니면 빈 네임스페이스 |
| `Vfs`, `File`, `Error`, `MemVfs`, `OsVfs` | 자주 쓰는 이름의 별칭 |
| `temp_directory` | `sqlite3_temp_directory` |

엔진 파일은 `@import("xqlite_vfs").vfs`, `.mem` 식으로 가져옵니다. 공개 Zig API(`xqlite.vfs`, `xqlite.MemVfs`, `xqlite.OsVfs`, `xqlite.UnixVfs`, `xqlite.WasiVfs`, `xqlite.HostVfs`, `xqlite.crash_vfs`)는 `src/root.zig`가 패키지의 이름을 다시 내보내므로 그대로입니다. C ABI의 C VFS 다리(`src/capi/vfs.zig`)는 capi에 남고, 패키지의 인터페이스만 씁니다.

엔진에서 VFS로 들어가던 두 의존성은 엔진이 넣어 주는 방식으로 바꿨습니다.

- **임시 파일 디렉터리.** `sqlite3_temp_directory`는 패키지 변수 `temp_directory`(`pkg/vfs/src/root.zig`)입니다. POSIX VFS는 읽기만 하고(`unixTempFileDir()`의 순서 그대로: 이 변수, `$SQLITE_TMPDIR`, `$TMPDIR`, `/var/tmp`, `/usr/tmp`, `/tmp`, `.`), 쓰는 쪽은 엔진입니다. `PRAGMA temp_store_directory`가 `sqlite3_malloc()` 메모리로 바꾸고, C ABI는 이 변수를 `sqlite3_temp_directory`라는 이름으로 내보내 C 프로그램이 직접 씁니다.
- **memdb의 힙.** `memdb.Memdb(heap)`는 `heap.allocator`, `heap.realloc(p, n)`, `heap.free(p)`로 저장소와 핸들을 할당합니다(`realloc`·`free`는 `sqlite3_realloc()`·`sqlite3_free()`처럼 포인터만 받음. `sqlite3_deserialize()`가 넘긴 버퍼를 키우고 해제해야 하므로). 엔진은 `src/sql/memdb.zig`에서 라이브러리 할당자(`src/sql/malloc.zig`)로 한 번만 인스턴스를 만들고, `sqlite3_deserialize()`, ATTACH의 임시 데이터베이스, C ABI의 "memdb" VFS가 모두 그것을 씁니다. 그래서 memdb의 메모리는 예전처럼 `sqlite3_status()`와 힙 한도(fuzzcheck의 한도 포함)에 잡힙니다. comptime 인자라서 초기화 순서가 없고, 공유 저장소와 설정(`state`)은 인스턴스마다 하나입니다.

## 스토리지 패키지

VFS 위의 스토리지 층(페이저, 페이지 캐시, WAL, B-tree)도 엔진과 따로 빌드되는 Zig 패키지(`pkg/storage/`, 모듈 이름 `xqlite_storage`)입니다. `std`, `xqlite_vfs`, `xqlite_base`(아래 [공용 패키지](#공용-패키지)) 말고는 아무것도 import하지 않습니다. 엔진이 넣어 주는 것은 원래부터 인자였던 할당자, VFS, 콜백(busy handler, 페이지 spill, 키 비교, autovacuum_pages 등)뿐입니다.

루트 `build.zig.zon`이 경로 의존성(`.xqlite_storage = .{ .path = "pkg/storage" }`)으로 받고, 패키지는 자기 `build.zig.zon`에서 `../vfs`와 `../base`에 의존합니다. `build.zig`의 `engineImports()`가 엔진 모듈, C ABI 라이브러리, wasm 모듈, 퍼저에 `xqlite_vfs`, `xqlite_storage`, `xqlite_base`를 함께 붙입니다. 루트와 스토리지 패키지의 `build.zig`가 같은 인자(`target`, `optimize`)로 VFS와 공용 패키지를 부르므로 빌드 시스템이 의존성을 하나씩만 만들고, 그래서 엔진과 스토리지가 같은 `xqlite_vfs`, `xqlite_base` 모듈을 씁니다(다르면 같은 파일이 두 모듈에 속해 컴파일 오류).

패키지 루트(`pkg/storage/src/root.zig`)가 내보내는 것은 다음과 같습니다.

| 이름 | 내용 |
| --- | --- |
| `pager`, `pcache`, `journal` | 페이저(`pager.wal`이 WAL), 페이지 캐시, 롤백 저널 형식 |
| `btree` | B-tree 층과 파일 헤더(`btree.header`) |
| `record`, `varint` | 레코드 형식(serial type 크기, 헤더 varint, 정수 디코딩, `memcmp`, `intFloatCompare`)과 varint. 파일 형식이라 여기 있고, 엔진의 `src/vdbe/serial.zig`(Mem을 쓰는 레코드 코드)도 이 함수들을 씀 |
| `btree_fuzz` | B-tree 퍼저(`src/fuzz_tests.zig`가 씀) |
| `sqlite_version_number` | 페이저가 파일 헤더에 쓰는 `SQLITE_VERSION_NUMBER`. `src/root.zig`가 다시 내보냄 |

한 파일은 한 모듈에만 속할 수 있으므로, 엔진과 스토리지가 함께 쓰는 파일 형식 코드(`record`, `varint`)는 이 패키지에 두고 엔진은 `@import("xqlite_storage").varint` 식으로 가져옵니다. 공개 Zig API(`xqlite.pager`, `xqlite.pcache`, `xqlite.btree`, `xqlite.record`, `xqlite.varint`)는 `src/root.zig`가 다시 내보내므로 그대로입니다. 패키지 디렉터리에서 `zig build test`를 하면 스토리지 테스트(B-tree, 페이저, WAL, 저널)만 돕니다. B-tree 테스트의 픽스처는 `pkg/storage/src/testdata`에 있습니다(`xqt gen fixtures`).

## 공용 패키지

어느 층의 것도 아니면서 스토리지 패키지와 엔진이 함께 쓰는 도우미는 `pkg/base/`(모듈 이름 `xqlite_base`)에 있습니다. `std`만 import하고, 루트와 스토리지 패키지가 경로 의존성으로 받습니다.

| 이름 | 내용 |
| --- | --- |
| `thunk` | 콜백 클로저. 엔진이 넘기는 콜백(busy handler 등)과 스토리지가 받는 타입이 같아야 함 |
| `status` | `sqlite3_status()` 카운터와 `SQLITE_CONFIG_MEMSTATUS`. 페이지 캐시와 엔진의 할당자가 함께 셈 |
| `fuzz` | 시드 퍼저의 도우미(시드 파싱, swarm testing). `src/fuzz_tests.zig`, IR 퍼저, B-tree 퍼저가 씀 |

`zig build test-pkg`는 세 패키지(`pkg/vfs`, `pkg/storage`, `pkg/base`)의 테스트만 엔진 없이 빌드해 돌립니다.

## 소스 파일

| 파일 | 내용 |
| --- | --- |
| `src/dialect/dialect.zig` | `Dialect`(`sqlite`, `postgres`, `mariadb`; 3은 MSSQL 자리), `Frontend`, `Hooks`, `Lang`, 연결별 상태(`ConnState`), 디스패치 |
| `src/dialect/func.zig` | 방언 함수 테이블을 만드는 생성자(`scalar`, `aggregate`) |
| `src/dialect/{sqlite,postgres,mariadb}/frontend.zig` | 방언마다 `frontend`와 `hooks` |
| `src/dialect/postgres/*.zig` | PostgreSQL 프론트엔드([PostgreSQL 호환](postgres.md)) |
| `src/dialect/mariadb/*.zig` | MariaDB 프론트엔드([MariaDB 호환](mariadb.md)) |
| `src/dialect/mssql/*.zig` | MSSQL(T-SQL) 프론트엔드([MSSQL 호환](mssql.md)) |
| `src/dialect/oracle/*.zig` | Oracle 프론트엔드([Oracle 호환](oracle.md)) |
| `src/ir/ir.zig` | IR 빌더 파사드: `stmt`, `expr`, `list`, `from`, `select`, `with`, `window`, `dml`, `ddl`, `txn`, `admin`. 각 항목은 대응하는 C 함수(`sqlite3PExpr`, `sqlite3StartTable` ...)의 별칭이거나 parse.y에서 옮긴 도우미 |
| `src/ir/tree.zig` | 구문 트리 IR과 의미 노드 (아래) |
| `src/ir/lower.zig` | `Lowerer.init(p, src)`, `statement(stmt)`(DDL 포함), `expr()`, `select()`; DML 기본값·identity, DDL의 카탈로그 기록 |
| `src/ir/render.zig` | `render.select(p, src, s)`, `render.expr()`, `render.statement()`(CREATE TABLE/INDEX/VIEW, ALTER TABLE)와 `Renderer` |
| `src/ir/test.zig`, `fuzz.zig`, `gen.zig` | render ≡ lower 테스트와 퍼저 |
| `src/catalog/catalog.zig`, `sequence.zig`, `schema.zig` | 방언 메타데이터, 시퀀스, 이름 붙은 스키마([스키마](#스키마네임스페이스)) |
| `pkg/vfs/build.zig`, `build.zig.zon` | VFS 패키지(`xqlite_vfs`): 모듈과 `zig build test`. 루트 빌드가 경로 의존성으로 받음([VFS 패키지](#vfs-패키지)) |
| `pkg/vfs/src/root.zig` | 패키지 루트: 인터페이스와 구현의 이름, `temp_directory`(`sqlite3_temp_directory`) |
| `pkg/vfs/src/vfs.zig` | VFS 인터페이스(`Vfs`, `File`, 잠금, 공유 메모리)와 `OsVfs` |
| `pkg/vfs/src/{unix,wasi,host,mem,memdb,inproc,crash}.zig` | VFS 구현([VFS](#vfs)의 표) |
| `src/sql/memdb.zig` | 엔진의 memdb 인스턴스: `Memdb(malloc)` |
| `pkg/storage/build.zig`, `build.zig.zon` | 스토리지 패키지(`xqlite_storage`): 모듈과 `zig build test`([스토리지 패키지](#스토리지-패키지)) |
| `pkg/storage/src/pager/{pager,pcache,wal,journal}.zig` | 페이저, 페이지 캐시, WAL, 롤백 저널 |
| `pkg/storage/src/btree/{btree,page,header,ptrmap,integrity}.zig` | B-tree 층 |
| `pkg/storage/src/{record,varint}.zig` | 엔진과 함께 쓰는 레코드 형식과 varint |
| `pkg/base/src/{thunk,status,fuzz}.zig` | 공용 패키지(`xqlite_base`): 클로저, 상태 카운터, 퍼저 도우미([공용 패키지](#공용-패키지)) |

구문 트리 IR(`src/ir/tree.zig`)이 나타내는 문장은 다음과 같습니다.

- 식
- SELECT: 복합 질의, CTE, 윈도우, 조인, 서브쿼리, VALUES
- INSERT/UPDATE/DELETE: RETURNING, upsert, UPDATE FROM, DELETE USING, ORDER BY ... LIMIT
- 트랜잭션
- DDL: CREATE/DROP TABLE/INDEX/VIEW/SEQUENCE, ALTER 일부

## 아직 하지 않은 것

- 방언별 문장 경계: `sqlite3_complete()`와 셸의 입력 분할은 SQLite 규칙을 씁니다.
- 시퀀스의 비트랜잭션 의미
- 붙인 데이터베이스(`ATTACH`)의 시퀀스(시퀀스는 모두 main의 `xq_sequence`에 있음). `CREATE SCHEMA`의 스키마의 시퀀스는 `s.seq`라는 이름으로 main에 있음
- `sequence.create()`의 중복 시 PostgreSQL 오류 메시지. PostgreSQL 프론트엔드의 `CREATE SEQUENCE`는 컴파일 시점에 검사합니다.
- 방언 함수의 `PRAGMA function_list` 노출
