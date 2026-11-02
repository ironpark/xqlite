# 방언 아키텍처

xqlite가 하나의 SQLite 엔진 위에서 여러 SQL 방언을 실행하는 구조를 설명합니다. 방언 선택, 프론트엔드 계약, 구문 트리 IR과 그 두 백엔드(lower, render), 방언 훅, 카탈로그를 다룹니다.

방언별 지원 범위는 [SQLite 호환](sqlite.md), [PostgreSQL 호환](postgres.md), [MariaDB 호환](mariadb.md), [MSSQL 호환](mssql.md), [Oracle 호환](oracle.md)에 있습니다.

## 목차

- [개요](#개요)
- [방언 고르기](#방언-고르기)
- [빌드에 넣을 방언과 확장](#빌드에-넣을-방언과-확장)
- [공통 IR의 두 층](#공통-ir의-두-층)
- [의미 노드](#의미-노드)
- [render와 lower의 계약](#render와-lower의-계약)
- [DML 공통 의미](#dml-공통-의미)
- [프론트엔드 계약](#프론트엔드-계약)
- [새 프론트엔드 붙이기](#새-프론트엔드-붙이기)
- [방언 훅](#방언-훅)
- [오류 코드](#오류-코드)
- [값 표시](#값-표시)
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
- **훅**: 방언이 엔진의 동작을 바꾸는 지점(함수 테이블, 엔진 함수, collation, 산술·제약 위반의 오류, 식의 타입 규칙 ...)입니다([방언 훅](#방언-훅)).

데이터는 하나의 SQLite 파일에 저장되고, 방언은 SQL을 해석하는 방식만 바꿉니다. 스키마에 저장되는 텍스트는 언제나 SQLite SQL이므로 sqlite3가 그 파일을 그대로 열 수 있습니다.

```
SQL 텍스트 ──▶ dialect.runParser()            연결의 방언(Sqlite3.xq.lang)으로 디스패치
                 ├─ dialect/sqlite    tokenize.zig + parser.zig (기준 구현) ─────────────┐
                 ├─ dialect/postgres  lexer → parser ─┐                                   │
                 ├─ dialect/mariadb   lexer → parser ─┤                                   │
                 ├─ dialect/mssql     lexer → parser ─┤                                   │
                 └─ dialect/oracle    lexer → parser ─┤                                   │
                                                      ▼                                   │
                                     구문 트리 IR (src/ir/tree.zig)                       │
                                       ├─ lower.zig  ─────────────────────────────────────┤ ir.*
                                       └─ render.zig ─▶ SQLite 텍스트 ─▶ lowerSqliteText ─┤
                                                         (sqlite_schema)                  ▼
                                                               파스 트리 + 빌더 ──▶ VDBE 바이트코드
                                                                          ▲
   방언 훅(dialect.Hooks): 함수 테이블 · 엔진 함수 · 추가 collation · 기본 collation · 산술·제약 오류 · 타입 규칙
   카탈로그(src/catalog): xq_catalog와 메모리의 카탈로그(meta.zig) · xq_sequence · 이름 붙은 스키마(schema.zig)
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

## 빌드에 넣을 방언과 확장

SQLite 방언을 뺀 방언과 내장 확장은 빌드에서 뺄 수 있습니다. 기본값은 모두 넣는 것입니다.

| 옵션 | 기본값 | 뜻 |
| --- | --- | --- |
| `-Ddialects=LIST` | `all` | 넣을 방언. `postgres`, `mariadb`, `mssql`, `oracle`을 쉼표로, 또는 `all`, `none` |
| `-Dext=LIST` | `all` | 넣을 확장. `carray`(C ABI의 `carray()`와 `sqlite3_carray_bind()`), `series`(셸의 `generate_series()`), `vtablog`(셸의 `XQ_VTABLOG`) |

```sh
zig build -Ddialects=none -Dext=none -Doptimize=ReleaseSmall   # SQLite만
zig build wasm -Ddialects=postgres                             # PostgreSQL 방언만 넣은 브라우저 모듈
```

- 빌드 시스템이 옵션을 `xqlite_config` 모듈(`dialect_<이름>`, `ext_<이름>` bool)로 만들어 엔진의 모든 컴파일에 붙입니다. Zig API에서는 `xqlite.config`입니다.
- 뺀 방언은 이름은 그대로 알고, `Dialect.built()`가 거짓입니다. `PRAGMA xq_dialect`, 셸의 `.dialect`, C API의 URI 파라미터와 `xqlite_set_dialect()`, wasm의 `xq_set_dialect`는 `dialect not built in: postgres`로 실패합니다. Zig API의 `setDialect()`는 enum을 받으므로 바꾸기는 하지만, 그 뒤 문장이 같은 메시지로 실패합니다(`src/dialect/disabled.zig`의 프론트엔드).
- 뺀 방언의 엔진 함수(`xq_coerce()` 등)도 빠지므로, 그 방언이 그런 함수를 넣어 쓴 스키마는 그 방언을 넣은 빌드가 있어야 씁니다. sqlite3로는 원래 쓸 수 없는 스키마이므로 같은 처지입니다.
- 방언 코드는 엔진의 약 1/3입니다. 모두 넣은 빌드와 SQLite만 넣은 빌드(ReleaseSmall)를 비교하면 브라우저 wasm은 2.33MB에서 0.95MB, `libxqlite3` 공유 라이브러리는 2.48MB에서 1.20MB입니다.
- `zig build check`는 `tools/minimal_test.zig`를 `-Ddialects=none -Dext=none`에 해당하는 엔진으로 빌드해 돌립니다(`zig build test-minimal`).

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
2. `dialect.Dialect`와 `module()`에 추가합니다.
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
| `arith` | 0으로 나누기와 64비트를 넘는 정수 결과에 SQLite의 NULL·실수 대신 낼 오류(메시지와 `ErrorState`). 문장을 컴파일한 방언의 것(`Vdbe.xq_lang`)을 쓰므로, 뷰와 CHECK의 식은 그것을 쓰는 문장의 방언 규칙으로 계산됩니다. 오류 분기에서만 읽어 연산 속도에는 영향이 없습니다. `int1`/`int2`/`int4`는 타입이 그 폭의 정수인 산술의 범위와 그 밖에서 낼 오류입니다(PostgreSQL `integer out of range`, SQL Server `Arithmetic overflow error converting expression to data type int.`). 아래 [타입을 읽는 코드 생성](#타입을-읽는-코드-생성). |
| `constraint` | 제약 위반(NOT NULL, UNIQUE·PRIMARY KEY, CHECK, 외래 키)의 오류. `message`가 위반(`dialect.Violation`: 종류, 테이블, 열, 제약 이름)을 방언의 메시지와 `ErrorState`로 바꿉니다. 문장을 컴파일할 때 정해 `OP_Halt`의 P4에 넣으므로(`src/dialect/constraint.zig`) 성공 경로의 비용은 없습니다. 중복 키의 값은 실행 중에 `value_mark` 자리에 씁니다. `foreign_key`는 어느 제약인지 모르는 외래 키 위반(COMMIT의 지연 제약)의 오류입니다. SQLite 방언과 엔진 내부 SQL은 SQLite의 메시지와 바이트코드 그대로입니다([제약 위반](#제약-위반)). |
| `foreign_keys` | 그 방언의 데이터베이스가 외래 키를 강제함. 응용이 그 방언으로 준비하는 첫 문장(트랜잭션 밖)에서 `PRAGMA foreign_keys`를 켜고, 강제하지 않는 방언의 첫 문장에서 자기가 켠 것이면 끕니다. 그 사이 응용이 바꾼 설정은 그대로 둡니다(`dialect.applyForeignKeys()`). |
| `check_errors` | 방언이 타입 검사에 붙인 CHECK 제약 이름의 오류 코드([오류 코드](#오류-코드)) |
| `typing` | 리터럴·연산자·함수의 타입 규칙(`typing.Rules`, [코어의 타입](#코어의-타입)). 이름 해석 뒤에 프론트엔드가 타입을 찍지 않은 식에 적용합니다. 규칙의 `overload`는 타입으로 연산자·함수를 고릅니다(PostgreSQL의 jsonb 연산자, JSON 함수의 인자). 코드 생성은 정수 산술의 폭과 저장 함수(`Rules.store`)만 읽습니다([타입을 읽는 코드 생성](#타입을-읽는-코드-생성)). |
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
- 반복을 줄이는 comptime 도우미가 같은 파일에 있습니다.
  - `dfunc.overloads("instr", &.{ 2, 3, 4 }, det, f)`: 인자 개수만 다른 등록을 한 번에(붙어 있음이 보장됨).
  - `dfunc.bind(f, .{ true, false })`: 고정 인자만 다른 구현을 손으로 쓴 래퍼 없이.
  - `dfunc.withArena(Call, f)`: 호출마다 아레나를 쓰는 구현의 `init`/`deinit`.
  - `dfunc.typed(name, o, Conv, f)`: 인자 개수를 `f`의 매개변수에서 정하고, 인자를 차례로 변환(NULL이면 그 자리에서 끝). 변환 규칙(`Conv`)은 방언 것입니다(Oracle은 `''`도 NULL).

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

## 오류 코드

오류마다 메시지와 함께 무엇인지(`int.ErrorState`)를 남깁니다. 와이어 프로토콜과 ORM이 메시지가 아니라 코드로 오류를 구분하기 때문입니다.

- `ErrorState`는 SQLSTATE(PostgreSQL의 코드 공간)와 방언의 번호(MySQL의 1146, SQL Server의 208, Oracle의 942; 없으면 0)입니다. 메시지에 딸린 것이라 `Parse.err_msg`, `Vdbe.err_msg`, 연결의 메시지가 각각 하나씩 갖고, 메시지가 바뀌면 함께 바뀝니다. 연결로 옮겨진 것을 Zig API가 `ErrorInfo.sqlstate`, `ErrorInfo.dialect_number`로 내보냅니다.
- 엔진은 SQLite의 오류에 SQLSTATE를 남깁니다: `no such table` 42P01, `no such column` 42703, `no such function` 42883, 문법 오류 42601, `already exists` 42P07, 트랜잭션 상태 25001·25P01, `no such savepoint` 3B001 ...(`util.errorMsgState()`, `aux.vdbeErrorState()`).
- 방언은 그 오류를 자기 말로 바꿀 때(`translateError()`) SQLSTATE는 두고 번호를 더합니다(`dialect.numberError()`: SQLSTATE마다 그 방언의 번호).
- 방언이 직접 내는 오류는 낼 때 남깁니다: 파서의 `failState(state, fmt, args)`, 실행 중에는 `api.resultErrorState(ctx, state, msg)`, 가상 테이블은 `vtab.setErrState()`. 컴파일 중에 실행한 문장의 오류를 그대로 내는 곳은 `failFrom(db)`(파서)나 `api.resultErrorFrom(ctx, db)`(함수)로 그 오류의 것을 옮깁니다. Oracle의 메시지는 번호로 시작하므로(`ORA-00942: ...`) `oracle/errors.zig`가 번호를 읽습니다. 파서에서는 형식 문자열에서 컴파일 시점에, 엔진 메시지를 바꾼 것과 실행 중 오류는 메시지에서 읽습니다.
- 번역 단계의 번호는 엔진 오류에만 붙습니다. 방언이 자기 번호를 준 오류는 그 번호를 유지합니다.
- 방언이 타입 검사에 붙이는 CHECK 제약 이름(`value too long for type character varying(3)`)은 `Hooks.check_errors`가 SQLSTATE와 번호를 줍니다. 테이블을 만든 방언이 연결의 방언이 아니어도 됩니다.
- `xqlite: ... is not supported` 형식의 메시지는 형식 문자열에서 컴파일 시점에 `0A000`(feature_not_supported)이 됩니다.
- 무엇인지 모르는 오류는 SQLSTATE가 없습니다. 확장 결과 코드가 구분하는 오류(제약, BUSY, INTERRUPT)는 그 코드로 알 수 있습니다.
- 새 오류를 낼 때는 그 방언의 SQLSTATE와 번호를 함께 적습니다. 실제 서버의 번호를 확신할 수 없으면 SQLSTATE만 적습니다(번호 0).

### 제약 위반

실행 중 제약 위반은 문장을 컴파일한 방언의 문구와 `ErrorState`입니다(`Hooks.constraint`, `src/dialect/constraint.zig`).

- 코드 생성기(`insert.zig`, `build.zig`, `fkey.zig`)가 제약의 `OP_Halt`/`OP_HaltIfNull`을 만들 때 방언의 `Constraint.message`가 메시지와 `ErrorState`를 정합니다. 그것을 P4에 넣고(SQLSTATE, 번호, 메시지) P5에 `P5_ConstraintDialect`를 켭니다. 실행은 위반했을 때만 P4를 풀어 오류로 남깁니다.
- 중복 키의 값(MariaDB `Duplicate entry '1'`, SQL Server `The duplicate key value is (1).`)은 P3부터 `P5 >> 8`개의 레지스터에 있고, 메시지의 `dialect.value_mark` 자리에 `Constraint.value_separator`로 이어 씁니다.
- 외래 키는 대개 문장이 끝날 때 카운터(`OP_FkCounter`)로 찾습니다. 위반을 세는 `OP_FkCounter`의 P4에 그 제약의 오류를 넣고, 마지막으로 센 것(`Vdbe.xq_fk_error`)을 문장의 오류로 씁니다. 다른 문장(COMMIT)이 찾은 지연 제약은 `Constraint.foreign_key`입니다.
- SQLite가 남기지 않는 제약 이름(UNIQUE, PRIMARY KEY, FOREIGN KEY에 사용자가 준 이름)은 CREATE TABLE이 `xq_catalog`의 `constraint:<종류>:<열>` 키에 적고(`lower.zig`), DML을 컴파일할 때 한 곳(`constraint.tableEntries()`)에서 읽습니다. 유일 인덱스는 인덱스 이름, CHECK는 SQLite가 남긴 이름을 씁니다. 이름이 없으면 방언이 짓습니다(PostgreSQL `t_a_key`, MariaDB `t_ibfk_1` ...).
- 방언이 타입 검사에 붙인 CHECK(`Hooks.check_errors`)는 이름이 곧 메시지입니다(`integer out of range`, `ORA-12899: ...`).
- SQLite 방언과 엔진이 직접 돌리는 SQL은 `Constraint.message`가 없으므로 SQLite의 메시지와 바이트코드 그대로입니다. 같은 테이블이어도 sqlite3나 SQLite 방언의 문장은 `UNIQUE constraint failed: t.a`입니다.

## 값 표시

엔진은 값을 SQLite처럼 저장하고 돌려줍니다. 불리언은 0/1, `numeric(10,2)`는 끝의 0이 없는 수, `timestamptz`는 오프셋 없는 UTC 텍스트입니다. 셸과 와이어 프로토콜은 그 방언의 클라이언트가 보는 텍스트로 보여 줍니다. C API와 Zig API가 돌려주는 값은 그대로입니다.

- `xqlite.types`(`src/sql/types.zig`, 엔진의 것): 방언의 선언 타입 → 방언과 무관한 `Type`(`boolean`, `int4`, `numeric(10,2)`, `timestamp_tz` ...). 테이블을 만든 방언으로 읽으므로, PostgreSQL 연결이 MSSQL이 만든 `bit` 열을 읽어도 `boolean`입니다.
- `xqlite.display.Columns`: 결과 열의 타입. 테이블 열이면 메모리의 카탈로그(`catalog.meta()`, [메모리의 카탈로그](#메모리의-카탈로그))에서 읽습니다. 식이면 엔진이 그 식에 매긴 타입입니다([코어의 타입](#코어의-타입)): 비교, `AND`/`OR`/`NOT`, `IS`, `IN`, `BETWEEN`, `LIKE`, `EXISTS`, 불리언 상수는 어느 방언에서나 불리언이고, 캐스트는 그 대상 타입입니다(`2.5::numeric(6,2)`, `CAST(x AS DECIMAL(6,2))`). 리터럴, 산술, `CASE`/`COALESCE`, 함수 호출은 방언의 규칙이 정한 타입입니다(PostgreSQL의 `1.50`, `n + 1`, `sum(n)`은 스케일 2의 `numeric`, MariaDB의 `7 / 2`는 `DECIMAL(14,4)`). 서브쿼리, CTE, 뷰의 열과 스칼라 서브쿼리는 그 열의 타입을 이어받습니다. 엔진은 타입을 문장에 `Type`으로 두고(`engine.resultType()`), 그 철자를 열의 선언 타입(`sqlite3_column_decltype()`)으로 남깁니다. SQLite 방언의 문장은 SQLite처럼 NULL입니다. 연결이 열의 출처를 기록해야 합니다(`setColumnMetadata`, Zig API의 `OpenOptions.column_metadata`; 셸은 늘 켬).
- `xqlite.display.text(viewer, type, value)`: 그 방언이 그 값을 보이는 텍스트. SQLite와 같으면 null입니다. `viewer`는 문장을 컴파일한 방언입니다.

| 방언 | 불리언 | `decimal(p,s)`/`numeric(p,s)` | 시간대 있는 타임스탬프 |
| --- | --- | --- | --- |
| PostgreSQL | `t`/`f` | s자리(`1.50`) | `+00`을 붙임 |
| MariaDB | 1/0(`TINYINT(1)`) | s자리(`220.00`) | |
| MSSQL | 1/0(`bit`) | s자리(`2.50`) | 저장할 때 이미 SQL Server 형식 |
| Oracle | `TRUE`/`FALSE` | 끝의 0 없음(`NUMBER`, SQLite와 같음) | |

- 셸은 SQL이나 JSON 값을 쓰는 스타일(`quote`, `insert`, `json`, `jobject`)에서는 SQLite 그대로 씁니다.
- 스케일 0의 수(`numeric(10,0)`, PostgreSQL의 `1e3`, `round(2.5)`)는 소수점 없이 보입니다(`1000`; SQLite는 실수 `1000.0`).
- 타입을 모르는 식(SQLite 테이블의 열을 쓰는 식, 규칙이 없는 함수)은 SQLite처럼 보입니다. 값마다 스케일이 정해지는 PostgreSQL의 `numeric` 나눗셈과 `avg()`도 그렇습니다(`numeric`이지만 스케일을 모름). 뷰의 캐스트 열도 그렇습니다: 뷰는 SQLite 텍스트로 저장되었다가 다시 컴파일되고, 캐스트는 SQLite의 식(`CAST(round(x, 2) AS NUMERIC)`)으로 내려가 대상 타입이 남지 않습니다. 뷰의 비교는 다시 컴파일할 때 다시 불리언이 됩니다.

### 코어의 타입

식의 타입은 코어의 개념입니다: `Expr.xq_type`(`src/sql/typing.zig`의 `TypeId`, u16, 0은 모름). 대부분 메타데이터이고, 코드 생성은 두 곳에서만 읽습니다([타입을 읽는 코드 생성](#타입을-읽는-코드-생성)). 방언이 타입으로 고르는 것(오버로드, 아래 `Rules.overload`)은 해석된 식을 바꿔 두는 것이라, 코드 생성은 그 식을 여느 식처럼 컴파일합니다. SQLite 방언의 문장, 스키마, 엔진이 스스로 컴파일하는 SQL에는 매기지 않으므로(`typing.active()`) 그 바이트코드는 SQLite의 것 그대로입니다.

- 매기는 곳
  - 내림(`Lowerer.expr()`): 프론트엔드가 아는 타입을 모든 식(결과 열만이 아님)의 뿌리에 찍습니다. 비교·논리·`IN`·`EXISTS`·`BETWEEN`·`LIKE`·`IS`는 불리언, 캐스트는 대상 타입을 프론트엔드의 철자로(PostgreSQL의 스케일만 있는 `numeric`은 `numeric(38,s)`), `COLLATE`는 피연산자의 타입. 캐스트는 내린 뒤에는 되살릴 수 없으므로(`CAST(round(x,s) AS NUMERIC)`, MariaDB의 `REAL` + `round`) 여기서 찍어야 합니다.
  - 이름 해석(`resolve.zig`): 프론트엔드가 찍지 않은 식에 연산자가 정하는 타입(`typing.ofOp()`: 비교·논리는 불리언, SQLite 텍스트인 뷰에도). FROM 서브쿼리·CTE·뷰의 열을 가리키는 `TK_COLUMN`은 그 결과 열의 타입(`lookupName`), 스칼라 `TK_SELECT`는 첫 열의 타입, 방언 테이블의 열은 카탈로그의 타입(`catalog.metaCached()`: 메모리에 있을 때만, 이름 해석 중에는 질의하지 않음. 방언 프론트엔드가 문장을 내릴 때 대개 이미 읽음. PostgreSQL 프론트엔드는 문장마다 모든 데이터베이스의 카탈로그를 메모리에 둠(`catalog.readAll()`, 스키마가 바뀌지 않으면 질의 없음): 뷰가 읽는 테이블의 열도 타입을 알도록). SQLite 방언의 테이블은 카탈로그 항목이 없으므로 모름입니다.
  - 방언의 규칙(`Hooks.typing`, `typing.Rules`): 이름 해석이 끝난 식(`resolveExprNames`/`resolveExprListNames`의 끝)을 안쪽부터 훑어(`typing.typeTree()`, 해석 워커는 그대로) 타입이 없는 노드에 매깁니다. 프론트엔드가 찍은 타입과 열의 타입은 그대로 둡니다. 서브쿼리는 자기 해석 때 이미 매겼으므로 들어가지 않습니다.
    - 리터럴(`Rules.literal`), 산술·연결·비트 연산(`Rules.operator`: `TK_PLUS` ... `TK_CONCAT`, 단항 `-`·`~`), 함수(`Rules.function`: 내린 이름(소문자)으로 찾는 `Ret` 표. 고정 타입, 인자 i의 타입, 인자들의 공통 타입, 방언이 계산하는 규칙. 없으면 코어의 `coalesce`/`ifnull`/`nullif`/`iif`/`min`/`max`). FuncDef가 아니라 방언의 이름 표에 두는 이유: 같은 내장 함수(`length`, `sum`)가 방언마다 다른 타입을 돌려줍니다. 엔진 함수(`xq_*`)도 같은 표에 둡니다.
    - 코어가 정하는 것: 단항 `+`와 `COLLATE`는 피연산자, `CASE`는 `THEN`/`ELSE` 값들의 공통 타입, 스칼라 서브쿼리는 첫 열(복합이면 항들의 공통 타입). 공통 타입(`typing.common()`): 같은 타입은 그 타입, 정수끼리는 넓은 쪽, 정확한 수끼리는 큰 스케일의 `numeric`, 실수가 섞이면 `double precision`, 문자열끼리는 길이 없는 문자열. NULL 리터럴은 어느 타입과도 맞고, 모르는 값이 하나라도 있거나 공통 타입이 없으면 모름입니다. PostgreSQL은 `numeric` 값마다 스케일이 있으므로(`Rules.value_scale`) 스케일이 다른 둘의 공통 타입은 스케일을 모릅니다.
    - 규칙이 만든 타입은 방언의 철자(`Rules.spell`)로 표에 넣습니다(`Interner.addType()`: (방언, 타입, 철자)). 철자가 타입보다 덜 말할 수 있습니다: PostgreSQL은 연산 결과의 `numeric`에 typmod를 두지 않으므로 `numeric`이라 쓰지만 스케일은 갖고 있어 그 자릿수로 보입니다.
    - 프론트엔드가 다른 함수로 바꾼 호출의 타입은 `tree.Func.result_type`으로 찍습니다(PostgreSQL `now()`은 `strftime()`이라 텍스트이지만 `timestamp with time zone`, MariaDB `NOW(3)`, SQL Server `GETDATE()`, Oracle `SYSDATE`).
    - PostgreSQL의 공통 타입에서 문자열 상수는 자기 타입이 없습니다(`Rules.unknown_strings`, PostgreSQL의 unknown): `coalesce(j, '{}')`, `CASE ... THEN j ELSE '[]' END`, `UNION`의 열은 다른 값들의 타입이고 모두 문자열이면 text입니다.
  - 방언의 선택(`Rules.overload`, `Rules.order_collation`): `typeTree()`가 노드마다, 피연산자의 타입을 매긴 뒤 노드 자신의 타입을 매기기 전에 부릅니다(프론트엔드가 타입을 찍은 노드도). 피연산자 타입으로 연산자와 함수를 고르는 자리입니다(PostgreSQL의 `overload.zig`: 산술·비트 연산자를 연산자 표로, `jsonb`의 `||`를 `xq_pg_jsonb_concat()`으로, `->`를 jsonb의 함수로, jsonb와 interval 비교에 collation, JSON을 만드는 함수의 인자를 감쌈). 바꿀 수 있는 것:
    - PostgreSQL의 연산자 표(`operators.zig`)는 `pg_operator`처럼 행마다 연산자, 피연산자 타입, 결과 타입, 구현(엔진의 연산 코드이거나 같은 인자의 엔진 함수)을 둡니다. 해석은 PostgreSQL의 순서입니다: 정확히 맞는 행(문자열 상수는 다른 쪽의 타입으로 봄), 암시적 캐스트로 맞는 행들 중 정확히 맞는 자리와 선호 타입이 많은 행, 문자열 상수 자리의 타입 범주. 엔진 함수의 행이면 연산자를 호출로 바꾸고(`date + 1` → `xq_pg_date_pli(d, 1)`), 연산 코드의 행이면 그대로 두며 정수와 만난 문자열 상수만 그 정수의 입력 함수로 감쌉니다(`xq_pg_int4('a')`). 맞는 행이 없거나 여럿이면 문장을 실패시킵니다(`operator does not exist: date + text` 42883, `operator is not unique` 42725). 타입을 모르는 피연산자가 있으면 표를 보지 않으므로 SQLite 테이블의 열을 쓰는 식은 SQLite의 연산 그대로이고, 매개변수와 NULL은 어느 타입과도 맞되 실패시키지 않습니다. 연산 코드 행의 결과 타입(정수의 폭, `numeric`의 스케일)은 여전히 `Rules.operator`가 셈하고, 엔진 함수의 결과 타입은 `Rules.function`이 그 함수 이름으로 표에서 읽습니다(뷰의 텍스트에 남은 호출도 같은 타입).
    - 같은 종류(스칼라, 집계, 윈도우)의 다른 함수로 이름만 바꿈(`Ctx.rename()`): 해석 뒤의 코드 생성·집계 분석·상수 판단은 모두 이름과 인자 수로 FuncDef를 다시 찾으므로 이름만 바꾸면 됩니다. 집계/윈도우 여부, `NC_HasAgg`, 집계 깊이는 해석 때 정해졌으므로 종류가 같아야 하고, 윈도우 함수는 `Window.w_func`도 바꿉니다.
    - 연산자를 호출로(`Ctx.toCall()`), 피연산자를 호출이나 `COLLATE`로 감쌈(`Ctx.call()`, `Ctx.collate()`): 새 호출은 해석기가 호출에 하는 일 중 FuncDef로 정하는 부분(`resolve.applyFuncDef()`: 권한 검사, 서브타입 인자 `EP_SubtArg`, `EP_ConstFunc`, 쓸 수 있는 곳)을 거치고(`resolve.resolveNewCall()`), 감싼 인자의 `EP_SubtArg`를 이어받습니다. 바꾼 노드 위로는 높이를 다시 셉니다. 같은 식을 내리기 전에 바꿨을 때와 바이트코드가 같습니다(PostgreSQL 테스트의 모든 문장으로 확인).
    - 문장을 실패시킴(`Ctx.fail()`: `json || json`).
    - `ORDER BY`(질의, 집계 안, 윈도우)는 항의 타입으로 collation을 고릅니다(`Rules.order_collation`, jsonb는 `xq_pg_jsonb`). 결과 열 번호·별칭인 항은 그 열로 바뀐 뒤에(`resolveOrderGroupByTerms`의 끝), 복합 질의의 항은 열 번호가 된 뒤 그 열의 공통 타입으로(`resolveCompoundOrderBy` 다음), 식인 항은 해석 직후(collation이 붙은 항은 결과 열과 같은 식이 아님).
    - 한 노드를 여러 번 볼 수 있으므로(`typeTree()`는 해석마다 부름) 선택은 한 번만 하게 짭니다(바꾼 뒤의 모양에서는 다시 고르지 않음).
    - 스키마가 남기는 SQL(뷰의 질의, 트리거의 프로그램: `Parse.xq_schema_text`)에서는 고르지 않습니다. 그 텍스트는 어느 방언에서나 적힌 뜻이어야 하므로, 방언이 고른 것은 텍스트에 함수로 적습니다(PostgreSQL의 `ddltype.zig`: 뷰·CHECK·생성 열·식 인덱스의 식을 따로 내려 해석만 해 보고(`lower.Origins`로 트리와 짝지음) 코어의 선택을 트리에 되돌린 뒤 렌더링).
  - 매개변수(`TK_VARIABLE`): 타입을 아는 피연산자와 비교·연산하면(`a = ?`, `? + 1`, `x BETWEEN ? AND ?`, `x IN (?, ?)`, `CASE x WHEN ? ...`) 그 타입을 받습니다(`typeTree()`의 `inferParams`). `INSERT VALUES`(복합 VALUES와 `INSERT ... SELECT`의 각 항 포함)와 `UPDATE SET`에서 열에 저장되는 매개변수는 그 열의 타입입니다(`typing.assign()`: 프론트엔드가 저장 값을 감싸는 함수 `xq_coerce`, `xq_tsql_store`, `xq_ora_coerce`(`Rules.store_wrappers`)를 지나서). 방언의 선택이 다른 타입의 행을 고르면(PostgreSQL의 `ts + $1`은 `timestamp + interval`) 그 타입으로 바꿉니다(`typing.retypeParam()`). 번호마다 처음 정해진 타입을 `Parse.xq_param_types`에 모아 `makeReady()`에서 `Vdbe.xq_param_types`에 값으로 둡니다(`engine.paramType()`, Zig API `Stmt.parameterType()`). 와이어 서버의 확장 질의(PostgreSQL `ParameterDescription`)가 쓸 자리입니다.
  - 결과 열(`generateColumnTypes`): 선언 타입은 테이블 열의 것이 먼저이고, 없으면 `xq_type`의 철자입니다. 복합 질의의 열은 모든 항의 공통 타입입니다(`typing.columnOf()`; SQLite의 선언 타입처럼 맨 왼쪽 항이 테이블 열이면 그 선언 타입이 철자). 타입은 `Vdbe.xq_col_types`에 값(`types.Type`)으로 둡니다(`engine.resultType()`). 값이라 연결의 표와 무관하고, 재컴파일(`aux.swap`)은 새로 계산한 것으로 바꿉니다.
- `TypeId`: 매개변수 없는 타입은 `Logical`마다 고정 id(`typing.plain()`, 철자 `boolean`, `integer`, `numeric` ...)이고, 그 밖(매개변수가 있는 `numeric(10,2)`, `varchar(20)`, 방언의 다른 철자 `int4`, `DECIMAL(6,2)`, `SIGNED`)은 연결의 표(`ConnState.types`, `typing.Interner`)에 (방언, 철자)로 넣습니다. 표는 `Type`과 철자를 갖고 있어 선언 타입이 프론트엔드의 텍스트와 바이트 단위로 같습니다. 표는 늘기만 하고 연결과 함께 해제되므로, 스키마만큼 사는 식(CHECK, 생성 열, 인덱스 식)이 id를 들고 있어도 안전합니다.
- 복합 질의(서브쿼리·CTE·뷰의 복합 포함)는 항들의 공통 타입입니다. 공통 타입이 없으면 모름입니다(`SELECT a = b ... UNION ALL SELECT 2`는 불리언이 아니라 저장된 대로 보임; PostgreSQL은 오류). 재귀 CTE의 재귀 항 안에서 CTE 자신의 열은 모름입니다(서브쿼리가 아니라 CTE 테이블이므로). 그래서 재귀 항이 그 열로 계산하면(`SELECT x + 1 FROM r`) 바깥에서 본 CTE의 열도 모름입니다.
- 타입으로 연산자를 고르는 방언에서는 같은 트리라도 내린 문장이 실패할 수 있습니다(PostgreSQL의 `boolean + integer`). 다른 방언이 만든 뷰의 SQLite 텍스트는 그 방언의 문장에서도 타입으로 고르지 않으므로 SQLite의 뜻대로 계산됩니다. 같은 식이라도 트리를 내린 것, 그 텍스트를 컴파일한 것, 스키마의 텍스트를 타입 없이 읽은 것의 타입이 다를 수 있으므로, IR 퍼저(`src/ir/fuzz.zig`)는 한쪽만 `operator does not exist`/`operator is not unique`로 실패하는 것을 차이로 보지 않습니다.
- 아직 없는 것: 해석 뒤에 새로 만든 노드(윈도우 재작성, `substExpr`의 래퍼)로의 타입 복사, 열 타입에 따른 json/jsonb 저장 값의 정규화를 코어에서(아직 `jtype.zig`가 내리기 전에 감쌈), 프론트엔드가 내리지 않고 지운 캐스트(뷰 텍스트의 `CAST(round(x,s) AS NUMERIC)`)의 타입. SQL Server의 `COUNT_BIG()`은 `count()`로 내려가 `int`입니다.

#### 타입을 읽는 코드 생성

방언의 문장(`typing.active()`)에서만, 타입이 요구하는 곳만 바이트코드가 달라집니다. SQLite 방언의 식에는 타입이 없고 테이블에는 저장 함수가 없으므로 SQLite의 바이트코드는 그대로입니다(EXPLAIN으로 비교).

- 정수 산술의 폭: `+ - * / %`와 단항 `-`(`0 - x`)의 타입이 64비트보다 좁은 정수이고 방언이 그 폭에 오류를 두면(`dialect.Arith`의 `int1`/`int2`/`int4`, `Arith.width()`) 코드 생성(`expr_code.zig`, `typing.arithWidth()`)이 `OP_Add` ... `OP_Remainder`의 P5에 폭(1 `int1`, 2 `int2`, 3 `int4`)을 적습니다. SQLite는 이 연산들의 P5를 쓰지 않습니다. 실행(`arith.zig`의 `opArith`)은 정수 결과를 낼 때 P5가 0이 아니면 범위를 보고, 밖이면(64비트를 넘으면 그 폭의 오류로) 방언의 오류를 냅니다. 성공 경로의 비용은 P5 비교 하나입니다.
  - PostgreSQL: `smallint`/`integer`(`integer + integer`, `smallint + smallint`; `integer + bigint`는 `bigint`라 검사 없음). 32비트 정수 리터럴은 `integer`이므로 `SELECT 2147483647 + 1`도 오류입니다(코어는 상수를 접지 않고, 상수 식은 프로그램 앞에서 한 번 계산될 뿐 같은 연산 코드). `sum()`은 `bigint`/`numeric`이라 검사 없음.
  - SQL Server: `tinyint`(0..255), `smallint`, `int`. `SUM()` of `int`도 `int`이므로, 집계 결과를 읽을 때 `0 + sum`을 그 폭으로 계산해 검사합니다(`TK_AGG_FUNCTION`, 이름이 `sum`인 것만).
  - MariaDB(`INT` 연산은 `BIGINT`)와 Oracle(`NUMBER`)에는 폭이 없습니다.
  - 매개변수의 타입은 추론한 것입니다(`$1 + a`에서 `a`의 `integer`). 클라이언트가 매개변수에 더 넓은 타입을 지정해도(PostgreSQL 확장 질의의 `int8`) 아직 반영하지 않습니다.
  - 뷰와 트리거 본문은 그것을 쓰는 문장 안에서 다시 해석되므로 그 문장 방언의 타입과 폭을 씁니다(PostgreSQL 문장이 읽는 뷰의 `a + 1`도 `integer out of range`). CHECK, 생성 열, 인덱스 식은 스키마를 읽을 때 해석되어(`init.busy`) 타입이 없으므로 64비트로 계산하고, 오류는 `Hooks.arith`의 0으로 나누기·64비트 넘침만입니다.
- 저장 함수: `Rules.store(type)`가 그 타입(카탈로그의 열 타입, `catalog.metaOf()`) 열에 저장하는 값이 지날 함수(인자 하나의 `FuncDef`)를 줍니다. `INSERT`(VALUES, 복합 VALUES, `INSERT ... SELECT`, 기본값이 아닌 값)와 `UPDATE SET`(`ON CONFLICT DO UPDATE` 포함)이 값을 레지스터에 넣은 직후, 트리거·생성 열·제약 검사 전에 `OP_Function` + `OP_Move`로 바꿉니다(`insert.codeStore()`, `typing.storeFunctions()`). 타입을 아는 값(숫자, 불리언 식, 같은 타입의 열)은 지나지 않고(`typing.storeNeeded()`), 매개변수와 타입을 모르거나 문자열인 값만 지납니다. 그래서 텍스트로 바인딩한 매개변수(와이어 프로토콜이 보내는 값)도 읽힙니다.
  - PostgreSQL: `date`, `time`, `timestamp`, `timestamptz`, `interval`은 그 타입의 캐스트 함수(`xq_pg_date` ...: PostgreSQL의 입력을 읽어 출력 텍스트로, `timestamptz`는 UTC, `'2 hours'`는 `02:00:00`; 아니면 `invalid input syntax for type date: "x"` 22007). `boolean`은 `xq_pg_store_boolean`(`'t'`, `'yes'`, `'on'`, `'1'` ...과 그 접두어, 대소문자·앞뒤 공백 무시; 아니면 `invalid input syntax for type boolean: "x"` 22P02), `numeric`은 `xq_pg_store_numeric`(`'1.50'` → 1.5, `'3'` → 3; 아니면 `invalid input syntax for type numeric: "x"` 22P02). 문자열이 아닌 값은 그대로 두고 열의 CHECK가 봅니다.
  - MariaDB(`xq_coerce`), SQL Server(`xq_tsql_store`), Oracle(`xq_ora_coerce`)은 프론트엔드가 저장 값을 이미 감쌉니다(`Rules.store_wrappers`). SQL Server `bit`의 `'true'`/`'false'`, Oracle `BOOLEAN`의 `'yes'`/`'no'`도 그 함수들이 읽습니다.

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
| `constraint:<종류>:<열>,...` | 사용자가 이름을 준 UNIQUE·PRIMARY KEY·FOREIGN KEY 제약의 이름(테이블 항목, `col`은 `''`). 방언의 제약 위반 오류에 씀([제약 위반](#제약-위반)) |

방언 고유 키는 `pg.`, `mariadb.`, `oracle.` 접두사를 씁니다.

### 엔진 쪽 API

| 언제 실행되나 | 함수 |
| --- | --- |
| 문장 안에서(코드 생성, 그 문장의 트랜잭션) | `catalog.codeSet(p, "main", tbl, col, key, value)`, `codeDeleteTable`, `codeRenameTable`, `sequence.codeCreate(p, "main", name, .{ .start, .increment, .min, .max, .cycle }, if_not_exists)`, `sequence.codeDrop`, `sequence.nextvalExpr(p, name)` |
| 지금 바로(열린 트랜잭션 안, 없으면 호출마다 autocommit) | `catalog.set/get/deleteTable`, `sequence.create/drop/nextval/currval/setval/lastval` |

`sequence.nextvalExpr()`는 identity 열의 DEFAULT나 INSERT 보완에 씁니다.

### 메모리의 카탈로그

컴파일 중에 카탈로그를 읽는 곳(프론트엔드, `lower.zig`의 identity, `display.Columns`)은 `xq_catalog`를 질의하지 않고 `catalog.meta(db, schema, tbl)`(또는 `metaOf(db, t)`)의 `TableMeta`를 씁니다(`src/catalog/meta.zig`).

- `TableMeta`: 테이블의 방언(`dialect`, `dialect_name`), 테이블 collation, 열마다 `ColumnMeta`(선언 타입 `decl_type`과 그것을 읽은 `types.Type`, `identity`, `identity_kind`, `collation`, `default`), 방언 고유 키를 위한 항목 전체(`entries`, `value(col, key)`). 열 이름은 SQLite처럼 대소문자를 무시합니다.
- 데이터베이스(`Schema`)마다 처음 쓸 때 그 데이터베이스의 `xq_catalog` 전체를 질의 하나로 읽어 `Schema.xq_meta`에 둡니다. 카탈로그는 작고, 읽는 문장은 대부분 테이블마다 읽으므로 테이블별 질의보다 쌉니다. 항목이 없는 테이블도 질의 없이 답합니다.
- 버리는 때: 스키마를 버릴 때(`build.schemaClear()`: 다시 읽기, 다른 연결의 스키마 변경, 스키마를 바꾼 트랜잭션의 롤백, DETACH, 닫기), 메모리의 스키마 쿠키가 읽을 때와 다를 때(이 연결의 모든 DDL), 이 연결이 `xq_catalog`에 쓸 때(`OP_SqlExec`로 실행되는 `code*()`, `set()`, `deleteTable()`. Oracle의 `COMMENT ON`처럼 스키마가 바뀌지 않는 쓰기), 그렇게 쓴 트랜잭션·세이브포인트·문장의 롤백(`ConnState.catalog_written`, SQLite의 `DBFLAG_SchemaChange`와 같은 방식).
- 보지 못하는 것: 응용이 SQL로 직접 쓴 `xq_catalog` 행, 다른 연결·프로세스가 스키마를 바꾸지 않고 쓴 행. 그 데이터베이스의 다음 스키마 변경 뒤에 보입니다.
- `TableMeta`는 버려질 때까지 유효합니다. 컴파일하는 동안만 쓰고, 문장을 실행한 뒤까지 들고 있지 않습니다(남길 문자열은 복사).

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

구현은 메서드 표를 손으로 채우지 않습니다. 구체 타입을 받는 `pub` 메서드(`pub fn read(f: *MemFile, buf: []u8, offset: u64) Error!usize`)를 쓰면 `&vfs.FileImpl(MemFile).vtable`이 표를 컴파일 시점에 만들고, 타입 지운 포인터를 되돌리는 호출은 인라인됩니다. 선택 메서드를 선언하지 않으면 null로 남고, 필수 메서드가 없으면 컴파일 오류입니다. 표는 타입마다 하나라 주소로 구현을 알아볼 수 있고(memdb), `FileImplWithout(T, &.{"shmMap", ...})`은 선언된 메서드를 빼고 만듭니다(crash VFS의 공유 메모리 없는 변형).

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
| `corrupt` | 손상을 찾은 위치(아래) |
| `sqlite_version_number` | 페이저가 파일 헤더에 쓰는 `SQLITE_VERSION_NUMBER`. `src/root.zig`가 다시 내보냄 |

한 파일은 한 모듈에만 속할 수 있으므로, 엔진과 스토리지가 함께 쓰는 파일 형식 코드(`record`, `varint`)는 이 패키지에 두고 엔진은 `@import("xqlite_storage").varint` 식으로 가져옵니다. 공개 Zig API(`xqlite.pager`, `xqlite.pcache`, `xqlite.btree`, `xqlite.record`, `xqlite.varint`)는 `src/root.zig`가 다시 내보내므로 그대로입니다. 패키지 디렉터리에서 `zig build test`를 하면 스토리지 테스트(B-tree, 페이저, WAL, 저널)만 돌고, `zig build bench`(루트에서는 `zig build bench-btree`)는 B-tree 커서 벤치마크(`pkg/storage/bench/btree.zig`)를 돌립니다. B-tree 테스트의 픽스처는 `pkg/storage/src/testdata`에 있습니다(`xqt gen fixtures`).

**손상 보고와 검사.** 스토리지 층에서 파일이 손상된 것을 찾는 곳은 모두 `error.Corrupt`를 그냥 돌려주지 않고 `corrupt(@src())`(페이지를 알면 `corruptPage(pgno, @src())`)를 돌려줍니다(`pkg/storage/src/corrupt.zig`, SQLite의 `SQLITE_CORRUPT_BKPT`·`SQLITE_CORRUPT_PAGE`). 오류는 같고, 훅 `corrupt.hook`이 있으면 소스 위치와 페이지를 받습니다. C ABI는 이 훅을 `SQLITE_CONFIG_LOG` 로거로 보내므로(`database corruption page 2 at line 268 of [page.zig]`), SQLite처럼 로그에서 어느 검사가 걸렸는지 보입니다. 모델 퍼저는 위치를 출력합니다.

`corrupt.never_corrupt`(`SQLITE_TESTCTRL_NEVER_CORRUPT`, 테스트 빌드의 기본값은 켜짐)가 켜져 있고 런타임 안전 검사가 있는 빌드이면, SQLite가 `CORRUPT_DB`로 감싼 디버그 검사가 돕니다. 손상된 파일이면 실패할 수 있는 검사들입니다. 커서가 캐시한 셀 정보(`assertCellInfo`), 부모 페이지의 자식 포인터(`assertParentIndex`), `at_last` 표시(`cursorIsAtLastEntry`), `editPage`가 만든 셀, `fillInCell`이 쓴 셀, 빠른 `cellSize`와 전체 파싱의 일치, 밸런싱 뒤의 포인터 맵(`ptrmapCheckPages`, SQLite에서는 `#if 0`)을 확인합니다. ReleaseFast에서는 comptime에 빠집니다. 손상된 파일을 다루는 테스트와 `btree_corrupt` 퍼저는 이 검사를 끕니다.

B-tree 층(`pkg/storage/src/btree/`)은 btree.c를 파일 몇 개로 나눕니다. `Btree`와 `Cursor`는 서로의 내부 메서드를 많이 부르므로 `btree.zig`에 함께 두고, 따로 떨어지는 부분은 `*Btree`를 받는 함수로 다른 파일에 둡니다. `btree.zig`가 그 함수들을 비공개 별칭(`const allocatePage = alloc.allocatePage;`)으로 메서드처럼 부르고 다시 내보내지 않으므로 엔진이 보는 API는 그대로입니다.

## 공용 패키지

어느 층의 것도 아니면서 스토리지 패키지와 엔진이 함께 쓰는 도우미, 그리고 엔진의 것이지만 엔진의 다른 코드가 필요 없는 도우미는 `pkg/base/`(모듈 이름 `xqlite_base`)에 있습니다. `std`만 import하고, 루트와 스토리지 패키지가 경로 의존성으로 받습니다. 엔진은 `@import("xqlite_base").ctype` 식으로 가져옵니다.

| 이름 | 내용 |
| --- | --- |
| `thunk` | 콜백 클로저. 엔진이 넘기는 콜백(busy handler 등)과 스토리지가 받는 타입이 같아야 함 |
| `status` | `sqlite3_status()` 카운터와 `SQLITE_CONFIG_MEMSTATUS`. 페이지 캐시와 엔진의 할당자가 함께 셈 |
| `fuzz` | 시드 퍼저의 도우미(시드 파싱, swarm testing). `src/fuzz_tests.zig`, IR 퍼저, B-tree 퍼저가 씀 |
| `ctype` | SQLite의 로캘 독립 문자 분류(`sqlite3CtypeMap`, `sqlite3Isxxx`), 대소문자 무시 비교 |
| `numeric` | 수와 텍스트 사이 변환(util.c의 `sqlite3AtoF()`, `sqlite3FpDecode()` 등). `xqlite.numeric`으로도 내보냄 |
| `hash` | SQLite `Hash`(hash.c)의 원소 순서. 스키마 해시를 C와 같은 순서로 돌 때 씀 |
| `flags` | 비트 플래그 집합(bool의 packed struct)에 공통인 연산 |
| `cast` | Zig 0.17의 좁히는 캐스트 오컴파일(ziglang/zig#37127)을 피하는 캐스트 |

`zig build test-pkg`는 세 패키지(`pkg/vfs`, `pkg/storage`, `pkg/base`)의 테스트만 엔진 없이 빌드해 돌립니다.

## 소스 파일

| 파일 | 내용 |
| --- | --- |
| `src/dialect/dialect.zig` | `Dialect`(`sqlite`, `postgres`, `mariadb`, `mssql`, `oracle`), `Frontend`, `Hooks`, `Lang`, 연결별 상태(`ConnState`), 디스패치 |
| `src/dialect/func.zig` | 방언 함수 테이블을 만드는 생성자(`scalar`, `aggregate`, `overloads`, `typed`)와 `bind`, `withArena` |
| `src/dialect/{calendar,json_text,words,lex,template,tokenized,shared_funcs}.zig` | 방언들이 함께 쓰는 것: 그레고리력 날짜 계산, JSON 문자열 이스케이프(방언별 차이는 comptime 옵션), 예약어 집합(접힌 대소문자를 컴파일 시점에 검사), 따옴표 토큰 스캔, 카탈로그 뷰 템플릿(`{key}`를 컴파일 시점에 검사), 문장을 먼저 토큰화하는 프론트엔드의 `run`, MariaDB와 MSSQL이 같은 뜻으로 쓰는 수학·문자열 함수(`LEFT`, `REPLICATE`, `ROUND` ...). 어느 방언 디렉터리에도 속하지 않으므로 `-Ddialects=`로 방언을 빼도 그대로입니다 |
| `src/dialect/{sqlite,postgres,mariadb,mssql,oracle}/frontend.zig` | 방언마다 `frontend`와 `hooks` |
| `src/dialect/constraint.zig`, `src/dialect/*/constraints.zig` | 제약 위반의 방언 문구와 `ErrorState`(`Hooks.constraint`, [제약 위반](#제약-위반)) |
| `src/dialect/postgres/*.zig` | PostgreSQL 프론트엔드([PostgreSQL 호환](postgres.md)) |
| `src/dialect/mariadb/*.zig` | MariaDB 프론트엔드([MariaDB 호환](mariadb.md)) |
| `src/dialect/mssql/*.zig` | MSSQL(T-SQL) 프론트엔드([MSSQL 호환](mssql.md)) |
| `src/dialect/oracle/*.zig` | Oracle 프론트엔드([Oracle 호환](oracle.md)) |
| `src/ir/ir.zig` | IR 빌더 파사드: `stmt`, `expr`, `list`, `from`, `select`, `with`, `window`, `dml`, `ddl`, `txn`, `admin`. 각 항목은 대응하는 C 함수(`sqlite3PExpr`, `sqlite3StartTable` ...)의 별칭이거나 parse.y에서 옮긴 도우미 |
| `src/ir/tree.zig` | 구문 트리 IR과 의미 노드 (아래) |
| `src/ir/lower.zig` | `Lowerer.init(p, src)`, `statement(stmt)`(DDL 포함), `expr()`, `select()`; DML 기본값·identity, DDL의 카탈로그 기록; `Origins`(내린 식과 트리의 짝) |
| `src/ir/render.zig` | `render.select(p, src, s)`, `render.expr()`, `render.statement()`(CREATE TABLE/INDEX/VIEW, ALTER TABLE)와 `Renderer` |
| `src/ir/test.zig`, `fuzz.zig`, `gen.zig` | render ≡ lower 테스트와 퍼저 |
| `src/catalog/catalog.zig`, `meta.zig`, `sequence.zig`, `schema.zig` | 방언 메타데이터와 메모리의 카탈로그([메모리의 카탈로그](#메모리의-카탈로그)), 시퀀스, 이름 붙은 스키마([스키마](#스키마네임스페이스)) |
| `src/sql/types.zig` | 방언과 무관한 타입(`Type`, `Logical`, `parse()`, `ofKind()`). 엔진의 것이고 `xqlite.types`로 내보냄 |
| `src/sql/typing.zig` | 식의 타입(`Expr.xq_type`의 `TypeId`, 고정 id와 연결의 `Interner`, `ofOp()`, 방언 규칙의 틀 `Rules`와 `typeTree()`, 규칙이 고르는 오버로드의 도구 `Ctx.rename()`·`toCall()`·`call()`·`collate()`, 공통 타입, 매개변수 타입)([코어의 타입](#코어의-타입)) |
| `src/dialect/*/typing.zig` | 방언의 타입 규칙(`Hooks.typing`): 리터럴, 연산자, 함수의 반환 타입 |
| `pkg/vfs/build.zig`, `build.zig.zon` | VFS 패키지(`xqlite_vfs`): 모듈과 `zig build test`. 루트 빌드가 경로 의존성으로 받음([VFS 패키지](#vfs-패키지)) |
| `pkg/vfs/src/root.zig` | 패키지 루트: 인터페이스와 구현의 이름, `temp_directory`(`sqlite3_temp_directory`) |
| `pkg/vfs/src/vfs.zig` | VFS 인터페이스(`Vfs`, `File`, 잠금, 공유 메모리), `OsVfs`, 타입 있는 메서드로 메서드 표를 만드는 `FileImpl`/`VfsImpl` |
| `pkg/vfs/src/{unix,wasi,host,mem,memdb,inproc,crash}.zig` | VFS 구현([VFS](#vfs)의 표) |
| `src/sql/memdb.zig` | 엔진의 memdb 인스턴스: `Memdb(malloc)` |
| `pkg/storage/build.zig`, `build.zig.zon` | 스토리지 패키지(`xqlite_storage`): 모듈과 `zig build test`([스토리지 패키지](#스토리지-패키지)) |
| `pkg/storage/src/pager/{pager,pcache,wal,journal}.zig` | 페이저, 페이지 캐시, WAL, 롤백 저널 |
| `pkg/storage/src/btree/btree.zig` | B-tree 층: `Btree`(열기, 잠금, 트랜잭션, 테이블)와 `Cursor` |
| `pkg/storage/src/btree/{page,header,ptrmap,integrity}.zig` | 페이지(`MemPage`, 셀 파싱, 페이지 접근), 파일 헤더, 포인터 맵, 무결성 검사 |
| `pkg/storage/src/btree/alloc.zig` | 페이지 할당: freelist, 셀의 overflow 체인 |
| `pkg/storage/src/btree/balance.zig` | 밸런싱(`balance_nonroot`를 단계별 메서드로 나눈 `Balance`, `balance_quick`, `balance_deeper`, CellArray) |
| `pkg/storage/src/btree/vacuum.zig` | auto-vacuum의 페이지 재배치 |
| `pkg/storage/src/corrupt.zig` | 손상 위치 보고와 `never_corrupt` 검사 스위치 |
| `pkg/storage/src/{record,varint}.zig` | 엔진과 함께 쓰는 레코드 형식과 varint |
| `pkg/storage/bench/btree.zig` | B-tree 커서 벤치마크(`zig build bench-btree`) |
| `pkg/base/src/{thunk,status,fuzz}.zig` | 공용 패키지(`xqlite_base`): 클로저, 상태 카운터, 퍼저 도우미([공용 패키지](#공용-패키지)) |
| `pkg/base/src/{ctype,numeric,hash,flags,cast}.zig` | 공용 패키지: 문자 분류, 수 변환, Hash 순서, 플래그 연산, 캐스트 |
| `src/dialect/disabled.zig` | 빌드에서 뺀 방언의 프론트엔드([빌드에 넣을 방언과 확장](#빌드에-넣을-방언과-확장)) |
| `tools/minimal_test.zig` | 방언·확장을 모두 뺀 엔진의 테스트(`zig build test-minimal`) |

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
