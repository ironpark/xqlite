# 검증

[Oracle 호환](README.md)의 일부입니다.

| 도구 | 하는 일 |
| --- | --- |
| `src/dialect/oracle/test.zig` | 종단 테스트(어휘, `''` 규칙, 질의, 날짜, DDL과 타입, identity·시퀀스, MERGE·INSERT ALL, 트랜잭션, 바인드 변수, 데이터 사전, JSON) |
| `xqt dialect-diff oracle` + `tools/dialect/oracle-cases.txt` | 실제 Oracle과 차등 비교. 61개 케이스(JSON 15개, 사용자·스키마 6개)가 Oracle Database 23ai Free와 같은 행·열 이름·오류 코드를 냄 |
| `xqt interop oracle` | sqlite3 교차 검증. 이 방언으로 쓴 데이터베이스(JSON 열 포함)가 sqlite3 무결성 검사를 통과하고, sqlite3와 xqlite(SQLite 방언)가 같은 행과 스키마를 읽어야 함 |
| `xqt interop ext` | [확장](../extension.md)을 올린 sqlite3로: 함수 기반 인덱스(`SUBSTR`, `JSON_VALUE`, `ADD_MONTHS`)·가상 열·`IS JSON` CHECK·뷰가 있는 데이터베이스의 무결성, 같은 결과, CHECK 위반의 같은 오류, sqlite3가 쓴 행(identity 포함)을 xqlite가 검사하고 읽음, 엔진 함수의 기록된 결과(`tools/ext/abi-oracle.sql`) |
| `zig build fuzz -- ir_roundtrip` | 퍼저의 방언 목록에 Oracle이 있음. 다른 방언의 트리로 만든 뷰를 Oracle 프론트엔드로 읽고, Oracle의 훅으로 렌더링한 텍스트를 모든 방언에서 컴파일 |

차등 비교는 Oracle 컨테이너를 띄운 뒤 실행합니다(`$ORA_SQLPLUS`, 기본값 `podman exec -i xq-ora sqlplus -s -L xq/xqpass@FREEPDB1`). 케이스는 한 번에 하나씩 돌고, 각 케이스는 SYSTEM으로 XQ에 DBA 역할을 주고 이전 케이스가 남긴 사용자(`XQ_...`)를 지운 뒤, 사용자 XQ의 테이블·뷰·시퀀스를 지우고 날짜 형식을 이 방언의 것(`YYYY-MM-DD HH24:MI:SS`)으로 맞춘 뒤 시작합니다. 비교할 때 오류는 ORA- 코드로 맞추고(SQLite 문구의 제약 위반은 Oracle이 같은 경우에 내는 코드로), Oracle의 `.5`와 `TRUE`는 `0.5`와 `1`로 맞춥니다. 서버에 닿지 않으면 바로 실패하며 `zig build check`에는 들어 있지 않습니다. 둘 다 먼저 `zig build tools`가 필요합니다.

```sh
podman run -d --name xq-ora -e ORACLE_PASSWORD=xqpass -e APP_USER=xq -e APP_USER_PASSWORD=xqpass \
  gvenzl/oracle-free:23-slim-faststart
zig-out/bin/xqt dialect-diff oracle --live
zig-out/bin/xqt interop oracle
```
