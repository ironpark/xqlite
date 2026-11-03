# 구조

[Oracle 호환](README.md)의 일부입니다.

프론트엔드는 `src/dialect/oracle/`에 있습니다. 문장을 구문 트리 IR(`src/ir/tree.zig`)로 파싱하고, 내림·렌더링·카탈로그 기록은 공용 `src/ir/lower.zig`와 `render.zig`가 합니다.

| 파일 | 내용 |
| --- | --- |
| `frontend.zig` | 진입점. 한 문장을 파싱해 IR로 내림. MERGE·INSERT ALL은 여러 문장을 한 프로그램으로 내림. 암묵적 트랜잭션, DDL 검사, 오류의 ORA- 코드 |
| `lexer.zig` | Oracle 어휘(아래 [어휘](support.md#어휘)) |
| `parser.zig` | 질의와 식. Oracle 의미를 해석함(`''`, `\|\|`, `ROWNUM`, `(+)`, `DUAL`, 함수 이름과 특수 문법, 결과 열 이름, NULL 정렬, 데이터 사전 뷰) |
| `stmt.zig` | 문장: DML(저장 변환 `xq_ora_coerce()`), MERGE·INSERT ALL, DDL과 타입·검사·identity, 트랜잭션 |
| `dates.zig` | 날짜 연산(`d + 1`, `d1 - d2`)과 숫자 열과 비교하는 문자열 상수 |
| `types.zig` | 타입 → STRICT 저장 타입·검사·카탈로그 철자 |
| `datetime.zig` | 날짜 텍스트, 달력 계산, 날짜 형식 모델(`TO_CHAR`, `TO_DATE`) |
| `funcs.zig` | 방언 함수와 엔진 함수(`xq_ora_*`) |
| `json.zig` | JSON 값, 파서(strict·lax), 직렬화(압축·`PRETTY`), SQL/JSON 경로 언어 |
| `jsonfuncs.zig` | SQL/JSON 엔진 함수(`xq_ora_json_*`)와 `JSON_TABLE`의 테이블 함수 `xq_ora_json_table` |
| `jsonsql.zig` | SQL/JSON 문법(함수의 절, `IS JSON`, 점 표기, `JSON_TABLE`)과 파싱 뒤의 해석 |
| `catalog_views.zig` | `USER_TABLES` 같은 데이터 사전 뷰 |
| `session.zig` | `CREATE/DROP/ALTER USER`, `ALTER SESSION SET CURRENT_SCHEMA`, `SYS_CONTEXT` |
| `state.zig` | 연결별 세션 상태(현재 스키마) |
| `test.zig` | 종단 테스트 |
