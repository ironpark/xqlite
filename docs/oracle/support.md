# 지원 범위

[Oracle 호환](README.md)의 일부입니다.

## 어휘

- 문자열: `'...'`(`''`로 따옴표), `N'...'`, 대체 따옴표 `q'[...]'`(`{}` `()` `<>` 또는 같은 문자 쌍, `Q`/`nq`도)
- 바인드 변수: `:name`은 SQLite의 이름 있는 매개변수 `:name`(`sqlite3_bind_parameter_index(":name")`), `:1`은 번호 매개변수 `?1`. 한 문장에서 둘을 섞으면 `:1`과 첫 이름이 같은 번호가 됩니다.
- 숫자: `42`, `4.2`, `.5`, `1e10`, `1.5f`/`2d`(접미사 무시)
- 주석: `--`, `/* */`(중첩 없음). 힌트 `/*+ ... */`는 주석입니다.
- 문장 끝: `;`, 그리고 SQL*Plus 스크립트처럼 홀로 있는 줄의 `/`
- 연산자: `||`, `<>`/`!=`/`^=`/`~=`, `(+)`

## SELECT

| 영역 | 지원 |
| --- | --- |
| 기본 | `DISTINCT`/`UNIQUE`, `WHERE`, `GROUP BY`, `HAVING`, `WINDOW` |
| FROM | 테이블, 서브쿼리, `DUAL`(없는 테이블로 다룸, `SELECT *`이면 `DUMMY` 열 하나), 테이블 함수 |
| JOIN | ANSI `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS`/`NATURAL`, `ON`/`USING`, 옛 `(+)` 외부 조인 |
| 정렬 | `ORDER BY ... [ASC\|DESC] [NULLS FIRST\|LAST]`(기본은 NULL이 가장 큰 값) |
| 행 수 제한 | `WHERE ROWNUM <= n`(`<`, `= 1`, `BETWEEN 1 AND n`) → LIMIT, `OFFSET n ROWS`, `FETCH FIRST\|NEXT n ROWS ONLY` |
| 집합 연산 | `UNION [ALL]`/`INTERSECT`/`MINUS`(같은 우선순위, 왼쪽부터) |
| CTE | `WITH`, `RECURSIVE` 없는 재귀 CTE(열 목록과 함께) |
| 그 밖 | 스칼라·상관 서브쿼리, `IN`/`EXISTS`/`= ANY (...)`/`<> ALL (...)`, 행 값, `FOR UPDATE`(무시) |

`ROWNUM`의 규칙은 다음과 같습니다.

- WHERE의 `ROWNUM` 조건은 그 질의의 LIMIT이 됩니다. Oracle은 정렬·그룹 전에 번호를 매기므로, 같은 질의에 `ORDER BY`가 있으면 `SELECT * FROM (... LIMIT n) ORDER BY ...`로, 집계·`GROUP BY`·`DISTINCT`가 있으면 FROM 항목(하나일 때만)을 `(SELECT * FROM t WHERE ... LIMIT n) t`로 감쌉니다.
- `ROWNUM > n`과 `ROWNUM = n`(n > 1)은 Oracle처럼 아무 행도 내지 않습니다.
- 그 밖의 자리(결과 열, `ORDER BY`)에서는 `row_number() OVER ()`입니다.
- UPDATE·DELETE의 `WHERE ROWNUM <= n`도 LIMIT입니다.

`(+)` 외부 조인은 WHERE의 각 조건에서 `(+)`가 붙은 열의 FROM 항목을 찾아, 그 조건들을 그 항목의 ON으로 옮기고 `LEFT JOIN`으로 만듭니다. `(+)` 쪽이 두 항목 중 첫 번째면 두 번째를 `RIGHT JOIN`으로 만듭니다. ANSI 조인과 섞으면 `ORA-25156`입니다.

## DML

- **INSERT**: 열 목록, `VALUES`(여러 행도), 서브쿼리, `DEFAULT`
- **INSERT ALL / INSERT FIRST**: 무조건 `INTO ...` 여러 개, `WHEN ... THEN INTO ...`, `ELSE INTO ...`
- **UPDATE**: `SET a = ...`, `SET (a, b) = (subquery)`, `= DEFAULT`, `t.a = ...`
- **DELETE**: `FROM` 생략 가능
- **MERGE**: `WHEN MATCHED THEN UPDATE SET ... [WHERE] [DELETE WHERE]`, `WHEN NOT MATCHED THEN INSERT ... VALUES ... [WHERE]`([MERGE와 INSERT ALL](merge.md))
- **TRUNCATE TABLE**

## 트랜잭션

`COMMIT [WORK]`, `ROLLBACK [WORK]`, `SAVEPOINT s`, `ROLLBACK TO [SAVEPOINT] s`. `SET TRANSACTION`, `ALTER SESSION`(`SET CURRENT_SCHEMA` 말고), `LOCK TABLE`은 받아들이고 아무것도 하지 않습니다. `EXPLAIN PLAN FOR`는 SQLite의 `EXPLAIN QUERY PLAN` 결과를 냅니다.

## DDL

- **CREATE TABLE**: 열 제약 `[CONSTRAINT n] NOT NULL`/`NULL`/`PRIMARY KEY`/`UNIQUE`/`CHECK`/`REFERENCES t (c) [ON DELETE CASCADE|SET NULL]`, `DEFAULT [ON NULL]`, 테이블 제약, 가상 열 `[GENERATED ALWAYS] AS (...) [VIRTUAL]`, identity `GENERATED {ALWAYS|BY DEFAULT [ON NULL]} AS IDENTITY [(옵션)]`, `CREATE TABLE ... AS SELECT`, `GLOBAL TEMPORARY`, 저장 옵션(`TABLESPACE`, `PCTFREE`, `STORAGE (...)` ...)과 제약 상태(`ENABLE`, `USING INDEX` ...)는 무시. 키 열은 Oracle처럼 NOT NULL입니다.
- **CREATE [UNIQUE|BITMAP] INDEX**, **CREATE [OR REPLACE] [FORCE] VIEW ... [WITH READ ONLY]**
- **CREATE SEQUENCE**: `START WITH`, `INCREMENT BY`, `MINVALUE`, `MAXVALUE`, `CYCLE`/`NOCYCLE`, `CACHE`/`NOCACHE`/`ORDER`(무시)
- **ALTER TABLE**: `ADD (열)`/`ADD 열`, `DROP COLUMN`/`DROP (열)`, `RENAME COLUMN a TO b`, `RENAME TO`. 한 번에 한 열씩입니다.
- **DROP TABLE ... [CASCADE CONSTRAINTS] [PURGE]**, **DROP VIEW/INDEX/SEQUENCE**, 23ai의 `IF [NOT] EXISTS`
- **RENAME a TO b**, **COMMENT ON TABLE/COLUMN ... IS '...'**(카탈로그 키 `oracle.comment`, `USER_TAB_COMMENTS`/`USER_COL_COMMENTS`)

## 식과 연산자

| 영역 | 지원 |
| --- | --- |
| 연산자 우선순위 | `OR` < `AND` < `NOT` < 비교·`IS`·`LIKE`·`BETWEEN`·`IN` < `+ - \|\|` < `* /` < 단항 |
| 나눗셈 | `/`는 실수 나눗셈(`7/2` = 3.5) |
| `LIKE` | 대소문자 구분, `ESCAPE`가 없으면 이스케이프 문자 없음(`xq_like(..., '')`) |
| NULL | `IS [NOT] NULL`, `IS [NOT] TRUE/FALSE`(23ai) |
| `CASE` | 단순·검색 `CASE` |
| `CAST` | `CAST(x AS type)`는 `xq_ora_cast(x, 'TYPE')`(저장 변환과 같은 규칙) |
| 의사 열 | `ROWNUM`, `ROWID`(SQLite의 rowid), `s.NEXTVAL`/`s.CURRVAL`, `SYSDATE`, `SYSTIMESTAMP`, `CURRENT_DATE`/`CURRENT_TIMESTAMP`, `USER`, `UID` |
| 날짜 상수 | `DATE 'YYYY-MM-DD'`, `TIMESTAMP 'YYYY-MM-DD HH24:MI:SS[.f]'` |
| 암묵적 변환 | `NUMBER` 열과 비교하는 문자열 상수(`n = '5'`, `BETWEEN`, `IN`)는 숫자 |

`s.NEXTVAL`은 Oracle처럼 한 행에서 한 번만 늘어납니다. 같은 결과 열 목록, `VALUES` 행, `SET` 목록 안의 두 번째 `NEXTVAL`은 `CURRVAL`입니다. 없는 시퀀스는 컴파일할 때 `ORA-02289`입니다.

## 함수

| 분류 | 함수 |
| --- | --- |
| NULL | `NVL`(→ `coalesce`), `NVL2`, `DECODE`(NULL끼리 같음), `COALESCE`, `NULLIF`, `LNNVL` |
| 문자열 | `SUBSTR`(음수·0 위치), `INSTR`(음수 위치·n번째), `LENGTH`/`LENGTHB`, `UPPER`/`LOWER`/`INITCAP`, `LPAD`/`RPAD`, `TRIM([LEADING\|TRAILING\|BOTH] [c FROM] s)`/`LTRIM`/`RTRIM`(문자 집합), `REPLACE`, `TRANSLATE`, `CONCAT`, `CHR`, `ASCII`, `RAWTOHEX`, `HEXTORAW` |
| 숫자 | `MOD`(`MOD(x, 0)` = x), `ABS`, `CEIL`, `FLOOR`, `ROUND`/`TRUNC`(자릿수), `POWER`, `SQRT`, `SIGN`, `EXP`, `LN`, `LOG(b, x)`, `GREATEST`/`LEAST`(NULL이 있으면 NULL, 첫 인자의 타입으로 비교) |
| 변환 | `TO_CHAR(날짜\|숫자 [, fmt])`, `TO_DATE`, `TO_TIMESTAMP`, `TO_NUMBER(s [, fmt])`, `CAST` |
| 날짜 | `SYSDATE`, `SYSTIMESTAMP`, `ADD_MONTHS`, `MONTHS_BETWEEN`, `LAST_DAY`, `NEXT_DAY`, `TRUNC`/`ROUND(날짜 [, 단위])`, `EXTRACT(YEAR\|MONTH\|DAY\|HOUR\|MINUTE\|SECOND FROM d)` |
| 집계·윈도우 | `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, `STDDEV`/`VARIANCE`(표본), `LISTAGG(x [, sep]) WITHIN GROUP (ORDER BY ...)`, `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `LAG`, `LEAD`, `FIRST_VALUE`, `NTILE` ... |
| 시퀀스·기타 | `s.NEXTVAL`, `s.CURRVAL`, `SYS_GUID()`(16바이트 난수 blob) |

숫자 형식 모델(`TO_CHAR(n, fmt)`)은 `9`, `0`, `.`/`D`, `,`/`G`, `$`, `S`, `MI`, `PR`, `FM`, `X`를 읽습니다. 자리가 모자라면 `#`입니다. 형식 없는 `TO_CHAR(0.5)`는 Oracle처럼 `.5`입니다.

## 데이터 사전

| 뷰 | 열 |
| --- | --- |
| `USER_TABLES`, `ALL_TABLES` | `TABLE_NAME`, `TABLESPACE_NAME`, `STATUS`, `TEMPORARY` ... (`ALL_*`은 `OWNER`) |
| `USER_TAB_COLUMNS`, `ALL_TAB_COLUMNS` | `COLUMN_NAME`, `DATA_TYPE`, `DATA_LENGTH`, `DATA_PRECISION`, `DATA_SCALE`, `NULLABLE`, `COLUMN_ID`, `DATA_DEFAULT`, `IDENTITY_COLUMN`, `VIRTUAL_COLUMN` |
| `USER_VIEWS`, `ALL_VIEWS` | `VIEW_NAME`, `TEXT_LENGTH`, `TEXT`(저장된 SQLite 텍스트) |
| `USER_SEQUENCES`, `ALL_SEQUENCES` | `SEQUENCE_NAME`, `MIN_VALUE`, `MAX_VALUE`, `INCREMENT_BY`, `CYCLE_FLAG`, `LAST_NUMBER` ... |
| `USER_INDEXES`, `ALL_INDEXES` | `INDEX_NAME`, `TABLE_OWNER`, `TABLE_NAME`, `UNIQUENESS` |
| `USER_TAB_COMMENTS`, `USER_COL_COMMENTS`, `ALL_*` | `COMMENT ON`의 내용 |
| `ALL_USERS`, `DBA_USERS`, `USER_USERS` | `USERNAME`, `USER_ID`, `ACCOUNT_STATUS`, `DEFAULT_TABLESPACE` ... |

- 뷰 정의는 Oracle SQL로 쓰여 있고, 프론트엔드가 FROM 자리에서 파싱해 넣습니다. 저장되는 것은 없습니다.
- `ALL_*`은 모든 사용자의 개체를 `OWNER`(시퀀스는 `SEQUENCE_OWNER`)와 함께, `USER_*`는 연결한 사용자 `MAIN`의 개체만 보여 줍니다. `DBA_*`(`DBA_TABLES` ...)는 `ALL_*`과 같습니다. 이름은 스키마를 뗀 이름입니다(`HR.EMP`가 아니라 `EMP`).
- 같은 이름의 테이블이 있으면 그 테이블이 먼저입니다. `SYS.USER_TABLES`처럼 `SYS`로 한정해도 됩니다.
