# PostgreSQL 호환: 차이점 및 제한 사항

xqlite PostgreSQL 방언과 네이티브 PostgreSQL 18 간의 주요 동작 차이점, 미지원 기능 목록 및 마이그레이션 시 주의사항입니다.

---

## 1. 엔진 설계 및 동작 차이점

xqlite는 SQLite 스토리지 및 VDBE 실행 엔진을 기반으로 구현되어 있으므로, 클라이언트-서버 구조의 대형 RDBMS인 PostgreSQL과 몇 가지 구조적 차이가 있습니다.

| 영역 | PostgreSQL 18 | xqlite (PostgreSQL 방언) | 설계 이유 및 영향 |
| --- | --- | --- | --- |
| **트랜잭션 모델** | 문장 단위 자동 커밋 제어 및 MVCC 기반 다중 버전 동시성 | 기본 SQLite 트랜잭션 모델(세이브포인트, 롤백 저널/WAL) 위에서 동작 | 단일 라이터-다중 리더 모델로 동작하며, `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT` 문법은 동일하게 지원됩니다. |
| **DDL 트랜잭션** | 스키마 변경 시 대부분 카탈로그 행 잠금으로 처리 | 트랜잭션 내에서 모든 DDL이 원자적으로 롤백 가능 (SQLite 특성 계승) | PostgreSQL과 마찬가지로 트랜잭션 내 `CREATE TABLE`, `DROP TABLE`, `ALTER TABLE` 후 `ROLLBACK` 시 완벽 복구됩니다. |
| **데이터 정렬 (Collation)** | 운영체제 로케일 기반 ICU/libc 정렬 | `NOCASE` 및 바이너리(UTF-8 바이트 순) 정렬 중심 | 일반 텍스트는 UTF-8 바이너리 순서(`memcmp`)로 정렬됩니다. 대소문자 무시 비교는 영문 ASCII 기준으로 동작합니다. |
| **바이너리 저장** | TOAST 메커니즘을 통한 대용량 튜플 외부 저장 | SQLite의 오버플로 페이지 체인 사용 | 사용자가 별도의 TOAST 설정을 신경 쓸 필요 없이 자동으로 페이지 단위로 분할 저장됩니다. |
| **UUID 저장 형식** | 16바이트 내부 바이너리 | 16바이트 `BLOB` (네트워크 바이트 순서) | `uuid_cmp()` 정렬 순서가 SQLite의 `memcmp`와 완전히 일치하여 인덱스 스캔 효율이 극대화됩니다. 질의 출력 시에는 표준 36자 문자열로 자동 변환됩니다. |
| **stable 함수** | 행마다 다시 계산 | interval의 텍스트(`::text`, `||`, `IntervalStyle`을 따르는 `xq_pg_iv_out()`)는 stable(SQLite의 `SQLITE_FUNC_SLOCHNG`)이라 상수의 텍스트는 문장에서 처음 쓸 때 한 번 만듭니다 | 같은 행에서 앞서 부른 `set_config('IntervalStyle', ...)`는 보이지만, 뒤 행의 `set_config()`가 바꾼 형식은 그 상수에 보이지 않습니다(PostgreSQL의 stable 정의는 둘 다 허용). 인덱스와 생성 열에는 여전히 쓸 수 없고 CHECK에는 쓸 수 있습니다. |
| **실수의 NaN** | `'NaN'::float8`은 NaN이고, NaN은 다른 모든 값보다 큼 | `double precision`·`real`의 NaN은 지원하지 않음: `'NaN'::float8`과 NaN을 float 열에 넣는 것은 `NaN is not supported for type double precision`(0A000) 오류입니다. NaN이 되는 계산의 결과는 SQLite처럼 NULL입니다. | SQLite의 값은 NaN이 될 수 없습니다(레코드에서 읽으면 NULL). NaN을 저장하면 sqlite3 + 확장이 읽는 인덱스의 순서가 깨집니다. `numeric`의 NaN은 지원합니다. |
| **집합 연산의 타입** | `'a' UNION SELECT 'b' UNION SELECT true`는 `UNION types text and boolean cannot be matched` | 불리언과 만난 문자열 상수는 PostgreSQL처럼 읽지만, 타입이 맞지 않는 항의 오류는 내지 않고 값을 그대로 둡니다 | |
| **통계·순서 집합 집계** | `pg_get_viewdef()`가 `WITHIN GROUP`을 보여 줌 | `variance()`·`stddev()`는 `var_samp()`·`stddev_samp()`로 보이고, `WITHIN GROUP`이 든 뷰는 SQLite 텍스트(`xq_percentile_cont(...)`)로 보입니다. 순서 집합 집계의 정렬과 `mode()`의 같음은 값의 순서(collation을 쓰지 않는 바이너리 비교)입니다. `percentile_cont(interval)`은 지원하지 않습니다. 실수 집계의 합은 arm64 빌드의 PostgreSQL처럼 `a * b + c`를 한 번에 반올림합니다(x86-64 빌드와는 마지막 자리가 다를 수 있음). 엔진 함수 `xq_float_*`, `xq_corr` ... 은 역함수가 없어 sqlite3 + 확장에서는 윈도우 함수로 쓸 수 없습니다. | |
| **커서** | 계획을 따라 행을 하나씩 만들고(holdable은 `COMMIT`에서 구체화), `SCROLL`이 없으면 계획이 뒤로 갈 수 있는지로 스크롤을 정함 | `DECLARE`가 실행될 때 질의를 끝까지 돌려 행을 메모리에 둠. `SCROLL`이 없을 때의 스크롤은 질의의 꼴로 어림함([지원 기능](features.md#23-커서)) | 커서는 언제나 insensitive이고, 큰 결과의 커서는 그만큼 메모리를 씁니다. 첫 `FETCH` 전에 질의 전체가 돕니다(부작용이 있는 함수도 그때 모두 불림). 플래너가 다른 계획을 고르면 `FETCH PRIOR`가 PostgreSQL에서만 실패하거나 그 반대일 수 있습니다. |
| **준비된 문장 (`PREPARE`)** | 계획을 한 번 세워 두고 `EXECUTE`마다 씀 | 문장의 텍스트를 두고 `EXECUTE`마다 인자를 넣은 문장을 컴파일 | 결과는 같지만 `PREPARE`가 계획 비용을 아껴 주지는 않습니다. `pg_prepared_statements` 뷰는 없습니다. |
| **`SET CONSTRAINTS`, `LOCK TABLE`** | 제약마다 미루기, 표 단위 잠금 | `SET CONSTRAINTS`는 모든 외래 키의 `defer_foreign_keys`, `LOCK`은 검사만 | SQLite는 외래 키를 함께 미루고 데이터베이스 전체를 잠급니다. 미룬 외래 키가 커밋에서 실패하면 트랜잭션이 열린 채로 남습니다(SQLite의 동작). |
| **데이터 변경 `WITH`의 스냅숏** | 모든 하위 문장과 바깥 질의가 문장 시작 때의 데이터를 봄. 같은 행을 두 하위 문장이 바꾸면 어느 쪽이 될지 모름 | 하위 문장이 차례로(쓴 순서로) 돌고, 각자 앞 문장이 바꾼 데이터를 봅니다. 바깥 질의도 바뀐 데이터를 봅니다(`WITH d AS (DELETE FROM t RETURNING *) SELECT count(*) FROM t`는 지운 뒤의 수) | 하위 문장은 문장이 돌 때 연결의 방언으로 컴파일되어 차례로 실행되고(`OP_SqlExec`), 돌려준 행은 바깥 질의가 읽는 테이블 값 함수로 남습니다([내부](internals.md#6-merge와-데이터-변경-with)). |
| **`MERGE`의 실행** | 조인의 행마다 고른 동작을 바로 실행 | 조인을 먼저 다 읽어 두고, `WHEN` 절마다 그 절을 고른 행에 `UPDATE`/`DELETE`/`INSERT` 한 문장. 동작이 실행되는 순서가 절 순서입니다(제약 위반이 어느 행에서 먼저 나는지가 다를 수 있음) | 바뀐 행 수와 `RETURNING`의 행은 같고, 행의 순서는 xqlite가 조인을 읽은 순서입니다(PostgreSQL도 실행 계획에 따름). `MERGE` 대상은 테이블만입니다(뷰는 지원하지 않음). |
| **숫자 정밀도** | 임의 정밀도 BCD 십진수 연산 | IEEE 754 부동소수점 및 64비트 정수 하이브리드 연산 | 64비트 정수 범위를 넘어서는 거대 십진 연산의 경우 미세한 정밀도 차이가 발생할 수 있습니다. |

---

## 2. 미지원 기능 목록 (Unsupported)

다음 기능들은 현재 xqlite PostgreSQL 방언에서 지원되지 않습니다.

### 2.1 프로그래밍 및 절차적 언어
- **PL/pgSQL**: `CREATE FUNCTION ... AS $$ ... $$ LANGUAGE plpgsql` 형태의 절차형 함수 및 트리거 작성은 지원하지 않습니다. (단, 단순 표현식 기반 SQL 함수나 `DO $$ ... $$` 익명 블록의 기본 실행은 일부 지원)
- **트리거 (Triggers)**: `CREATE TRIGGER` 문법은 현재 SQLite 네이티브 트리거 구문만 허용되며, PostgreSQL 형식의 트리거 프로시저는 미지원합니다.
- **`DECLARE BINARY`**: 이진 커서는 지원하지 않습니다(`0A000`). 이진 결과는 확장 질의의 형식 코드로 받습니다.

### 2.2 고급 스키마 및 관리 기능
- **파티셔닝 (Table Partitioning)**: `PARTITION BY RANGE / LIST / HASH` 구문은 지원되지 않습니다.
- **테이블스페이스 (Tablespaces)**: `CREATE TABLESPACE` 및 물리적 디스크 경로 지정은 지원되지 않습니다 (SQLite 단일 파일 DB 특성).
- **역할 및 권한 (Roles & Privileges)**: `CREATE ROLE`, `GRANT`, `REVOKE` 문장은 구문 파싱 단계에서 무시되거나 허용되지 않으며, 파일 시스템 기반 권한을 따릅니다.
- **도메인 및 사용자 정의 타입 (UDT)**: `CREATE DOMAIN`과 복합·범위 타입(`CREATE TYPE ... AS (...)`, `AS RANGE`)은 지원되지 않습니다. 열거형(`CREATE TYPE ... AS ENUM`)은 지원하지만, 값은 레이블의 순서가 아니라 텍스트 순서로 비교·정렬되고 타입은 `public`에만 둡니다. `pg_type`·`pg_enum`에는 나오지 않습니다.
- **`inet`·`cidr`의 순서**: 텍스트 순서로 비교·정렬합니다(PostgreSQL은 주소족, 주소 순서). `<<`, `>>` 같은 포함 연산자는 없습니다.
- **구체화된 뷰 (Materialized Views)**: `CREATE MATERIALIZED VIEW` 및 `REFRESH MATERIALIZED VIEW`는 지원되지 않습니다.

### 2.3 질의 및 색인 제약
- **`LATERAL`과 뷰**: 앞 항목의 열을 쓰는 `LATERAL` 서브쿼리(와 그런 인자의 `generate_series()`)는 뷰의 질의에 쓸 수 없습니다(`LATERAL in the query of a view is not supported`). SQLite 텍스트로 쓸 방법이 없기 때문입니다. `RIGHT`/`FULL JOIN LATERAL`은 PostgreSQL처럼 오류입니다.
- **`DISTINCT ON`, `GROUPING SETS`, `WITH TIES`, `INTERSECT ALL`의 모양**: 뷰에는 SQLite가 아는 모양으로 풀어 쓴 질의가 저장되므로 `pg_get_viewdef()`도 그것을 보여 줍니다(`row_number() OVER (...)`의 서브쿼리, 집합마다의 `UNION ALL`). 뷰 질의의 `*`는 만들 때의 열로 풀어 씁니다(풀 수 없는 `*`, 예를 들어 함수나 `USING` 조인의 `*`는 오류). `INTERSECT ALL`/`EXCEPT ALL`의 왼쪽 항에는 `*`를 쓸 수 없고, `GROUPING SETS`는 `*`, 윈도우 함수, `DISTINCT ON`·`WITH TIES`와 함께 쓸 수 없습니다. `FETCH ... WITH TIES`는 `DISTINCT`가 없는 한 `SELECT`(합성 질의가 아닌)에만 씁니다.
- **`ROWS FROM (...)`, `TABLESAMPLE`, `B'...'` 비트 문자열**: 지원하지 않습니다. `OVERLAPS`는 날짜·시각 값에만 맞게 동작하고, 정수 같은 다른 타입에 대해서도 PostgreSQL처럼 오류를 내지는 않습니다.
- **GIN / GiST / BRIN 인덱스**: SQLite B-Tree 기반 단일 인덱스 엔진을 사용하므로, GIN/GiST 특수 인덱스 문법은 B-Tree 인덱스로 대체되거나 지원되지 않습니다.
- **XML 타입 및 함수**: `xml` 데이터 타입 및 XPath/XSLT 관련 함수는 지원하지 않습니다.
- **외래 데이터 래퍼 (FDW)**: `postgres_fdw` 등의 원격 데이터베이스 연결 기능은 지원되지 않습니다.

---

## 3. 주의사항 및 권장 대응책 (Workaround)

1. **자동 증분 기본키**:
   - PostgreSQL의 `SERIAL` 또는 `BIGSERIAL`은 내부적으로 SQLite의 `AUTOINCREMENT` 및 시퀀스 카탈로그로 매핑됩니다. 새로운 테이블을 설계할 때는 표준인 `GENERATED ALWAYS AS IDENTITY` 또는 `GENERATED BY DEFAULT AS IDENTITY` 사용을 권장합니다.
2. **동적 쿼리 및 매개변수 바인딩**:
   - 질의 매개변수는 `$1`, `$2`, ... 형식의 PostgreSQL 스타일 위치 매개변수와 `?` 물음표 매개변수를 모두 지원합니다. 드라이버 사용 시 언어별 표준 바인딩 방식을 그대로 사용할 수 있습니다.
3. **대소문자 구분 규칙**:
   - 따옴표 없는 식별자는 PostgreSQL 규칙에 따라 소문자로 폴딩(folding)됩니다. 예를 들어 `SELECT MyColumn FROM MyTable`은 `SELECT mycolumn FROM mytable`로 해석됩니다. 대소문자를 유지하려면 큰따옴표(`"MyColumn"`)로 감싸야 합니다.
4. **JSON vs JSONB**:
   - JSON 연산이 빈번한 열은 인덱싱과 연산자 최적화가 적용되는 `jsonb` 타입을 사용하는 것이 성능상 훨씬 유리합니다.
