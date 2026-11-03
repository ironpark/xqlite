# uuid

[PostgreSQL 호환](README.md)의 일부입니다.

`uuid`는 16바이트 BLOB으로 저장합니다(`src/dialect/postgres/uuid.zig`). PostgreSQL의 uuid 순서(`uuid_cmp()`)는 바이트 순서이므로 SQLite의 BLOB 비교(memcmp)가 곧 PostgreSQL의 순서입니다. 그래서 인덱스, 범위 검색, `ORDER BY`, `PRIMARY KEY`/`UNIQUE`/외래 키가 값 그대로 동작하고, `uuidv7()` 키는 시간 순서라 인덱스에 거의 끝에만 붙습니다.

- 입력은 PostgreSQL의 `uuid_in()`과 같습니다: 16진수 32자리(대소문자 무관), 네 자리마다(마지막 뒤 말고) 하이픈 하나를 둘 수 있음, 전체를 `{}`로 감쌀 수 있음, 공백은 없음. 아니면 `invalid input syntax for type uuid: "x"`(22P02). 출력은 소문자의 `8-4-4-4-12`입니다.
- 열에 넣는 값(상수, 텍스트·이진으로 바인딩한 매개변수, `INSERT ... SELECT`의 값)은 저장 함수 `xq_pg_uuid()`가 16바이트로 바꿉니다. 열의 CHECK `length(u) = 16`(이름 `invalid input syntax for type uuid`)은 다른 BLOB을 막습니다. `DEFAULT '...'`은 CREATE TABLE에서 읽어 `X'..'`로 남고, `DEFAULT gen_random_uuid()`는 `xq_postgres_uuidv4()`입니다.
- 캐스트: `'...'::uuid`는 `xq_pg_uuid('...')`(상수라 한 번 계산), `u::text`와 `u || 'x'`, `concat()`·`format()`의 인자, JSON을 만드는 함수의 인자(`to_json(u)`는 `"a0eebc99-..."`), 배열의 원소(`ARRAY[u]`, `array_agg(u)`, `u = ANY(arr)`)는 그 텍스트(`xq_pg_uuid_text()`)입니다. `uuid[]`는 다른 배열처럼 원소의 텍스트로 저장합니다.
- 비교(`=`, `<` ..., `IN`, `BETWEEN`)는 문자열 상수와 매개변수를 열의 형태로 바꿉니다(`u = xq_pg_uuid('...')`, `u = xq_pg_uuid($1)`). 열은 그대로 두므로 인덱스를 씁니다. 뷰·CHECK·식 인덱스의 텍스트에도 그 함수가 남습니다.
- 셸과 와이어 서버는 텍스트로 보여 줍니다([값 표시](../architecture.md#값-표시)). 와이어의 열 OID는 2950, 이진 형식은 16바이트(결과와 매개변수), API로 돌아오는 값은 16바이트 BLOB입니다.
- **예전 테이블**: uuid를 TEXT로 저장하던 때에 만든 테이블의 열(선언 타입 `uuid`, 저장 `TEXT`)은 그 표현을 유지합니다. 열마다 저장 타입으로 정합니다: 넣는 값은 `xq_pg_uuid_text()`가 정규 텍스트로 바꾸고(`Rules.store_text`), 비교는 상수를 텍스트로 바꿔(`u = xq_pg_uuid_text('...')`) 그 열의 인덱스를 씁니다. 텍스트 열과 BLOB 열의 비교(`old.u = new.u`)는 BLOB 쪽을 텍스트로 바꿔 맞습니다. 새 테이블(`ALTER TABLE ADD COLUMN` 포함)은 BLOB입니다.
- PostgreSQL 18의 함수:
  - `gen_random_uuid()`와 `uuidv4()`: 무작위 버전 4. 파서가 `gen_random_uuid()`를 `uuidv4()`로 부릅니다. 예전 스키마의 `xq_postgres_gen_random_uuid()`는 뜻 그대로(36자 텍스트) 남습니다.
  - `uuidv7([shift interval])`: 앞 48비트가 Unix 밀리초, 다음 12비트가 밀리초 안의 1/4096(RFC 9562의 방법 3), 나머지가 무작위인 버전 7. PostgreSQL처럼 연결(세션)마다 시계가 호출마다 적어도 1/4096밀리초 앞으로 가므로(`get_real_time_ns_ascending()`) 한 연결이 만든 값은 순서대로입니다. `shift`는 `timestamptz + interval`처럼 더하고, 1970년 전이나 48비트 밖이면 `timestamp out of range for UUID version 7`(22008). 확장을 올린 sqlite3도 연결마다 그 시계를 둡니다.
  - `uuid_extract_version(u)`: 버전(`smallint`), RFC 9562 변형이 아니면 NULL.
  - `uuid_extract_timestamp(u)`: 버전 1과 7의 시각(`timestamptz`), 그 밖은 NULL.
  - `gen_random_uuid()`와 `uuidv7()`은 결정적이지 않으므로 인덱스·CHECK에는 쓸 수 없고 DEFAULT에는 씁니다.
