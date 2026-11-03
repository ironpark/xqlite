# `sql_mode`

[MariaDB 호환](README.md)의 일부입니다.

- 연결 단위입니다.
- 기본값은 MariaDB 10.2+의 `STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION`입니다.
- `SET [SESSION] sql_mode = ...`, `SET @@sql_mode = CONCAT(@@sql_mode, ',ANSI_QUOTES')`, `SET sql_mode = DEFAULT`로 바꿉니다.
- `SELECT @@sql_mode`로 읽습니다. 조합 모드(`ANSI`, `TRADITIONAL`, `POSTGRESQL` ...)는 MariaDB처럼 펼쳐 보입니다.
- `SET`은 문장이 실행될 때 적용됩니다. 문법에 영향을 주는 모드는 그 뒤에 컴파일되는 문장부터 적용됩니다.
- 데이터 모드는 실행 시점의 모드를 읽으므로 준비된 문장도 현재 모드를 따릅니다.

| 모드 | 효과 |
| --- | --- |
| `ANSI_QUOTES` | `"x"`가 식별자입니다(아니면 문자열). |
| `PIPES_AS_CONCAT` | `\|\|`가 연결입니다(아니면 `OR`). |
| `NO_BACKSLASH_ESCAPES` | 문자열의 `\`가 보통 문자입니다. |
| `EMPTY_STRING_IS_NULL` | `''`가 NULL입니다. |
| `NO_AUTO_VALUE_ON_ZERO` | `AUTO_INCREMENT` 열의 0이 다음 값을 만들지 않습니다. |
| `STRICT_TRANS_TABLES`, `STRICT_ALL_TABLES` | 엄격 모드입니다. 모든 테이블이 트랜잭션 테이블이라 둘은 같은 뜻입니다. |
| `NO_ZERO_DATE`, `NO_ZERO_IN_DATE`, `ALLOW_INVALID_DATES` | 날짜 변환에 반영합니다. |

## 엄격 모드와 값 변환

- INSERT/UPDATE가 저장하는 값마다 `xq_coerce(value, type, ...)`를 거칩니다.
- 엄격 모드에서는 범위 밖·너무 긴 값·잘못된 날짜가 MariaDB 메시지로 문장을 실패시킵니다(`Out of range value for column 'i' at row 1`, `Data too long ...`, `Incorrect date value ...`).
- 엄격 모드가 아니거나 `INSERT/UPDATE IGNORE`이면 잘라 저장하고 경고를 남깁니다(`SHOW WARNINGS`, `@@warning_count`).
- `NOT NULL` 열의 NULL은 MariaDB와 같이 처리합니다.
- 기본값 없는 `NOT NULL` 열을 생략하면 MariaDB와 같이 `Field 'c' doesn't have a default value`입니다.

## 받아들이지만 효과가 없는 모드

- `ONLY_FULL_GROUP_BY`
- `ERROR_FOR_DIVISION_BY_ZERO`: 0으로 나누기는 언제나 NULL입니다.
- `HIGH_NOT_PRECEDENCE`
- `PAD_CHAR_TO_FULL_LENGTH`
- `IGNORE_SPACE`
- `REAL_AS_FLOAT`
