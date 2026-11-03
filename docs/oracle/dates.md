# 날짜

[Oracle 호환](README.md)의 일부입니다.

Oracle의 `DATE`는 시각을 포함합니다. 이 방언은 날짜를 SQLite 날짜 함수가 읽는 텍스트로 저장합니다.

- `DATE`: `'YYYY-MM-DD HH24:MI:SS'`
- `TIMESTAMP(p)`: `'YYYY-MM-DD HH24:MI:SS.ffffff'`(p자리 뒤는 0, 소수는 늘 6자리라서 텍스트로 비교됨)
- `SYSDATE`는 문장 시각(UTC)의 `strftime('%Y-%m-%d %H:%M:%S', 'now')`, `SYSTIMESTAMP`는 밀리초까지입니다.
- 질의 결과의 날짜도 이 텍스트입니다(`NLS_DATE_FORMAT`을 따르지 않음). `TO_CHAR(d, fmt)`로 형식을 정합니다.
- 날짜로 읽는 텍스트는 ISO 형식, 그리고 Oracle 기본 형식 `DD-MON-RR`(`DD-MON-YYYY`)입니다.

날짜 연산은 파서가 날짜라고 아는 피연산자에서만 날짜 연산이 됩니다(`dates.zig`). 날짜라고 아는 것은 `SYSDATE`·`SYSTIMESTAMP`, `TO_DATE`·`TO_TIMESTAMP`·`ADD_MONTHS`·`LAST_DAY`·`NEXT_DAY`·날짜의 `TRUNC`/`ROUND`, 날짜 상수, `CAST(... AS DATE)`, FROM에 있는 테이블의 `DATE`/`TIMESTAMP` 열, 그런 열 하나를 고르는 스칼라 서브쿼리, 그리고 날짜 연산의 결과입니다.

| Oracle | xqlite |
| --- | --- |
| `d + n`, `n + d` | `datetime(d, n \|\| ' days')`(밀리초 단위로 정확) |
| `d - n` | `datetime(d, (-n) \|\| ' days')` |
| `d1 - d2` | `(unixepoch(d1, 'subsec') - unixepoch(d2, 'subsec')) / 86400.0`(일 수) |

`TIMESTAMP`가 낀 연산도 `DATE`를 냅니다. `TIMESTAMP - TIMESTAMP`는 Oracle에서 `INTERVAL`이지만 여기서는 일 수입니다.

날짜 형식 모델(`TO_CHAR`, `TO_DATE`)은 `YYYY YYY YY Y RRRR RR SYYYY Q MM MON MONTH RM WW IW W DDD DD D DAY DY J HH HH12 HH24 MI SS SSSSS FF[1-9] AM PM A.M. P.M. FM`, `"텍스트"`, 구두점을 읽습니다. 이름은 영어(`AMERICAN`)이고 `Month`/`MONTH`/`month`의 대소문자를 따릅니다. `TO_DATE`는 Oracle처럼 구분자에 너그럽고, 빠진 연·월은 현재 연·월, 일은 1일입니다.
