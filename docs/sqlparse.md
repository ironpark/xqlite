# SQL 파서 공통 층

방언 파서 네 개(PostgreSQL, Oracle, MariaDB, SQL Server)가 함께 쓰는 파서 층입니다. 렉서 쪽은 [sqllex 패키지](architecture.md#sqllex-패키지)이고, 이 문서는 그 위, 토큰을 받아 IR 트리(`src/ir/tree.zig`)를 만드는 쪽을 다룹니다.

방언 파서는 모두 손으로 쓴 재귀 하강 파서입니다. 방언마다 다른 것은 토큰 종류, 키워드의 대소문자, 우선순위, 오류 문구, 트리에 담는 의미(`Div`, `Concat`, `Like` 등)입니다. 이것은 방언에 남기고, 같은 것(토큰을 읽는 연산, 오류 기록, 되감기, 몇몇 문법, 문장 둘레의 처리)을 공통으로 둡니다.

## 1. 층

```
pkg/sqllex              스캐너 (std만)
pkg/sqlparse            토큰 공급원, 커서, 오류 기록, 단어 집합 (std + sqllex)
src/dialect/syntax.zig  IR 트리를 만드는 공통 문법 조각
src/dialect/driver.zig  프런트엔드 드라이버 (Frontend.run)
src/dialect/<방언>/     렉서 디스패치, 우선순위, 방언의 의미
```

나누는 기준은 IR 트리에 의존하는지입니다. 트리를 모르는 것은 패키지에 있어 엔진 없이 빌드하고 테스트합니다(`zig build test-pkg`). 트리 노드를 만드는 것과 `Parse`를 아는 것은 엔진 쪽에 있습니다.

들어가지 않는 것:

- **SQLite 방언**: `src/parse/`(lemon 문법)는 SQLite의 바이트코드와 같아야 하므로 이 층을 쓰지 않습니다. sqllex를 쓰지 않는 것과 같은 이유입니다.
- **의미 해석**: 이름 해석, 캐스트 계획, 함수 매핑은 방언의 것입니다.
- **IR 트리**: `tree.zig`가 import하는 엔진 것은 `Dialect` enum뿐이라 패키지로 옮길 수는 있습니다. 하지만 트리의 약속(`lower.zig`·`render.zig`와의 계약, `xq_*` 엔진 함수)이 엔진의 것이라 엔진에 둡니다.

## 2. `pkg/sqlparse`

### 토큰

패키지는 토큰 타입을 정하지 않고, 방언의 토큰이 가져야 할 것을 컴파일 시점에 검사합니다(`checkToken(T)`).

| 가져야 할 것 | 뜻 |
| --- | --- |
| `kind` | `eof`가 있는 enum |
| `start`, `end` | 문장 텍스트 안의 바이트 오프셋(`u32`) |
| `isKw(comptime kw)` | 따옴표 없는 키워드 `kw`인지. 방언이 비교하는 대로(PostgreSQL은 소문자, Oracle은 대문자로 접어 `eql`, MariaDB와 SQL Server는 `eqlIgnoreCase`) |
| `isOp(op)` | 연산자 `op`인지 |

`text`가 해석된 값인지(PostgreSQL, Oracle) 원문 조각인지(MariaDB, SQL Server)는 방언의 것입니다. `standard_conforming_strings`나 sql_mode가 렉서에 걸려 있기 때문입니다. eof 토큰은 되풀이됩니다. eof 뒤로 나아가도 eof에 머뭅니다.

### 토큰 공급원

| | 쓰는 방언 | 앞보기 | 되감기(`Mark`) |
| --- | --- | --- | --- |
| `Buffered(Token)` | PostgreSQL, Oracle | 미리 토큰화한 배열의 인덱스 | 인덱스 |
| `Streaming(Lexer)` | MariaDB, SQL Server | 렉서 사본을 k번 읽음 | 공급원 전체(렉서, 다음 토큰, 직전 끝)의 사본 |

- PostgreSQL과 Oracle은 문장 끝(`;`, Oracle의 `/` 줄)까지 미리 토큰화합니다. 앞보기가 실패하지 않고, 렉서 오류가 구문 오류보다 먼저 나옵니다. PostgreSQL의 `OPERATOR(pg_catalog.~)` 같은 전처리도 이 배열에 합니다.
- MariaDB와 SQL Server는 렉서를 파서가 읽는 만큼만 돌립니다. SQL Server는 세미콜론 없이 "다른 문장을 시작하는 단어 앞"에서 문장이 끝나므로 문장 끝을 렉서가 알 수 없습니다. 미리 끝까지 토큰화하면 문장이 많은 스크립트를 문장마다 다시 읽습니다.
- 스트리밍의 앞보기를 배열에 쌓는 방식으로 하지 않은 것은, 그러면 모든 `peek`가 할당 실패(`OutOfMemory`)를 돌려줄 수 있게 되기 때문입니다. 렉서 사본은 지금까지와 같은 비용입니다.

### 커서 `Cursor(Source, State, Hooks)`

방언 파서는 필드 `c` 하나로 커서를 갖고 `p.c.eatKw("from")`처럼 부릅니다. 커서에는 토큰이 든 텍스트(`sql`), 아레나(`arena`), 오류(`diag`)가 있습니다.

| 연산 | 내용 |
| --- | --- |
| `peek()`, `peekAt(k)`, `prev()` | 다음 토큰, 그 k개 뒤(0이 다음), 마지막으로 먹은 토큰(`Buffered`만) |
| `advance()`, `skip()`, `skipN(n)` | 먹기(토큰을 돌려줌 / 버림) |
| `here()`, `lastEnd()` | 다음 토큰의 시작, 마지막으로 먹은 토큰의 끝 |
| `mark()`, `reset(m)` | 되감기 |
| `atEof()`, `is(kind)`, `eat(kind)`, `expect(kind)` | 종류로 |
| `isKw`, `isKwAt`, `isAnyKw`, `eatKw`, `expectKw` | 키워드로 |
| `eatKws(.{"if", "exists"})` | 단어가 모두 이어지면 먹고 true, 아니면 아무것도 먹지 않음 |
| `optKws(...)`, `ifExists()`, `ifNotExists()` | 첫 단어가 있으면 나머지가 와야 함(없으면 오류) |
| `isOp`, `eatOp`, `expectOp` | 연산자로 |
| `eatComma()`, `list(T, ctx, item)` | 쉼표(방언에 `comma` 토큰 종류가 있으면 그것, 없으면 연산자 `,`), 쉼표로 이은 목록 |
| `fail(pos, fmt, args)`, `failState(pos, state, fmt, args)` | 오류를 기록하고 `error.ParseFailed` |
| `failedIn(&sub.c, err)` | 하위 파서(방언이 쓴 텍스트를 읽은 것)의 오류를 이 커서의 오류로(위치 없이) |
| `syntaxError()`, `missingKeyword()` | 방언의 구문 오류, 키워드가 없을 때의 오류 |

`Hooks`는 방언의 것입니다. 훅이 아닌 공개 선언이 있으면 컴파일되지 않습니다(철자가 틀린 선택 훅이 조용히 무시되지 않게).

- `syntaxError(c)`(필수): 다음 토큰에서의 구문 오류. 예: PostgreSQL `syntax error at or near "x"`, MariaDB `You have an error in your SQL syntax; ... near '...' at line N`, SQL Server `Incorrect syntax near '...'.`, Oracle `ORA-00933`/`ORA-00936`.
- `missingKeyword(c)`(선택): `expectKw()`가 실패할 때. Oracle의 `ORA-00905: missing keyword`. 없으면 구문 오류입니다.
- `missingToken(c, kind)`(선택): `expect(kind)`가 실패할 때. Oracle의 괄호와 쉼표(`ORA-00906`, `ORA-00907`, `ORA-00917`).
- `stateOfFormat(fmt)`(선택): 부르는 쪽이 오류 상태를 주지 않은 `fail()`의 상태. Oracle의 `ORA-` 번호에서 SQLSTATE를 찾습니다. 없으면 `State.ofFormat(fmt)`(엔진의 `int.ErrorState`)입니다.

`State`는 엔진의 `int.ErrorState`입니다. 패키지는 엔진을 모르므로 타입 인자로 받습니다.

### 오류 기록 `Diag(State)`

`msg`(커서의 아레나), `pos`(문장 텍스트 안의 오프셋, null이면 위치 없음), `state`, `failed`입니다. 마지막으로 기록한 오류가 남고, 파서는 오류를 기록하면 곧바로 `error.ParseFailed`로 돌아갑니다.

- 엔진에 옮기는 것은 드라이버(`driver.recordDiag`, PostgreSQL과 Oracle은 `driver.parseFailed`)입니다. `p.tail`을 바꾸기 전에 `ir.stmt.errorMsgState()`로 옮기므로 오류 위치(`sqlite3_error_offset()`)가 그대로입니다.
- `Parse`에 이미 오류가 있으면(파서가 부른 빌더나 낮추기가 남긴 것) 그것을 남깁니다. MariaDB와 SQL Server는 파싱하면서 낮추므로 이 순서가 필요합니다.
- 방언이 직접 쓴 텍스트를 하위 파서로 읽다 난 오류(MariaDB의 information_schema, SQL Server의 sys 뷰와 `OBJECT_ID()`)는 커서의 `failedIn(&sub.c, err)`가 바깥 파서의 오류로 옮깁니다. 그 위치는 바깥 텍스트에 없으므로 null입니다.

### 단어 집합 `words`

`folded(case, list)`는 렉서가 접는 대소문자(PostgreSQL 소문자, Oracle 대문자)로 비교하는 집합입니다. 그 대소문자가 아닌 단어는 컴파일되지 않습니다. `noCase(list)`는 대소문자를 가리지 않는 집합입니다(MariaDB, SQL Server). 예약어 표 자체는 방언에 있습니다.

## 3. 공통 문법 조각 `src/dialect/syntax.zig`

조각은 방언 파서 `p`(anytype)를 받는 함수입니다. `p.c`(커서)와, comptime 인자로 받은 방언의 함수(`operand`: 그 구문이 읽는 우선순위의 식)만 씁니다. 키워드는 대문자로 쓰고, 커서가 방언대로 비교합니다. 키워드가 없으면 커서의 `expectKw()`처럼 실패합니다(Oracle은 `ORA-00905`, 나머지는 구문 오류).

| 조각 | 옵션 | 방언 |
| --- | --- | --- |
| `caseExpr(p, operand)` | 없음. WHEN 없는 CASE는 키워드가 없는 오류(Oracle `ORA-00905`, 나머지는 구문 오류) | 넷 모두 |
| `sortList(p, operand, opts)` | `nulls`: NULLS FIRST/LAST와, 없을 때 큰 값처럼 정렬(PostgreSQL, Oracle). `using`: `USING <`/`>`(PostgreSQL) | 넷 모두 |
| `windowClauses(p, &w, bound, opts)` | PARTITION BY, ORDER BY(`p.exprList()`, `p.sortList()`)와 프레임 | 넷 모두 |
| `frame(p, bound, opts)`, `frameBound(p, bound)` | `groups`: GROUPS 단위(PostgreSQL, Oracle). `exclude`: EXCLUDE(SQL Server는 없음) | 넷 모두 |

윈도 이름(`OVER (w ORDER BY ...)`)과 괄호를 읽는 방법은 방언마다 달라서 방언에 남습니다. SELECT 전체, 조인, DDL도 방언 차이(TOP, ROWNUM, `(+)`, LIMIT의 여러 모양, 인덱스 힌트, 타입)가 커서 방언에 있습니다.

## 4. 드라이버 `src/dialect/driver.zig`

`dialect.Frontend.run`의 둘레입니다. 하는 일은 앞의 빈 문장(`;`, SQL Server의 `GO`)과 빈 텍스트, 방언의 `statement()` 호출, 문장 끝 확인, 오류 옮기기, `finishCoding()`, 다음 문장의 시작(`p.tail`), 방언의 문구로 바꾸기(`translateError()`)입니다.

- `run(parser, compile, translateError)`: 미리 토큰화하는 파서(PostgreSQL, Oracle). 렉서의 오류도 처리합니다.
- `streaming(F)`: 읽으며 가는 파서(MariaDB, SQL Server). `F`는 방언의 `frontend.zig` 자체(`driver.streaming(@This())`)로, `Parser`, `init`, `separator`(문장을 끝내는 토큰), `statement`, `translateError`를 주고, 선택적으로 `begin`(MariaDB: 경고 지우기, SQL Server: 앞서 컴파일한 CREATE SCHEMA의 요소)과 `end`(SQL Server: 같은 CREATE SCHEMA의 요소가 더 있는지)를 줍니다.

## 5. 검증

이 층은 리팩터링으로 들어왔습니다. 오류 문구, 위치, SQLSTATE, 결과 열 이름, 만들어지는 트리가 바이트 단위로 같아야 합니다. 그래서 다음을 확인했습니다.

- `zig build check`: `dialect-diff pg` 기록, `xqt interop` 전체, planner, fuzzcheck.
- 옮기기 전 커밋으로 빌드한 바이너리와 출력을 견주는 비교. 오류를 내는 문장, 윈도·CASE·ORDER BY, 여러 문장 입력을 네 방언에서 실행해 셸의 출력(오류 위치 표시 포함)이 같은지 봤습니다.

## 6. 남은 것

- **우선순위**: `orExpr` → `andExpr` → `notExpr` → ... 의 사슬도 모양은 같으므로 표로 쓰는 우선순위 파서(Pratt)를 생각할 수 있습니다. 하지만 단계마다 붙는 의미(MariaDB의 `/`는 `Div .real`, SQL Server의 `+`는 피연산자 타입으로 결정, Oracle의 날짜 산술)가 커서, 표가 함수 포인터 모음이 됩니다. 지금은 두지 않았습니다.
- **더 옮길 수 있는 조각**: `WITH` 절의 틀, `ON`/`USING`, 괄호 친 이름 목록. 방언마다 이름을 읽는 방법(`colId`, `name`, `anyName`)이 달라 그 차이를 옵션으로 받아야 합니다.
