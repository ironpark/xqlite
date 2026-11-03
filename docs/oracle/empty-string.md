# 빈 문자열은 NULL

[Oracle 호환](README.md)의 일부입니다.

Oracle에서 `''`는 NULL입니다. 그래서 `'' IS NULL`은 참, `LENGTH('')`는 NULL, `'a' || NULL`은 `'a'`입니다. 이 방언은 이 규칙을 의미 노드로 일관되게 지킵니다.

| 어디서 | 하는 일 | IR |
| --- | --- | --- |
| 문자열 상수 | `''`는 NULL 상수 | `null` (render는 `NULL`을 씀, `''`가 아님) |
| `\|\|`, `CONCAT(a, b)` | NULL은 건너뛰고, 결과가 `''`이면 NULL | `nullif(concat{skip}(a, b, ...), '')` |
| 문자열 함수 | 인자의 `''`는 NULL, 결과가 `''`이면 NULL(`SUBSTR('abc', 4)`, `REPLACE('aa', 'a')`, `TRIM('  ')`, `LPAD('x', 0)`) | 방언 함수(`xq_oracle_substr` ...), `UPPER`/`LOWER`는 `nullif(upper(x), '')` |
| 저장 | INSERT·UPDATE·MERGE가 Oracle이 만든 테이블의 열에 넣는 값은 `xq_ora_coerce()`를 거침: `''`는 NULL(바인딩한 `''`도) | `func` 노드(엔진 함수) |

`xq_ora_coerce(value, 'TYPE', 'T', 'COL', flags)`는 저장 변환도 함께 합니다.

- 숫자 열: 문자열은 숫자로(`'12.5'` → 12.5, 아니면 `ORA-01722`), `NUMBER(p,s)`는 s자리로 반올림, 정밀도를 넘으면 `ORA-01438`. 정수 값의 실수는 정수로 저장
- 문자 열: 숫자는 Oracle 철자의 텍스트로(0.5 → `'.5'`), 길이를 넘으면 `ORA-12899`, `CHAR(n)`은 공백으로 채움
- 날짜 열: 텍스트를 `YYYY-MM-DD HH24:MI:SS`(`TIMESTAMP`는 소수 6자리)로 바꿈, 아니면 `ORA-01861`
- `RAW`/`BLOB`: 텍스트는 16진수로 읽음, `BOOLEAN`: `TRUE`/`'Y'`/`1` 같은 철자를 1/0으로
- NOT NULL 열(키 포함)에 NULL이나 `''`를 넣으면 `ORA-01400`

한계는 다음과 같습니다.

- `xq_ora_coerce()`는 xq_catalog에 선언 타입이 있는 테이블(이 방언이 만든 테이블)에만 붙습니다. SQLite나 다른 방언이 만든 테이블에는 `''`가 그대로 들어갑니다.
- 다른 방언이나 sqlite3가 쓴 `''` 값은 저장된 그대로 `''`입니다. 이 방언의 함수는 그런 값도 NULL로 읽지만, `col IS NULL`이나 `count(col)`은 `''`를 NULL로 보지 않습니다.
- `(a, b) = (SELECT ...)` 꼴의 UPDATE SET 값은 변환하지 않습니다.
- `||`의 숫자 피연산자는 SQLite가 텍스트로 바꿉니다(`'x' || 0.5`는 `'x0.5'`, Oracle은 `'x.5'`).
