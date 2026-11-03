# 검증

[MSSQL(T-SQL) 호환](README.md)의 일부입니다.

## SQL Server와 비교

`xqt dialect-diff mssql`(`tools/xqt/dialect_diff.zig`)은 `tools/dialect/mssql-cases.txt`의 각 경우를 SQL Server(sqlcmd)와 `xqlite sql`(`.dialect mssql`)에서 실행해 결과 행, 열 이름, `ERROR:` 줄을 비교합니다. 지금 58개 경우가 모두 같습니다.

```sh
zig build tools
podman run -d --name xq-mssql -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD='Xq_Passw0rd!' \
  -e MSSQL_MEMORY_LIMIT_MB=2048 mcr.microsoft.com/azure-sql-edge:latest
podman cp sqlcmd xq-mssql:/tmp/sqlcmd     # go-sqlcmd linux-arm64 (github.com/microsoft/go-sqlcmd 릴리스)
zig-out/bin/xqt dialect-diff mssql --live [cases-file]
```

- 서버는 Azure SQL Edge(SQL Server 엔진 15.0, arm64 빌드가 있음)입니다. arm64 macOS의 podman에서 `mcr.microsoft.com/mssql/server:2022-latest`(amd64 전용)는 qemu 에뮬레이션에서 시작하자마자 segfault로 죽습니다. Rosetta를 켠 podman 머신이면 그 이미지도 쓸 수 있습니다.
- 이미지에 sqlcmd가 없어서 go-sqlcmd를 컨테이너에 복사해 둡니다. 서버 접속 명령은 `MSSQL_CLIENT`로 바꿉니다(기본 `podman exec -i xq-mssql /tmp/sqlcmd -S localhost -U sa -P Xq_Passw0rd! -C`).
- 각 경우는 새로 만든 데이터베이스 `main`에서 `SET NOCOUNT ON`으로 시작하고, 서버에서는 한 번에 하나씩 돕니다.
- SQL Server는 배치를 실행하기 전에 컴파일하므로, 컴파일 오류가 나는 문장과 그 뒤 문장은 `GO`로 나눕니다.
- 정규화: sqlcmd의 점선, 빈 결과의 머리글, `(n rows affected)`·`Changed database context`·`The statement has been terminated.` 줄을 빼고, 필드의 공백과 소수의 끝 0을 뗍니다. sqlcmd는 좁은 열의 NULL을 열 너비로 자르고(`NU`) 2진 문자열을 16진으로 쓰므로 경우가 그런 모양을 피합니다.

## sqlite3와 교차 검사

`xqt interop mssql`(`tools/xqt/interop/mssql.zig`)은 T-SQL 방언으로 쓴 데이터베이스를 sqlite3로 확인합니다.

- sqlite3의 무결성·외래 키 검사를 통과해야 합니다.
- sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 합니다.
- 다루는 것: STRICT 테이블과 타입의 CHECK, identity 시퀀스, 계산 열(`+`가 열 타입으로 `+`/`||`가 됨), `NOCASE`/`BINARY` 열, 테이블 안과 밖의 인덱스, 뷰, `xq_catalog`, `CHECK (ISJSON(c) = 1)`, `CREATE SCHEMA sales`의 테이블·인덱스·뷰(sqlite3의 `.tables`에 `sales.orders`로 보이고, sqlite3가 쓴 행을 T-SQL 방언이 `sales.orders`로 읽음).
- sqlite3가 타입·제약을 어기는 값을 거부하는지, xqlite가 sqlite3가 바꾼 값을 읽는지도 봅니다.
- 엔진 함수(`xq_tsql_*`)를 쓰는 식(JSON 계산 열과 그 인덱스, `DATEPART` CHECK, `TRY_CAST`·`CONVERT` 뷰, identity)은 `xqt interop ext`가 [확장](../extension.md)을 올린 sqlite3로 확인합니다. `OPENJSON`은 `src/dialect/mssql/test.zig`에서 확인합니다.

## 퍼저

`zig build fuzz -- ir_roundtrip SEED`의 방언 목록에 `mssql`이 있습니다. 트리를 T-SQL 방언의 훅으로 lower하고, 뷰와 저장된 텍스트를 T-SQL 프론트엔드로 읽습니다.
