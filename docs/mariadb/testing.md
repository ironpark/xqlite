# 검증

[MariaDB 호환](README.md)의 일부입니다.

## MariaDB 서버와 비교

`xqt dialect-diff mariadb`(`tools/xqt/dialect_diff.zig`)는 `tools/dialect/maria-cases.txt`의 각 경우를 MariaDB 서버와 `xqlite sql`(`.dialect mariadb`)에서 실행해 결과 행, 열 이름, `ERROR:` 줄을 비교합니다.

```sh
zig build tools
podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
zig-out/bin/xqt dialect-diff mariadb --live [cases-file]
```

- 서버는 `$MARIA_CLIENT`로 연결합니다. 기본값은 `podman exec -i xq-maria mariadb -uroot`입니다.
- 각 경우는 빈 데이터베이스 `main`(collation `utf8mb4_general_ci`)에서 시작합니다. 경우와 MariaDB의 오류 메시지가 `main`이라는 이름을 쓰므로 서버에서는 한 번에 한 경우씩 돌고, xqlite 쪽만 병렬로 돕니다.
- 서버의 준비 문장은 시스템 데이터베이스가 아닌 모든 데이터베이스(앞 경우가 만든 것)를 지우고 `main`을 다시 만듭니다(`BEGIN NOT ATOMIC FOR ... EXECUTE IMMEDIATE 'DROP DATABASE ...'`).
- 서버에 닿지 않으면 바로 실패하고 컨테이너를 띄우는 명령을 알려 줍니다. `zig build check`에는 들어 있지 않습니다.
- 소수 부분이 있는 수는 끝의 0을 떼고 비교합니다(MariaDB `DECIMAL`은 `3.5000`, 방언의 `REAL`은 `3.5`).

## sqlite3와 교차 검사

`xqt interop mariadb`(`tools/xqt/interop/mariadb.zig`)는 MariaDB 방언으로 쓴 데이터베이스를 sqlite3로 확인합니다.

- sqlite3의 무결성 검사를 통과해야 합니다.
- sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 합니다.
- 다루는 것: STRICT 테이블, 이름 붙은 CHECK, DEFAULT·생성 열 식, `AUTO_INCREMENT`, 테이블과 함께 이름이 바뀌는 `"t$i"` 인덱스, 뷰, `xq_catalog`, `CREATE DATABASE`의 테이블·뷰·인덱스(`"sales.orders"`를 sqlite3가 읽고 쓰고, sqlite3가 쓴 행을 방언이 `sales.orders`로 읽음).
- 엔진 함수(`xq_*`)를 쓰는 식(`DIV`, `XOR`, `DATE_ADD`, `JSON_VALUE`의 생성 열과 그 인덱스, `STDDEV_POP` 뷰 ...)은 `xqt interop ext`가 [확장](../extension.md)을 올린 sqlite3로 확인합니다. `JSON_TABLE`을 쓰는 뷰는 `src/dialect/mariadb/test.zig`에서 확인합니다.
- 먼저 `zig build tools`가 필요합니다. sqlite3는 xqt의 `cfg.sqlite3`(`--sqlite3`, `$SQLITE3`)입니다.
