# 이름의 대소문자

[Oracle 호환](README.md)의 일부입니다.

- 따옴표 없는 식별자는 대문자로 접고(`emp` → `EMP`), `"Quoted"`는 그대로 둡니다. 그래서 이 방언이 만든 테이블과 열의 이름은 `sqlite_schema`에 대문자로 남고, `USER_TABLES.TABLE_NAME`도 Oracle처럼 `EMP`입니다.
- SQLite의 이름 비교는 대소문자를 구분하지 않습니다. 그래서 `"Emp"`와 `EMP`는 Oracle에서는 다른 테이블이지만 xqlite에서는 같은 테이블입니다. 반대로 SQLite에서 `emp`로 만든 테이블도 이 방언에서 `EMP`, `emp`, `"emp"`로 모두 찾습니다.
- 결과 열 이름은 Oracle 규칙을 따릅니다. 열이면 그 열 이름(만든 대로의 대소문자), 의사 열이면 `NEXTVAL`, `ROWID`, 그 밖의 식이면 식의 텍스트를 대문자로 바꾸고 공백을 뺀 것(`count(*)` → `COUNT(*)`, `NVL(b, 'x')` → `NVL(B,'X')`)입니다.
- 스키마(사용자) 이름도 같은 규칙으로 접습니다(`hr.emp`는 사용자 `HR`의 `EMP`). 스키마는 [사용자와 스키마](schemas.md)를 보세요.
