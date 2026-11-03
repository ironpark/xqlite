# 타입 매핑

[PostgreSQL 호환](README.md)의 일부입니다.

| PostgreSQL | STRICT 저장 | 검사(이름이 PostgreSQL 메시지인 CHECK) |
| --- | --- | --- |
| `smallint`(`smallserial`) | `INTEGER` | 범위 → `smallint out of range`. 넣는 값은 아래 정수 열처럼 |
| `integer`(`serial`) | `INTEGER` | 범위 → `integer out of range` |
| `bigint`, `bigserial`, `oid` | `INTEGER` | |
| `real`, `double precision`, `float(p)` | `REAL` | |
| `numeric(p,s)`, `decimal` | `BLOB` | 정렬 키만(`xq_dec_valid(n, p, s)` → `invalid input syntax for type numeric`). 넣는 모든 값을 `numeric(p,s)`의 키로 바꿈(아래 [numeric](numeric.md)) |
| `boolean` | `INTEGER` | 0/1만(`invalid input syntax for type boolean`). 문자열은 불리언 철자로 읽어 넣음(아래) |
| `text` | `TEXT` | |
| `varchar(n)`, `char(n)` | `TEXT` | `length() <= n`(`value too long for type character varying(n)`, `character(n)`). 넣는 문자열의 n자 뒤가 공백뿐이면 잘라 냄(`'abcd    '`는 `'abcd'`). `char(n)`은 뒤 공백을 모두 떼어 저장하고, 셸과 서버가 n자까지 공백으로 채워 보여 줌(`'a   '`) |
| `bytea` | `BLOB` | |
| `date`, `time`, `timestamp[tz]` | `TEXT` | 넣는 문자열은 PostgreSQL이 읽고 쓰는 텍스트로(아래) |
| `interval` | `BLOB` | `xq_pg_iv_valid()`(`invalid input syntax for type interval`); 넣는 값은 interval의 BLOB으로([interval](interval.md)). 예전 데이터베이스의 열은 `TEXT` |
| `uuid` | `BLOB` | 16바이트(`invalid input syntax for type uuid`). 넣는 문자열은 `uuid_in()`처럼 읽음([uuid](uuid.md)). 예전 테이블의 `TEXT` 열은 텍스트 그대로 |
| `json` | `TEXT` | `json_valid()`; 넣는 값은 검사([JSON](json.md)) |
| `jsonb` | `BLOB` | `json_valid(j, 8)`; 넣는 값은 정준 JSONB(이 방식 전에 만든 TEXT 열은 정규화한 텍스트, [JSON](json.md)) |
| 배열(`integer[]`, `text[]`, `varchar(n)[]` ...) | `TEXT` | 배열 리터럴(`malformed array literal`); 넣는 값은 원소 타입으로 읽어 정규 텍스트로([배열](arrays.md)) |

정수 열에 넣는 값은 PostgreSQL의 대입처럼 바꿉니다(`integer.zig`의 저장 함수, `INSERT`·`UPDATE`·`INSERT ... SELECT`). 문자열과 매개변수는 정수 입력으로 읽고(`'  12  '`, `'0x10'`, `'-1_000'`; `'34.5'`, `''`, `'- 1234'`는 `invalid input syntax for type smallint: "..."`, `'100000'`은 `value "100000" is out of range for type smallint`), `numeric`(`34.5`)은 0에서 먼 쪽으로, `double precision`·`real`은 짝수 쪽으로 반올림합니다. 정수는 바꾸지 않으므로 그 INSERT는 SQLite의 것과 같은 코드입니다.

- 선언 타입은 `xq_catalog`의 `type` 키에 `format_type()` 철자(`character varying(20)`, `timestamp with time zone`)로 남습니다.
- 다른 타입의 값을 넣으면 SQLite STRICT 오류(`cannot store TEXT value in INTEGER column t.a`)가 납니다.
- `boolean` 열에 넣는 문자열(상수, 텍스트로 바인딩한 매개변수, `INSERT ... SELECT`의 값)은 PostgreSQL이 그 타입의 입력을 읽듯 읽습니다: `'t'`, `'true'`, `'yes'`, `'on'`, `'1'`(그 접두어 `'tr'`, `'of'` ..., 대소문자·앞뒤 공백 무시)은 1/0. 아니면 `invalid input syntax for type boolean: "x"`(22P02). `numeric` 열에 넣는 값은 모두 `xq_dec_key(v, p, s)`를 지납니다(아래 [numeric](numeric.md)). `INSERT`와 `UPDATE`(`ON CONFLICT DO UPDATE` 포함)가 저장 직전에 바꿉니다([타입을 읽는 코드 생성](../architecture.md#타입을-읽는-코드-생성)).
- `date`, `time`, `timestamp`, `timestamptz`, `interval` 열에 넣는 문자열도 그 타입의 입력으로 읽어 PostgreSQL의 출력 텍스트로 넣습니다: `'2024-1-5'`는 `2024-01-05`, `'2 hours'`는 `02:00:00`, `timestamptz`의 `'2024-01-01 10:00:00+02'`는 UTC의 `2024-01-01 08:00:00`. 읽지 못하면 `invalid input syntax for type date: "x"`(22007), 범위 밖의 필드는 `date/time field value out of range: "2024-02-30"`(22008). 텍스트는 그대로 sqlite3의 날짜 함수가 읽습니다.
- `interval` 열에 넣는 값(문자열, 텍스트나 바이너리로 바인딩한 매개변수, interval 식)은 `xq_pg_iv()`로 BLOB이 됩니다. `DEFAULT '1 hour'`는 `DEFAULT (xq_pg_iv('1 hour'))`로 남습니다.
- 모르는 타입은 `type "x" does not exist`(배열이면 `type "x[]" does not exist`), `serial[]`은 `array of serial is not implemented`입니다.

## 캐스트

| 캐스트 | xqlite | PostgreSQL과 다른 점 |
| --- | --- | --- |
| `::date`/`::time`/`::timestamp`/`::timestamptz`/`::interval` | `xq_pg_date()`/`xq_pg_time()`/`xq_pg_timestamp()`/`xq_pg_timestamptz()`/`xq_pg_iv()`(interval의 BLOB; `::text`는 `xq_pg_iv_out()`): PostgreSQL의 입력(ISO 날짜, `T`나 공백 뒤의 시각, 오프셋, `BC`; interval의 단위·시각·`ago`·ISO 8601 `P1DT2H`; `now`, `today`, `tomorrow`, `yesterday`, `epoch`)을 읽어 그 출력으로(초의 소수는 끝의 0 없이: `03:04:05.5`). 읽지 못하면 오류 | `infinity`, 시간대 이름(`Asia/Seoul`), `DateStyle`이 바꾸는 입력·출력은 없음. `timestamptz`는 UTC. `::timetz`는 `time()` |
| `::smallint`/`::int`/`::bigint` | `xq_pg_cast_int2/4/8()`(`integer.zig`): 문자열은 정수 입력으로 읽음(`' 0x1F '`, `'1_000'`; `'2.5'::int`는 `invalid input syntax for type integer: "2.5"`, `'70000'::int2`는 `value "70000" is out of range for type smallint`), 실수는 짝수 쪽으로 반올림(`2.5::float8::int`는 2), `numeric`은 0에서 먼 쪽으로(`2.5::int`는 3), 범위 밖은 `smallint out of range` ... . 예전 스키마가 부르는 `xq_pg_int2/4/8()`(실수는 0에서 먼 쪽, 16진·`_` 없음)은 뜻이 그대로 | |
| `::varchar(n)`, `::char(n)` | 자름. `char(n)`의 결과는 n자로 채워 보여 줌 | |
| `::numeric`, `::numeric(p,s)` | `xq_dec(x [, p, s])`: 정확한 키, s로 반올림, p - s자리를 넘으면 `numeric field overflow`(22003) | |
| `::boolean` | `'t'`/`'yes'`/`'on'` 같은 철자를 읽음 | |
| `::json`/`::jsonb` | `xq_pg_json()`/`xq_pg_jsonb()` | |
| `::uuid`, uuid의 `::text` | `xq_pg_uuid()`(16바이트), `xq_pg_uuid_text()`([uuid](uuid.md)) | `bytea`·정수에서의 캐스트는 실행 중 오류(PostgreSQL은 해석 중 `cannot cast type`) |
| `::int[]`(`text[]`, `numeric[]` ...) | `xq_pg_array_int4()` ...: 배열 입력, 원소마다 그 타입으로 읽어 정규 텍스트로(위 [배열](arrays.md)) | 원소 타입의 typmod(`numeric(10,2)[]`의 반올림, `varchar(3)[]`의 길이)는 적용하지 않음 |
