# 타입 매핑

[Oracle 호환](README.md)의 일부입니다.

| Oracle | STRICT 저장 | 검사(이름이 Oracle 메시지인 CHECK) |
| --- | --- | --- |
| `NUMBER`, `NUMBER(p,s)`(s > 0), `FLOAT(b)`, `DECIMAL`, `REAL`, `DOUBLE PRECISION` | `ANY` | 숫자만(`ORA-01722: invalid number`), 정밀도(`ORA-01438`) |
| `NUMBER(p)`, `NUMBER(p,0)`(p ≤ 18), `INTEGER`/`INT`/`SMALLINT`(`NUMBER(*,0)`) | `INTEGER` | 정밀도 `abs(x) < 10^p` |
| `BINARY_FLOAT`, `BINARY_DOUBLE` | `REAL` | |
| `VARCHAR2(n [BYTE\|CHAR])`, `NVARCHAR2(n)`, `VARCHAR(n)` | `TEXT` | 길이 `octet_length(x) <= n`(CHAR 의미면 `length`) → `ORA-12899` |
| `CHAR(n)`, `NCHAR(n)` | `TEXT` + `COLLATE RTRIM` | 길이. 공백으로 채워 저장하고 공백을 무시하고 비교 |
| `CLOB`, `NCLOB`, `LONG` | `TEXT` | |
| `DATE`, `TIMESTAMP[(p)] [WITH [LOCAL] TIME ZONE]`, `INTERVAL ...` | `TEXT` | |
| `BLOB`, `RAW(n)`, `LONG RAW` | `BLOB` | `RAW(n)`은 길이 |
| `BOOLEAN`(23ai) | `INTEGER` | 0/1만 |
| `JSON`(23ai) | `TEXT` | `json_valid()`(`ORA-40441`). 저장 변환이 Oracle처럼 정규화한 JSON 텍스트를 넣음([JSON](json.md)) |

- 선언 타입은 `xq_catalog`의 `type` 키에 Oracle 철자(`NUMBER(10,2)`, `VARCHAR2(20 CHAR)`, `NUMBER(*,0)`, `TIMESTAMP(6) WITH TIME ZONE`)로 남고, `xq_ora_coerce()`가 실행할 때 그 철자를 읽습니다.
- identity 열은 타입이 `NUMBER`여도 `INTEGER`로 저장합니다. 키이면 SQLite의 INTEGER PRIMARY KEY(rowid)입니다.
- sqlite3는 STRICT 타입과 CHECK를 그대로 강제합니다. 저장 변환(`xq_ora_coerce()`)은 이 방언의 DML에만 있습니다.
