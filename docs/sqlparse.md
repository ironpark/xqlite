# SQL 렉서·파서 공통 층

다섯 방언(SQLite, PostgreSQL, Oracle, MariaDB, SQL Server)의 SQL 텍스트를 토큰으로 나누고 문장으로 읽는 층입니다. 렉서는 `pkg/sql/lexer`(`@import("sql/lexer")`), 파서의 틀은 `pkg/sql/parse`(`@import("sql/parse")`)이고, IR 트리와 엔진에 의존하는 것은 `src/dialect/`에 있습니다.

> 이 문서는 리팩터링의 설계와 그 결과입니다. 설계와 다르게 된 곳은 각 절에 적었고, 진행은 [7. 단계](#7-단계)에 있습니다.

## 0. 배경

xqlite는 SQLite 3.54.1에서 멈추고 더 이상 업스트림을 따라가지 않습니다. 예전에 SQLite 방언이 공통 층을 쓰지 않은 이유는 lemon 문법(`src/parse/grammar.zig`, `parser.zig`)과 `tokenize.zig`를 업스트림 그대로 다시 생성할 수 있게 두기 위해서였습니다. 그 이유가 없어졌으므로 SQLite 방언도 공통 렉서 위의 손으로 쓴 파서로 옮겼고, `src/parse/`는 없어졌습니다.

남는 약속은 [AGENTS.md](../AGENTS.md)의 것입니다. SQLite 방언의 **바이트코드와 파일 형식은 SQLite와 같아야** 합니다. 이번 리팩터링에서는 다음 넷이 바이트 단위로 그대로여야 합니다.

- 만들어지는 VDBE 프로그램
- `sqlite_schema`에 저장되는 CREATE 텍스트
- 오류 문구와 위치(`sqlite3_error_offset()`)
- 공개 API(`sqlite3_complete()`, `sqlite3_keyword_*()`)

목표는 세 가지입니다.

1. **SQL에 특화된 일반화**: 토큰 종류, 따옴표, 문자열 접두사, 파라미터, 키워드 같은 SQL의 어휘 구조를 패키지가 압니다. 방언은 그것을 선언(spec)으로 고르고, 정말 특이한 것만 코드로 씁니다.
2. **한 가지 토큰**: 다섯 방언이 같은 `Token`을 씁니다. 커서, 공통 문법 조각, 우선순위 파서가 그 토큰 위에서 한 번만 구현됩니다.
3. **한 가지 파서 방식**: 다섯 방언 모두 손으로 쓴 재귀 하강 파서입니다. 네 방언의 식은 표로 쓰는 우선순위 파서(Pratt)로 읽습니다(SQLite는 [5.3](#53-파서)). lemon, `grammar.zig`, `tools/parser/lemon2zig.zig`, `xqt gen parser`는 없어졌습니다.

## 1. 층

```
pkg/sql/lexer            토큰, 선언형 렉서 Lexer(spec), 키워드 표, 값 해석, 스캐너 (std만)
pkg/sql/parse            토큰 공급원, 커서, 오류 기록, 우선순위 파서 (std + sql/lexer)
src/dialect/syntax.zig   IR 트리를 만드는 공통 문법 조각
src/dialect/driver.zig   프런트엔드 드라이버 (Frontend.run)
src/dialect/<방언>/      lexer.zig: spec와 훅, 키워드 표
                         parser.zig: 문법, 연산자 표, 트리에 담는 의미
```

나누는 기준은 지금과 같습니다. IR 트리를 모르는 것은 패키지에 있어 엔진 없이 빌드하고 테스트합니다(`zig build test-pkg`). 트리 노드를 만드는 것과 `Parse`를 아는 것은 엔진 쪽에 있습니다.

SQLite 방언은 `src/dialect/sqlite/`(`lexer.zig`, `parser.zig`, `normalize.zig`)에 있습니다. 엔진 곳곳이 쓰는 `TK_*` 코드는 파서와 상관없는 엔진의 상수(`src/sql/tk.zig`)입니다(아래 [5.1](#51-tk-코드와-키워드-api)).

## 2. 렉서 `pkg/sql/lexer`

### 2.1 토큰

```zig
pub fn TokenOf(comptime Keywords: type) type {   // 방언의 키워드 표(없으면 void)
    return struct {
        kind: Kind,
        /// kind의 세부(문자열 접두사, 파라미터 모양, 숫자 진법, illegal의 까닭).
        sub: Sub = .none,
        /// 따옴표 없는 단어면 방언 키워드 표의 번호(1부터), 아니면 0.
        kw: u16 = 0,
        /// 문장 텍스트 안의 바이트 범위. 토큰의 원문은 sql[start..end].
        start: u32,
        end: u32,
        // isKw(comptime "from"), isAnyKw, isKwText(런타임 단어), isOp(sql, op), text(sql)
    };
}
```

필드는 모든 방언이 같고(12바이트), 타입만 방언의 키워드 표로 갈립니다. 그래서 `t.isKw("from")`이 컴파일 시점에 키워드 번호로 바뀌어 정수 비교가 되고, 표에 없는 단어는 컴파일되지 않습니다([2.3](#23-키워드-표)).

| `kind` | 뜻 | `sub` |
| --- | --- | --- |
| `eof` | 텍스트의 끝. 되풀이됩니다 | |
| `word` | 따옴표 없는 단어(키워드이거나 이름) | |
| `quoted_ident` | `"x"`, `` `x` ``, `[x]`, `U&"x"` | `unicode`(U&) |
| `string` | 문자열 상수 | 없음('...'), `national`(N''), `escape`(E''), `unicode`(U&''), `dollar`($tag$), `alt_quote`(Oracle q'[]'), `blob`(X''), `bits`(B'') |
| `integer`, `float` | 숫자 | 진법 `hex`, `octal`, `binary` |
| `param` | 바인드 파라미터 | `positional`(?), `numbered`($1, ?1), `named`(:x) |
| `variable` | 세션 변수 | `user`(@x), `system`(@@x) |
| `op` | 연산자와 문장 부호(아래 다섯 개 말고) | |
| `lparen`, `rparen`, `comma`, `semi`, `dot` | 자주 비교하는 문장 부호 | |
| `terminator` | `;`가 아닌 문장 끝: SQL Server의 GO 줄, Oracle의 `/` 줄 | |
| `illegal` | 토큰이 되지 못한 것 | `bad_char`, `unterminated`, `empty`, `trailing_junk`, `bad_radix`, `unicode_off`, `uescape_follow`, ... |

**`text`를 두지 않습니다.** 원문은 늘 `sql[t.start..t.end]`이고, 값은 필요할 때 해석합니다([2.4](#24-값-해석)). 예전에는 PostgreSQL과 Oracle이 렉싱하면서 값을 해석해 `text`에 두고, MariaDB와 SQL Server는 원문 조각을 두었습니다. 이 갈래가 없어져 토큰이 작아지고 렉싱에 할당이 없습니다.

**렉서 오류는 `illegal` 토큰입니다.** 렉서는 실패하지 않고 `illegal` 토큰과 그 까닭을 냅니다. 오류 문구와 위치는 방언이 정합니다(PostgreSQL `unterminated quoted string at or near ...`, Oracle `ORA-01756`, SQLite `unrecognized token: "..."`). 미리 토큰화하는 방언(PostgreSQL, Oracle)은 `illegal`을 만나면 그 자리에서 렉서 오류로 실패하므로, 렉서 오류가 구문 오류보다 먼저 나오는 동작이 그대로입니다. 스트리밍 방언은 파서가 그 토큰에 닿을 때 실패합니다.

### 2.2 선언형 렉서 `Lexer(D)`

방언의 어휘 구조는 `D.spec`(`Spec`)에 적습니다. 렉서가 첫 글자로 갈라 읽는 순서는 정해져 있고(`lexer.zig` 머리말), spec은 각 갈래를 고릅니다.

```zig
pub const Spec = struct {
    ident_start: Set, ident: Set,       // 단어의 첫 글자와 나머지
    comments: Comments,                 // --, #, /* */(중첩 여부), 닫히지 않은 주석이 illegal인지
    numbers: Numbers,                   // _ 구분자, 1..2, 진법 접두사, 꼬리(tail), 빈 진법, Oracle f/d
    quotes: []const Quote,              // ' " ` [ 와 닫는 글자, 겹친 따옴표, 백슬래시, ANSI_QUOTES 조건
    prefixes: []const Prefix,           // N'' E'' X'' B'' q'' nq'' 와 sub, 이스케이프
    string_continuation: bool,          // 줄바꿈 낀 두 문자열은 하나(PostgreSQL)
    empty_ident_illegal: bool,          // "" 는 illegal(PostgreSQL, Oracle)
    dollar_quotes: bool,                // $tag$...$tag$
    params: Params,                     // ?, ?NNN, $N, :name
    variables: bool,                    // @x, @@x
    ops: Ops,                           // 여러 글자 연산자 목록, PostgreSQL식 연산자 글자의 연속, 한 글자
    slash_line: bool,                   // Oracle의 / 줄
};
```

| 숫자 꼬리(`numbers.tail`) | 뜻 | 방언 |
| --- | --- | --- |
| `none` | 숫자에서 끝나고 다음 토큰이 시작 | Oracle, SQL Server |
| `junk` | 글자가 붙으면 `illegal`(trailing_junk) | PostgreSQL |
| `word` | 정수 뒤에 단어 글자가 붙으면 전체가 단어(`1abc`, `0x1g`) | MariaDB |
| `illegal` | 단어 글자가 붙으면 전체가 `illegal` | SQLite |

세션이 바꾸는 규칙은 런타임 옵션(`sqllex.Options`)으로 받습니다. `backslash_escapes`는 MariaDB의 `NO_BACKSLASH_ESCAPES`가 아닐 때와 PostgreSQL의 `standard_conforming_strings = off`이고, `ansi_quotes`는 MariaDB의 `ANSI_QUOTES`입니다. SQLite의 `"x"`는 늘 `quoted_ident`이고, 문자열로 바꾸는 것은 이름 해석이 합니다(SQLite의 DQS).

선언으로 담기지 않는 것은 `D`의 선택 함수(훅)입니다. `D`에 그 밖의 공개 선언이 있으면 컴파일되지 않습니다(철자가 틀린 훅이 조용히 무시되지 않게).

| 훅 | 쓰는 방언 |
| --- | --- |
| `skip(l) ?Token`: 공백과 주석 | MariaDB의 실행 주석 `/*! ... */`, `/*M!NNNNN ... */`(`State`에 열린 수) |
| `scan(l, start) ?Token`: 규칙 앞에서 읽는 토큰 | PostgreSQL의 `U&'...'`와 UESCAPE, MariaDB의 `@` 변수 |
| `word(l, t) Token`: 단어를 다른 토큰으로 | SQL Server의 GO 줄 |
| `number(l, t) Token`: 숫자를 고침 | Oracle의 19자리 넘는 정수(float) |

PostgreSQL의 `OPERATOR(pg_catalog.~)`는 렉서가 아니라 미리 토큰화한 배열에서 PostgreSQL 파서가 줄입니다.

### 2.3 키워드 표

```zig
pub const keywords = sqllex.Keywords(&.{
    .{ "select", .reserved }, .{ "abort", .unreserved }, .{ "between", .col_name }, ...
});
```

- 렉서가 `word` 토큰마다 표를 찾아 `kw`를 채웁니다(ASCII 대소문자 무시). 따옴표 친 이름은 키워드가 아닙니다.
- 파서는 키워드를 지금처럼 문자열로 씁니다(`c.eatKw("from")`). 토큰 타입이 표를 알므로 문자열은 컴파일 시점에 번호로 바뀌고, 비교는 정수 비교입니다. 표에 없는 단어는 컴파일되지 않으므로 철자가 틀린 키워드가 조용히 거짓이 되던 일이 없어집니다. 런타임 단어는 `isKwText()`입니다.
- 키워드 인자를 enum 리터럴(`.select`)로 바꾸는 것도 생각했지만, 같은 검사를 얻으면서 네 방언의 키워드 호출 수천 곳을 그대로 둘 수 있어 문자열로 두었습니다.
- 등급(`reserved`, `unreserved`, `col_name`, `type_func_name`)은 표에 함께 둡니다. 예전에 방언 파서마다 따로 있던 `reserved` 집합(`words.folded`, `words.noCase`)이 이것으로 바뀝니다.
- SQLite의 표는 mkkeywordhash가 만든 것을 대신하고, `sqlite3_keyword_name()`이 돌려주는 순서를 지키도록 목록 순서를 그대로 둡니다.

### 2.4 값 해석

패키지(`sqllex.value`)는 방언에 상관없는 해석을 줍니다.

| 함수 | 결과 |
| --- | --- |
| `name(a, sql, t, case)` | 이름. 따옴표 없는 단어는 `case`로 접고(null이면 그대로), 따옴표 친 것은 겹친 따옴표를 풉니다 |
| `plainString(a, sql, t)` | 이스케이프 없는 문자열의 값. 겹친 따옴표를 풀고 이어진 문자열을 잇습니다 |
| `segments(sql, t, escapes)` | 이어진 문자열의 조각들. 방언이 이스케이프를 풀 때 씁니다 |
| `dollarBody`, `altBody` | `$tag$` 인용과 q 인용의 본문 |
| `digits(a, sql, t)`, `decimal(a, sql, t)` | `_`를 뺀 숫자, 진법을 10진으로 바꾼 정수 |

백슬래시 이스케이프의 뜻은 방언마다 달라(PostgreSQL의 `E''`는 `\u`와 8진수, MySQL은 `\%`를 남김) 방언이 풉니다. 이스케이프의 오류(PostgreSQL의 `invalid Unicode escape` 등)는 PostgreSQL이 미리 토큰화하면서 그 문자열을 풀어 봐서 냅니다. 닫히지 않은 문자열도 끝에 닿기 전의 이스케이프 오류가 먼저이므로 같은 방법으로 냅니다.

### 2.5 스캐너

지금의 스캐너(`Scanner(spec)`, `quotedEnd`, `radixDigits`, `blockCommentEnd`, `longestOp`, 위치 함수)는 그대로 공개합니다. `Lexer(spec)`가 이것으로 만들어지고, 토큰 단위가 아닌 일을 하는 코드도 계속 씁니다. `pgcatalog.Scanner`, ALTER의 이름 바꾸기, `sqlite3_complete()`가 그런 예입니다.

## 3. 파서 틀 `pkg/sql/parse`

### 3.1 토큰 공급원과 커서

지금과 같습니다. 바뀌는 것은 토큰이 `sqllex.TokenOf(방언의 키워드 표)`가 되는 것입니다.

| | 쓰는 방언 | 앞보기 | 되감기(`Mark`) |
| --- | --- | --- | --- |
| `Buffered` | PostgreSQL, Oracle | 미리 토큰화한 배열의 인덱스 | 인덱스 |
| `Streaming(Lexer)` | MariaDB, SQL Server, SQLite | 렉서 사본을 k번 읽음 | 공급원 전체의 사본 |

SQLite는 `Streaming`입니다. 지금 `runParser()`가 문장마다 코드를 만들며 읽고, 한 텍스트에 문장이 많을 수 있기 때문입니다. 또 SQLite의 오류는 렉서 오류도 구문 오류처럼 토큰을 만나는 순서대로 나옵니다.

`Cursor(Source, State, Hooks)`의 연산은 지금과 같습니다. 키워드는 문자열 그대로이고 토큰 타입이 컴파일 시점에 번호로 바꿉니다. 원문이 필요하면 `c.text(t)`, 토큰 하나가 연산자인지는 `c.isOpTok(t, op)`입니다.

| 연산 | 내용 |
| --- | --- |
| `peek()`, `peekAt(k)`, `prev()` | 다음 토큰, 그 k개 뒤, 마지막으로 먹은 토큰 |
| `advance()`, `skip()`, `skipN(n)` | 먹기 |
| `here()`, `lastEnd()`, `text(t)` | 다음 토큰의 시작, 마지막으로 먹은 토큰의 끝, 토큰의 원문 |
| `mark()`, `reset(m)` | 되감기 |
| `atEof()`, `is(kind)`, `eat(kind)`, `expect(kind)` | 종류로 |
| `isKw("k")`, `isKwAt(n, "k")`, `isAnyKw(&.{...})`, `eatKw`, `expectKw` | 키워드로 |
| `eatKws(&.{...})`, `optKws(&.{...})`, `ifExists()`, `ifNotExists()` | 키워드 연속 |
| `isOp`, `eatOp`, `expectOp`, `isOpTok(t, op)` | 연산자로. `(` `)` `,` `;` `.`도 연산자처럼 비교됩니다 |
| `eatComma()`, `list(T, ctx, item)` | 쉼표, 쉼표로 이은 목록 |
| `isName(class)`, `name(class)` | 이름 자리에 올 수 있는 토큰. 따옴표 친 이름과, 키워드 표의 등급이 `class`가 허락하는 키워드입니다(PostgreSQL의 `ColId`, `type_function_name`, SQLite의 fallback) |
| `fail`, `failState`, `failedIn`, `syntaxError`, `syntaxErrorAt`, `missingKeyword` | 오류 |
| `enter()`, `leave()` | 재귀 깊이. 넘으면 방언의 `tooDeep` 훅으로 실패합니다 |

`Hooks`는 지금 것(`syntaxErrorAt`, `missingKeyword`, `missingToken`, `stateOfFormat`)에 하나를 더합니다.

- `tooDeep(c)`: 재귀가 너무 깊을 때의 오류

### 3.2 우선순위 파서 `pratt`

예전에는 방언마다 `orExpr → andExpr → notExpr → ... → unary → postfix → primary`의 사슬이 있었습니다. 사슬의 모양은 같고, 다른 것은 연산자의 자리와 단계마다 붙는 의미입니다. 이 둘을 나눕니다.

- **모양은 표로**: 방언은 comptime 연산자 표(`pratt.Op(Tag)`)를 줍니다. 항목은 무엇에 맞는지(키워드, 연산자 글자, 토큰 종류와 그 뒤의 토큰들), 왼쪽과 오른쪽의 결합력, 전위·중위·후위인지, 방언 enum의 태그입니다.
- **의미는 방언의 콜백으로**: 엔진(`Pratt(P, Expr, Tag, table).expr(p, min)`)은 `operand()`, `prefix(tag, m, rbp)`, `infix(tag, lhs, m, rbp)`, `postfix(tag, lhs, m)`만 부르고, 방언은 태그로 `switch`합니다. `m`(`Matched`)은 연산자의 첫 토큰과 마지막 토큰, 그 고리의 `min`입니다. 중위 연산자의 오른쪽은 방언이 직접 읽습니다(`expr(p, rbp)`). 그래서 `BETWEEN ... AND`, `IN (...)`, `IS [NOT] DISTINCT FROM`, `= ANY (...)`, `LIKE ... ESCAPE` 같은 모양도 같은 틀에 들어갑니다.

```zig
const ops = [_]pratt.Op(Tag){
    pratt.left(Tag, .@"or", 10, .{ .kw = "or" }),
    pratt.prefixAt(Tag, .not, 30, 30, .{ .kw = "not" }),                       // 조건 자리에서만
    pratt.left(Tag, .not_like, 40, .{ .kw = "not", .then = "like" }),
    pratt.postfix(Tag, .is, 40, .{ .kw = "is", .cap = 40 }),                    // IS ... 뒤에 + 못 옴
    pratt.left(Tag, .at_zone, 120, .{ .kw = "at", .seq = &.{ .{ .kw = "time" }, .{ .kw = "zone" } } }),
    pratt.left(Tag, .add, 80, .{ .op = "+" }),
    pratt.prefix(Tag, .binary, 120, .{ .kw = "binary", .unless = .{ .op = "(" } }),
    ...
};
```

SQL 문법에는 우선순위만으로 담기지 않는 것이 있어 엔진이 셋을 더 압니다. 네 방언을 옮기며 나온 것입니다.

- **전위 연산자의 자리(`prefixAt`의 `level`)**: NOT은 조건이 시작하는 자리에서만 연산자입니다. `1 + NOT x`는 식이 아닙니다. `min <= level`인 곳에서만 전위 연산자이고, 다른 곳에서는 그 토큰이 피연산자(`operand()`)로 갑니다.
- **뒤에 더 강한 연산자가 올 수 없는 모양(`cap`)**: `x IS NULL`, `x IN (...)`, `x LIKE y ESCAPE z` 뒤에는 `+`가 올 수 없습니다(`x IS NULL + 1`은 `(x IS NULL) + 1`이 아니라 오류). cap이 `c`인 연산자(정적인 `cap`이나, 콜백이 부른 `cap(c)`) 뒤에는 왼쪽 결합력이 `c` 이하인 연산자만 식을 잇습니다. 이 제한은 그 고리에서도, 그 식이 오른쪽인 바깥 고리에서도 지켜지지만, 그 뒤에 읽은 토큰(닫는 괄호)을 넘지는 않습니다.
- **여러 토큰과 음의 앞보기(`seq`, `then`, `unless`)**: `NOT LIKE`, `AT TIME ZONE`, Oracle의 `(+)`처럼 여러 토큰인 연산자와, MySQL의 `BINARY x`(그러나 `BINARY(x)`는 함수)처럼 뒤에 어떤 토큰이 오면 연산자가 아닌 것.

표에 없는 토큰에서 고리가 끝날 때는 선택 콜백 `unmatched(lhs, min, last)`를 부릅니다. PostgreSQL은 연산자 집합이 열려 있어 표에 없는 연산자의 "operator does not exist"(42883)를 여기서 냅니다.

예전 문서는 Pratt를 두지 않은 이유로 "표가 함수 포인터 모음이 된다"를 들었습니다. 태그 enum과 방언의 `switch` 하나로 하면 함수 포인터가 없고, 단계마다 붙는 의미(MariaDB의 `/`가 `Div .real`, SQL Server의 `+`, Oracle의 날짜 산술)는 방언 코드에 그대로 남습니다. MariaDB의 `PIPES_AS_CONCAT`처럼 세션이 연산자의 자리를 바꾸는 것은 comptime 표 두 벌로 둡니다.

SQLite는 이 엔진을 쓰지 않습니다([5.3](#53-파서)).

```
%left OR. %left AND. %right NOT.
%left IS MATCH LIKE_KW BETWEEN IN ISNULL NOTNULL NE EQ.
%left GT LE LT GE. %right ESCAPE.
%left BITAND BITOR LSHIFT RSHIFT. %left PLUS MINUS.
%left STAR SLASH REM. %left CONCAT PTR. %left COLLATE. %right BITNOT.
```

### 3.3 오류 기록과 단어 집합

`Diag(State)`는 지금과 같습니다. `words.folded`와 `words.noCase`는 키워드 표의 등급으로 바뀌어 없어지고, 키워드가 아닌 단어 집합(PostgreSQL의 타입 이름 등)은 `Keywords`와 같은 해시를 쓰는 `sqllex.WordSet`이 대신합니다.

## 4. 공통 문법 조각과 드라이버

`src/dialect/syntax.zig`의 조각(`caseExpr`, `sortList`, `windowClauses`, `frame`, `frameBound`)은 그대로입니다. 그 키워드도 방언의 표에 있어야 컴파일됩니다. 다섯 방언이 같은 토큰을 쓰게 되므로 다음 조각을 더합니다. 이름을 읽는 방법은 커서의 `name(class)`에 방언의 이름 등급을 넘깁니다.

| 조각 | 내용 |
| --- | --- |
| `qualifiedName(p, class, max)` | `a.b.c`. 부분 개수 상한과 각 부분의 위치 |
| `parenNames(p, class)` | `(a, b, c)` |
| `withClause(p, cte)` | `WITH [RECURSIVE] name [(cols)] AS [[NOT] MATERIALIZED] (...)`의 틀. 본문은 방언의 `cte` |
| `joinConstraint(p, operand, class)` | `ON expr` / `USING (names)` |

`src/dialect/driver.zig`는 `run()`(미리 토큰화)과 `streaming()`(읽으며 감) 그대로입니다. SQLite도 `streaming()`을 씁니다. 다만 SQLite는 한 번의 호출로 텍스트의 문장을 모두 읽고, 문장마다 `finishCoding()`이 끝나면 멈추므로(`rc == DONE`) 드라이버에 그 동작을 옵션으로 둡니다.

## 5. SQLite 방언

### 5.1 TK 코드와 키워드 API

`TK_*`는 파서만의 것이 아닙니다. `Expr.op`가 `TK_*`이고, VDBE의 비교·산술 연산 코드가 같은 번호를 씁니다(`src/vdbe/opcodes.zig`). 그래서 `TK`는 엔진의 `src/sql/tk.zig`에 parse.y의 번호 그대로 있습니다. SQLite 파서는 토큰을 이 코드로 읽습니다(`lexer.getToken()`, `lexer.code()`).

키워드 표(`src/dialect/sqlite/lexer.zig`의 `keyword_list`)는 mkkeywordhash가 만든 목록을 그 순서 그대로 옮긴 것입니다. `sqlite3_keyword_count()`, `sqlite3_keyword_name()`, `sqlite3_keyword_check()`가 이 표를 씁니다. parse.y의 `%fallback ID`에 든 키워드(`fallsBack()`)는 sqllex 표의 등급이 `unreserved`입니다.

### 5.2 렉서

`src/dialect/sqlite/lexer.zig`는 `Lexer(sqlite)`의 spec과 훅(`x'..'`, `:name` 같은 파라미터, 공백과 주석)이고, 그 위에 tokenize.c의 `sqlite3GetToken()`(`getToken()`: 공백과 주석 토큰까지, 코드와 길이)을 둡니다. 렉서가 읽는 것은 다음과 같습니다.

- `'...'`, `"..."`, `` `...` ``, `[...]`
- `x'..'`
- `?`, `?NNN`, `:name`, `@name`, `$name`(`$` 뒤 `::`와 `(...)` 접미사 포함), `#name`
- `--`와 `/* */`(닫히지 않은 블록 주석은 끝까지)
- 숫자의 `_`(QNUMBER)
- `||`, `->`, `->>`
- 잘못된 문자(`illegal`)

파서, ALTER의 이름 바꾸기와 제약 지우기, `sqlite3_normalized_sql()`(`normalize.zig`)이 `getToken()`을 씁니다.

`WINDOW`, `OVER`, `FILTER`는 tokenize.c의 `analyze*Keyword()`와 같은 규칙으로 가립니다. WINDOW는 뒤에 이름과 AS가 올 때, OVER는 `)` 뒤에서 `(`나 이름이 올 때, FILTER는 `)` 뒤에서 `(`가 올 때만 키워드이고, 아니면 이름(ID)입니다. 재귀 하강 파서는 문법의 자리로 가릴 수도 있지만, 그러면 `SELECT window w AS x`(SQLite는 `window`에서 구문 오류)처럼 SQLite와 다른 곳이 생깁니다. 그래서 이 규칙은 파서가 토큰을 읽을 때(`lexOne()`) 그대로 적용합니다.

### 5.3 파서

`src/dialect/sqlite/parser.zig`는 parse.y의 문법을 손으로 쓴 재귀 하강 파서이고, `runParser()`(`sqlite3RunParser()`)가 그 입구입니다. lemon이 parse.y에서 만드는 파서의 reduce 동작 412개가 부르던 `ir.*` 빌더를 같은 순서, 같은 인자로 부릅니다. 같은 빌더를 같은 순서로 같은 인자로 부르면 바이트코드가 같다는 것이 이 설계의 근거이고, [6](#6-검증)의 비교로 확인했습니다.

| 지켜야 할 것 | 방법 |
| --- | --- |
| **빌더를 부르는 순서**. 동작에는 부작용이 있습니다(`beginCreate`, `startTable`, `addColumn`, 윈도 목록, CTE). lemon은 규칙의 마지막 토큰 다음 토큰이 들어올 때 reduce합니다 | 토큰을 먹으면(`advance()`) 곧바로 다음 토큰을 넣고(`feed()`), 빌더는 규칙의 마지막 토큰을 먹은 뒤 다른 토큰을 먹기 전에 부릅니다. 그래서 빌더가 보는 lookahead(`scanpt`, `scantok`)와 `p.last_token`이 lemon과 같습니다. 빈 규칙(`createkw ::= CREATE`, `ifnotexists ::=`)도 같은 자리에서 부릅니다 |
| **오류 뒤에 멈추는 자리**. lemon은 빌더가 오류를 남긴(rc가 OK가 아닌) 토큰을 넣은 뒤 멈춥니다. `finishCoding()`의 DONE도 같습니다 | 넣던 토큰을 먹을 때 rc를 보고 멈춥니다. 같은 토큰에서 난 구문 오류는 앞의 오류 문구를 덮어씁니다(`sqlite3ErrorMsg()`처럼) |
| **구문 오류의 토큰**. lemon은 문법에 맞는 접두사가 끊기는 첫 토큰에서 `near "X": syntax error`를 내고, 텍스트 끝(가짜 SEMI, 토큰 0)이면 `incomplete input`입니다 | 각 자리에서 lemon의 상태가 받는 토큰만 받고, 아니면 호출한 쪽으로 돌아갑니다(lemon의 기본 reduce). 그러면 기대하던 토큰이 그 자리에서 실패합니다 |
| **키워드의 fallback**. 키워드는 상태에 그 키워드의 동작이 있으면 키워드이고, 없고 ID의 동작이 있으면 이름입니다 | 자리마다 문법이 받는 키워드를 먼저 보고, 나머지 fallback 키워드를 `isNm()`, `isIds()`, `isId()`로 이름으로 받습니다. 그래서 `a INT GENERATED ALWAYS AS (1)`의 타입은 SQLite처럼 `INT GENERATED ALWAYS`입니다 |
| **스키마 텍스트와 범위**. CREATE 문, 열 정의, CHECK와 DEFAULT의 텍스트는 토큰 위치로 잘라 저장됩니다 | 빌더에 넘기는 `int.Token`(`z`, `n`)을 lemon의 동작과 같은 토큰에서 만듭니다 |
| **여러 문장**. `cmdx`가 reduce될 때 문장마다 `finishCoding()`하고(`xq_hold_finish`면 빼고), `EXPLAIN`, 빈 문장(`;;`)이 있습니다 | 문장 고리(`input()`)가 같은 순서로 부릅니다 |
| **runParser의 검사**. 공백과 주석까지 세는 `SQLITE_LIMIT_SQL_LENGTH`, 특수 토큰에서의 중단 검사, 주석 오류(스키마를 읽을 때와 `SQLITE_DBCONFIG_ENABLE_COMMENTS`가 아니면), 잘못된 토큰 | 넣는 토큰까지의 원문에만 같은 순서로 합니다(`feed()`) |

설계와 다르게 된 곳과 그 까닭은 다음과 같습니다.

- **토큰은 커서가 아니라 파서의 공급원으로 읽습니다.** 위의 검사와 `p.last_token`은 lemon에 넣는 토큰에만 일어나야 하는데, 결정을 위해 앞을 본 토큰(`at(k)`)은 아직 넣지 않은 것입니다. `Streaming` 커서는 이 둘을 나누지 않으므로, 넣는 토큰(`peek()`)과 앞을 본 토큰을 따로 두는 작은 공급원을 파서에 두었습니다.
- **식은 Pratt 엔진이 아니라 parse.y의 우선순위로 직접 읽습니다(precedence climbing, `level()`과 `binds()`).** 어떤 토큰이 연산자인지가 위의 fallback 규칙에 달려 있고(`LIKE_KW`, `MATCH`는 fallback 키워드입니다), BETWEEN의 가운데 피연산자는 결합력 하나로 나타낼 수 없습니다. 맨 바깥의 AND에서 끝나지만 OR 오른쪽 안의 AND는 먹습니다(`x BETWEEN a OR b AND c AND d`, `exprBetween()`). 또 `NOT NULL`, `NOT LIKE`, `NOT BETWEEN`, `NOT IN`은 그 연산자가 아니라 NOT의 우선순위로 붙습니다. lemon이 충돌을 푸는 규칙(토큰의 우선순위가 높거나, 같고 오른쪽 결합이면 shift)을 그대로 적은 것이 `binds()`입니다.
- **재귀 제한.** lemon은 힙의 스택이 `SQLITE_LIMIT_PARSER_DEPTH`를 넘으면 `Recursion limit`를 냅니다. 파서는 lemon 스택에 쌓일 기호 수를 셉니다(`push()`). ReleaseSafe에서 이 오류가 나는 중첩 수는 lemon과 1 이내로 같습니다(괄호 2494겹, 함수 호출 832겹, 부질의 499겹). 이 파서는 네이티브 스택을 쓰므로 한 번의 파싱이 1 MiB(WebAssembly는 512 KiB)를 넘게 쓰면 같은 오류로 멈춥니다. Debug 빌드는 프레임이 커서 그보다 얕은 중첩(괄호 약 1200겹)에서 멈춥니다. 깊은 중첩의 길에 있는 함수(`exprAbove()`, `operand()`, `infix()`, `parenthesized()`)는 프레임을 작게 두고, 나머지는 따로 둡니다.

## 6. 검증

이 리팩터링의 결과는 모든 방언에서 출력이 바이트 단위로 같아야 합니다.

- **네 방언**: 옮기기 전 커밋으로 빌드한 바이너리와 출력을 견줍니다. 볼 것은 오류 문구, 위치, SQLSTATE, 결과 열 이름입니다. 여기에 `zig build check`(기록된 `dialect-diff pg`, `xqt interop`, planner, fuzzcheck)를 돌립니다.
- **렉서**: 방언마다 옛 렉서와 새 `Lexer(spec)`의 토큰열을 무작위 문자열로 비교했습니다. 비교는 종류, 범위, 값, 오류입니다.
- **SQLite 파서는 lemon을 기준으로 두었습니다.** 새 파서를 lemon과 나란히 빌드하고, 두 메모리 DB에서 한쪽은 lemon, 한쪽은 새 파서로 같은 스크립트를 문장 단위로 돌리며 다음을 비교했습니다(비교 도구는 lemon과 함께 지웠습니다).
  - prepare의 결과: 코드, 오류 문구, `sqlite3_error_offset()`, tail
  - 프로그램: 연산 코드, 피연산자, P4(EXPLAIN의 표시), P5. 트리거의 하위 프로그램까지
  - 결과 열 이름, 파라미터 이름, 실행 결과
  - 파일 끝의 `sqlite_schema`

  `sqlite3_complete()`는 파서를 쓰지 않으므로(`src/sql/complete.zig`) 비교하지 않았습니다. 결과는 다음과 같습니다(문장 수는 prepare의 tail로 나눈 것이라, 오류 뒤의 남은 텍스트도 문장으로 셉니다).

  | 입력 | 문장 | 같음 | 다름 |
  | --- | ---: | ---: | ---: |
  | `ref/sqlite/test/*.test`의 SQL(1141개 파일) | 107706 | 107705 | 1 |
  | fuzzcheck 코퍼스(`fuzzdata1~8.db`의 스크립트, 하나씩 새 DB에서) | 322281 | 322280 | 1 |
  | `ref/sqllogictest`(73개 파일: `select1~5`, `evidence`, `index`·`random`의 일부) | 657907 | 657907 | 0 |
  | `tools/planner/*.txt` | 45905 | 45905 | 0 |
  | lemon 문법의 규칙으로 만든 문장 52000개(절반은 토큰 하나를 지우거나 겹치거나 맞바꾸거나 끼우거나, 뒤를 자른 것) | 1294201 | 1294201 | 0 |
  | 옛 `tokenize.zig`의 파서 시험, 손으로 고른 경계 사례 | 516 | 516 | 0 |

  다른 둘은 파서와 상관없습니다. 하나는 무작위로 정해지는 rowid라 두 쪽 모두 lemon으로 돌려도 다르고, 하나는 `strftime('%J')`의 현재 시각입니다. 두 파서에서 똑같이 엔진이 panic하는 입력이 세 가지 있었습니다(`UPDATE ... SET (a, b) = 스칼라`의 `update.zig`, 트리거 안의 `INSERT ... RETURNING`, `writable_schema`로 바꾼 스키마의 `startTable`). 새 파서로 `zig build check`(planner의 sqlite3 바이트코드 비교 포함)도 통과했습니다.

  `parser.zig`의 시험은 길이 한도, 중단, 주석, 재귀 한도에서의 결과를 lemon이 낸 값으로 적어 두고 확인합니다.
- 마지막에 3단계 검사(`check check-matrix -Dfuzz=true`, `test-wasi`, `test-pkg`, `wasm`, `wire-diff pg`)를 돌립니다.

## 7. 단계

진행: 1~6단계가 끝났습니다. 다섯 방언이 공통 렉서와 키워드 표를 쓰고, 네 방언의 식은 `pratt` 표 하나로 읽습니다(MariaDB는 `PIPES_AS_CONCAT`에 따라 두 벌). SQLite 방언은 손으로 쓴 파서이고 lemon은 없어졌습니다.

1. **토큰과 렉서**: `sqllex`에 `Token`, `Kind`, `Lexer(spec, Hooks)`, `Keywords`, 값 해석을 더합니다. 네 방언 렉서를 spec과 훅으로 옮기고, 새 토큰열과 옛 토큰열을 비교하는 시험을 둡니다.
2. **커서와 방언 파서**: 커서가 새 토큰을 받게 하고, 네 방언에 키워드 표를 두어 파서를 새 렉서로 옮깁니다. 방언 렉서의 `Token`, `Kind`, 옛 토큰화 코드, `words` 집합은 지웁니다. 이스케이프를 푸는 코드는 방언에 남습니다.
3. **Pratt**: `pratt`를 더하고 네 방언의 식 사슬을 연산자 표와 `prefix`/`infix`/`postfix`로 옮깁니다. 공통 조각(`qualifiedName`, `parenNames`, `withClause`, `joinConstraint`)도 이 단계에서 더합니다.
4. **SQLite 렉서**: `Lexer(sqlite)`와 SQLite 키워드 표를 만들고, `getToken()`을 그 위에 다시 써서 사용처를 옮깁니다.
5. **SQLite 파서**: `src/dialect/sqlite/parser.zig`를 lemon과 나란히 만들고 [6](#6-검증)의 비교로 맞춥니다.
6. **정리**: `runParser()`가 새 파서만 씁니다. `src/parse/`(lemon 엔진과 `grammar.zig`, `tokenize.zig`), `tools/parser/`, `xqt gen parser`, 비교 도구를 지우고, `TK`를 `src/sql/tk.zig`로, 키워드 표를 `lexer.zig`로, `normalize.zig`를 `src/dialect/sqlite/`로 옮겼습니다.

## 8. 들어가지 않는 것

- **의미 해석**: 이름 해석, 캐스트 계획, 함수 매핑은 방언의 것입니다.
- **IR 트리**: `tree.zig`는 엔진에 둡니다. 트리의 약속(`lower.zig`·`render.zig`와의 계약, `xq_*` 엔진 함수)이 엔진의 것이기 때문입니다.
- **오류 복구**: 다섯 방언 모두 첫 오류에서 멈춥니다(lemon도 `YYNOERRORRECOVERY`). 여러 오류를 모으는 복구는 두지 않습니다.
