# 지원 범위: 식, 함수, 정규식

[PostgreSQL 호환](README.md)의 일부입니다.

## 식과 연산자

| 영역 | 지원 |
| --- | --- |
| 캐스트 | `::type`, `CAST`, 타입 리터럴(`DATE '2024-01-01'`, `INTERVAL '1-2' YEAR TO MONTH`, `INTERVAL(2) '1.234 sec'`) |
| NULL·진리값 | `IS [NOT] NULL`/`ISNULL`/`NOTNULL`, `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE/FALSE/UNKNOWN` |
| 술어 | `BETWEEN`, `IN (목록\|서브쿼리)`, `x op ANY\|SOME\|ALL (배열\|서브쿼리)`(`= <> < <= > >=`, `[NOT] LIKE`, `[NOT] ILIKE`), `EXISTS` |
| 패턴 | `LIKE`/`ILIKE`/`~~`/`~~*`와 `ESCAPE`, 정규식 `~`/`~*`/`!~`/`!~*`(`xq_pg_re()`, 아래 [정규식](#정규식)), `[NOT] SIMILAR TO 패턴 [ESCAPE e]`(PostgreSQL처럼 `x ~ similar_to_escape(패턴, e)`) |
| 날짜·시각 | `date ± integer`, `date - date`, `date ± interval`, `date + time`, `timestamp[tz] ± interval`, `timestamp[tz] - timestamp[tz]`, `time ± interval`, `time - time`, `interval ± interval`, `-interval`, `interval * 수`, `interval / 수`(아래 [연산자 해석](#연산자-해석)) |
| JSON | `->`, `->>`, `#>`, `#>>`, `@>`, `<@`, `?`, `?\|`, `?&`, jsonb의 `\|\|`, `-`, `#-`, `@?`, `@@`, `IS [NOT] JSON` (아래 [JSON](json.md)) |
| 배열 | `ARRAY[...]`, `ARRAY(서브쿼리)`, `a[i]`, `a[i][j]`, `a[lo:hi]`, `\|\|`, `@>`, `<@`, `&&`, 비교와 `ORDER BY`(아래 [배열](arrays.md)) |
| 그 밖 | `CASE`, 행 값, `(레코드).필드`(`_pg_expandarray()`의 `x`, `n`), `\|\|`(피연산자가 NULL이면 NULL) |
| 집계 | `count(*)`, 집계의 `DISTINCT`/`ORDER BY`/`FILTER` |
| 윈도우 | `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE/GROUPS ... EXCLUDE ...)`, `OVER name` |

연산자 우선순위는 PostgreSQL의 것입니다(낮은 것부터).

`OR` < `AND` < `NOT` < `IS` < 비교 < `BETWEEN`/`IN`/`LIKE` < 기타 연산자(`||`, `->`, `~`) < `+ -` < `* / %` < `^` < 단항 < `::`

### 연산자 해석

산술·비트 연산자(`+ - * / %`, 단항 `-`, `& | << >>`)는 피연산자의 타입으로 연산자 표(`operators.zig`)의 행을 고릅니다. PostgreSQL의 연산자 해석과 같은 순서입니다.

1. 타입이 정확히 같은 행. 문자열 상수(PostgreSQL의 unknown)는 먼저 다른 피연산자의 타입으로 봅니다(`date '2024-01-02' - '2024-01-01'`은 `date - date`, `1`).
2. 없으면 피연산자가 암시적으로 캐스트되는 행들: 정수는 더 넓은 정수·`numeric`·실수로, `numeric`은 실수로, `date`는 `timestamp[tz]`로, `timestamp`는 `timestamptz`로, `time`은 `interval`로, 문자열끼리. 문자열 상수는 어느 타입과도 맞습니다.
3. 그중 정확히 맞는 자리가 가장 많은 행, 그다음 캐스트하는 자리에 선호 타입(`double precision`, `text`, `timestamptz`, `interval`)이 가장 많은 행. 문자열 상수의 자리는 남은 행들의 타입 범주가 하나여야 합니다(문자열 범주가 있으면 그것).
4. 한 행이면 그 연산자, 없으면 `operator does not exist: date + text`(42883), 여럿이면 `operator is not unique: date + unknown`(42725).

| 행 | 구현 |
| --- | --- |
| 정수(`smallint`/`integer`/`bigint`의 모든 쌍, 넓은 쪽), `real`, `double precision`의 `+ - * /`; 같은 타입의 `%`(실수의 `%`는 없음); 단항 `-`; 정수의 `& \|`와 `<< >>`(오른쪽 `integer`) | 엔진의 연산 코드(SQLite의 바이트코드). 문자열 상수는 그 정수 타입으로 읽음(`xq_pg_cast_int4('a')`: `'a' + 1`은 `invalid input syntax for type integer: "a"`) |
| 같은 정수 타입의 `#`(배타적 논리합) | `integer.zig`의 엔진 함수 `xq_pg_int_xor()`(연산 코드가 없음; 파서가 호출로 만들고 `overload.zig`가 표로 타입을 검사: `text # integer`는 `operator does not exist`) |
| `numeric`의 `+ - * / %`, 단항 `-` | `xq_dec_add()` ... `xq_dec_neg()`: 정확한 키([numeric](numeric.md)) |
| `date ± integer` → `date`, `date - date` → `integer`, `date ± interval`·`date + time` → `timestamp`, `timestamp[tz] ± interval` → 같은 타입, `timestamp[tz] - timestamp[tz]` → `interval`, `time ± interval` → `time`, `time - time`, `interval ± interval`, `-interval`, `interval * double precision`, `interval / double precision` → `interval`(교환한 행 포함) | `datetime.zig`의 엔진 함수 `xq_pg_<PostgreSQL 구현 이름>`(`xq_pg_date_pli`, `xq_pg_timestamp_pl_interval`, `xq_pg_interval_mul` ...) |
| `jsonb - text`, `jsonb - integer`, `jsonb - text[]` | `xq_pg_jsonb_delete()`, `xq_pg_jsonb_delete_keys()` |

- 달 더하기는 PostgreSQL처럼 달, 날, 시간 순서이고 달의 마지막 날로 맞춥니다(`date '2024-01-31' + interval '1 month'`은 `2024-02-29 00:00:00`). 타임스탬프의 차는 날과 시간의 interval입니다(`justify_hours()`: `1 day 02:00:00`, `-1 days -02:00:00`). `interval * 수`·`/ 수`는 달의 나머지를 30일로, 날의 나머지를 시간으로 내립니다(`interval '1 month' / 2`는 `15 days`).
- interval은 세션의 `IntervalStyle`로 보입니다. 기본(postgres)은 `1 day`, `1 day 02:00:00`, `-1 mons`, `3 years 2 mons`, `-1 days +01:00:00`, `infinity`/`-infinity`이고, 다른 형식은 아래 [interval](interval.md)에 있습니다.
- interval 연산은 PostgreSQL 18의 것입니다: 무한의 규칙(`infinity + 1 day`는 `infinity`, `infinity - infinity`와 `infinity * 0`은 `interval out of range`, `time + infinity`는 `cannot add infinite interval to time`), 필드가 넘치면 `interval out of range`, 곱셈·나눗셈의 반올림은 `rint()`(짝수 쪽).
- 피연산자 하나라도 타입을 모르면(SQLite 테이블의 열, 규칙이 없는 함수) 표를 보지 않고 SQLite의 연산입니다(오류 없음). 매개변수와 NULL은 문자열 상수처럼 어느 타입과도 맞지만 문장을 실패시키지 않고, 행이 정해지면 매개변수는 그 행의 타입을 받습니다(`ts + $1`의 `$1`은 `interval`). 문자열 상수끼리(`'1' + '2'`)도 SQLite의 연산입니다.
- `||`는 표에 없습니다(PostgreSQL의 `text || anynonarray`는 어느 타입이나 받으므로). jsonb의 `||`와 비교는 `overload.zig`의 따로 된 선택이고, jsonb `-`의 오른쪽이 표가 모르는 타입(SQLite 열, `int[]`)일 때도 그쪽이 고릅니다.
- 뷰, CHECK, 생성 열, 식 인덱스의 텍스트에는 고른 함수가 남습니다(`xq_pg_date_pli("d", 1)`). 어느 방언의 연결에서 읽어도 같은 뜻입니다.

## 함수

SQLite 내장 함수에 더해 다음을 지원합니다. 같은 이름의 SQLite 내장(`random()`, `floor()` 등)은 이 방언에서 가려집니다.

| 분류 | 함수 |
| --- | --- |
| 날짜·시각 | `now()`, `current_timestamp`, `localtimestamp`, `current_date`, `extract(field FROM x)`/`date_part`(timestamp와 [interval](interval.md)), `make_interval()`, `date_trunc(unit, x)`(timestamp·timestamptz·interval; date는 timestamptz로), `date_bin(stride, ts, origin)`, `timezone(zone, x)`과 `x AT TIME ZONE zone`·`AT LOCAL`(아래 [형식 함수](formatting.md)); 연산자는 위 [연산자 해석](#연산자-해석) |
| 형식 | `to_char`, `to_number`, `to_date`, `to_timestamp(text, text)`, `to_timestamp(double)`(아래 [형식 함수](formatting.md)) |
| 입력 검사 | `pg_input_is_valid(text, type)`, `pg_input_error_info(text, type)`(FROM에서; 아래 [형식 함수](formatting.md)) |
| 인자 | 이름 붙은 인자 `f(name := v)`/`f(name => v)`(`make_interval`, `make_date`, `make_time`, `make_timestamp`의 매개변수 이름; 위치 인자 뒤에만, 주지 않은 것은 기본값), `VARIADIC`(아래) |
| 문자열 특수 문법 | `substring(x FROM a FOR b)`, `substring(x FROM 패턴)`·`substring(x SIMILAR 패턴 ESCAPE e)`(아래 [정규식](#정규식)), `position(a IN b)`, `trim([BOTH\|LEADING\|TRAILING] [c] FROM x)` |
| 정규식 | `regexp_match`, `regexp_matches`(집합 반환, `'g'`), `regexp_replace`, `regexp_split_to_table`/`regexp_split_to_array`, `regexp_count`, `regexp_instr`, `regexp_substr`, `regexp_like`, `similar_to_escape`(아래 [정규식](#정규식)) |
| 문자열 | `strpos`, `left`/`right`, `concat`/`concat_ws`, `lpad`/`rpad`, `repeat`, `reverse`, `split_part`, `starts_with`, `btrim`, `char_length`, `ascii`/`chr` |
| 집계 | `string_agg`, `bool_and`/`bool_or`/`every`, `array_agg`(윈도우 함수로도) |
| 배열 | 아래 [배열](arrays.md) |
| 비교 | `greatest`/`least`(NULL은 건너뜀) |
| 수학 | `floor`, `ceil`, `sqrt`, `power`, `exp`, `ln`, `log`, `log10`, `mod`, `trunc`, `sign`, `pi`, `factorial`, `width_bucket`, `gcd`/`lcm`(정수는 `integer out of range`·`bigint out of range`, numeric은 큰 쪽 스케일, NaN·무한은 NaN), `float8(x)`/`float4(x)` |
| 불리언·해시 | `booleq`/`boolne`, `interval_hash()`(같은 interval이면 같은 값; PostgreSQL의 수와는 다름) |
| 난수·UUID | `random()`(0 이상 1 미만 실수), `gen_random_uuid()`, `uuidv4()`, `uuidv7([shift interval])`, `uuid_extract_version()`, `uuid_extract_timestamp()`(아래 [uuid](uuid.md)) |
| 시스템 | `version()`, `current_user`, `current_database()`, `current_schema`, `current_schemas(bool)`, `current_setting(name [, missing_ok])`, `set_config(name, value, false)`, `format_type(oid, typmod)`(와이어 서버가 알리는 타입 OID의 이름, psql의 `\gdesc`), `pg_backend_pid()`, `pg_is_in_recovery()`, `quote_ident`/`quote_literal`/`quote_nullable` |
| 카탈로그 | 아래 [카탈로그](catalog.md)의 함수 |
| 시퀀스 | 시퀀스 함수(`nextval()` 등) |
| JSON | 아래 [JSON](json.md) |

- 이름 붙은 인자는 파서가 매개변수 자리로 옮깁니다. 모르는 이름이나 이름 붙은 인자를 받지 않는 함수는 `function make_interval(foo => integer) does not exist`(42883, 인자 타입은 리터럴이 알려 주는 만큼), 이름 붙은 인자 뒤의 위치 인자는 `positional argument cannot follow named argument`, 같은 이름 둘은 `argument name "x" used more than once`입니다.
- `VARIADIC`은 마지막 인자에만 씁니다. `concat(VARIADIC a)`·`concat_ws(sep, VARIADIC a)`는 `array_to_string(a, sep)`(원소의 텍스트, NULL 원소는 건너뜀, 배열이 NULL이면 NULL), `format(fmt, VARIADIC ARRAY[...])`와 `json[b]_build_array/object(VARIADIC ARRAY[...])`는 원소를 그대로 인자로 펼칩니다(`VARIADIC NULL::t[]`은 인자 없음). 배열이 아닌 상수는 `VARIADIC argument must be an array`(42804), 그 밖의 함수는 `function f(integer[]) does not exist`입니다.

## 정규식

`~` 연산자, `SIMILAR TO`, `regexp_*()` 함수는 PostgreSQL의 고급 정규식(ARE)을 `are.zig`가 그대로 따릅니다.

- 문법: `.`, `[...]`/`[^...]`(범위, `[:alpha:]` 같은 POSIX 문자 클래스 `alnum alpha ascii blank cntrl digit graph lower print punct space upper word xdigit`, `[.c.]`, `[=c=]`), `\d \s \w \D \S \W`, 문자 이스케이프(`\n \t \uXXXX \UXXXXXXXX \xhh \0oo \cX` ...), 역참조 `\1` ... `\mnn`, 제약 `^ $ \A \Z \m \M \y \Y`, 전방·후방 탐색 `(?=...) (?!...) (?<=...) (?<!...)`, `(...)`·`(?:...)`·`(?#...)`, `|`, 수량자 `* + ? {m} {m,} {m,n}`(255까지)와 그 non-greedy 형(`*?` ...), `***=`(나머지는 글자 그대로)와 `***:`, 맨 앞의 포함 옵션 `(?inx...)`.
- 플래그(`regexp_*()`의 `flags`, 포함 옵션): `i`/`c`(대소문자), `n`/`m`, `p`, `w`, `s`(줄바꿈 민감), `x`(공백과 `#` 주석 무시), `t`, `q`(패턴이 글자 그대로), `e`(ERE: 백슬래시는 다음 글자 그대로, `(?`와 non-greedy 없음), `g`(모든 일치: `regexp_matches`, `regexp_replace`). 모르는 글자는 `invalid regular expression option: "z"`, `g`를 받지 않는 함수는 `regexp_match() does not support the "global" option`(`regexp_match`는 HINT와 함께)입니다.
- 일치는 PostgreSQL의 규칙입니다. 가장 왼쪽에서 시작하는 일치 중, 식 전체가 greedy면 가장 긴 것, 아니면 가장 짧은 것입니다(식의 greediness는 처음으로 greediness가 있는 수량자가 정하고, `|`는 greedy). 그 범위 안에서 부분식은 앞의 것부터 자기 greediness대로 나눕니다: `regexp_match('abc01234xyz', '(.*?)(\d+)(.*)')`는 `{abc,0,""}`, `regexp_match('abcd', '(a|ab)(c|bcd)(d*)')`는 `{ab,c,d}`. 반복된 그룹은 마지막 반복의 것이고, `x{m,n}`(m ≥ 1)은 PostgreSQL처럼 `x{m-1,n-1}` 뒤의 마지막 `x`로 나눕니다(`regexp_match('aaa', '(a*)+')`는 `{""}`, `'(a*)*'`는 `{aaa}`).
- 일치 범위는 Pike VM이 찾으므로(역추적 없음) `(a*)*b` 같은 패턴도 입력 길이에 비례합니다. 역참조가 있는 식만 역추적으로 맞춥니다. 후방 탐색은 거꾸로 읽는 프로그램으로 그 위치에서 뒤로 한 번 돌립니다. 그룹을 쓰지 않는 호출(`~`, `regexp_count`, `regexp_like`, `regexp_split_*`, `subexpr`가 0인 `regexp_instr`/`regexp_substr`, `\1`..`\9`가 없는 `regexp_replace`)은 부분식을 나누지 않습니다.
- 컴파일한 패턴은 상수면 문장에 두고, 행마다 바뀌는 패턴은 PostgreSQL의 `RE_compile_and_cache()`처럼 연결마다 최근 32개를 둡니다.
- 오류는 `invalid regular expression: parentheses () not balanced`, `... brackets [] not balanced`, `... braces {} not balanced`, `... invalid repetition count(s)`, `... quantifier operand invalid`, `... invalid escape \ sequence`, `... invalid backreference number`, `... invalid character class`, `... invalid character range`, `... invalid embedded option`(2201B)입니다.
- 함수: `regexp_match(s, p [, flags])`(그룹의 `text[]`, 그룹이 없으면 일치 전체, 없으면 NULL), `regexp_matches(s, p [, flags])`(행마다 `text[]`; FROM과 select 목록에서), `regexp_replace(s, p, r [, start [, N]] [, flags])`(`\1`..`\9`, `\&`, `\\`; 네 번째 인자가 수이면 start, 텍스트면 flags), `regexp_split_to_table`/`regexp_split_to_array(s, p [, flags])`, `regexp_count(s, p [, start [, flags]])`, `regexp_instr(s, p [, start [, N [, endoption [, flags [, subexpr]]]]])`, `regexp_substr(s, p [, start [, N [, flags [, subexpr]]]])`, `regexp_like(s, p [, flags])`. 위치는 문자 단위이고, 범위 밖의 `start`/`N`/`endoption`/`subexpr`는 `invalid value for parameter "start": 0`(22023)입니다.
- `substring(x FROM 패턴)`(`substring(x, 패턴)`도)은 첫 그룹이(없으면 일치 전체) 맞은 부분, `substring(x SIMILAR 패턴 ESCAPE e)`와 `substring(x FROM 패턴 FOR e)`는 SIMILAR 패턴의 두 `e"` 사이입니다. 패턴이 문자열 상수일 때 고르고(PostgreSQL의 `substring(text, text)`), 그 밖은 `substr()`입니다.
- `SIMILAR TO`는 PostgreSQL처럼 `similar_to_escape()`로 정규식을 만들어 `~`로 맞춥니다(`%`는 `.*`, `_`는 `.`, `(`는 갈무리하지 않는 그룹, 기본 이스케이프는 `\`, `ESCAPE ''`는 이스케이프 없음, `ESCAPE NULL`이면 NULL). 두 글자 이상의 이스케이프는 `invalid escape string`(HINT와 함께)입니다.
- 대소문자 무시(`i`, `~*`)와 문자 클래스는 ASCII에 더해 라틴 문자·그리스 문자·키릴 문자의 대소문자를 압니다. 그 밖의 ASCII 밖 문자는 글자(`[[:alpha:]]`)로 보고, 대소문자가 없는 것으로 봅니다.
- 예전 데이터베이스의 스키마(CHECK, 식 인덱스, 뷰)에 남은 `xq_pg_regex()`는 예전 엔진(`regex.zig`) 그대로 계산합니다. 새 스키마는 `xq_pg_re()`를 씁니다.
