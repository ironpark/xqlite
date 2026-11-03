# Oracle 호환: 차이점 및 제한 사항

xqlite Oracle 방언과 네이티브 Oracle Database 23ai 간의 주요 동작 차이점, 미지원 기능 목록 및 주의사항입니다.

---

## 1. 주요 동작 및 엔진 차이점

| 주제 | Oracle 23ai | xqlite (Oracle 방언) | 설명 및 이유 |
| --- | --- | --- | --- |
| **`NUMBER` 정밀도** | 최대 38자리 고정밀 BCD 십진수 | 64비트 정수 또는 IEEE 754 부동소수점 | 극단적인 고정밀 소수점 연산(`0.1 + 0.2` 등)에서 부동소수점 미세 오차가 발생할 수 있습니다. |
| **날짜 저장 및 출력** | 독자 바이너리 포맷, `NLS_DATE_FORMAT`에 따른 출력 | 표준 ISO-8601 텍스트(`YYYY-MM-DD HH24:MI:SS`)로 저장 및 출력 | 질의 결과를 다른 애플리케이션이나 SQLite 함수에서 바로 읽을 수 있도록 정규화되었습니다. 필요 시 `TO_CHAR(d, fmt)`로 포맷을 지정합니다. |
| **DDL 트랜잭션** | DDL 실행 시 앞뒤로 강제 자동 커밋(Implicit Commit) | DDL 실행 시 자동 커밋되지 않음 | xqlite에서는 트랜잭션 안에서 DDL을 수행해도 원자적으로 롤백할 수 있습니다. |
| **`SYSDATE` 시간대** | 데이터베이스 서버 운영체제 시간대 | UTC 기준 현재 시각 | 일관된 표준 시간 처리를 위해 UTC를 반환합니다. |
| **오류 메시지** | 모든 오류에 ORA- 코드 부여 | 구문 분석, 타입 변환, 제약 위반에 대해서만 ORA- 코드 제공 | 엔진 코어(SQLite) 내부 에러는 기본 메시지로 전달될 수 있습니다. |

---

## 2. 미지원 기능 목록 (Unsupported)

### 2.1 절차적 언어 및 저장 서브프로그램
- **PL/SQL 블록**: `DECLARE ... BEGIN ... END;` 형태의 절차형 블록, 익명 블록, 예외 처리기(`EXCEPTION WHEN ...`)는 미지원합니다.
- **패키지, 프로시저, 함수**: `CREATE PACKAGE`, `CREATE PROCEDURE`, `CREATE FUNCTION`은 지원되지 않습니다.
- **트리거**: PL/SQL 기반 트리거는 지원되지 않습니다.
- **`RETURNING ... INTO`**: PL/SQL 변수로 수신하는 DML 구문은 미지원합니다.

### 2.2 고급 질의 및 DDL
- **`PIVOT` / `UNPIVOT`**: 행-열 변환 구문은 미지원합니다.
- **플래시백 질의**: `AS OF TIMESTAMP / SCN` 구문은 지원되지 않습니다.
- **동의어 (Synonyms)**: `CREATE SYNONYM`은 미지원합니다.
- **구체화된 뷰 (Materialized Views)**: `CREATE MATERIALIZED VIEW`는 미지원합니다.
- **파티셔닝**: `PARTITION BY RANGE / LIST / HASH`는 미지원합니다.

---

## 3. 주의사항 및 마이그레이션 팁

1. **명시적 `COMMIT` 필수**:
   - DML 문장을 실행한 후 세션을 종료하면 커밋되지 않은 트랜잭션은 **자동으로 롤백**됩니다. 스크립트 작성이나 애플리케이션 연동 시 중요한 변경 후에는 반드시 `COMMIT;`을 실행하세요.
2. **식별자 대문자화**:
   - 기존 애플리케이션에서 소문자 식별자를 전제로 개발된 경우, Oracle 방언에서는 대문자로 변환되므로 스키마 정의 시 큰따옴표(`"table_name"`)를 사용하거나 대문자 컬럼명을 참조해야 합니다.
3. **`ROWNUM` vs `LIMIT`**:
   - `WHERE ROWNUM <= 10`은 정렬(`ORDER BY`) 전 행 번호에 적용될 수 있으므로, 정렬된 상위 n건을 조회할 때는 인라인 뷰를 사용하거나 ANSI 표준인 `OFFSET ... FETCH NEXT` 절을 사용하는 것이 권장됩니다.
