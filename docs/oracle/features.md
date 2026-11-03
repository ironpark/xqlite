# Oracle 호환: 지원 기능

xqlite Oracle 방언이 지원하는 핵심 시맨틱, 데이터 타입, DDL/DML 구문, 날짜 연산, 특수 함수 및 데이터 사전 뷰의 상세 명세입니다.

---

## 1. Oracle 핵심 시맨틱

### 1.1 빈 문자열의 NULL 취급 (Empty String is NULL)
Oracle 표준에 따라 길이가 0인 문자열 리터럴 `''`과 빈 문자열 연산 결과는 항상 `NULL`로 취급됩니다.
- `'abc' || ''`의 결과는 `'abc'`입니다.
- `INSERT INTO t (col) VALUES ('')` 시 해당 열에는 `NULL`이 저장됩니다.
- `WHERE col = ''`는 참이 될 수 없으며, `WHERE col IS NULL`을 사용해야 합니다.

### 1.2 식별자 대문자 폴딩 (Uppercase Folding)
큰따옴표로 감싸지 않은 모든 식별자(테이블, 열, 뷰 이름 등)는 대문자로 자동 변환됩니다.
- `CREATE TABLE my_table (my_col INT);` → `MY_TABLE`, `MY_COL`로 등록.
- 대소문자를 유지하려면 `"my_table"`과 같이 큰따옴표를 사용해야 합니다.

### 1.3 암묵적 트랜잭션 관리
Oracle은 명시적인 `BEGIN` 문장 없이 동작합니다.
- `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `INSERT ALL` 실행 시 트랜잭션이 자동으로 시작됩니다.
- 변경 사항을 영구적으로 디스크에 반영하려면 명시적으로 `COMMIT;`을 실행해야 합니다.
- `ROLLBACK;`을 실행하면 현재 트랜잭션의 모든 변경 사항이 취소됩니다.

---

## 2. 데이터 타입 매핑

테이블은 `STRICT` 모드로 생성되며 Oracle 타입 제약을 엄격히 검사합니다.

| Oracle 타입 | 저장 타입 | 설명 및 제약 |
| --- | --- | --- |
| `NUMBER`, `NUMBER(p,s)` | `ANY` 또는 `INTEGER` | 소수점이 없으면 64비트 정수로, 소수점이 있으면 실부동소수점으로 저장됩니다. 정밀도 p와 스케일 s 범위를 검사합니다 (`ORA-01438`). |
| `BINARY_FLOAT`, `BINARY_DOUBLE` | `REAL` | 부동소수점 실수. |
| `VARCHAR2(n [BYTE\|CHAR])`, `VARCHAR(n)`, `NVARCHAR2(n)` | `TEXT` | 최대 길이 n 초과 시 `ORA-12899` 오류를 발생시킵니다. |
| `CHAR(n)`, `NCHAR(n)` | `TEXT` (`COLLATE RTRIM`) | 고정 길이 문자열. 비교 시 후행 공백이 무시됩니다. |
| `DATE` | `TEXT` | **날짜와 시각을 모두 포함**하며 ISO 형식(`YYYY-MM-DD HH24:MI:SS`)으로 저장됩니다. |
| `TIMESTAMP[(p)]` | `TEXT` | 마이크로초 단위 소수점 초를 포함하는 시각. |
| `CLOB`, `NCLOB`, `LONG` | `TEXT` | 대용량 텍스트. |
| `BLOB`, `RAW(n)`, `LONG RAW` | `BLOB` | 바이너리 데이터. |
| `BOOLEAN` | `INTEGER` | 0 또는 1 정수로 저장되며 질의 출력 시 `TRUE`/`FALSE`로 렌더링됩니다. |
| `JSON` | `TEXT` | 유효한 JSON 텍스트 (`json_valid`). |

---

## 3. 지원 SQL 문장 및 특수 구문

### 3.1 DDL (데이터 정의어)
- **`CREATE TABLE`**:
  - `GENERATED {ALWAYS | BY DEFAULT} AS IDENTITY` 지원
  - 제약조건: `PRIMARY KEY`, `UNIQUE`, `NOT NULL`, `CHECK`, `REFERENCES`
- **시퀀스**: `CREATE SEQUENCE seq_name`, `seq_name.NEXTVAL`, `seq_name.CURRVAL`
- **가상 테이블**: `DUAL` 더미 테이블 지원 (`SELECT 1 + 1 FROM DUAL;`)
- **가상 열**: `ROWNUM` (질의 결과 행 번호 1-based 제한 조건 지원)

### 3.2 DML (데이터 조작어)
- **`SELECT`**:
  - `(+)` 구식 외부 조인 구문 지원: `SELECT * FROM a, b WHERE a.id = b.id(+)`
  - 계층형 쿼리: `START WITH ... CONNECT BY PRIOR ...`
  - 페이징: `WHERE ROWNUM <= n` 및 `OFFSET n ROWS FETCH NEXT m ROWS ONLY`
- **`MERGE INTO`**:
  - 소스 테이블과 타깃을 조인하여 `WHEN MATCHED THEN UPDATE`, `WHEN NOT MATCHED THEN INSERT`를 통합 수행
- **`INSERT ALL`**:
  - 다중 테이블 조건부 일괄 삽입: `INSERT ALL INTO t1 VALUES (...) INTO t2 VALUES (...) SELECT ...`

---

## 4. 날짜 산술 연산 및 내장 함수

### 4.1 날짜 산술 연산
- `date + n`: n일을 더한 날짜를 계산.
- `date - n`: n일을 뺀 날짜를 계산.
- `date1 - date2`: 두 날짜 사이의 일수(소수점 포함)를 부동소수점으로 반환.

### 4.2 내장 함수
- **조건 및 치환**: `NVL(expr1, expr2)`, `NVL2(expr1, expr2, expr3)`, `DECODE(val, search, result, ..., default)`, `COALESCE(...)`, `NULLIF(a, b)`
- **형식 변환**:
  - `TO_CHAR(val [, fmt])`: 날짜 및 숫자를 지정된 포맷 모델로 변환.
  - `TO_DATE(str [, fmt])`: 문자열을 날짜로 변환.
  - `TO_NUMBER(str)`
- **날짜 함수**: `SYSDATE`, `SYSTIMESTAMP`, `ADD_MONTHS(d, n)`, `MONTHS_BETWEEN(d1, d2)`, `LAST_DAY(d)`, `NEXT_DAY(d, day)`, `TRUNC(d [, fmt])`, `ROUND(d [, fmt])`
- **문자열 함수**: `SUBSTR()`, `INSTR()`, `LENGTH()`, `LPAD()`, `RPAD()`, `TRIM()`, `LTRIM()`, `RTRIM()`, `REPLACE()`, `UPPER()`, `LOWER()`, `CONCAT()`
- **수학 함수**: `ABS()`, `CEIL()`, `FLOOR()`, `ROUND()`, `TRUNC()`, `MOD()`, `POWER()`, `SQRT()`, `SIGN()`
- **JSON 함수**: `JSON_OBJECT`, `JSON_ARRAY`, `JSON_VALUE`, `JSON_QUERY`, `JSON_EXISTS`
- **데이터 사전 뷰**: `USER_TABLES`, `USER_TAB_COLUMNS`, `USER_CONSTRAINTS`, `USER_SEQUENCES`, `ALL_TABLES`
