# sqlite3용 확장

xqlite가 방언으로 만든 데이터베이스는 SQLite 파일입니다. 그런데 스키마에 남는 식(CHECK, DEFAULT, 생성 열, 인덱스 식, 뷰, 트리거)은 엔진 함수(`xq_like()`, `xq_pg_jsonb()`, `xq_div()` ...)와 방언의 함수(`xq_postgres_left()` ...)를 부르고, 방언의 collation(`xq_pg_jsonb`, `xq_pg_interval` ...)을 씁니다. 평범한 sqlite3와 시스템 SQLite를 쓰는 프로그램(Python의 `sqlite3`, Datasette, DB Browser)은 그 식에서 `no such function`, `no such collation sequence`로 실패합니다. 그래서 그런 데이터베이스는 xqlite 밖에서 반만 쓸 수 있었습니다.

`libxqlite_ext`는 같은 Zig 소스로 만든 SQLite 로더블 확장입니다. 실제 sqlite3 연결에 스키마 텍스트가 부를 수 있는 엔진 함수와 collation을 모두 등록하고, 뜻은 xqlite와 같습니다(같은 구현을 부르므로). 확장을 올린 sqlite3는 그런 데이터베이스를 읽고 쓰고 `PRAGMA integrity_check`로 검사할 수 있습니다.

## 목차

- [빌드](#빌드)
- [올리기](#올리기)
- [설계](#설계)
- [함수 목록](#함수-목록)
- [빠진 것과 이유](#빠진-것과-이유)
- [ABI 규칙](#abi-규칙)
- [검증](#검증)
- [한계](#한계)

## 빌드

```sh
zig build ext                         # zig-out/lib/libxqlite_ext.dylib (macOS), .so (Linux)
zig build ext -Doptimize=ReleaseFast  # 배포용
zig build ext -Ddialects=postgres     # PostgreSQL 방언의 것만
```

- `zig build tools`도 확장을 만들고, `zig build check`는 그것을 `xqt interop`에 넘깁니다(`--ext`).
- `-Ddialects`를 따릅니다. 빌드에서 뺀 방언의 함수와 collation은 확장에도 없습니다. `-Ddialects=none`이면 어느 방언에도 속하지 않는 것(`xq_like()`, `xq_ilike()`, `xq_ext_version()`)만 남습니다.
- 라이브러리는 SQLite에 링크하지 않습니다. 모든 호출이 로더가 넘겨 주는 `sqlite3_api_routines` 표를 거치므로 그 확장을 올리는 SQLite(시스템 sqlite3, Python, xqlite의 C ABI)의 것을 씁니다. SQLite 3.31.0 이상이 필요합니다(`SQLITE_INNOCUOUS`).
- 내보내는 심볼은 진입점 두 개뿐입니다. 엔진은 라이브러리 안에 감춰져 있어서 올린 SQLite의 `sqlite3_*`와 부딪치지 않습니다.
- WebAssembly는 해당하지 않습니다(동적 로더가 없음). wasm 대상에서 `zig build ext`는 아무것도 만들지 않습니다.

## 올리기

진입점은 `sqlite3_xqliteext_init`입니다. sqlite3의 로더가 파일 이름 `libxqlite_ext`에서 만드는 이름(`lib`를 떼고 글자만 남김)이 이것이고, 이름을 줄 때도 이것을 씁니다. 로더가 먼저 찾는 기본 이름 `sqlite3_extension_init`도 같은 함수입니다.

sqlite3 셸:

```sh
sqlite3 app.db
sqlite> .load ./zig-out/lib/libxqlite_ext
sqlite> PRAGMA integrity_check;
ok
sqlite> SELECT xq_ext_version();
1
```

`.load FILE sqlite3_xqliteext_init`처럼 진입점을 줄 수도 있습니다. C에서는 `sqlite3_enable_load_extension(db, 1)` 뒤에 `sqlite3_load_extension(db, "libxqlite_ext", 0, &err)`(`tools/capi/capi_test.c`의 `test_b_xqlite_ext()`).

Python:

```python
import sqlite3

con = sqlite3.connect("app.db")
con.enable_load_extension(True)
con.load_extension("./zig-out/lib/libxqlite_ext")
con.enable_load_extension(False)
print(con.execute("PRAGMA integrity_check").fetchone())   # ('ok',)
for row in con.execute("SELECT * FROM doc_v"):             # 엔진 함수를 부르는 뷰
    print(row)
```

함수는 연결마다 등록되므로 연결마다 올립니다. 같은 연결에 두 번 올려도 됩니다(새로 등록한 것이 바꿈).

`nextval()`처럼 쓰는 함수는 innocuous가 아니므로, 스키마(DEFAULT)에서 부르려면 xqlite처럼 `PRAGMA trusted_schema=ON`이어야 합니다. sqlite3 셸은 기본으로 끄고, Python의 sqlite3는 켜 둡니다. 나머지 함수와 collation은 xqlite의 내장 함수처럼 innocuous라 `trusted_schema`와 상관없이 스키마에서 씁니다.

## 설계

어댑터이지 포크가 아닙니다. 확장의 함수는 xqlite의 `FuncDef` 자체(`src/dialect/abi.zig`의 `catalogue`)이고, 호출마다 같은 구현을 엔진의 진짜 `Context`와 `Mem`으로 부릅니다.

| 부분 | 위치 | 하는 일 |
| --- | --- | --- |
| C 쪽 | `src/loadable/entry.c` | 진입점, `SQLITE_EXTENSION_INIT1/2`, 쓰는 API(`sqlite3_value_*`, `sqlite3_result_*`, `sqlite3_create_function_v2` ...)를 감싼 작은 함수. 표가 C 구조체라 sqlite3ext.h로 쓰면 순서가 저절로 맞음(`src/capi/loadext.c`와 같은 이유) |
| 어댑터 | `src/loadable/root.zig` | 연결마다 사설 xqlite 연결(아무것도 저장하지 않는 메모리 DB) 하나. `sqlite3_value`를 같은 타입의 `Mem`으로(텍스트·블롭은 sqlite3의 바이트를 가리키는 `MEM_Static`, 서브타입 포함), 구현을 부르고, 결과 `Mem`(값, 서브타입, 오류 메시지와 코드)을 `sqlite3_result_*()`로 |
| 집계·윈도우 | 같은 파일 | 엔진의 누산기 `Mem`을 `sqlite3_aggregate_context()`에 두고, 끝은 `OP_AggFinal`처럼 `mem.finalize()`, 윈도우의 현재 값은 `mem.aggValue()` |
| collation | 같은 파일 | `CollSeq.cmp`를 `sqlite3_create_collation_v2()`로 |
| 시퀀스 | `src/loadable/sequence.zig` | `nextval()` 등을 sqlite3 연결 자신에서 SQL로 |
| 목록과 ABI | `src/dialect/abi.zig`, `abi.txt` | 스키마가 부를 수 있는 함수·collation 전부, 빠진 것과 이유, ABI 버전 |
| 루트 | `src/loadable.zig` | 모듈이 `src/` 안의 파일을 쓰도록 `src/capi.zig` 옆에 둔 루트 |

값 API를 두 번째 백엔드(`Context`·`Mem`을 `sqlite3_context`·`sqlite3_value`로 바꾸는 comptime 선택)로 갈아 끼우지 않은 이유는, 구현이 값 API보다 많은 것을 쓰기 때문입니다.

- 연결의 할당자(`dfunc.gpa()`, `contextDbHandle(ctx).gpa`), 한도(`SQLITE_LIMIT_LENGTH`), PRNG(`random()`, UUID)
- 엔진의 집계 상태(`dfunc.aggState()`가 누산기 `Mem`을 씀)
- 보조 데이터(`getAuxdataTyped()`: `xq_coerce()`가 파싱한 타입을, SQLite의 JSON 함수가 파싱한 JSON을 둠)와 문장 시각(`stmtCurrentTime()`)
- 엔진의 `memCompare()`(`greatest()`), printf, SQLSTATE가 붙은 오류(`resultErrorState()`)
- `Mem` 위의 SQLite 변환(REAL의 텍스트, 텍스트의 수 친화도). 구현이 쓰는 `api.*` 호출은 41가지(값 읽기 `valueText`·`valueInt64`·`valueDouble`·`valueType`·`valueBlob`·`valueBytes`·`valueSubtype`·`valueNumericType`·`valueDup`·`valueFree`, 결과 `resultNull`·`resultInt64`·`resultDouble`·`resultText`·`resultBlob`·`resultValue`·`resultSubtype`·`resultError`·`resultErrorState`·`resultErrorFrom`·`resultErrorNomem`·`resultErrorTooBig`, 문맥 `contextDbHandle`·`userData`·`getAuxdataTyped`·`setAuxdataTyped`·`stmtCurrentTime`, 그리고 연결에서 SQL을 돌리는 함수만 쓰는 문장 API `step`·`reset`·`finalize`·`column*`·`bind*`)

이것을 sqlite3 쪽으로 다시 짜면 변환과 비교의 구현이 둘이 되고, 그 둘이 한 구석에서라도 다르면 식 인덱스가 깨집니다. 여기서는 하나입니다. 값 API의 호출은 모두 엔진의 것이 진짜 `Mem` 위에서 하고, 문맥 쪽은 어댑터가 채웁니다.

| 호출 | 확장에서 |
| --- | --- |
| `contextDbHandle()`, `dfunc.gpa()` | 사설 연결(할당자, 한도, PRNG) |
| `getAuxdata*()`, `setAuxdata*()` | 대리 문장(`OP_Function` 하나인 `Vdbe`)에 두고 호출이 끝나면 지움. SQLite의 JSON 캐시처럼 넣고 바로 읽는 것은 되고, 호출을 넘는 캐시는 없음(`xq_coerce()`는 호출마다 타입을 파싱) |
| `uuidv7()`의 시계(`ConnState.postgres`) | 사설 연결의 것이라 sqlite3 연결마다 하나: 한 연결이 만든 uuidv7은 순서대로 |
| `stmtCurrentTime()` | 호출마다 시계를 읽음(xqlite는 문장마다 한 번). `'now'`가 한 문장 안에서도 행마다 다를 수 있음 |
| `aggregateContext()`, `dfunc.aggState()` | `sqlite3_aggregate_context()` 안의 누산기 `Mem` |
| `resultErrorState()` | 메시지와 결과 코드만(sqlite3에는 SQLSTATE가 없음) |
| `resultErrorNomem()` | `sqlite3_result_error_nomem()`, 사설 연결의 메모리 부족 상태는 호출 뒤에 지움 |
| `resultSubtype()` | 함수에 `SQLITE_RESULT_SUBTYPE`가 있을 때만(`SQLITE_STRICT_SUBTYPE`로 빌드한 sqlite3는 없는 함수가 서브타입을 주면 실패) |

등록 플래그는 엔진이 다루는 대로입니다: `CONSTANT`는 `SQLITE_DETERMINISTIC`, `UNSAFE`가 아니면 `SQLITE_INNOCUOUS`, `DIRECT`는 `SQLITE_DIRECTONLY`, 서브타입 플래그는 그대로. SQLite 내장 함수의 "하나 이상"(-3) 같은 인자 수는 `-1`로 등록하고 호출에서 검사합니다(그래서 그 오류는 컴파일이 아니라 실행 중에 남).

## 함수 목록

스키마가 부를 수 있는 이름은 다섯 가지이고, 전체 목록(이름, 인자 수, 플래그)은 `src/dialect/abi.txt`입니다. 확장을 올린 연결에서는 `SELECT name, narg FROM pragma_function_list WHERE name LIKE 'xq\_%' ESCAPE '\'`로도 봅니다.

| 종류 | 이름 | 예 |
| --- | --- | --- |
| 엔진 함수 | `xq_*`(방언마다 `xq_pg_*`, `xq_tsql_*`, `xq_ora_*`, MariaDB는 `xq_div` 같은 이름) | `xq_like('a%', s)`, `xq_pg_jsonb_get_text(body, 'kind')` |
| 방언 함수의 한정 이름 | `xq_<방언>_<이름>`(`dialect.qualifiedFunctionSearch()`) | `xq_postgres_left(s, 2)`, `xq_mariadb_JSON_EXTRACT(j, '$.a')` |
| 방언이 가린 SQLite 내장 함수 | `xq_sqlite_<이름>`(`lower.functionName()`) | `xq_sqlite_concat(a, b)`, `xq_sqlite_json_extract(...)` |
| 시퀀스 함수 | identity의 DEFAULT가 부르는 평범한 이름 | `nextval('t_id_seq')`, `currval()`, `setval()`, `lastval()` |
| collation | 방언의 것 | `COLLATE xq_pg_jsonb`, `xq_pg_interval`, `xq_pg_array`, `xq_pg_array_num` |

PostgreSQL의 `jsonb` 열은 SQLite의 JSONB(BLOB)라서 값 자체는 확장 없이 읽힙니다(`json(j)`, `json_extract(j, '$.a')`, `j ->> '$.a'`). 확장이 드는 것은 jsonb의 연산자·비교·정렬이 남긴 식입니다: `xq_pg_jsonb_get()` ...과 `xq_pg_jsonb_key()`(비교와 `ORDER BY`의 정렬 키), `xq_pg_jsonb_bin()`(정준 JSONB: 상수가 아닌 DEFAULT, 생성 열), `xq_pg_jsonb_text()`(`jsonb::text`). sqlite3가 jsonb 열에 넣을 때는 `jsonb('...')`(정준이 아닐 수 있음, 방언이 읽을 때 정규화) 또는 확장의 `xq_pg_jsonb_bin('...')`을 씁니다. TEXT는 STRICT BLOB 열이 받지 않습니다.

방언별로 확장이 등록하는 수(모든 방언을 넣은 빌드, 인자 수가 다른 것은 따로 셈; 모두 753개, 빠지는 것 65개). 이 표의 수는 `src/dialect/abi.zig`의 테스트가 카탈로그와 맞춰 봅니다:

| 방언 | 엔진 함수 | 한정 이름 | 시퀀스 | 빠짐 | collation |
| --- | --- | --- | --- | --- | --- |
| 공통 | 47(`xq_like` 2, `xq_ilike` 2, `xq_ext_version`, numeric의 `xq_dec*` 42) | | 5(`nextval`, `currval`, `setval` 2, `lastval`) | | |
| PostgreSQL | 179 | 224 | 5 | 36 | 4 |
| MariaDB | 19 | 101 | 4 | 5 | |
| SQL Server | 18 | 40 | 2 | 20 | |
| Oracle | 20 | 49 | 5 | 4 | |
| SQLite 내장(`xq_sqlite_*`) | | 35 | | | |

모두 결정적이면 결정적으로 등록하므로 식 인덱스, CHECK, 생성 열에 쓸 수 있습니다. `xq_pg_iv_out()`(interval의 텍스트, xqlite에서는 세션의 `IntervalStyle`)은 결정적이지 않아 CHECK와 뷰에만 쓰이고(xqlite에서는 stable: 상수 인자의 텍스트는 문장마다 한 번 만듦), 확장에서는 세션이 없으므로 기본 형식(postgres)으로 씁니다. 집계(`xq_stddev_pop()`, `xq_postgres_array_agg()`, `xq_tsql_for_json()` ...)와 윈도우 함수(`xq_postgres_array_agg`의 윈도우 형태)도 등록합니다.

## numeric 키

PostgreSQL의 `numeric` 열(`dialect/decimal.zig`)은 값 자체가 정렬 키인 BLOB입니다. 키의 바이트는 디스크 형식이라 바뀌지 않습니다.

- 첫 바이트는 부류: `0x10` -Infinity, `0x20` 음수, `0x30` 0, `0x40` 양수, `0x50` +Infinity, `0x60` NaN.
- 양수 0.c1c2...cn × 100^E(c는 100진 자리, 처음과 끝이 0 아님): E는 -126..125면 한 바이트 E + 0x80, 더 크면 `0xFE`와 빅엔디언 2바이트 E - 126, 더 작으면 `0x01`과 2바이트 E + 65661. 자리는 한 바이트 2c + 1, 마지막만 2c.
- 음수는 부류 뒤의 바이트를 모두 보수(255 - b)로.
- 저장한 값은 키뿐이고(정규화: `1.50`과 `1.5`는 한 키), 계산한 값은 표시 스케일을 뒤에 빅엔디언 2바이트로 붙일 수 있습니다(다른 수의 순서는 바꾸지 않음). `xq_dec_key()`가 떼어냅니다.

엔진 함수(모든 방언, `decimal_sql.zig`): `xq_dec(x [, p, s])`, `xq_dec_key(x [, p, s])`, `xq_dec_valid(k [, p, s])`, `xq_dec_text(x [, s])`, `xq_dec_add`/`sub`/`mul`/`div`/`mod`/`div_trunc`, `xq_dec_neg`/`abs`/`ceil`/`floor`/`sign`/`trim_scale`, `xq_dec_round`/`trunc(x [, s])`, `xq_dec_scale`/`min_scale`, `xq_dec_int2`/`int4`/`int8`/`float4`/`float8`/`number`, `xq_dec_sqrt`/`exp`/`ln`/`log(x)`(밑 10)/`log(b, x)`/`power(x, y)`(PostgreSQL의 자릿수와 스케일, `decimal_math.zig`), `xq_dec_factorial(n)`, `xq_dec_width_bucket(x, b1, b2, n)`(정수), 집계·윈도우 `xq_dec_sum`/`xq_dec_avg`. 인자는 키, 정수, 실수(15자리), 텍스트(`numeric_in()`)이고, 결과와 오류는 PostgreSQL의 것입니다. sqlite3에서 numeric 열에 쓰려면 키를 넘깁니다(`INSERT INTO t VALUES (xq_dec_key('1.50'))`). 결과는 `tools/ext/abi-core.sql`에 기록되어 있습니다.

시퀀스 함수는 `catalog/sequence.zig`과 같은 문장을 같은 표(`main.xq_sequence`)에 sqlite3 연결 자신에서 돌립니다. 그래서 한 엔진이 준 값은 다른 엔진이 다시 주지 않고, 오류 문구(`relation "x" does not exist`, `nextval: reached maximum value of sequence ...`)도 같습니다. `currval()`과 `lastval()`은 xqlite처럼 연결마다입니다. MariaDB의 `LASTVAL(seq)`(한정 이름 `xq_mariadb_lastval`)는 NULL을 돌려주고, SQL Server의 `NEXT VALUE FOR`(`xq_mssql_xq_tsql_next_value`)와 identity의 `nextval()`은 시퀀스만 움직입니다(`SCOPE_IDENTITY()`는 xqlite 세션의 것).

## 빠진 것과 이유

`abi.zig`의 `unportable_names`가 이유와 함께 적고, `abi.txt`에 `xqlite-only:<이유>`로 남습니다. 모두 인자만으로 정해지지 않는 함수라 인덱스나 CHECK에는 있을 수 없고, 그것을 부르는 뷰는 xqlite에서만 읽힙니다.

| 이유 | 함수 |
| --- | --- |
| xqlite 세션의 상태(`session`) | PostgreSQL `current_setting()`, `set_config()`, `current_schema()`, `current_schemas()`, `current_database()`, `pg_backend_pid()`; MariaDB의 시스템·사용자 변수(`xq_sysvar`, `xq_uservar`); SQL Server `SCOPE_IDENTITY()`, `@@TRANCOUNT`(`xq_tsql_trancount`), 변수(`xq_tsql_getvar`); Oracle `SYS_CONTEXT()`, `set_current_schema()`, `xq_ora_autocommit()` |
| xqlite가 연결에 두는 카탈로그(`catalog`) | PostgreSQL의 reg 형(`xq_pg_regclass` ... `_out`), `to_regclass()` 계열, `pg_get_viewdef()`·`pg_get_indexdef()`·`pg_get_constraintdef()`·`pg_get_expr()`·`pg_get_serial_sequence()`, `obj_description()`·`col_description()`, `pg_table_is_visible()`·`pg_type_is_visible()`; SQL Server `IDENT_CURRENT()`, `SCHEMA_ID()`, `SCHEMA_NAME()`, `OBJECT_NAME()`, `OBJECT_SCHEMA_NAME()`, `xq_tsql_schema_of`, `xq_tsql_bare_name` |
| 최상위 SQL 전용(`direct_only`) | 변수 대입, `IDENTITY_INSERT`, 트랜잭션, MERGE, `USE` 같은 frontend 내부 함수. SQLite가 스키마에서 부르지 못하게 함 |
| 인라인 내장 함수(`inline_builtin`) | 방언이 가린 SQLite 내장 함수 중 인라인으로 컴파일되거나 VM을 읽는 것. 지금 빌드에는 없음(목록이 비어 있음) |

등록하지 않는 것이 하나 더 있습니다. 엔진의 테이블 값 함수(MariaDB `JSON_TABLE`의 `xq_maria_json_table`, SQL Server `OPENJSON`, Oracle `JSON_TABLE`, `pg_catalog`의 `xq_pg_class` ...)는 엔진의 가상 테이블 인터페이스(`sql/vtab.zig`)로 짜여 있어 어댑터가 다리를 놓지 않습니다. 그것을 읽는 뷰는 sqlite3에서 `no such table`입니다.

## ABI 규칙

식 인덱스나 STORED 생성 열은 한 엔진이 계산해 파일에 넣은 값을 다른 엔진이 읽고, 다시 계산해 비교합니다(`PRAGMA integrity_check`, UPDATE·DELETE의 인덱스 항목 찾기). 두 엔진의 결과가 다르면 인덱스가 깨진 것입니다. 그래서 스키마가 부를 수 있는 함수와 collation의 뜻은 파일 형식의 일부입니다.

- **규칙: 스키마가 부를 수 있는 함수·collation은 뜻(결과, 오류, NULL 처리, 비교 순서)을 바꾸지 않습니다. 바꾸려면 새 이름을 만들고, 옛 이름은 옛 뜻을 그대로 둡니다.** 새 frontend는 새 이름을 쓰고, 옛 데이터베이스는 옛 이름으로 계속 읽힙니다.
- 프론트엔드가 상수로 더하는 인자의 값도 뜻의 일부입니다: `xq_pg_to_char(x, t, 종류)`·`xq_pg_timezone(z, x, 종류)`·`xq_pg_at_time_zone(z, x, 종류)`(`AT TIME ZONE`으로 쓴 것, 같은 계산)의 종류(`formatting.Kind`의 번호), `xq_pg_gcd(a, b, 비트)`의 비트(32, 64, numeric은 0). 이미 있는 스키마의 텍스트도 적힌 뜻 그대로 읽힙니다: 다시 컴파일할 때 그런 인자를 더하지 않습니다(PostgreSQL의 `xq_postgres_to_char(x, t)`는 저장 형식으로 읽음).
- `xq_ext_version()`은 엔진과 확장에서 같은 상수(`abi.zig`의 `version`, 지금 1)를 돌려줍니다. 새 이름으로 피할 수 없는 뜻의 변경이 있었다면 그때만 올립니다(지금까지 없음). 응용은 두 값을 비교해 확장이 데이터베이스를 쓴 xqlite와 맞는지 볼 수 있습니다.
- 확장과 엔진은 같은 소스로 만들어지므로, 같은 릴리스의 둘은 결과가 같습니다. 다른 릴리스 사이의 규칙이 위의 것입니다.

규칙을 지키는 검사는 셋입니다.

| 검사 | 지키는 것 |
| --- | --- |
| `src/dialect/abi.zig`의 테스트 `abi: ...`와 `abi.txt` | 이름, 인자 수, 출처, 플래그(결정성, unsafe, 서브타입), 빠진 것과 이유, collation. 기록된 줄이 사라지거나 바뀌면 실패(데이터베이스가 깨짐), 새 함수는 `abi.txt`에 줄을 더해야 통과. 모든 방언을 넣은 빌드에서만 |
| `xqt interop ext`의 `abi cases` + `tools/ext/abi-*.sql` | 가장자리 값(NULL, 범위 끝, 잘못된 입력과 그 오류 문구)에서 결과가 기록 `tools/ext/abi-*.out`과 같음. xqlite와 확장을 올린 sqlite3 둘 다. 뜻을 바꾸면 여기서 실패하고, 새 이름을 만들라는 뜻. 기록을 다시 쓰는 것(`XQT_EXT_RECORD=1`)은 함수를 더할 때만 |
| `xqt interop ext`의 방언별 검사 | 한 엔진이 쓴 인덱스 항목을 다른 엔진의 `integrity_check`가 다시 계산해 확인 |

## 검증

`xqt interop ext`(`tools/xqt/interop/ext.zig`)가 확장을 올린 sqlite3-ref(`--ext`, `$XQT_EXT`, 기본 `zig-out/lib/libxqlite_ext.{dylib,so}`)로 다음을 봅니다. 빌드에 있는 방언마다:

| 검사 | 하는 일 |
| --- | --- |
| integrity | 그 방언으로 만든 데이터베이스(jsonb·배열·interval·numeric·boolean 열, 엔진 함수의 CHECK·생성 열·식 인덱스·뷰, collation으로 정렬하는 뷰, identity)를 확장을 올린 sqlite3가 `PRAGMA integrity_check`로 통과. 확장 없는 sqlite3는 통과하지 못함 |
| reads | CHECK, 생성 열, 뷰, 기본값의 결과가 xqlite(SQLite 방언, collation을 쓰는 것은 그 방언)와 같음 |
| rejects | 방언의 CHECK를 어기는 sqlite3의 INSERT·UPDATE가 xqlite와 같은 오류로 거부됨 |
| writes | sqlite3가 jsonb·배열·interval·numeric·boolean 열과 identity 표에 쓴 행이 xqlite의 `integrity_check`를 통과하고(sqlite3가 만든 인덱스 항목을 xqlite가 다시 계산), 방언으로 다시 읽힘. 시퀀스는 두 엔진 사이에서 이어짐 |
| Python's sqlite3 | 시스템 Python의 `sqlite3`(시스템 SQLite)가 확장을 올려 같은 것을 읽음. `python3`이 없거나 확장을 못 올리면 건너뜀 |
| abi cases | 위의 [ABI 규칙](#abi-규칙) |

그리고 방언과 상관없이:

| 검사 | 하는 일 |
| --- | --- |
| generated calls (4조각) | 확장을 올린 sqlite3가 나열하는(`pragma_function_list`) 결정적인 `xq_*` 함수마다, 가장자리 값 묶음(NULL, 64비트 끝, `-0.0`, `1e308`, 빈 텍스트·블롭, 잘못된 UTF-8, JSON, 배열, interval, 날짜, 경로, 패턴, 타입 이름 ...)에서 뽑은 인자로 부르는 문장을 만들어 xqlite와 sqlite3+확장에서 돌리고, 결과(`quote()`)와 오류 문구를 비교. 집계는 세 행에 걸쳐. `XQT_SEED`로 시드를 바꿈(기본은 고정) |
| load and version | `xq_ext_version()`이 두 엔진에서 같고, 진입점 이름으로, 두 번 올려도 됨 |

C API 테스트(`zig build test-capi`)는 확장을 libxqlite3에 올려(`test_b_xqlite_ext()`) 같은 `sqlite3_api_routines` 경로를 확인합니다.

이 검사가 찾은 엔진의 버그는 고쳤습니다: 인자가 모자라거나 범위를 넘는 호출에서 xqlite 자신도 죽던 함수들(`xq_pg_json_ctor_object()`·`_array()`, `xq_pg_slice()`, `xq_pg_subscript()`, `xq_pg_array_set()`, `xq_tsql_json_object()`·`_array()`, `xq_tsql_for_json()`는 SQLite의 `wrong number of arguments` 오류로(`dfunc.atLeast()`), `pg_size_pretty(1e308)`, `REPLICATE(s, 1e308)`, `EOMONTH(d, 1e308)`, MariaDB `INSERT(s, 2, 9223372036854775807, t)`, 큰 배열 첨자의 넘침).

### ir_ext 퍼저: 렌더링한 텍스트를 sqlite3+확장으로

`ir_ext`(`src/ir/fuzz.zig`의 `extRoundtrip()`)는 `ir_roundtrip`의 테이블 이벤트를 확장을 올린 sqlite3로 봅니다. `generated calls`가 함수 하나하나를 보는 데 비해, 이것은 렌더러가 실제로 쓰는 호출의 조합(중첩, 인자의 타입, `xq_coerce()`, 방언 함수)을 봅니다.

1. 방언 d마다 CHECK·DEFAULT·생성 열이 있는 무작위 테이블(`gen.TableSpec`)을 트리로 만들고(렌더링한 SQLite 텍스트가 엔진 함수를 부름), 행을 SQLite 텍스트로 넣습니다. CHECK나 STRICT 타입이 거부한 행을 셉니다.
2. 그 파일(`VACUUM INTO`)을 확장을 올린 sqlite3가 읽어 `PRAGMA integrity_check`가 `ok`이고 저장된 행(기본 열과 생성 열의 `quote()`)이 xqlite의 것과 같아야 합니다.
3. 테이블을 비운 파일에 sqlite3+확장이 같은 INSERT를 돌려, 같은 행을 거부하고 같은 행을 저장해야 합니다.

`zig build check -Dfuzz=true`가 같은 빌드의 확장(`--ext`)으로 무작위 시드로 돌립니다. 손으로는 `zig build ext tools && zig build fuzz -- ir_ext [SEED] --ext $PWD/zig-out/lib/libxqlite_ext.dylib`(또는 `$XQT_EXT`)이고, 확장을 주지 않으면 건너뜁니다(예전 빌드의 라이브러리와 비교하지 않도록 기본 경로를 찾지 않음). 시드 다섯 개로 300 이벤트씩(테이블 약 7300개, 그중 약 2800개가 `xq_*` 함수를 부름, 행 약 29000개) 차이가 없었습니다.

## 한계

- 엔진의 테이블 값 함수는 없습니다(위).
- xqlite의 SQLite 방언은 방언의 collation과 평범한 이름의 시퀀스 함수를 그 방언에서만 찾습니다(`dialect.findCollation()`, `Hooks.functions`). 그래서 jsonb·배열로 정렬하는 뷰(interval은 예전 `TEXT` 열을 정렬하는 것만: interval BLOB의 비교·정렬은 엔진 함수와 BLOB 순서)나 `nextval()` DEFAULT는 xqlite의 SQLite 방언 연결에서는 읽히지 않는데, 확장을 올린 sqlite3에서는 읽힙니다. 엔진은 바꾸지 않았습니다(SQLite 방언의 동작이 그대로이도록).
- 세션에 기대는 함수의 기본값: `xq_coerce()`(MariaDB의 열 변환)는 새 세션의 `sql_mode`(엄격 모드)로 계산하고, 경고는 남지 않습니다. xqlite에서도 그 결과는 `sql_mode`에 따라 다르므로 STORED 열에는 맞지 않습니다.
- 방언의 산술(0으로 나누기, 정수 범위)은 함수가 아니라 문장을 컴파일한 방언의 바이트코드라, sqlite3에서는 SQLite의 산술입니다(`1/0`은 NULL). 저장되는 식의 범위 검사는 CHECK라 sqlite3에서도 지켜집니다.
- 오류의 SQLSTATE와 방언의 오류 번호는 sqlite3로 가지 않고 메시지만 갑니다. 메시지 안의 NUL은 sqlite3에서 거기서 끊깁니다.
- xqlite의 C ABI에 이 확장을 SQL의 `load_extension()`으로(문장 실행 중에) 올리면, 같은 이름의 엔진 함수가 이미 있어 `unable to delete/modify user-function due to active statements`로 실패합니다. C의 `sqlite3_load_extension()`은 됩니다(xqlite에는 확장이 필요 없지만).
