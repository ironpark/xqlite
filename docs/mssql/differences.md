# MSSQL (T-SQL) 호환: 차이점 및 제한 사항

xqlite MSSQL 방언과 네이티브 Microsoft SQL Server 2022 간의 주요 동작 차이점, 미지원 기능 목록 및 주의사항입니다.

---

## 1. 주요 동작 및 엔진 차이점

| 항목 | SQL Server | xqlite (MSSQL 방언) | 설명 및 영향 |
| --- | --- | --- | --- |
| **`decimal` / `money` 저장** | 고정 소수점 십진 바이너리 저장 | `REAL` (부동소수점) 저장 | 출력 시 정밀도와 스케일에 맞춰 표기되지만, 연산 시 IEEE 754 부동소수점 반올림 규칙이 적용됩니다. |
| **후행 공백 비교** | 문자열 비교 시 후행 공백 무시 (`'a' = 'a '` 참) | 후행 공백 엄격 비교 (`'a' = 'a '` 거짓) | `LEN()` 함수는 SQL Server와 동일하게 후행 공백을 제외한 길이를 반환합니다. |
| **`char(n)` 공백 패딩** | 선언된 길이 n까지 공백으로 채워 저장 | 별도의 공백 패딩 없이 입력된 문자열 그대로 저장 | 스토리지 절약을 위해 공백 채움 저장을 수행하지 않습니다. |
| **문자열 정렬 (Collation)** | Windows 로케일 기반 대소문자 무시 (`CI_AS`) | ASCII 기준 대소문자 무시 (`NOCASE`) | 비-ASCII 유니코드 문자의 대소문자는 구분될 수 있습니다. |
| **`NVARCHAR` 바이트 크기** | UTF-16 인코딩 (문자당 기본 2바이트) | UTF-8 인코딩 (문자당 가변 1~4바이트) | `DATALENGTH(N'a')` 호출 시 SQL Server는 2를 반환하지만, xqlite는 UTF-8 바이트 수인 1을 반환합니다. |
| **날짜 산술 연산** | `GETDATE() + 1` 직접 가산 허용 | `DATEADD(day, 1, GETDATE())` 함수 사용 필수 | 날짜 값에 정수를 직접 더하는 연산은 미지원하며 표준 `DATEADD` 함수를 사용해야 합니다. |

---

## 2. 미지원 기능 목록 (Unsupported)

### 2.1 절차적 프로그래밍 및 제어문
- **제어 흐름 블록**: `IF ... ELSE`, `WHILE`, `BEGIN ... END`, `TRY ... CATCH`, `THROW` / `RAISERROR` 등 프로시저 블록 제어문은 미지원합니다.
- **저장 프로시저 및 사용자 정의 함수**: `CREATE PROCEDURE`, `CREATE FUNCTION`, `EXEC` (일부 시스템 프로시저 제외)는 지원되지 않습니다.
- **테이블 변수 및 커서**: `DECLARE @t TABLE (...)`, `DECLARE cursor_name CURSOR`는 지원되지 않습니다.

### 2.2 고급 질의 및 DML 구문
- **`OUTPUT ... INTO`**: `OUTPUT` 절의 결과를 즉시 반환하는 것은 지원하지만, 임시 테이블로 수신하는 `INTO` 절은 아직 미지원합니다.
- **`TOP ... WITH TIES`**: 동점자 포함 페이징은 미지원합니다.
- **`PIVOT` / `UNPIVOT`**: 행-열 전환 연산자는 지원되지 않습니다.
- **`FOR XML`**: XML 직렬화는 지원되지 않습니다 (`FOR JSON`은 완벽 지원).

### 2.3 스키마 및 관리
- **`ALTER TABLE` 고급 구문**: 제약 조건 추가/삭제(`ADD CONSTRAINT`), 열 수정(`ALTER COLUMN`) 일부 기능은 제한됩니다.
- **사용자 및 권한**: `CREATE USER`, `CREATE ROLE`, `GRANT`, `REVOKE`는 지원되지 않습니다.

---

## 3. 주의사항 및 권장 대응책

1. **배치 구분자 `GO`**:
   - T-SQL 스크립트 작성 시 문장 구분을 위해 세미콜론(`;`) 또는 `GO`를 사용할 수 있습니다. 단, xqlite 셸 환경에서는 단독 행의 `GO`만 배치 실행으로 인식합니다.
2. **트랜잭션 명시**:
   - `SET IMPLICIT_TRANSACTIONS ON`은 지원되지 않으므로, 다중 문장 트랜잭션이 필요한 경우 명시적으로 `BEGIN TRANSACTION`과 `COMMIT`을 사용해야 합니다.
3. **날짜 포맷 주의**:
   - 날짜 문자열 파싱은 표준 ISO 8601(`YYYY-MM-DD` 또는 `YYYY-MM-DDTHH:MM:SS`)을 사용하는 것이 가장 안전합니다.
