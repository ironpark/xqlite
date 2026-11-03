# MariaDB (MySQL) 호환: 차이점 및 제한 사항

xqlite MariaDB 방언과 네이티브 MariaDB 11 / MySQL 8.0 간의 주요 동작 차이점, 미지원 기능 목록 및 주의사항입니다.

---

## 1. 주요 동작 및 엔진 차이점

| 항목 | MariaDB / MySQL | xqlite (MariaDB 방언) | 설명 및 영향 |
| --- | --- | --- | --- |
| **`DECIMAL` 저장** | 고정 소수점 바이너리 포맷 | `REAL` (부동소수점) 또는 정수 저장 | scale이 0이고 18자리 이하면 정수, 소수가 있으면 IEEE 754 부동소수점으로 저장됩니다. 질의 출력 시에는 소수점 자리수(scale)에 맞춰 패딩되어 출력되지만, 부동소수점 연산 오차가 발생할 수 있습니다. |
| **UPDATE 대입 순서** | 순차적 평가 (앞 열의 변경이 뒤 열에 반영) | 동시 평가 (모든 대입식이 이전 행 값을 참조) | MariaDB의 `UPDATE t SET a = b, b = a`는 앞의 a가 바뀌어 b에 반영되지만, xqlite는 SQLite의 동시 대입 방식(Simultaneous Assignment)으로 동작합니다. |
| **`LAST_INSERT_ID()`** | 다중 행 INSERT 시 첫 번째 생성된 ID 반환 | 다중 행 INSERT 시 마지막으로 생성된 ID 반환 | 배치 삽입 시 반환되는 ID 기준점에 차이가 있습니다. |
| **`ON DUPLICATE KEY UPDATE` 영향 행수** | 변경 없음: 0, 갱신 성공: 2, 신규 삽입: 1 | SQLite 방식 (삽입/갱신 모두 변경된 행마다 1) | `ROW_COUNT()` 또는 드라이버의 affected rows 수치에 차이가 있습니다. |
| **PAD SPACE 정렬** | 문자열 비교 시 후행 공백을 무시 (`'a' = 'a '` 참) | 후행 공백을 엄격하게 비교 (`'a' = 'a '` 거짓) | 후행 공백 일치 비교가 필요한 경우 명시적으로 `TRIM()`을 사용해야 합니다. |
| **`TIMESTAMP` 시간대** | 세션 `time_zone`에 따라 저장 시 UTC 변환 및 조회 시 로컬 변환 | 변환 없이 UTC 기준 ISO 텍스트 저장 | MariaDB의 `DATETIME`과 동일한 방식으로 보존됩니다. |

---

## 2. 미지원 기능 목록 (Unsupported)

### 2.1 저장 루틴 및 프로그래밍
- **저장 프로시저 및 함수**: `CREATE PROCEDURE`, `CREATE FUNCTION` (사용자 정의 함수)는 지원되지 않습니다.
- **트리거 및 이벤트**: `CREATE TRIGGER` (MySQL 문법), `CREATE EVENT` 스케줄러는 지원되지 않습니다.
- **커서 및 제어문**: `DECLARE ... CURSOR`, `LOOP`, `REPEAT`, `WHILE` 등의 복합 프로시저 블록은 지원되지 않습니다.

### 2.2 DML 및 고급 질의
- **다중 테이블 `UPDATE` / `DELETE`**: `UPDATE t1, t2 SET ...` 형태의 다중 테이블 일괄 수정은 미지원합니다.
- **`SELECT ... INTO OUTFILE / DUMPFILE`**: 서버 측 파일 내보내기는 지원되지 않습니다.
- **`LOAD DATA INFILE`**: 서버 측 파일 대량 임포트는 지원되지 않습니다.
- **전체 텍스트 검색**: `MATCH(...) AGAINST(...)` 구문은 지원되지 않습니다 (SQLite FTS5 모듈 대체 필요).
- **`WITH ROLLUP`**: `GROUP BY ... WITH ROLLUP` 소계 생성은 아직 미지원합니다.

### 2.3 DDL 및 스키마 관리
- **복합 `ALTER TABLE`**: 단일 문장에서 여러 변경(열 추가 + 인덱스 삭제 등)을 동시에 수행하는 구문 및 `CHANGE COLUMN`, `MODIFY COLUMN` 일부 형태는 제한적입니다.
- **파티셔닝**: `PARTITION BY HASH / RANGE / LIST` 구문은 무시되거나 에러를 반환합니다.
- **가상 열 (Generated Columns)**: `STORED`는 지원되나 `VIRTUAL` 열은 제한적으로 동작합니다.
- **`CREATE TABLE ... LIKE`**: 다른 테이블 스키마 복제 구문은 미지원합니다.

---

## 3. 주의사항 및 권장 대응책

1. **문자 집합 및 Collation**:
   - xqlite의 모든 데이터는 내부적으로 `UTF-8`로 인코딩됩니다. DDL에 명시된 `DEFAULT CHARSET=utf8mb4`나 `COLLATE=utf8mb4_general_ci` 구문은 호환성을 위해 오류 없이 수용됩니다. 대소문자 무시 비교(`utf8mb4_general_ci`)는 영문 ASCII 기준으로 동작합니다.
2. **트랜잭션 DDL 주의**:
   - 네이티브 MariaDB에서는 `CREATE TABLE`, `ALTER TABLE` 실행 시 직전 트랜잭션이 강제로 커밋(Implicit Commit)되지만, xqlite에서는 SQLite 코어 특성상 트랜잭션 안에서 DDL을 수행해도 롤백이 가능합니다.
3. **경고 확인**:
   - 엄격 모드가 꺼져 있을 때 발생하는 잘림(truncation)이나 변환 이슈는 `SHOW WARNINGS;` 문장으로 직전 8개까지 상세히 확인할 수 있습니다.
