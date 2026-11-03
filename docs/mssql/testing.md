# MSSQL (T-SQL) 호환: 검증 및 테스트

xqlite의 MSSQL (T-SQL) 방언 호환성을 보증하기 위한 테스트 체계, 차등 비교(differential testing) 도구 및 실행 가이드입니다.

---

## 1. 테스트 체계 개요

MSSQL 방언은 순수 Zig 단위 테스트, SQLite 상호운용성 검증, 실제 SQL Server 엔진과의 실시간 차등 비교를 통해 검증됩니다.

```mermaid
flowchart LR
    Unit["단위 테스트 (Zig)"] --> Interop["SQLite 상호운용 검증 (interop)"]
    Interop --> Live["SQL Server 차등 검증 (dialect-diff mssql --live)"]
```

1. **Zig 단위 테스트**: T-SQL 파서, `+` 연산자 정적 분석기, `MERGE`, `OUTPUT`, `OPENJSON` 기능을 검증합니다.
2. **`xqt interop mssql`**: T-SQL 방언으로 기록된 데이터베이스 파일을 순수 `sqlite3` 바이너리로 검증합니다.
3. **`dialect-diff mssql`**: `tools/dialect/mssql-cases.txt`의 모든 테스트 케이스를 xqlite와 실제 SQL Server(Azure SQL Edge)에서 실행하여 결과와 에러 메시지를 1:1 비교합니다.

---

## 2. 테스트 실행 방법

### 2.1 단위 테스트
```sh
# MSSQL 방언 단위 테스트 실행
zig build test -Dtest-filter='mssql:'
```

### 2.2 SQLite 상호운용성 검증
```sh
zig build tools
zig-out/bin/xqt interop mssql
```

---

## 3. 실서버 교차 검증 (`dialect-diff`)

실제 SQL Server 엔진과의 차등 테스트는 Docker/Podman 컨테이너를 통해 수행됩니다. Apple Silicon(macOS arm64) 환경에서는 ARM64를 공식 지원하는 Azure SQL Edge 이미지를 권장합니다.

```sh
# 1. Azure SQL Edge 컨테이너 시작
podman run -d --name xq-mssql -e ACCEPT_EULA=1 \
  -e MSSQL_SA_PASSWORD='Xq_Passw0rd!' \
  -e MSSQL_MEMORY_LIMIT_MB=2048 \
  -p 1433:1433 \
  mcr.microsoft.com/azure-sql-edge:latest

# 2. 컨테이너 내부로 sqlcmd CLI 도구 복사 (필요 시)
# go-sqlcmd 리눅스 바이너리를 컨테이너 내 /tmp/sqlcmd 로 복사

# 3. 실서버 차등 검증 실행
zig-out/bin/xqt dialect-diff mssql --live

# 4. 특정 케이스 파일만 지정 실행
zig-out/bin/xqt dialect-diff mssql --live tools/dialect/mssql-cases.txt
```

- sqlcmd 출력의 점선 구분자, NULL 표기 너비 차이, 소수점 끝 0 표기 차이는 테스트 도구에서 자동으로 정규화되어 정확한 의미적 비교를 수행합니다.
