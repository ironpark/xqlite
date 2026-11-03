# MariaDB와 다른 점

[MariaDB 호환](README.md)의 일부입니다.

## 타입과 값

| 항목 | xqlite |
| --- | --- |
| `DECIMAL` | `REAL`로 저장합니다(scale 0이고 정밀도 18 이하면 `INTEGER`). 반올림은 되지만 정확한 십진 연산이 아닙니다. API로는 `220.00`이 `220.0`이고, 셸과 서버는 `DECIMAL(p,s)` 열을 s자리로 보여 줍니다(`220.00`, [값 표시](../architecture.md#값-표시)). `CAST(x AS DECIMAL(p,s))`와 스케일을 아는 식(`1.50`, `d + 1`, `7 / 2`의 `3.5000`, `AVG(int)`의 `7.0000`, `ROUND(x, 2)`)도 그렇습니다. |
| 식의 타입 | MariaDB의 규칙으로 매깁니다: 정수 리터럴은 `int`(64비트면 `bigint`), `1.50`은 `decimal(3,2)`, 정수의 `+ - * %`는 `bigint`, `/`는 scale이 4 더 큰 `decimal`, `DIV`는 `bigint`, `DECIMAL`끼리는 MariaDB의 scale 규칙(`+ -`는 큰 쪽, `*`는 합), 실수가 섞이면 `double`, `COUNT()`은 `bigint`, `SUM()`·`AVG()`은 `decimal`([코어의 타입](../architecture.md#코어의-타입)). 결과 열의 선언 타입과 값 표시, 매개변수 타입에만 쓰고 계산에는 쓰지 않습니다. 정밀도는 단순화했습니다: 정수는 그 타입의 자릿수(`INT`는 10)로 셉니다(MariaDB는 리터럴의 자릿수, 표시 폭). |
| 정수 값의 실수 | `POW(2,10)`이 `1024.0`처럼 SQLite 형식으로 보입니다. |
| `BIGINT UNSIGNED`, `CAST(... AS UNSIGNED)` | 부호 있는 64비트 범위입니다. |
| `TIMESTAMP` | 시간대 변환이 없고 범위도 `DATETIME`과 같습니다. 시간대는 UTC입니다. |
| PAD SPACE | 비교에 없으므로 `'x' = 'x  '`는 거짓입니다. |

## 문장의 동작

| 항목 | xqlite |
| --- | --- |
| UPDATE의 대입 | 모두 이전 행 값을 봅니다(`SIMULTANEOUS_ASSIGNMENT`와 같음). |
| `LAST_INSERT_ID()` | 여러 행 INSERT에서는 마지막 행의 id입니다. 직접 넣은 id에도 바뀝니다. |
| `ON DUPLICATE KEY UPDATE` | affected rows는 SQLite 방식(행마다 1)입니다. 한 행이 두 UNIQUE 키에서 서로 다른 두 행과 충돌하면 첫 행만 고칩니다. |
| `SHOW WARNINGS` | 문장을 컴파일할 때(보통 직전 문장 실행 직후) 기록된 경고를 보여 줍니다. 경고는 다음 문장을 컴파일할 때 지워집니다. 최대 8개를 저장하고 개수는 전부 셉니다. |
| 엔진 오류 | 제약 위반은 MariaDB 문구입니다([제약 위반](databases.md#제약-위반)). 그 밖의 엔진 오류는 SQLite 메시지 그대로이고, `no such table`(MariaDB의 `Table 'db.t' doesn't exist`)과 64비트를 넘는 정수 결과(`BIGINT value is out of range`)만 MariaDB 문구입니다. |
| `INSERT ... SELECT` | 변환 오류 메시지의 행 번호가 언제나 1입니다. |

## 데이터베이스

| 항목 | xqlite |
| --- | --- |
| 같은 이름의 테이블 | 두 데이터베이스의 같은 이름 테이블(`main.t`와 `sales.t`)을 한 FROM에 별칭 없이 쓰면 둘 다 `t`라서 `main.t.a`, `sales.t.a`로 구별되지 않습니다(`ambiguous column name`). 별칭을 붙이세요. |
| `main`의 한정하지 않은 이름 | SQLite의 규칙대로 붙인 데이터베이스의 테이블도 찾습니다. |
| 시스템 데이터베이스 | `mysql`, `performance_schema`, `sys`는 없습니다. `information_schema`는 `SHOW DATABASES`에만 나옵니다. |
| 뷰의 `DATABASE()` | 뷰를 만들 때의 값이 상수로 저장됩니다. |
| 시퀀스 | `SHOW TABLES`, `information_schema.TABLES`에 나오지 않습니다. 붙인 데이터베이스에는 시퀀스가 없습니다(`main`과 `CREATE DATABASE`의 데이터베이스에만). |
| `VIEWS.VIEW_DEFINITION` | MariaDB가 다시 쓴 텍스트가 아니라 저장된 SQLite 질의 텍스트입니다(붙인 데이터베이스는 NULL). |
| 데이터베이스의 문자 집합 | 기록만 하고 테이블에 적용하지 않습니다. |

## 스키마에 저장되는 식

- `DEFAULT (...)`, `CHECK`, 생성 열, 뷰에는 MariaDB처럼 변수와 매개변수를 쓸 수 없습니다.
  - `Function or expression '@x' cannot be used in the CHECK clause of ...`
  - `View's SELECT contains a variable or parameter`
- 엔진 함수(`xq_div` ...)나 방언 함수(`xq_mariadb_*`)를 부르는 스키마는 xqlite에서는 어느 방언으로든 같은 결과를 냅니다.
- 평범한 sqlite3는 그런 식을 계산할 수 없고, [확장](../extension.md)(`libxqlite_ext`)을 올린 sqlite3는 xqlite와 같은 결과로 계산합니다(시스템 변수·사용자 변수를 읽는 함수만 빠짐). 그 함수들의 뜻은 파일 형식의 일부라 바뀌지 않습니다([ABI 규칙](../extension.md#abi-규칙)).
- `/`, `UCASE`, `GREATEST`, `IF`, `CONCAT`, `LIKE` 같은 식은 sqlite3에서도 같습니다(`xqt interop mariadb`).
- 저장된 식의 비교는 열 collation이 없으면 읽는 연결의 기본 collation을 씁니다.

| 읽는 쪽 | 기본 collation |
| --- | --- |
| MariaDB 방언 | `NOCASE` |
| SQLite 방언, sqlite3 | `BINARY` |

- 문자열 열에는 언제나 collation을 적으므로 열과의 비교는 어디서나 같습니다.
- 열이 아닌 값끼리 비교할 때(`'a' = 'A'`, `UPPER(x) = 'a'`)만 다릅니다.

## 아직 쓸 수 없는 스키마 식

| 항목 | 이유 |
| --- | --- |
| `DEFAULT (NEXT VALUE FOR s)` | `nextval()`이 unsafe라 스키마에서 부를 수 없습니다. |
| `ALTER TABLE ... ADD COLUMN`의 DEFAULT | SQLite처럼 상수여야 합니다. |
| `information_schema`를 읽는 뷰 | pragma 테이블 값 함수가 스키마에서 unsafe입니다. |
