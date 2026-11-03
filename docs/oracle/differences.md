# Oracle과 다른 점

[Oracle 호환](README.md)의 일부입니다.

| 주제 | Oracle | xqlite | 이유 |
| --- | --- | --- | --- |
| `NUMBER` | 38자리 십진수 | SQLite 수(64비트 정수 또는 실수). `0.1 + 0.2`는 `0.30000000000000004` | 저장 타입이 `ANY`/`INTEGER` |
| 숫자 출력 | `.5`, `2` | `0.5`, `2.0`(실수 나눗셈 결과) | sqlite3 API의 값 타입. `TO_CHAR`는 Oracle 철자 |
| 날짜 | `DATE` 타입, `NLS_DATE_FORMAT`으로 출력 | ISO 텍스트([날짜](dates.md)) | SQLite 날짜 함수가 그대로 읽음 |
| 날짜 연산 | 늘 타입으로 판단 | 파서가 날짜라고 아는 피연산자만 | 식의 타입은 이름 해석 뒤에야 알고, 아직 계산에 쓰지 않음 |
| 식의 타입 | | 수는 `NUMBER`(`BINARY_DOUBLE`이 섞이면 그것), 문자열 리터럴은 `CHAR(n)`, `\|\|`는 길이의 합인 `VARCHAR2`, `COUNT()`·`SUM()`·`LENGTH()`는 `NUMBER`, `TO_DATE()`는 `DATE`([코어의 타입](../architecture.md#코어의-타입)). 결과 열의 선언 타입과 매개변수 타입에만 씀 | 타입은 메타데이터 |
| `SYSDATE` | 서버의 시간대 | UTC | |
| 0으로 나누기 | `ORA-01476` | 같음 | 64비트를 넘는 정수 결과는 오류가 아니라 실수(NUMBER는 38자리) |
| 이름의 대소문자 | `"Emp"`와 `EMP`는 다름 | 같음([이름의 대소문자](names.md)) | SQLite의 이름 비교 |
| `BOOLEAN`(23ai) | `TRUE`/`FALSE` | 정수 1/0. 셸과 서버는 `BOOLEAN` 열과 불리언 식을 `TRUE`/`FALSE`로 보여 줌([값 표시](../architecture.md#값-표시)) | sqlite3 API로 돌아오는 값 타입 |
| 오류 문구 | ORA- 메시지 | 컴파일 때와 저장 변환의 오류, 실행 중 제약 위반([제약 위반](#제약-위반))은 ORA- 코드와 메시지 | |
| DDL | 앞뒤로 커밋 | 커밋하지 않음([트랜잭션](support.md#트랜잭션)) | |
| `RETURNING` | `RETURNING ... INTO`(PL/SQL) | 지원하지 않음 | |
| 외래 키 | 늘 강제 | 같음. 이 방언의 첫 문장에서 연결의 `PRAGMA foreign_keys`를 켬. 응용이 끈 것은 그대로 둠 | sqlite3는 여전히 끈 채로 씀 |
| `CHAR` 비교 | 공백을 채워 비교 | `COLLATE RTRIM` | 근사 |
| 저장되는 식 | | IR이 SQLite 텍스트로 렌더링. 방언 함수는 `xq_oracle_substr(...)`처럼, 저장 변환은 쓰지 않음(DML에만) | 다른 방언에서도 같은 뜻. 평범한 sqlite3는 그런 식을 계산할 수 없고, [확장](../extension.md)을 올린 sqlite3는 같은 결과로 계산(`SYS_CONTEXT()`처럼 세션을 읽는 것만 빠짐). 함수의 뜻은 바뀌지 않음([ABI 규칙](../extension.md#abi-규칙)) |
| JSON 타입 | 이진(OSON) | 정규화한 JSON 텍스트 | sqlite3가 읽음 |
| JSON 결과 열의 순서 | `JSON_OBJECTAGG`, `ORDER BY` 없는 `JSON_ARRAYAGG`는 처리 순서 | SQLite가 행을 읽는 순서 | |
| 셸 | | 셸은 SQLite 규칙으로 문장을 나눔. `/` 줄과 `q'[it's]'` 같은 홀수 따옴표는 한 번에 넘긴 텍스트(`exec`)에서만 | 방언별 문장 경계는 아직 없음 |

## 제약 위반

이 방언으로 컴파일한 문장의 제약 위반은 Oracle의 코드와 메시지입니다. 제약은 `스키마.이름`으로 씁니다(main의 테이블이면 사용자 `MAIN`).

| 위반 | 메시지 | SQLSTATE |
| --- | --- | --- |
| PRIMARY KEY, UNIQUE, 유일 인덱스 | `ORA-00001: unique constraint (MAIN.T_PK) violated` | 23505 |
| `CREATE UNIQUE INDEX`가 중복을 찾음 | `ORA-01452: cannot CREATE UNIQUE INDEX; duplicate keys found` | 23505 |
| NOT NULL | `ORA-01400: cannot insert NULL into ("MAIN"."T"."A")`, UPDATE면 `ORA-01407: cannot update ("MAIN"."T"."A") to NULL` | 23502 |
| CHECK | `ORA-02290: check constraint (MAIN.T_CK) violated` | 23514 |
| 외래 키(자식 행) | `ORA-02291: integrity constraint (MAIN.T_FK) violated - parent key not found` | 23503 |
| 외래 키(부모 행) | `ORA-02292: integrity constraint (MAIN.T_FK) violated - child record found` | 23503 |

- Oracle은 이름 없는 제약을 데이터베이스의 번호로 `SYS_C0012345`처럼 부릅니다. 여기서는 고정된 이름 `SYS_C_<TABLE>_<COLUMNS>`(CHECK는 `SYS_C_<TABLE>`)입니다. 이름을 준 UNIQUE, PRIMARY KEY, FOREIGN KEY의 이름은 CREATE TABLE이 `xq_catalog`에 적어 둡니다(키 `constraint:<종류>:<열>`).
- 타입이 있는 열의 NOT NULL은 저장 변환(`xq_ora_coerce`)이 먼저 `ORA-01400`으로 막습니다. 그 오류는 SQL 함수의 오류라 결과 코드가 SQLITE_ERROR이고, UPDATE에서도 `ORA-01400`입니다.
- 문장이 끝날 때 찾는 외래 키 위반은 마지막으로 센 위반의 제약을 말합니다. 어느 제약인지 모를 때(지연 제약의 COMMIT, DROP TABLE)는 `ORA-02291: integrity constraint violated - parent key not found`입니다.
