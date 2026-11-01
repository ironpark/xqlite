# 서버

와이어 프로토콜 서버(PostgreSQL v3, MySQL, TDS)를 위한 모듈 `xqlite_server`(`src/server/`)입니다. 지금은 프로토콜과 상관없는 기반만 있고, 프로토콜 자체는 아직 없습니다.

- [구조](#구조)
- [세션과 이벤트](#세션과-이벤트)
- [열의 타입](#열의-타입)
- [오류 분류](#오류-분류)
- [명령 분류](#명령-분류)
- [취소와 세션 목록](#취소와-세션-목록)
- [동시성](#동시성)
- [테스트](#테스트)
- [다음 단계](#다음-단계)

## 구조

```
클라이언트 ──TCP── Server(Protocol) ── 연결마다 태스크 하나
                        │
                Protocol.serve(conn)          ← 프로토콜이 쓰는 부분 (아직 없음)
                        │  핸드셰이크, 메시지 읽기·쓰기
                        ▼
                    Session ── xqlite.Db (클라이언트의 방언, 서버의 DB 파일)
                        │  run(sql, sink): columns / row / complete / failed
                        ▼
              types · errors · command  ← 열 타입, SQLSTATE, 명령 태그
```

- 모듈은 Zig API(`xqlite` 모듈)만 씁니다. 엔진 라이브러리와 C ABI에는 네트워크 코드가 들어가지 않습니다.
- 서버에 필요해서 Zig API에 더한 것: `Db.script()`(문장마다 결과를 읽는 스크립트, 텍스트는 한 번만 복사), `Db.interrupt()`(다른 스레드에서 부르는 취소), `Stmt.columnOrigin()`(결과 열이 읽는 테이블 열), `Stmt.columnTypeAlloc()`(그 열의 선언 타입과 그 타입을 쓴 방언), `Stmt.countsChanges()`(바꾼 행 수를 세는 문장인지), `Db.schemaVersion()`(파일을 읽지 않는 스키마 버전), `OpenOptions.column_metadata`(컴파일하며 열의 출처를 기록).
- 빌드: `build.zig`의 `xqlite_server` 모듈. `zig build test`가 테스트를 돌립니다. wasm 타깃에서는 빌드하지 않습니다.

| 파일 | 내용 |
| --- | --- |
| `Server.zig` | `Server(Protocol)`: 리슨, 연결마다 태스크, 연결 수 제한, 종료. `Connection`(소켓의 reader·writer, `openSession()`), `Config` |
| `Session.zig` | 한 클라이언트의 연결. 스크립트를 문장 단위로 돌려 이벤트로 알림. 트랜잭션 상태, PostgreSQL의 실패한 트랜잭션 |
| `Registry.zig` | 세션 id와 비밀 키, 바깥에서 오는 취소 요청, 연결 수 |
| `types.zig` | 방언의 선언 타입 → `Type`(`boolean`, `int4`, `varchar(20)`, `timestamp_tz` ...) |
| `errors.zig` | 엔진 오류(확장 코드 + 방언의 메시지) → `Class`와 SQLSTATE |
| `command.zig` | 문장 텍스트 → 명령(`INSERT`, `CREATE INDEX` ...) |
| `test.zig` | 루프백 TCP 위의 테스트용 줄 프로토콜 |

## 세션과 이벤트

`Session.run(sql, sink)`은 스크립트를 한 문장씩 컴파일해 돌리고, 결과를 프로토콜과 상관없는 이벤트로 `sink`에 넘깁니다. 프로토콜은 이 이벤트를 자기 메시지로 씁니다.

| 이벤트 | 언제 | PostgreSQL | MySQL | TDS |
| --- | --- | --- | --- | --- |
| `columns([]Column)` | 결과 열이 있는 문장의 행 앞(행이 없어도) | RowDescription | 열 정의 | COLMETADATA |
| `row(*Row)` | 행마다 | DataRow | 행 | ROW |
| `complete(Complete)` | 문장이 끝나면. 명령, 반환한 행 수, 바꾼 행 수, 마지막 rowid | CommandComplete | OK / EOF | DONE |
| `failed(Failure)` | 실패한 문장. 스크립트는 거기서 멈춤 | ErrorResponse | ERR | ERROR + DONE |

- 표현식 열의 타입은 첫 행 값의 저장 클래스로 정합니다. 그래서 `columns`는 첫 `step()` 뒤에 나갑니다. 행이 없으면 `unknown`입니다.
- 세션은 `column_metadata`로 열므로 열의 출처를 찾으려고 문장을 다시 컴파일하지 않습니다. 테이블 열의 선언 타입은 세션의 캐시에 두고, 그 데이터베이스의 스키마 버전이 바뀌면(이 연결이든 다른 연결이든) 다시 읽습니다. 그래서 같은 테이블을 읽는 질의는 `xq_catalog`를 다시 보지 않습니다.
- 바꾼 행 수(`Complete.changes`)는 엔진이 정합니다(`Stmt.countsChanges()`). 방언이 DML로 바꾸는 문장(`MERGE`, `TRUNCATE`)도 셉니다.
- `Row.value(i)`는 빌린 값입니다. sink가 돌아가기 전까지만 유효합니다.
- 실패한 문장은 `run()`의 오류가 아니라 `failed` 이벤트입니다. `run()`의 오류는 sink의 오류(클라이언트가 떠남)와 메모리 부족뿐입니다.
- `Options.abort_failed_transactions`: PostgreSQL의 규칙입니다. 트랜잭션 안에서 문장이 실패하면 트랜잭션이 끝날 때까지 `ROLLBACK` 말고는 모두 `25P02`로 실패하고, `COMMIT`은 롤백합니다(`ROLLBACK` 태그). PostgreSQL처럼 이 판정(`Session.admit()`)은 문장을 컴파일하기 전에 하고, 확장 질의의 Execute도 같은 함수를 씁니다. 끄면 SQLite·MySQL·SQL Server처럼 실패한 문장만 되돌립니다.
- `status()`: `idle`, `in_transaction`, `aborted`. PostgreSQL ReadyForQuery의 `I`/`T`/`E`, MySQL의 `SERVER_STATUS_IN_TRANS`입니다.

## 열의 타입

클라이언트는 행 앞에 받은 열 타입으로 값을 읽습니다. 예를 들어 PostgreSQL 방언의 `boolean` 열은 SQLite에 0/1로 저장되지만 PostgreSQL 클라이언트에는 `t`/`f`로 가야 합니다. 그래서 열의 타입은 SQLite의 선언 타입이 아니라 테이블을 만든 방언의 선언 타입(`xq_catalog`의 `type` 키)에서 옵니다.

- `Stmt.columnTypeAlloc(gpa, i)`: 결과 열이 테이블 열이면 그 열의 방언 타입(`character varying(20)`, `DATETIME2(3)`, `NUMBER(10,2)`)과 그 테이블을 만든 방언, 카탈로그 항목이 없으면 SQLite 선언 타입과 `.sqlite`, 표현식이면 null. 세션의 방언이 아니라 테이블을 만든 방언으로 읽습니다(PostgreSQL 세션이 MariaDB가 만든 테이블을 읽을 때).
- `types.parse(dialect, name)`: 이름을 `Type`(`logical`, `length`, `precision`, `scale`)으로 읽습니다. 방언마다 다른 것: SQLite의 정수·실수는 모두 64비트, MariaDB·MSSQL의 `TINYINT`는 `int1`, MSSQL의 `BIT`은 `boolean`, Oracle의 `DATE`는 시각이 있어 `timestamp`, Oracle의 `NUMBER(p)`는 자릿수에 따라 정수.
- 각 프로토콜이 `Logical`을 자기 코드로 바꿉니다(PostgreSQL의 타입 OID, MySQL의 `MYSQL_TYPE_*`, TDS의 타입 토큰). 값의 텍스트 형식(불리언, 날짜, 바이트열)도 프로토콜이 정합니다.

## 오류 분류

클라이언트와 ORM은 메시지가 아니라 코드로 오류를 구분합니다. 유일성 위반은 PostgreSQL에서 `23505`, MySQL에서 1062, SQL Server에서 2627입니다. `errors.classify(dialect, code, message)`가 엔진의 오류를 `Class`로 읽고, `Class.sqlstate()`가 SQLSTATE를 줍니다. MySQL과 TDS의 오류 번호는 각 프로토콜이 `Class`에서 정합니다.

- 확장 결과 코드가 정확한 곳은 코드로 정합니다: `CONSTRAINT_UNIQUE`/`PRIMARYKEY` → `23505`, `NOTNULL` → `23502`, `FOREIGNKEY` → `23503`, `BUSY` → `55P03`, `BUSY_SNAPSHOT` → `40001`, `INTERRUPT` → `57014`, `READONLY` → `25006` ...
- `SQLITE_ERROR`는 모든 SQL 오류를 덮으므로 메시지로 정합니다. 그 방언의 문구를 먼저 보고(`relation "t" does not exist`, `Table 'db.t' doesn't exist`, `Invalid object name`, `ORA-00942`), 다음에 SQLite의 문구를 봅니다(`no such table`). 방언도 엔진의 오류는 SQLite 문구로 내기 때문입니다.
- 방언은 타입 검사를 이름 붙은 CHECK 제약으로 합니다(`value too long for type character varying(3)`). 그래서 `CONSTRAINT_CHECK`도 제약 이름을 먼저 보고, 아는 이름이 아니면 `23514`입니다.
- 아는 문구가 없으면 `.other`(`HY000`)입니다. 메시지 문구에 기대는 것은 임시입니다. 방언이 오류를 낼 때 자기 코드를 함께 남기면 이 표는 필요 없어집니다([다음 단계](#다음-단계)).

## 명령 분류

`command.classify(sql)`은 문장 텍스트의 앞 키워드로 명령을 정합니다. 프론트엔드가 이미 문장을 파싱했으므로 근본적으로는 엔진이 문장의 종류를 기록해야 합니다([다음 단계](#다음-단계)). 텍스트 판정은 그때까지의 것이고, 컴파일 전에 판정해야 하는 곳(실패한 트랜잭션의 `ROLLBACK`/`COMMIT`, 컴파일에 실패한 문장)에만 남습니다. PostgreSQL의 명령 태그(`INSERT 0 3`, `CREATE INDEX`), MySQL OK 패킷의 바뀐 행 수, TDS DONE의 행 수에 씁니다.

- 주석과 `WITH` 절을 건너뜁니다. `WITH x AS (...) DELETE ...`는 `DELETE`입니다. 모든 방언의 따옴표(`'...'`, `"..."`, `` `...` ``, `[...]`)를 알아서, 문자열과 이름 안의 키워드는 보지 않습니다.
- `CREATE`/`DROP`/`ALTER`는 수식어를 뺀 객체 종류를 씁니다: `CREATE UNIQUE INDEX` → `INDEX`, `CREATE OR REPLACE VIEW` → `VIEW`, `CREATE MATERIALIZED VIEW` → `MATERIALIZED VIEW`.
- 별칭: `START TRANSACTION` → `BEGIN`, `END` → `COMMIT`, `REPLACE INTO` → `INSERT`, `EXEC`/`CALL` → `EXECUTE`.

## 취소와 세션 목록

취소 요청은 세션 바깥에서 옵니다. PostgreSQL의 CancelRequest는 새 연결로 와서 프로세스 id와 비밀 키로 세션을 가리키고, MySQL의 `KILL QUERY`는 다른 세션의 문장입니다.

- `Connection.openSession()`이 세션을 `Registry`에 등록하고 `Ticket`(id, 비밀 키)을 받습니다. 프로토콜은 이것을 클라이언트에 알립니다(BackendKeyData, 연결 id, SPID).
- `Registry.cancel(id, key)`가 그 세션의 `Db.interrupt()`를 부릅니다. 원자 변수라서 어느 스레드에서 불러도 됩니다. 세션이 닫히는 중이 아니도록 레지스트리의 뮤텍스를 잡은 채로 부릅니다.
- SQLite처럼 문장이 시작할 때 실행 중인 문장이 없으면 걸려 있던 인터럽트를 지웁니다. 그래서 문장 사이에 온 취소는 다음 문장을 멈추지 않습니다. PostgreSQL과 같은 동작입니다.
- `Config.max_connections`를 넘는 세션은 `error.TooManySessions`입니다(SQLSTATE `53300`은 프로토콜이 보냄).

## 동시성

- 연결마다 `std.Io`의 태스크 하나(`Group.concurrent`)입니다. `std.Io.Threaded`에서는 스레드 하나입니다. 세션의 문장은 그 태스크에서 돌므로, 느린 질의는 자기 클라이언트만 잡습니다.
- 세션마다 같은 DB 파일을 따로 엽니다. 엔진의 멀티스레드 모드에서 서로 다른 연결은 서로 다른 스레드에서 동시에 써도 됩니다([C API의 스레드](c-api.md#스레드)). POSIX 잠금 표는 프로세스 전역입니다.
- 기본 `Config.open`은 WAL과 busy timeout 5초입니다. 한 세션이 쓰는 동안 다른 세션이 읽고, 쓰기끼리는 실패하지 않고 기다립니다.
- `run()`은 취소될 때까지 받습니다. 호출하는 쪽이 `io.concurrent(Server.run, .{&server})`로 돌리고 그 future를 cancel하면 연결 태스크도 모두 취소됩니다.

## 테스트

- 각 파일의 단위 테스트: 방언별 선언 타입, 방언별 오류 문구, 명령 분류, 세션 이벤트와 PostgreSQL의 실패한 트랜잭션, 레지스트리.
- `src/server/test.zig`: 루프백 TCP로 실제 서버를 띄우고 테스트용 줄 프로토콜(한 줄에 스크립트 하나, 이벤트마다 한 줄)로 확인합니다. 두 클라이언트가 같은 DB를 보는지, 세 번째 클라이언트의 취소가 끝없는 재귀 CTE를 멈추는지(`57014`), 그 뒤에도 세션이 계속 쓰이는지 봅니다.

## 다음 단계

1. **pgwire v3**: startup·인증(trust, cleartext/MD5/SCRAM), 단순 질의, 확장 질의(Parse/Bind/Describe/Execute/Sync, 이름 붙은 문장과 포털), 텍스트 형식 값, CancelRequest, `xqlite serve --pg PORT`. `psql`과 드라이버(libpq, pgjdbc, psycopg)로 검증합니다.
2. **방언의 오류 코드**: 방언 프론트엔드가 오류를 낼 때 자기 코드(SQLSTATE, MySQL 번호, SQL Server 번호, ORA-)를 함께 남겨, 메시지 문구로 분류하는 표를 없앱니다.
3. **문장의 종류를 엔진이 기록**: `Parse`에 동사와 객체 종류를 두고 빌더 진입점이 기본값을, 방언 프론트엔드가 다르게 낮추는 문장(`SET`, `SHOW`, `TRUNCATE`, `MERGE` ...)을 덮어써 `Stmt.command()`로 내보냅니다. 명령 태그가 첫 소비자입니다.
4. **방언의 타입 서술자**: 선언 타입 텍스트를 프로토콜 중립 타입으로 바꾸는 방언 훅. 각 방언의 타입 enum 위의 망라적 switch라서 `types.zig`의 이름 표가 필요 없어지고, `UNSIGNED`, `enum`, `year`, `xml`, 배열 같은 것도 다룹니다.
5. **확장 질의의 Describe**: 실행 전 파라미터 타입과 결과 열 타입. 지금은 표현식 열의 타입을 첫 행에서 정합니다.
6. MySQL 프로토콜, TDS.
