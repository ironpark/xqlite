# interval

[PostgreSQL 호환](README.md)의 일부입니다.

interval은 정렬 키와 필드를 붙인 32바이트 BLOB입니다(`src/dialect/interval.zig`). 앞 16바이트는 PostgreSQL의 `interval_cmp_value()`(한 달 = 30일, 하루 = 24시간인 마이크로초, 128비트, 부호 비트를 뒤집은 big-endian)이고, 뒤 16바이트는 필드(달 `i32`, 날 `i32`, 마이크로초 `i64`, 같은 방식)입니다. 그래서 `memcmp`의 순서가 PostgreSQL의 순서입니다. `'1 mon'`과 `'30 days'`는 길이가 같지만 다른 값이라(`date + '1 mon'`과 `date + '30 days'`는 다름) 필드를 남깁니다. 이 인코딩은 파일 형식이라 바뀌지 않습니다.

| 쓰는 곳 | xqlite |
| --- | --- |
| 정렬, 인덱스, `min`/`max` | BLOB 그대로(SQLite의 BINARY). BLOB 열의 인덱스가 `ORDER BY`와 범위 검색을 맡음 |
| `=`, `<>`, `IS [NOT] DISTINCT FROM`, `IN (...)`, `BETWEEN` | 키(`xq_pg_iv_key()`)끼리: `'1 mon' = '30 days'` |
| BLOB 열과 `<`, `<=`, `>`, `>=` | 열은 그대로, 상대는 그 길이의 경계(`< xq_pg_iv_key(x)`, `<= xq_pg_iv_high(x)`): 인덱스 범위 검색 |
| `GROUP BY`, `DISTINCT`, 창의 `PARTITION BY`·`ORDER BY`, 여러 항의 `ORDER BY`의 마지막이 아닌 항 | 키로(같은 길이는 같은 그룹·동점). `DISTINCT`는 결과 열의 `GROUP BY`가 됨 |
| `::text`, `\|\|`, `concat()`, `format()`, JSON | 세션의 `IntervalStyle`로 쓴 텍스트(`xq_pg_iv_out()`, 결정적이지 않음) |
| 배열의 원소 | 기본 형식의 텍스트(`xq_pg_iv_text()`): 배열이 저장하는 형태. 보일 때 세션의 형식으로 |
| `sum()`, `avg()` | `xq_pg_iv_sum()`/`xq_pg_iv_avg()`: PostgreSQL처럼 필드별 합, 평균은 `interval / 개수`, 무한은 같은 부호면 그 무한·다르면 `interval out of range`. 창 함수로도 |
| 입력(캐스트, 리터럴, 열에 넣는 값, 연산자의 문자열 상수 피연산자) | `xq_pg_iv_in(x, typmod)`(`ivinput.zig`): PostgreSQL 18의 `interval_in()`. 연산자의 상수는 `xq_pg_iv_in('1 hour', -1)`. `IntervalStyle` sql_standard인 세션에서 컴파일한 캐스트·리터럴·`DEFAULT`는 `xq_pg_iv_in(x, typmod, 1)`(그 부호 규칙), 열에 넣는 값은 실행할 때의 세션으로 읽음. interval을 받는 함수(`uuidv7(interval)`, `to_char()`, `EXTRACT` ...)와 서버가 받는 매개변수도 같은 입력 |
| `EXTRACT(f FROM x)`, `date_part(f, x)` | `xq_pg_iv_extract()`(`numeric`), `xq_pg_iv_date_part()`(`double precision`) |
| `justify_hours()`, `justify_days()`, `justify_interval()`, `isfinite()`, `make_interval()` | 방언 함수(BLOB을 돌려줌) |
| 셸, 서버 | 값 표시 계층이 BLOB을 세션의 `IntervalStyle`로 쓴 텍스트로(`valuetext.Settings`). 서버의 바이너리 형식은 PostgreSQL의 `interval_send`(마이크로초 `int64`, 날 `int32`, 달 `int32`), 매개변수도 |

- `IntervalStyle`(`SET IntervalStyle = ...`)은 연결의 설정이고 출력할 때만 읽습니다. 저장된 값(BLOB, 배열의 텍스트)은 어느 형식에서나 같습니다. PostgreSQL 18의 `EncodeInterval()`과 같이 씁니다.
  - `postgres`(기본): `1 day 02:00:00`, `-1 days +02:03:04`
  - `postgres_verbose`: `@ 1 day 2 hours`, `@ 1 day ago`, `@ 1 day -1 sec`, `@ 0.5 secs ago`, `@ 0`
  - `sql_standard`: `1 2:00:00`, `-1-2`, `0`, 부호가 섞이면 모든 부호를 씀(`+1-2 -3 +4:05:06`)
  - `iso_8601`: `P1DT2H`, `P-1Y-2M3DT-4H-5M-6S`, `PT0S`
  - 무한은 어느 형식에서나 `infinity`/`-infinity`입니다.
  - 형식을 따르는 곳: 셸과 와이어 서버의 값(텍스트 형식, interval 배열의 원소, 예전 데이터베이스의 TEXT 열), `::text`·`||`·`concat()`·`format()`·JSON(`xq_pg_iv_out()`), 제약 위반의 `DETAIL`. 뷰의 `v::text`도 읽을 때의 세션을 따릅니다(PostgreSQL과 같음). 와이어 서버는 바뀐 값을 다음 `ReadyForQuery` 앞에 `ParameterStatus`로 알립니다.
  - `xq_pg_iv_out()`은 PostgreSQL의 `interval_out()`처럼 결정적이지 않아(stable), 식 인덱스와 생성 열에는 쓸 수 없습니다(`non-deterministic functions prohibited in index expressions`; PostgreSQL은 `functions in index expression must be marked IMMUTABLE`). CHECK에는 됩니다. 예전 스키마가 부르는 `xq_pg_iv_text()`는 늘 기본 형식입니다. [확장](../extension.md)을 올린 sqlite3에는 세션이 없으므로 `xq_pg_iv_out()`도 기본 형식입니다.
  - 입력: `sql_standard`에서는 첫 필드가 `-`로 시작하고 다른 필드에 부호가 없으면 모든 필드가 음수입니다(`'-1 2:03:04'`는 `-1 days -02:03:04`, 다른 형식에서는 `-1 days +02:03:04`). 캐스트와 리터럴은 컴파일할 때의 세션으로 읽고(`sql_standard`로 바뀌거나 그것에서 바뀌는 `SET IntervalStyle`이 준비된 문장을 다시 컴파일함), 스키마의 `DEFAULT`도 만들 때 읽은 대로 남습니다(PostgreSQL이 상수를 그때 읽는 것과 같음). 열에 넣는 값은 실행할 때의 세션으로 읽습니다. ISO 8601(`P1Y2M3DT4H5M6S`, `P0001-02-03T04:05:06`)과 `@ ... ago`는 어느 형식에서나 읽습니다.
- 뷰, CHECK, 식 인덱스의 텍스트에는 이 함수들이 남고(`xq_pg_iv_key("v") = xq_pg_iv_key('30 days')`, `GROUP BY xq_pg_iv_key("v")`), 모두 엔진 함수라 SQLite 방언과 [확장](../extension.md)을 올린 sqlite3도 읽습니다. 연산자의 함수는 `xq_pg_iv_<연산>`(`xq_pg_iv_timestamp_pl_interval()` ...)입니다.
- UNIQUE와 PRIMARY KEY, `UNION`/`INTERSECT`/`EXCEPT`, `count(DISTINCT v)`, `IN (SELECT ...)`는 바이트로 비교하므로 `'1 mon'`과 `'30 days'`를 다르게 봅니다(PostgreSQL은 같음). 같은 길이의 `max()`/`min()`이 어느 철자를 돌려주는지도 다를 수 있습니다.
- 입력은 PostgreSQL 18의 `interval_in()`입니다(`ivinput.zig`). 텍스트를 필드로 나눠 오른쪽부터 읽고(단위가 숫자 앞에 옴, 단위 없는 수는 앞 필드의 단위 그대로, 시간 뒤와 `hour` 뒤는 날), 아니면 ISO 8601(`P1Y2M`, `P0001-02-03T04:05:06`, `P00010203T040506`)로 읽습니다. SQL의 연-월(`'1-2'`, `'+1-2 -3 +4:05:06.789'`), `@ ... ago`, 단위의 앞 10글자(`millenniums`), 같은 단위 두 번의 오류(`'1 2 days'`)도 PostgreSQL의 것입니다. 필드 하나가 넘치면 `interval field value out of range: "..."`(22015), 합친 달이 넘치면 `interval out of range`(22008)입니다. 이 함수는 예전 `xq_pg_iv()`와 다른 이름이라, 예전 스키마가 부르는 `xq_pg_iv()`와 연산자의 함수(`xq_pg_iv_timestamp_pl_interval()` ...)가 텍스트 인자를 읽는 방식은 뜻이 그대로입니다.
- 필드와 정밀도(타입 수식자): `INTERVAL '1' YEAR`, `'1 2' DAY TO HOUR`, `'12:34.5678' MINUTE TO SECOND(2)`, `INTERVAL(2) '...'`, `'...'::interval day to minute`, 열 타입 `interval year to month`·`interval(0)`·`interval day to second(3)`. 수식자는 PostgreSQL의 `INTERVAL_TYPMOD()`이고(`format_type()`과 `atttypmod`에 보임), 단위 없는 수를 그 마지막 필드로 읽은 뒤(`interval '1' year to month`는 `1 mon`, `MINUTE TO SECOND`의 `'2:03'`은 2분 3초) 그 뒤의 필드를 버리고 초를 정밀도로 반올림합니다(`AdjustIntervalForTypmod()`). 열에 넣는 값(`INSERT`, `UPDATE`)과 `DEFAULT`도 열의 수식자를 지납니다. 정밀도는 6을 넘으면 6입니다(PostgreSQL은 경고를 냄).
- `EXTRACT`/`date_part`는 PostgreSQL 18의 `interval_part_common()`입니다: `microsecond`·`millisecond`·`second`(초 안의 값), `minute`, `hour`, `day`, `week`, `month`, `quarter`, `year`, `decade`, `century`, `millennium`, `epoch`(한 해 365.25일). `EXTRACT`는 `numeric`(`epoch`·`second`는 소수 6자리, `millisecond`는 3자리), `date_part`는 `double precision`이고, 무한 interval은 `hour`·`day`·`year`...·`epoch`가 `±Infinity`, 나머지는 NULL입니다. 모르는 단위는 `unit "x" not recognized for type interval`, `timezone`·`dow` 같은 것은 `unit "x" not supported for type interval`입니다. 파서는 `xq_pg_part(field, x, timestamp의 값, EXTRACT인지)`를 만들고 `overload.zig`가 `x`의 타입으로 interval의 함수나 timestamp의 식을 고릅니다(타입을 모르는 값은 실행 중에 값으로).
- `make_interval(years, months, weeks, days, hours, mins, secs)`: 주지 않은 인자는 0(파서가 채움), 넘치거나 무한·NaN인 초는 `interval out of range`, `secs * 1e6`이 넘치면 `value out of range: overflow`.
- 예전 데이터베이스(interval을 텍스트로 저장하던 xqlite)의 `TEXT` 열은 그대로입니다. 열마다 선언된 저장 타입으로 구분해, `TEXT` 열에 넣는 값은 텍스트로(무한은 `interval out of range`) 넣고, 정렬은 예전처럼 collation `xq_pg_interval`, 비교와 연산은 위의 함수(텍스트와 BLOB을 모두 읽음)입니다. 예전 스키마가 부르는 `xq_pg_interval()`, `xq_pg_interval_pl()` ...와 collation은 뜻이 그대로 남습니다. 옮기려면 테이블을 다시 만듭니다.
