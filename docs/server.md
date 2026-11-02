# 서버

와이어 프로토콜 서버(PostgreSQL v3, MySQL, TDS)를 위한 모듈 `xqlite_server`(`src/server/`)입니다. 프로토콜과 상관없는 기반, PostgreSQL 프로토콜(`src/server/pg/`), MySQL/MariaDB 프로토콜(`src/server/mysql/`)이 있고 `xqlite serve --pg PORT --mysql PORT`로 띄웁니다. TDS는 아직 없습니다.

- [구조](#구조)
- [세션과 이벤트](#세션과-이벤트)
- [준비된 문장](#준비된-문장)
- [열의 타입](#열의-타입)
- [오류 분류](#오류-분류)
- [명령 분류](#명령-분류)
- [취소와 세션 목록](#취소와-세션-목록)
- [동시성](#동시성)
- [PostgreSQL 프로토콜](#postgresql-프로토콜)
- [xqlite serve](#xqlite-serve)
- [테스트](#테스트)
- [MySQL 프로토콜](#mysql-프로토콜)
- [다음 단계](#다음-단계)

## 구조

```
클라이언트 ──TCP── Server(Protocol) ── 연결마다 태스크 하나
                        │
                Protocol.serve(conn)          ← 프로토콜이 쓰는 부분 (pg/)
                        │  핸드셰이크, 인증, 메시지 읽기·쓰기
                        ▼
                    Session ── xqlite.Db (클라이언트의 방언, 서버의 DB 파일)
                        │  run(sql, sink): columns / row / complete / failed / notice
                        │  prepare(sql) → Prepared: bind / execute(max_rows, sink)
                        ▼
              types · errors · command  ← 열 타입, SQLSTATE, 명령 태그
```

- 모듈은 Zig API(`xqlite` 모듈)만 씁니다. 엔진 라이브러리와 C ABI에는 네트워크 코드가 들어가지 않습니다.
- 서버에 필요해서 Zig API에 더한 것: `Db.script()`(문장마다 결과를 읽는 스크립트, 텍스트는 한 번만 복사), `Db.interrupt()`(다른 스레드에서 부르는 취소), `Stmt.columnOrigin()`(결과 열이 읽는 테이블 열), `Stmt.columnTypeAlloc()`(그 열의 선언 타입과 그 타입을 쓴 방언), `Stmt.countsChanges()`(바꾼 행 수를 세는 문장인지), `Db.schemaVersion()`(파일을 읽지 않는 스키마 버전), `OpenOptions.column_metadata`(컴파일하며 열의 출처를 기록), `Db.columnConstraints()`(테이블 열의 NOT NULL, PRIMARY KEY, AUTOINCREMENT, UNIQUE, 인덱스: MySQL 열 정의의 플래그).
- 빌드: `build.zig`의 `xqlite_server` 모듈. CLI(`src/cli/serve.zig`)가 가져다 씁니다. `zig build test`가 테스트를 돌립니다. wasm 타깃에서는 빌드하지 않습니다(wasm용 CLI는 이 모듈 없이 빌드하고 `serve`는 오류).
- `-Ddialects`에서 `postgres`나 `mariadb`를 빼도 모듈과 CLI는 빌드됩니다. 프로토콜의 세션은 그 프로토콜의 방언이어야 하므로, 방언이 빠진 프로토콜은 띄우지 않습니다: `xqlite serve --pg`(postgres가 없을 때)와 `--mysql`(mariadb가 없을 때)은 그 사실을 알리고 1로 끝납니다. 그 방언이 필요한 테스트는 건너뜁니다. 라이브러리의 `mysql.Protocol`은 `dialect` 필드로 방언을 고를 수 있어 기본값만 SQLite로 물러납니다([MySQL 프로토콜](#mysql-프로토콜)).

| 파일 | 내용 |
| --- | --- |
| `Server.zig` | `Server(Protocol)`: 리슨, 연결마다 태스크, 연결 수 제한, 종료. `Connection`(소켓의 reader·writer, `openSession()`), `Config` |
| `Session.zig` | 한 클라이언트의 연결. 스크립트를 문장 단위로 돌려 이벤트로 알림. 준비된 문장(`prepare()`, `Prepared`). 트랜잭션 상태, PostgreSQL의 실패한 트랜잭션과 암묵적 트랜잭션 |
| `Registry.zig` | 세션 id와 비밀 키, 바깥에서 오는 취소 요청, 연결 수 |
| `errors.zig` | 오류의 SQLSTATE: 엔진·방언이 남긴 것, 없으면 확장 결과 코드의 것 |
| `command.zig` | 문장 텍스트 → 명령(`INSERT`, `CREATE INDEX` ...) |
| `test.zig` | 루프백 TCP 위의 테스트용 줄 프로토콜 |
| `pg/root.zig` | PostgreSQL 프로토콜의 `Protocol`, `Config`(인증, 데이터베이스 이름, `server_version`) |
| `pg/Backend.zig` | 한 PostgreSQL 클라이언트: startup, 인증, 단순 질의, 확장 질의(문장과 포털) |
| `pg/wire.zig` | 메시지 틀: 타입 바이트, 길이, 본문. 읽기와 쓰기 |
| `pg/values.zig` | `types.Logical` → 타입 OID·typlen·typmod, 값의 텍스트·이진 형식, 매개변수 읽기 |
| `pg/auth.zig` | cleartext, MD5, SCRAM-SHA-256 |
| `pg/test.zig` | 테스트용 최소 PostgreSQL 클라이언트와 루프백 테스트 |
| `mysql/` | MySQL/MariaDB 프로토콜([MySQL 프로토콜](#mysql-프로토콜)) |

## 세션과 이벤트

`Session.run(sql, sink)`은 스크립트를 한 문장씩 컴파일해 돌리고, 결과를 프로토콜과 상관없는 이벤트로 `sink`에 넘깁니다. 프로토콜은 이 이벤트를 자기 메시지로 씁니다.

| 이벤트 | 언제 | PostgreSQL | MySQL | TDS |
| --- | --- | --- | --- | --- |
| `columns([]Column)` | 결과 열이 있는 문장의 행 앞(행이 없어도) | RowDescription | 열 정의 | COLMETADATA |
| `row(*Row)` | 행마다 | DataRow | 행 | ROW |
| `complete(Complete)` | 문장이 끝나면. 명령, 반환한 행 수, 바꾼 행 수, 마지막 rowid | CommandComplete | OK / EOF | DONE |
| `failed(Failure)` | 실패한 문장. 스크립트는 거기서 멈춤 | ErrorResponse | ERR | ERROR + DONE |

- 표현식 열의 타입은 문장이 매긴 타입(`engine.resultType()`)이고, 없으면 첫 행 값의 저장 클래스로 정합니다. 그래서 `columns`는 첫 `step()` 뒤에 나갑니다. 행도 없으면 `unknown`입니다. 준비된 문장의 `columns`는 실행 전의 것입니다([준비된 문장](#준비된-문장)).
- 세션은 `column_metadata`로 열므로 열의 출처를 찾으려고 문장을 다시 컴파일하지 않습니다. 테이블 열의 선언 타입은 연결이 메모리에 둔 카탈로그(`catalog/meta.zig`)에서 읽고, 그 데이터베이스의 스키마가 바뀌면(이 연결이든 다른 연결이든) 다시 읽습니다. 그래서 같은 테이블을 읽는 질의는 `xq_catalog`를 다시 보지 않습니다([메모리의 카탈로그](architecture.md#메모리의-카탈로그)).
- 바꾼 행 수(`Complete.changes`)는 엔진이 정합니다(`Stmt.countsChanges()`). 방언이 DML로 바꾸는 문장(`MERGE`, `TRUNCATE`)도 셉니다.
- `Row.value(i)`는 빌린 값입니다. sink가 돌아가기 전까지만 유효합니다.
- 실패한 문장은 `run()`의 오류가 아니라 `failed` 이벤트입니다. `run()`의 오류는 sink의 오류(클라이언트가 떠남)와 메모리 부족뿐입니다.
- `Options.abort_failed_transactions`: PostgreSQL의 규칙입니다. 트랜잭션 안에서 문장이 실패하면 트랜잭션이 끝날 때까지 `ROLLBACK` 말고는 모두 `25P02`로 실패하고, `COMMIT`은 롤백합니다(`ROLLBACK` 태그). PostgreSQL처럼 이 판정(`Session.admit()`)은 문장을 컴파일하기 전에 하고, 확장 질의의 Execute도 같은 함수를 씁니다. 끄면 SQLite·MySQL·SQL Server처럼 실패한 문장만 되돌립니다.
- `Options.implicit_transactions`: PostgreSQL의 암묵적 트랜잭션 블록입니다. 트랜잭션 밖에서 스크립트의 문장들(문장이 둘 이상일 때)이나 `sync()`까지 실행한 준비된 문장들은 세션이 연 트랜잭션 하나에서 돌고, 스크립트 끝이나 `sync()`에서 커밋됩니다. 문장이 실패하면 그 앞의 문장까지 롤백됩니다. 그 안의 `BEGIN`은 트랜잭션을 클라이언트의 것으로 바꾸고(실행하지 않고 `BEGIN` 완료), 트랜잭션 밖의 `COMMIT`/`ROLLBACK`은 오류가 아니라 경고(`notice`, `25P01` "there is no transaction in progress")입니다. `SAVEPOINT`, `RELEASE`, `VACUUM`, `ATTACH`, `DETACH`, `PRAGMA`, `SET`, `SHOW`, `USE`는 암묵적 트랜잭션을 열지 않습니다.
- `notice(Notice)`는 선택 이벤트입니다. sink에 `pub fn notice`가 없으면 부르지 않습니다.
- `SET`은 결과가 없습니다. 방언이 `SET`을 질의로 돌려도(PostgreSQL의 `set_config()`) `columns`·`row` 없이 `complete`만 나갑니다.
- `status()`: `idle`, `in_transaction`, `aborted`. PostgreSQL ReadyForQuery의 `I`/`T`/`E`, MySQL의 `SERVER_STATUS_IN_TRANS`입니다. 세션이 연 암묵적 트랜잭션은 `idle`입니다.
- `markFailed()`: 프로토콜이 스스로 낸 문장의 실패(보낼 수 없는 값, 읽을 수 없는 매개변수) 뒤에, 문장의 실패처럼 암묵적 트랜잭션을 롤백하거나 열린 트랜잭션을 실패로 표시합니다.

## 준비된 문장

확장 질의(PostgreSQL의 Parse/Bind/Execute, MySQL의 `COM_STMT_PREPARE`/`COM_STMT_EXECUTE`)를 위한 프로토콜 중립 API입니다.

```zig
const p = try session.prepare(sql, &sink) orelse return; // 실패는 sink.failed()로 알림
defer p.close();
p.parameterCount(); p.parameterType(1); p.columns;      // 실행 전의 설명
try p.bind(1, .{ .integer = 42 });                       // 값은 복사됨, 바인딩은 남음
switch (try p.execute(max_rows, &sink)) { .complete, .suspended, .failed, .empty => {} }
try session.sync(&sink);                                 // 암묵적 트랜잭션의 끝
```

- `prepare()`는 문장 하나만 받습니다. 둘 이상이면 `42601` "cannot insert multiple commands into a prepared statement", 빈 텍스트는 문장 없는 `Prepared`(`execute()`가 `.empty`)입니다. 컴파일 실패는 문장의 실패처럼 트랜잭션을 실패시킵니다. 실패한 트랜잭션에서는 `ROLLBACK`/`COMMIT` 말고는 준비하지 않습니다(`25P02`, PostgreSQL의 Parse와 같음).
- `columns`는 실행 전의 결과 열입니다. 테이블 열은 그 선언 타입, 식은 문장이 매긴 타입(`engine.resultType()`), 모르면 `unknown`입니다. 스키마가 바뀌어 문장이 다시 컴파일되면(`Stmt.recompileCount()`) 다음 실행이 시작할 때 다시 설명합니다(`SELECT *`에 더한 열).
- 실행이 sink에 보내는 `columns`는 이 `columns`에서 `unknown`인 식만 첫 행 값의 저장 클래스로 정한 것입니다(`run()`과 같음, 행이 없으면 그대로). 이미 설명을 보낸 프로토콜은 무시합니다(PostgreSQL: `Describe`의 타입으로 행을 씀). 실행 응답에 열 정의를 다시 보내는 MySQL은 이것을 씁니다.
- `parameterType(i)`는 `Stmt.parameterType()`입니다. `INTEGER PRIMARY KEY`(rowid의 별칭)인 열과 비교한 매개변수는 아직 타입이 없습니다(엔진).
- `execute(max_rows, sink)`: 실행을 시작하거나 이어 갑니다. 시작할 때 첫 행을 읽고 `columns`(위의 것), 행을 최대 `max_rows`개(0이면 모두), 끝나면 `complete`(그 호출의 행 수)나 `failed`. `max_rows`개를 보내면 `.suspended`이고, 다음 호출이 이어 갑니다(미리 읽지 않으므로 남은 행이 없어도 `.suspended`일 수 있음: PostgreSQL과 같음). `admit()`과 암묵적 트랜잭션 규칙은 `run()`의 문장과 같습니다.
- `bind()`와 `clearBindings()`는 진행 중인 실행을 끝냅니다(`reset()`). sink의 오류(클라이언트가 떠남)도 실행을 끝냅니다.
- 한 `Prepared`는 실행을 하나만 가집니다. 같은 문장의 포털이 여럿이면 프로토콜이 문장을 다시 준비합니다(`pg/Backend.zig`).
- 두 프로토콜이 이 API를 씁니다: PostgreSQL의 문장과 포털(`pg/Backend.zig`), MySQL의 `COM_STMT_*`(`mysql/prepared.zig`: 문장 id, 클라이언트가 묶은 매개변수 타입, `SEND_LONG_DATA`, 이진 매개변수만 MySQL의 것). MySQL 세션은 `implicit_transactions`와 `abort_failed_transactions`를 끄므로 준비·실행에 트랜잭션 규칙이 끼지 않습니다.

## 열의 타입

클라이언트는 행 앞에 받은 열 타입으로 값을 읽습니다. 예를 들어 PostgreSQL 방언의 `boolean` 열은 SQLite에 0/1로 저장되지만 PostgreSQL 클라이언트에는 `t`/`f`로 가야 합니다. 그래서 열의 타입은 SQLite의 선언 타입이 아니라 테이블을 만든 방언의 선언 타입(`xq_catalog`의 `type` 키)에서 옵니다.

- `Stmt.columnTypeAlloc(gpa, i)`: 결과 열이 테이블 열이면 그 열의 방언 타입(`character varying(20)`, `DATETIME2(3)`, `NUMBER(10,2)`)과 그 테이블을 만든 방언, 카탈로그 항목이 없으면 SQLite 선언 타입과 `.sqlite`. 세션의 방언이 아니라 테이블을 만든 방언으로 읽습니다(PostgreSQL 세션이 MariaDB가 만든 테이블을 읽을 때). 표현식이면 문장이 매긴 타입의 철자와 문장의 방언(PostgreSQL의 `a + 1`은 `integer`, `count(*)`는 `bigint`), 모르면 null.
- `Stmt.parameterType(i)`: 문장이 매개변수에 매긴 타입(비교·연산의 상대, 저장되는 열의 타입). `Prepared.parameterType()`으로 확장 질의(`ParameterDescription`)가 씁니다.
- 세션은 열의 타입을 `xqlite.display.Columns`로 읽습니다(상태가 없고, 테이블 열은 연결이 메모리에 둔 카탈로그에서). 같은 것을 셸도 씁니다([값 표시](architecture.md#값-표시)).
- `xqlite.types.parse(dialect, name)`: 이름을 `Type`(`logical`, `length`, `precision`, `scale`)으로 읽습니다. 방언마다 다른 것: SQLite의 정수·실수는 모두 64비트, MariaDB·MSSQL의 `TINYINT`는 `int1`, MSSQL의 `BIT`은 `boolean`, Oracle의 `DATE`는 시각이 있어 `timestamp`, Oracle의 `NUMBER(p)`는 자릿수에 따라 정수.
- 각 프로토콜이 `Logical`을 자기 코드로 바꿉니다(PostgreSQL의 타입 OID, MySQL의 `MYSQL_TYPE_*`, TDS의 타입 토큰). 값의 텍스트는 `xqlite.display.text()`가 그 방언의 클라이언트가 보는 대로 만듭니다(PostgreSQL의 `t`/`f`, `numeric(10,2)`의 `1.50`).

## 오류 분류

클라이언트와 ORM은 메시지가 아니라 코드로 오류를 구분합니다. 유일성 위반은 PostgreSQL에서 `23505`, MySQL에서 1062, SQL Server에서 2627입니다. 엔진과 방언이 오류를 낼 때 그 오류가 무엇인지 함께 남기므로(`ErrorInfo.sqlstate`, `ErrorInfo.dialect_number`, [방언 아키텍처의 오류 코드](architecture.md#오류-코드)), 서버는 메시지를 읽지 않습니다.

- `Failure.sqlstate`는 `errors.sqlstate(code, recorded)`입니다. 남긴 SQLSTATE가 있으면 그것이고, 없으면 확장 결과 코드가 구분하는 것입니다: `CONSTRAINT_UNIQUE`/`PRIMARYKEY` → `23505`, `NOTNULL` → `23502`, `FOREIGNKEY` → `23503`, `CHECK` → `23514`, `BUSY` → `55P03`, `BUSY_SNAPSHOT` → `40001`, `INTERRUPT` → `57014`, `READONLY` → `25006` ... 둘 다 없으면 일반 오류 `HY000`입니다.
- `Failure.number`는 방언의 번호입니다(MariaDB 세션의 1146, MSSQL 세션의 208, Oracle 세션의 942). MySQL 프로토콜과 TDS는 이 번호를 그대로 보내고, 없으면 SQLSTATE에서 정합니다.
- 세션이 스스로 내는 것: 실패한 트랜잭션의 `25P02`, 연결 수 초과의 `53300`(`errors.in_failed_transaction`, `errors.too_many_connections`).

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

## PostgreSQL 프로토콜

`pg.Protocol`(`src/server/pg/`)은 PostgreSQL의 frontend/backend 프로토콜 3.0입니다. 세션은 PostgreSQL 방언으로, `abort_failed_transactions`와 `implicit_transactions`를 켜고 엽니다.

```zig
var protocol: server.pg.Protocol = .init(io, .{ .auth = .{ .method = .@"scram-sha-256", .password = pw } });
var srv = try server.Server(server.pg.Protocol).init(io, gpa, &protocol, .{ .address = addr, .path = "app.db" });
```

### 시작과 인증

- `SSLRequest`와 `GSSENCRequest`에는 `N`을 답합니다(TLS 없음: `sslmode=prefer`는 평문으로 이어 가고 `require`는 실패). `CancelRequest`는 `Registry.cancel(pid, key)`이고 답하지 않습니다.
- `StartupMessage` 3.0: `user`(없으면 `28000`), `database`(없으면 사용자 이름), `application_name`, `options`(`-c name=value`, `--name=value`, 모르는 이름이면 FATAL). `application_name`과 `options`의 값은 방언의 `xq_pg_startup_setting()`으로 정하므로 그 값이 세션의 값이자 `RESET`이 돌아가는 값입니다(PostgreSQL과 같음). 데이터베이스 이름은 `current_database()`, `pg_database.datname`, `information_schema`의 `table_catalog`가 됩니다(숨은 설정 `xqlite.database`). 그 밖의 설정(`client_encoding`, `DateStyle`, `extra_float_digits` ...)은 무시합니다. 3.x의 더 높은 마이너 버전이나 `_pq_.` 옵션에는 `NegotiateProtocolVersion`(3.0)을 보냅니다.
- 데이터베이스 이름: 서버는 파일 하나를 내놓으므로 어떤 이름이든 그 파일입니다. `Config.database`(`--database`)를 주면 그 이름만 받습니다(아니면 `3D000`).
- 인증(`auth.Config`): `trust`(기본), `password`(cleartext), `md5`, `scram-sha-256`. 비밀번호는 하나(모든 사용자)이고, `user`를 주면 그 사용자만 받습니다(아니면 `28000` "role does not exist"). 틀리면 `28P01`. SCRAM은 RFC 5802/7677을 따르고 채널 바인딩은 없습니다(`SCRAM-SHA-256-PLUS`를 알리지 않고, `p=`를 요구하는 클라이언트는 거절). 키(StoredKey, ServerKey)는 시작할 때 무작위 소금과 4096회 PBKDF2로 한 번 만듭니다. 비밀번호는 정규화(SASLprep)하지 않으므로 ASCII 비밀번호가 PostgreSQL과 같게 동작합니다. 인증 전의 메시지는 10000바이트까지입니다.
- 그 뒤: `AuthenticationOk`, `ParameterStatus`(`server_version` "16.15 (xqlite)" — 방언의 `SHOW server_version`, `server_version_num` 160015, `version()`의 "PostgreSQL 16.15"와 같은 릴리스. psql 16이 주 버전이 다르다는 경고를 내지 않음, `server_encoding`/`client_encoding` UTF8, `DateStyle` "ISO, MDY", `integer_datetimes` on, `standard_conforming_strings` on, `TimeZone` UTC, `IntervalStyle` postgres, `is_superuser` on, `session_authorization`, `application_name`, `default_transaction_read_only`, `in_hot_standby`), `BackendKeyData`(세션의 `Ticket`), `ReadyForQuery`(`Session.status()`의 `I`/`T`/`E`).

### 단순 질의

- `Query`의 텍스트는 스크립트입니다(`Session.run()`): 문장마다 `RowDescription`, `DataRow`, `CommandComplete`. 문장이 실패하면 `ErrorResponse`를 보내고 나머지는 돌리지 않으며, 암묵적 트랜잭션이면 앞의 문장도 롤백됩니다. 문장이 없으면 `EmptyQueryResponse`. 끝에 `ReadyForQuery`.
- 명령 태그: `SELECT n`(VALUES도), `INSERT 0 n`, `UPDATE n`, `DELETE n`, `MERGE n`, `TRUNCATE TABLE`, `CALL`, 나머지는 명령 분류의 단어(`CREATE TABLE`, `BEGIN`, `SET`, `RESET`, `COMMENT` ...). `SET`과 `RESET`은 행을 보내지 않습니다.
- `ErrorResponse`: `S`/`V`(ERROR, FATAL), `C`(SQLSTATE), `M`, 오프셋을 알면 `P`(질의 텍스트에서 1부터 센 문자 위치). 취소된 문장은 PostgreSQL처럼 "canceling statement due to user request"(`57014`). `NoticeResponse`는 세션의 경고(트랜잭션 밖의 `COMMIT`)입니다.
- 단순 질의는 이름 없는 문장과 포털을 지웁니다.

### 확장 질의

- `Parse`: 이름 있는 문장과 이름 없는 문장(새 `Parse`가 바꿈), 클라이언트가 준 매개변수 타입 OID(0이면 문장이 매긴 타입, 그것도 없으면 `text`). 이미 있는 이름은 `42P05`. 매개변수 OID는 값을 읽는 데만 씁니다(엔진의 매개변수 타입에는 아직 반영하지 않음, [타입을 읽는 코드 생성](architecture.md#타입을-읽는-코드-생성)).
- `Bind`: 포털(이름 없는 것은 새 `Bind`가 바꿈). 매개변수는 텍스트 형식, 또는 이진 형식의 `bool`, `int2`, `int4`, `int8`, `float4`, `float8`, `bytea`, `text`/`varchar`/`bpchar`/`name`/`json`, `jsonb`, `uuid`(그 밖은 `0A000`). 텍스트 값은 매개변수의 타입으로 읽습니다: 정수, 실수, 불리언(`t`, `yes`, `on`, `1` ...), `bytea`(`\x` 16진수나 escape 형식)는 그 값으로, 나머지(`numeric`, 날짜·시각 ...)는 텍스트 그대로 바인딩하고 문장이 읽습니다(저장 함수, [타입을 읽는 코드 생성](architecture.md#타입을-읽는-코드-생성)). 읽을 수 없으면 `22P02`. 결과 형식 코드는 텍스트와, 이진 매개변수와 같은 타입의 이진 형식입니다. 이진으로 보낼 수 없는 열(`numeric`, 날짜·시각 ...)을 이진으로 달라고 하면 `Bind`가 `0A000`으로 실패합니다.
- `Describe`: 문장(`S`)은 `ParameterDescription`과 `RowDescription`(또는 `NoData`), 포털(`P`)은 그 형식 코드의 `RowDescription`. 실행 전의 타입입니다([준비된 문장](#준비된-문장)): 식의 타입을 문장이 모르면 `text`입니다.
- `Execute`: 행 수 제한이 있으면 그만큼 보내고 `PortalSuspended`, 다음 `Execute`가 이어 갑니다. 끝난 포털을 다시 실행하면 행 없이 `CommandComplete`. 실패한 트랜잭션의 규칙(`Session.admit()`)은 실행할 때 봅니다(`Bind`는 받음).
- `Close`, `Flush`, `Sync`. 확장 질의 메시지가 실패하면 `ErrorResponse`를 보내고 `Sync`까지 메시지(단순 질의 포함, PostgreSQL과 같음)를 버립니다.
- 암묵적 트랜잭션: 트랜잭션 밖의 `Execute`들은 세션의 암묵적 트랜잭션에서 돌고 `Sync`에서 커밋됩니다(`Session.sync()`). 실패하면 그 앞의 실행도 롤백됩니다. 포털은 트랜잭션이 끝날 때 없어집니다: 트랜잭션 밖이면 `Sync`마다, `BEGIN` 안이면 `COMMIT`/`ROLLBACK`까지 삽니다(PostgreSQL의 holdable이 아닌 포털).
- 같은 문장의 포털이 둘 이상 동시에 있으면 두 번째부터는 문장을 다시 준비합니다. 문장을 닫아도 그 포털은 계속 실행할 수 있습니다.

### 값과 타입

- 열의 타입 OID: `boolean` 16, `int1`/`int2` 21, `int4` 23, `int8` 20, `float4` 700, `float8` 701, `numeric` 1700, `text` 25, `varchar` 1043, `char` 1042(`bpchar`), `bytes` 17(`bytea`), `date` 1082, `time` 1083, `time_tz` 1266, `timestamp` 1114, `timestamp_tz` 1184, `interval` 1186, `uuid` 2950, `json` 114, `jsonb` 3802, 모름은 `text` 25. typmod: `varchar(n)`/`char(n)`은 n+4, `numeric(p,s)`는 ((p<<16)|s)+4, 시각·타임스탬프는 소수 자릿수, 그 밖은 -1. 테이블 OID와 열 번호는 0입니다.
- 텍스트 형식의 값: `xqlite.display.text()`가 아는 것은 그것(`t`/`f`, `numeric(p,s)`의 s자리, `timestamptz`의 `+00`), 정수는 십진수, 실수는 PostgreSQL의 float8 텍스트(되읽으면 같은 값인 가장 짧은 자릿수, 지수 -4..14는 고정 소수점: `100`, `0.1`, `1e+20`, `NaN`, `Infinity`; `real` 열은 float4의 자릿수), 블롭은 `\x`와 16진수, NULL은 길이 -1.
- 이진 형식의 값은 열의 타입으로 바꿉니다(SQLite는 어느 열에나 어느 값이든 저장하므로). 바꿀 수 없으면(정수 열의 `'abc'`) 그 `Execute`가 `22P03`으로 실패합니다.
- `pg_catalog.format_type(oid, typmod)`는 PostgreSQL 방언의 함수입니다(이 OID들의 이름). psql의 `\gdesc`가 씁니다.
- 방언의 시스템 카탈로그(`pg_type`, `pg_attribute.atttypid` ...)도 같은 OID를 씁니다(`pgcatalog.zig`의 `oidOfLogical()`과 `values.zig`의 `ofType()`이 같은 표이고 테스트가 비교). 카탈로그의 `oid` 열은 `int4`(23)로 알립니다(PostgreSQL은 `oid` 26; 값은 2^31 아래라 텍스트·이진 형식이 같음). [PostgreSQL 호환의 카탈로그](postgres.md#카탈로그).
- 세션은 `generate_series()`(셸과 같은 `ext/series.zig`)를 등록합니다. psql의 `\d`가 씁니다.

### PostgreSQL과 다른 점

- TLS, GSSAPI, 채널 바인딩이 없습니다. 비밀번호는 서버에 하나입니다(사용자별 비밀번호, `pg_hba.conf` 같은 규칙 없음).
- `COPY`는 지원하지 않습니다: 방언이 파싱하지 못하고, 서버는 그 오류를 `0A000` "COPY is not supported by this server"로 바꿔 보냅니다. CopyData/CopyDone/CopyFail은 PostgreSQL처럼 무시합니다. 함수 호출 프로토콜(`FunctionCall`)은 `0A000`입니다.
- 클라이언트가 바꾼 설정(`SET client_encoding`, `DateStyle` ...)을 `ParameterStatus`로 다시 알리지 않습니다. 시작할 때의 값은 늘 UTF8, ISO, UTC입니다.
- 실행 전의 열 타입(`Describe`)은 문장이 매긴 타입입니다. 문장이 모르는 식(SQLite 테이블의 열을 쓰는 식, 규칙이 없는 함수)은 `text`로 알리고, 단순 질의에서는 첫 행의 값으로 정합니다.
- 단순 질의의 문장이 하나뿐이면 암묵적 트랜잭션을 열지 않습니다(SQLite의 자동 커밋과 같음).
- SQL 수준의 `PREPARE`/`EXECUTE`/`DECLARE CURSOR`는 방언의 일입니다(지금은 없음).
- `Config.reuse_address`(기본 꺼짐)를 켜면 서버가 닫은 연결이 `TIME_WAIT`로 잡고 있는 포트를 바로 다시 씁니다(`SO_REUSEADDR`). Zig 표준 라이브러리가 `SO_REUSEPORT`도 함께 켜서, 같은 포트에 띄운 둘째 서버가 실패하지 않고 클라이언트를 나눠 받으므로 기본으로는 끕니다. 그래서 재시작 직후에는 `address in use`로 잠시 실패할 수 있습니다.

## xqlite serve

```sh
xqlite serve DB [--pg PORT] [--mysql PORT] [--host ADDR] [--max-connections N] [--user NAME] [--password PW] [--auth METHOD] [--database NAME]
```

- `--pg PORT`(PostgreSQL v3, postgres 방언)와 `--mysql PORT`(MySQL/MariaDB 프로토콜, mariadb 방언) 중 하나 이상을 줍니다. 둘 다 주면 같은 DB 파일에 두 `Server(Protocol)`가 동시에 받습니다(같은 `--host`, 포트는 달라야 함). 한 프로토콜의 리슨이 실패하면 아무것도 띄우지 않고 1로 끝납니다.
- 방언이 빠진 빌드에서는 그 프로토콜을 띄우지 않고 오류로 끝납니다(`--pg`와 `--mysql`이 같은 규칙, [구조](#구조)).

- `DB`는 없으면 만듭니다. 시작할 때 한 번 열어 보고, 열리지 않으면 바로 실패합니다.
- `--host`: 기본 `127.0.0.1`. 컨테이너나 다른 호스트의 클라이언트에는 `0.0.0.0`. IP 주소만 받습니다.
- `--password`가 없으면 `$XQLITE_PASSWORD`를 씁니다(프로세스 목록에 비밀번호가 보이지 않도록). 비밀번호가 있으면 기본 인증은 `scram-sha-256`, 없으면 `trust`입니다. `--auth`가 `trust`가 아닌데 비밀번호가 없으면 오류입니다. 비밀번호는 로그에 쓰지 않습니다.
- `--user`와 `--password`는 두 프로토콜에 같이 씁니다(사용자 하나, 비밀번호 하나). `--auth`는 PostgreSQL의 방법을 고릅니다. MySQL에는 `mysql_native_password`뿐이라, 인증이 `trust`가 아니면(비밀번호가 있으면) MySQL 클라이언트도 그 비밀번호로 `mysql_native_password` 검사를 받고(`caching_sha2_password` 등으로 온 클라이언트는 AuthSwitch), `trust`이면 MySQL도 비밀번호를 보지 않습니다. `--database`는 PostgreSQL만의 것입니다(MySQL 핸드셰이크의 데이터베이스는 `USE`).
- `--max-connections`는 프로토콜마다의 한도입니다(서버마다 레지스트리가 따로 있음). 연결 id(MySQL의 `CONNECTION_ID()`, `KILL`)도 프로토콜마다 따로 셉니다.
- 시작하면 표준 오류에 `xqlite serve: listening on 0.0.0.0:5432 (postgres, auth scram-sha-256) for app.db`, `xqlite serve: listening on 0.0.0.0:3306 (mysql, mysql_native_password) for app.db`를 씁니다. SIGINT(Ctrl-C)나 SIGTERM을 받으면 받기를 멈추고 연결을 모두 취소한 뒤(세션은 닫혀 열린 트랜잭션은 롤백) 0으로 끝납니다. 시그널은 스레드가 생기기 전에 막고 `sigwait()`로 기다립니다.
- 다른 프로토콜(TDS)은 같은 옵션 파서에 플래그 하나와 `Listeners`(`src/cli/serve.zig`)에 `Server(Protocol)` 하나를 더해 함께 돌립니다.

psql로 확인한 것(`postgres:16-alpine`의 psql 16, macOS podman에서 `host.containers.internal`):

```sh
xqlite serve app.db --pg 15432 --host 0.0.0.0
podman run --rm postgres:16-alpine psql "host=host.containers.internal port=15432 user=u dbname=x sslmode=disable" -c "SELECT 1"
```

- 메타 명령: `\d`, `\dt`, `\di`, `\dv`, `\ds`, `\dn`, `\df`, `\dT`, `\l`, `\du`, `\dt+`의 출력이 PostgreSQL 16과 같은 모양입니다(스키마·이름·종류·소유자, `\dt+`의 Persistence·Access method·Description). `\d 테이블`(열·타입·기본값·`generated always as identity`, 인덱스, CHECK, 외래 키, Referenced by), `\d 뷰`, `\d 인덱스`, `\d 시퀀스`(Owned by)는 PostgreSQL 16의 출력과 같았습니다. 단 이들은 psql이 `OPERATOR(pg_catalog.~)`와 `!~`, 정책 질의의 `array(...)`·`= any(...)`, 발행 질의의 배열 첨자를 함께 보내므로, 정규식 연산자와 배열 문법이 들어간 뒤에 그대로 됩니다(확인은 그 부분을 임시로 넣고 했음). `\d+ 테이블`은 `unnest()`가 FROM에 필요합니다.
- 여러 문장(`\;`), 오류와 위치(`LINE 1: ... ^`), `BEGIN`/실패/`25P02`/`ROLLBACK`, 트랜잭션 밖 `COMMIT`의 경고, `\gdesc`(Parse/Describe와 `format_type()`), `\bind ... \g`(확장 질의), `bytea`·`jsonb`·`numeric(10,2)`·`timestamptz`의 값, `SET`/`SHOW`, `COPY`의 오류, `timeout -s INT`로 보낸 psql의 취소 요청, SCRAM-SHA-256(`sslmode=prefer channel_binding=prefer` 포함)·MD5·틀린 비밀번호·없는 사용자.

## 테스트

- 각 파일의 단위 테스트: 방언별 선언 타입, 방언별 오류 문구, 명령 분류, 세션 이벤트와 PostgreSQL의 실패한 트랜잭션, 레지스트리.
- 세션: 암묵적 트랜잭션(실패가 앞의 문장을 롤백, `BEGIN`이 트랜잭션을 넘겨받음, 트랜잭션 밖 `COMMIT`의 경고), 준비된 문장(실행 전의 매개변수·열 타입, 몇 행씩 실행, 둘 이상의 문장·컴파일 실패·빈 문장, 실패한 트랜잭션에서의 준비와 실행, 스키마 변경 뒤 다시 설명, 첫 행으로 정하는 모르는 식의 타입).
- `src/server/pg/test.zig`: 테스트 안의 최소 PostgreSQL 클라이언트(startup, 인증 교환, 메시지마다 한 줄의 기록)로 루프백 서버를 확인합니다. startup과 `ParameterStatus`, 여러 문장의 단순 질의와 값의 텍스트(`numeric(10,2)`, 불리언, `bytea`, `float8`), 빈 질의, 오류 위치(문자 단위), 암묵적 트랜잭션의 롤백, ReadyForQuery의 `I`/`T`/`E`, 확장 질의(문장 설명, 행 수 제한과 `PortalSuspended`, 이진 매개변수와 결과, 클라이언트의 OID, `Sync`까지 건너뛰기, 이름 없는 빈 문장, `Close`, 트랜잭션 안에서 `Sync`를 넘는 포털), `CancelRequest`, cleartext·MD5·SCRAM-SHA-256과 틀린 비밀번호·없는 사용자, 카탈로그와 설정(`ParameterStatus`·`SHOW server_version`·`version()`의 릴리스, 클라이언트가 준 데이터베이스 이름, `RESET`의 태그와 시작 값, `regclass`와 `pg_class.oid`, `pg_attribute.atttypid`가 RowDescription의 OID와 같은지, `INTEGER PRIMARY KEY`와 비교한 매개변수의 `int4`). `pg/auth.zig`는 RFC 7677의 예(클라이언트 증명과 서버 서명)로 SCRAM을 확인합니다.
- `src/server/test.zig`: 루프백 TCP로 실제 서버를 띄우고 테스트용 줄 프로토콜(한 줄에 스크립트 하나, 이벤트마다 한 줄)로 확인합니다. 두 클라이언트가 같은 DB를 보는지, 세 번째 클라이언트의 취소가 끝없는 재귀 CTE를 멈추는지(`57014`), 그 뒤에도 세션이 계속 쓰이는지 봅니다.
- `src/server/mysql/test.zig`: MySQL 프로토콜([MySQL 프로토콜의 테스트](#mysql-프로토콜의-테스트)).

## MySQL 프로토콜

`src/server/mysql/`의 `mysql.Protocol`은 MySQL/MariaDB 클라이언트·서버 프로토콜입니다(`Server(mysql.Protocol)`). 세션은 MariaDB 방언입니다. `mariadb`·`mysql` 클라이언트, libmariadb·Connector/J 같은 드라이버가 쓰는 프로토콜 4.1(핸드셰이크 v10)을 말합니다.

```zig
var proto: server.mysql.Protocol = .{ .user = "app", .password = "secret" };
defer proto.deinit(gpa);
var srv = try server.Server(server.mysql.Protocol).init(io, gpa, &proto, .{
    .address = try .parse("0.0.0.0", 3306),
    .path = "app.db",
});
defer srv.deinit();
try srv.run(); // 취소될 때까지
```

| 필드 | 뜻 |
| --- | --- |
| `user` | 받는 사용자. null이면 아무 이름이나 받습니다. |
| `password` | `mysql_native_password`의 비밀번호. null이면 클라이언트가 보낸 것을 보지 않고 받습니다(로컬 개발용). |
| `dialect` | 세션의 방언. 기본은 MariaDB, MariaDB 방언 없이 빌드하면(`-Ddialects=none` ...) SQLite 방언입니다. 프로토콜은 그대로이고 SQL만 SQLite입니다. |
| `version` | 핸드셰이크의 서버 버전. 기본 `11.8.0-MariaDB-xqlite`(MariaDB 클라이언트는 `MariaDB`를 찾습니다). `SELECT VERSION()`은 방언의 `11.8.0-MariaDB-xqlite-3.54.1`입니다. |

`xqlite serve DB --mysql 3306`으로 띄웁니다([xqlite serve](#xqlite-serve)).

| 파일 | 내용 |
| --- | --- |
| `Protocol.zig` | 공유 상태(인증 설정, KILL을 위한 연결 목록, `COM_STATISTICS`의 숫자)와 `serve()` |
| `Handler.zig` | 한 클라이언트: 핸드셰이크, 인증, 명령, 결과 집합과 OK/EOF/ERR, `KILL` |
| `prepared.zig` | 준비된 문장(`COM_STMT_*`): `Session.Prepared`를 문장 id로 보관, 이진 매개변수, `SEND_LONG_DATA` |
| `columns.zig` | 열 정의(타입, 플래그, 길이), 텍스트 행과 이진 행의 값 |
| `errors.zig` | ERR 패킷의 오류 번호와 SQLSTATE |
| `packet.zig`, `consts.zig`, `auth.zig` | 패킷(3바이트 길이, 순서 번호, 16MB 분할), 상수, `mysql_native_password` |

### 연결과 인증

- 서버가 먼저 세션을 엽니다(`Connection.openSession()`). 연결 id는 그 레지스트리 티켓의 id이고 MariaDB 방언의 `CONNECTION_ID()`도 이 값입니다. 연결 수를 넘으면 첫 패킷이 ERR 1040 `Too many connections`, DB를 열 수 없으면 ERR 1105입니다.
- 능력 플래그: `PROTOCOL_41`, `SECURE_CONNECTION`, `PLUGIN_AUTH`, `PLUGIN_AUTH_LENENC_CLIENT_DATA`, `CONNECT_WITH_DB`, `CONNECT_ATTRS`(받고 버림), `TRANSACTIONS`, `MULTI_STATEMENTS`, `MULTI_RESULTS`, `PS_MULTI_RESULTS`, `DEPRECATE_EOF`, `FOUND_ROWS`, `LONG_FLAG`, `INTERACTIVE`. SSL, 압축, `LOCAL INFILE`, 세션 추적, 쿼리 속성, MariaDB 확장 능력은 없습니다. 4.1 이전 프로토콜과 SSL 요청은 ERR 1043입니다.
- 문자 집합은 언제나 utf8mb4(`utf8mb4_general_ci`, 45)입니다. 클라이언트가 고른 문자 집합은 보지 않습니다.
- 인증은 `mysql_native_password`입니다(SHA1 스크램블, 20바이트). 다른 플러그인으로 온 클라이언트(`caching_sha2_password`, `client_ed25519`)는 `password`가 있으면 AuthSwitchRequest로 `mysql_native_password`로 바꿉니다. 틀린 사용자·비밀번호는 ERR 1045 `Access denied for user 'u'@'%' (using password: YES)`입니다.
- 핸드셰이크의 데이터베이스는 `USE`처럼 고릅니다. 없으면 ERR 1049이고 연결이 끝납니다.

### 명령

| 명령 | 동작 |
| --- | --- |
| `COM_QUERY` | `Session.run()`으로 스크립트를 문장마다 실행합니다. 결과가 있는 문장은 텍스트 결과 집합, 없는 문장은 OK, 실패는 ERR이고 스크립트는 거기서 멈춥니다. 빈 질의는 ERR 1065. |
| `COM_INIT_DB` | ``USE `db` ``를 실행합니다. |
| `COM_PING`, `COM_QUIT` | OK, 연결 끝. |
| `COM_STATISTICS` | `Uptime: … Threads: … Questions: …` 문자열(`mariadb-admin status`). |
| `COM_PROCESS_KILL` | `KILL CONNECTION n`. |
| `COM_SET_OPTION` | 한 `COM_QUERY`의 여러 문장 켜기·끄기. EOF로 답합니다. |
| `COM_RESET_CONNECTION` | 트랜잭션 롤백, 준비된 문장 닫기, MariaDB 세션(sql_mode, 사용자 변수, 현재 데이터베이스, 경고)을 기본값으로. |
| `COM_FIELD_LIST` | 테이블의 열 정의(기본값은 NULL)와 EOF. 테이블이 없으면 ERR. |
| `COM_STMT_PREPARE`, `_EXECUTE`, `_SEND_LONG_DATA`, `_RESET`, `_CLOSE` | [준비된 문장](#준비된-문장). |
| `COM_STMT_FETCH` | 커서가 없으므로 ERR 1235. |
| `COM_CHANGE_USER`, `COM_SHUTDOWN`, 그 밖 | ERR(1235, 1227, 1047). |

- 여러 문장: 각 결과의 마지막 패킷(OK, 또는 결과 집합 끝의 EOF/OK)은 다음 이벤트가 올 때까지 보내지 않고 기다렸다가, 뒤에 결과가 더 있으면 `SERVER_MORE_RESULTS_EXISTS`를 붙여 보냅니다. 문장이 실패하면 앞 결과에 이 플래그가 붙고 ERR이 마지막입니다(MariaDB와 같음). 클라이언트가 `MULTI_STATEMENTS`를 켜지 않았으면 두 번째 문장이 있는 질의는 아무것도 실행하지 않고 ERR 1064입니다. 이 판단은 따옴표와 주석(`#`, `-- `, `/* */`)을 아는 텍스트 검사입니다.
- `DEPRECATE_EOF`가 없으면 열 정의 뒤와 결과 집합 끝에 EOF 패킷을, 있으면 결과 집합 끝에 헤더가 `0xFE`인 OK 패킷을 보냅니다.
- OK 패킷: 바뀐 행 수는 `Complete.changes`, 마지막 삽입 id는 `INSERT`가 행을 넣었을 때의 `Complete.last_insert_id`(여러 행이면 마지막 행의 id, `LAST_INSERT_ID()`와 같음), 경고 수는 MariaDB 세션의 경고 수입니다(`SET sql_mode=''` 뒤의 잘린 값 → `warnings=1`, `SHOW WARNINGS`). 상태 플래그는 `AUTOCOMMIT`(언제나), 트랜잭션 안이면 `IN_TRANS`, `NO_BACKSLASH_ESCAPES` 모드면 `NO_BACKSLASH_ESCAPES`(클라이언트의 문자열 이스케이프가 이것을 봅니다)입니다. 상태와 경고 수는 그 문장이 끝났을 때의 것입니다.
- `UPDATE`의 바뀐 행 수는 SQLite처럼 조건에 맞은 행 수입니다(`FOUND_ROWS`의 뜻). 값이 같아 바뀌지 않은 행도 셉니다.

### KILL

MariaDB 방언에는 `KILL`이 없으므로 프로토콜이 `COM_QUERY`의 텍스트를 먼저 봅니다. 질의 전체가 `KILL [HARD | SOFT] [CONNECTION | QUERY] n [;]`이면 세션에 넘기지 않고 직접 실행합니다.

- `KILL QUERY n`: 연결 n의 실행 중인 문장을 멈춥니다(`Registry.cancel()`). 그 문장은 ERR 1317 `Query execution was interrupted`(70100)로 실패하고 연결은 계속 쓰입니다. 문장 사이에 온 취소는 다음 문장을 멈추지 않습니다([취소와 세션 목록](#취소와-세션-목록)).
- `KILL [CONNECTION] n`, `COM_PROCESS_KILL`: 문장을 멈추고 연결 n의 소켓을 닫습니다(`shutdown`). 그 클라이언트는 `Lost connection`을 봅니다.
- 없는 연결은 ERR 1094 `Unknown thread id: n`. 자기 연결의 `KILL QUERY`는 ERR 1317, `KILL CONNECTION`은 ERR 1927 뒤 연결 끝입니다. `KILL QUERY ID n`(질의 id)과 `KILL USER`는 없습니다.
- 사용자 구분이 없으므로 어느 연결이든 다른 연결을 멈출 수 있습니다.

### 열과 값

열 정의(ColumnDefinition41)는 세션의 `Column`에서 만듭니다.

- catalog `def`. schema·table·org_table·org_name은 열의 출처(`Column.origin`)이고, 표현식은 비어 있습니다. `CREATE DATABASE sales`의 테이블(main의 `"sales.o"`)은 schema `sales`, table `o`입니다. table은 별칭이 아니라 테이블 이름입니다.
- 타입은 `types.Logical`에서, `Logical`이 구분하지 않는 것은 선언 타입의 텍스트에서 정합니다.

| xqlite | MySQL 타입 | 문자 집합 |
| --- | --- | --- |
| `boolean`, `int1` / `int2` / `int4` / `int8` | `TINY` / `SHORT` / `LONG` / `LONGLONG`(`MEDIUMINT`는 `INT24`) | binary |
| `float4` / `float8` | `FLOAT` / `DOUBLE`(decimals 31) | binary |
| `numeric(p,s)` | `NEWDECIMAL`(decimals s, 길이 p + 부호 + 소수점) | binary |
| `varchar(n)` / `char(n)`, `uuid` | `VAR_STRING` / `STRING`(길이 4n) | utf8mb4 |
| `text`, `json`(`longtext`) | `BLOB`(`TEXT` 65535, `LONGTEXT` 4294967295 ...) | utf8mb4 |
| `bytes` | `BLOB`, `VARBINARY`는 `VAR_STRING`, `BINARY`는 `STRING` | binary |
| `date` / `time` / `timestamp` | `DATE` / `TIME` / `DATETIME`(`TIMESTAMP`와 시간대 있는 것은 `TIMESTAMP`), decimals는 초의 자릿수 | binary |
| `YEAR`, `BIT(n)`, `ENUM`, `SET` | `YEAR`, `BIT`, `STRING` + `ENUM_FLAG`/`SET_FLAG` | |
| 모름, `interval`, 문자열·바이트 표현식 | `VAR_STRING` | |

- 플래그: 숫자는 `NUM`·`BINARY`, `UNSIGNED`·`ZEROFILL`(선언 타입), BLOB은 `BLOB`, 테이블 열이면 `Db.columnConstraints()`로 `NOT_NULL`(PRIMARY KEY 포함), `PRI_KEY`, `AUTO_INCREMENT`, `UNIQUE_KEY`(UNIQUE 인덱스의 열), `MULTIPLE_KEY`(UNIQUE가 아닌 인덱스의 첫 열).
- MySQL 8의 `JSON` 타입(245)이 아니라 MariaDB처럼 utf8mb4 `BLOB`(`LONGTEXT`)으로 보냅니다.
- 텍스트 행의 값은 `display.text()`의 MariaDB 텍스트(`DECIMAL(10,2)`의 `1.50`), 그 밖에는 SQLite 텍스트입니다. NULL은 `0xFB`. `BIT` 값은 MariaDB처럼 빅엔디언 바이트입니다(`b'0101'`은 `0x05`).
- 표현식의 타입은 문장이 매긴 타입이고(MariaDB의 `7 / 2`는 `NEWDECIMAL` 4자리, 비교는 `TINY`, `CAST(x AS CHAR)`는 `STRING`), 문장이 모르면 세션처럼 첫 행 값의 저장 클래스로 정합니다.

### 준비된 문장

준비된 문장은 `Session`의 프로토콜 중립 API([준비된 문장](#준비된-문장)) 위에 있습니다. `prepared.zig`에는 MySQL의 것(문장 id, 클라이언트가 묶은 매개변수 타입, `SEND_LONG_DATA`의 바이트, 이진 매개변수 읽기)만 있고, 실행·설명·트랜잭션 상태는 `Session.Prepared`가 합니다.

- `COM_STMT_PREPARE`: `Session.prepare()`. 문장은 하나만 받습니다: `MULTI_STATEMENTS`를 켠 클라이언트라도 두 번째 문장이 있으면 ERR 1064(MariaDB와 같음, `COM_QUERY`와 같은 텍스트 검사), 빈 텍스트는 ERR 1065 `Query was empty`, 컴파일 오류는 그 ERR입니다. 답은 문장 id, 열 수, 매개변수 수, 매개변수 정의(타입은 `Prepared.parameterType()`, 모르면 `VAR_STRING`), 실행 전의 열 정의(`Prepared.columns`: 테이블 열은 선언 타입, 식은 문장이 매긴 타입, 모르면 `VAR_STRING`)입니다.
- `COM_STMT_EXECUTE`: NULL 비트맵, 새로 묶은 타입(없으면 앞 실행의 타입), 이진 값을 읽어 `Prepared.bind()`로 묶고 `Prepared.execute(0, sink)`로 모든 행을 보냅니다(커서 없음). 결과는 열 정의(실행 전의 것에서 모르는 식만 첫 행으로 정한 것)와 이진 행입니다. 묶을 수 없는 값(너무 큰 값)은 ERR 1210입니다. 문장 id `0xFFFFFFFF`는 MariaDB처럼 마지막으로 준비한 문장입니다. 커서 플래그는 무시하고(`SERVER_STATUS_CURSOR_EXISTS`를 보내지 않으므로 클라이언트는 행을 바로 읽음) 반복 횟수는 1입니다. 실행이 끝나면(실패해도) 문장을 `reset()`해 잠금을 놓습니다.
- 매개변수: `TINY`·`SHORT`·`YEAR`·`LONG`·`INT24`·`LONGLONG`(부호 없음 플래그, `i64`를 넘는 부호 없는 값은 십진 텍스트), `FLOAT`·`DOUBLE`, `DATE`·`DATETIME`·`TIMESTAMP`(`YYYY-MM-DD[ HH:MM:SS[.ffffff]]` 텍스트), `TIME`(`[-]HH:MM:SS[.ffffff]`, 일은 시간으로), BLOB 계열·`BIT`·`GEOMETRY`는 BLOB, 그 밖의 문자열·`DECIMAL`은 텍스트로 묶습니다. 저장할 때 방언의 값 변환이 열 타입으로 바꿉니다.
- `COM_STMT_SEND_LONG_DATA`: 매개변수의 바이트를 모아 다음 실행에 씁니다(BLOB 타입이면 BLOB, 아니면 텍스트). 답이 없습니다.
- `COM_STMT_RESET`은 모은 데이터를 버리고 OK, `COM_STMT_CLOSE`는 답이 없습니다. 없는 문장 id는 ERR 1243입니다.
- 이진 행의 값은 열 정의의 타입대로 씁니다. 다른 저장 클래스의 값은 그 타입으로 바꿉니다(정수 열의 실수는 반올림, 날짜로 읽을 수 없는 텍스트는 0 날짜). `NEWDECIMAL`, 문자열, `BIT`는 텍스트 행과 같은 바이트입니다.
- 스키마가 바뀌면(이 연결이든 다른 연결이든) 엔진이 문장을 다시 컴파일하고, `USE`는 준비된 문장을 만료시킵니다. 다시 컴파일된 문장은 실행할 때 열을 다시 설명합니다(`ALTER TABLE ... ADD COLUMN` 뒤의 `SELECT *`는 새 열까지 보냄). 준비 응답의 열 정의는 준비할 때의 것으로 남습니다(드라이버는 실행 응답의 것을 씁니다).

### 오류

- 오류 번호는 `Failure.number`(MariaDB 방언이 오류를 낸 곳에서 남긴 번호: 1146, 1062, 1064, 1048, 1452, 4025, 1690 ...)이고, 없으면 SQLSTATE에서 정합니다(`23505` → 1062, `42P01` → 1146, `57014` → 1317, `40001` → 1213, `55P03` → 1205 ...). 그것도 없으면 1105 `ER_UNKNOWN_ERROR`입니다.
- ERR의 SQLSTATE는 MariaDB가 그 번호에 쓰는 것입니다(모든 제약 위반은 `23000`, 없는 테이블은 `42S02`, 문법 오류는 `42000`, 그 밖은 `HY000`). `Failure.sqlstate`는 PostgreSQL 코드 공간이라 쓰지 않습니다.
- 메시지는 방언의 것이고, 취소된 문장만 MariaDB의 `Query execution was interrupted`로 바꿉니다.

### MariaDB 서버와 다른 점

| 항목 | xqlite |
| --- | --- |
| 인증 | `mysql_native_password`만 있습니다. 사용자는 하나(`user`)이고 권한이 없습니다. |
| 문자 집합 | utf8mb4만 있습니다. |
| 열 정의의 table | 별칭이 아니라 테이블 이름입니다. |
| 준비 응답의 열 타입 | 문장이 타입을 매기지 못한 표현식(MariaDB 방언에 규칙이 없는 식, 예: `id + 0.5`)은 실행 전에는 `VAR_STRING`이고, 실행 응답의 열 정의에서 첫 행으로 정합니다(드라이버는 실행 응답의 것을 씁니다). 매개변수도 문장이 타입을 모르면(rowid의 별칭인 정수 기본 키와 비교한 `?` 등, [준비된 문장](#준비된-문장)) `VAR_STRING`입니다. |
| `CREATE DATABASE`의 바뀐 행 수 | 0(MariaDB는 1). |
| `UPDATE`의 바뀐 행 수 | 조건에 맞은 행 수(`FOUND_ROWS`와 같음). |
| 결과에 없는 것 | 세션 추적(`SESSION_TRACK`)이 없으므로 클라이언트는 `USE` 뒤의 현재 데이터베이스를 직접 알지 못합니다(`mariadb` 클라이언트의 프롬프트). |
| 커서 | `COM_STMT_FETCH`가 없습니다. |
| `mariadb-dump` | 테이블 구조까지는 나오지만 `information_schema.COLUMNS`의 `GENERATION_EXPRESSION`이 없어 멈춥니다(방언의 `information_schema`). |

### MySQL 프로토콜의 테스트

- `src/server/mysql/test.zig`: 테스트 안의 작은 MySQL 클라이언트(핸드셰이크, `mysql_native_password`와 AuthSwitch, 결과를 한 줄씩 적음)로 루프백 서버를 확인합니다. 인증 성공·실패, 결과 집합의 타입·출처·플래그, 오류 번호와 SQLSTATE, 여러 문장과 `MORE_RESULTS_EXISTS`, 실패에서 멈춤, `IN_TRANS`, 경고 수, `MULTI_STATEMENTS`와 `DEPRECATE_EOF`가 없는 클라이언트와 `COM_SET_OPTION`, `COM_INIT_DB`와 핸드셰이크의 데이터베이스, `COM_PING`, `COM_STATISTICS`, `COM_FIELD_LIST`, `COM_RESET_CONNECTION`, 준비된 문장(이진 매개변수 `LONGLONG`·`DOUBLE`·문자열·`DATETIME`·`TIME`·BLOB·NULL, `SEND_LONG_DATA`, 실행 전에 타입을 아는 식, 이진 결과 행, 다시 실행, 스키마 변경 뒤 재컴파일과 `SELECT *`의 새 열, 문장 id -1, 닫기, 없는 id, 두 문장·빈 문장의 준비), `KILL QUERY`가 끝없는 재귀 CTE를 멈추는지와 `COM_PROCESS_KILL`이 연결을 닫는지, 열 수 없는 DB를 봅니다. MariaDB 방언이 없는 빌드에서는 SQLite 방언으로 도는 것만 봅니다.
- `src/cli/serve.zig`: 옵션 파서(`--pg`, `--mysql`, 둘 다 없음, 같은 포트)와, 두 프로토콜을 포트 0에 함께 띄워 PostgreSQL의 SSLRequest 답(`N`)과 MySQL의 핸드셰이크(프로토콜 10)를 받는 테스트.
- 실제 클라이언트: 호스트에서 `xqlite serve x.db --pg 15432 --mysql 33061 --host 0.0.0.0`을 띄우고 컨테이너의 `mariadb` 클라이언트로 붙습니다(macOS podman에서 `host.containers.internal`이 호스트입니다).

```sh
podman run --rm mariadb:11 mariadb -h host.containers.internal -P 33061 -u u --skip-ssl -t --column-type-info -e "SELECT ..."
podman run --rm mariadb:11 mariadb-admin -h host.containers.internal -P 33061 -u u --skip-ssl ping status
```

  기본 질의, 오류(1146, 1062, 1064, 1048, 1690), `--delimiter=//`로 한 `COM_QUERY`의 여러 문장, 트랜잭션, `SHOW WARNINGS`, `USE`와 `-D`, `--column-type-info`, `-vvv`의 `Query OK, 2 rows affected`, 다른 연결의 `KILL QUERY`/`KILL`, 비밀번호와 `--default-auth=client_ed25519`의 AuthSwitch를 확인했습니다. `mariadb` 클라이언트는 이진 프로토콜을 쓰지 않으므로 준비된 문장은 Zig 테스트로 봅니다.

## 다음 단계

1. **pgwire 다듬기**: 드라이버(pgjdbc, psycopg, pgx, node-postgres)로 검증, `numeric`·날짜·시각의 이진 형식, 클라이언트가 준 매개변수 타입을 엔진의 매개변수 타입으로, 바뀐 설정의 `ParameterStatus`, TLS, `COPY`(방언의 파싱부터).
2. **문장의 종류를 엔진이 기록**: `Parse`에 동사와 객체 종류를 두고 빌더 진입점이 기본값을, 방언 프론트엔드가 다르게 낮추는 문장(`SET`, `SHOW`, `TRUNCATE`, `MERGE` ...)을 덮어써 `Stmt.command()`로 내보냅니다. 명령 태그가 첫 소비자입니다.
3. **방언의 타입 서술자**: 선언 타입 텍스트를 프로토콜 중립 타입으로 바꾸는 방언 훅. 각 방언의 타입 enum 위의 망라적 switch라서 `types.zig`의 이름 표가 필요 없어지고, `UNSIGNED`, `enum`, `year`, `xml`, 배열 같은 것도 다룹니다.
4. TDS.
5. MySQL 프로토콜의 나머지: `caching_sha2_password`(MySQL 8 클라이언트의 기본)와 SSL, 세션 추적(`USE`의 현재 데이터베이스, 시스템 변수), `COM_STMT_FETCH` 커서, `COM_CHANGE_USER`.
