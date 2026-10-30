# xqt

xqlite의 테스트 도구입니다. xqlite와 sqlite3(또는 PostgreSQL·MariaDB 서버)를 나란히 실행해 결과를 비교하는 검사(check)를 작업 풀에서 병렬로 돌립니다. 예전의 셸 스크립트와 Python 스크립트(교차 검증, 플래너 비교, sqllogictest 실행, 방언 차등 테스트, 벤치마크, 코드·fixture 생성, 소스 내려받기)를 모두 대신합니다. Python이나 셸은 쓰지 않습니다. 실행하는 외부 프로그램은 다음과 같습니다.

| 프로그램 | 쓰는 곳 |
| --- | --- |
| xqlite (`--xq`) | 모든 명령 |
| sqlite3 (`--sqlite3`) | `interop`, `bench`, `gen superjournal` |
| 플래너 기준 sqlite3 (`--sq`) | `planner` |
| `PATH`의 `sqlite3` (`--fixtures-sqlite3`) | `gen fixtures` |
| C 실행기 `sqllogictest` (`--ref`, 선택) | `slt` |
| 서버 클라이언트(`$PG_PSQL`, `$MARIA_CLIENT`, `$ORA_SQLPLUS`, 기본 `podman exec -i ...`) | `dialect-diff` |
| `zig cc`, `zig run` (`$ZIG`) | `gen parser`, `gen opcodes` (크래시 shim은 `zig build tools`가 `zig cc`로 빌드) |
| `tclsh` | `gen opcodes` |
| `git` | `fetch slt` (`fetch sqlite`는 내려받기와 압축 풀기를 프로세스 안에서 함) |

다른 테스트 도구는 [테스트와 검증](../../docs/testing.md)에 정리되어 있습니다.

## 목차

- [빌드와 실행](#빌드와-실행)
- [바이너리 고르기](#바이너리-고르기)
- [zig build check](#zig-build-check)
- [구조](#구조)
- [모듈과 검사 추가](#모듈과-검사-추가)
- [Check API](#check-api)
- [병렬화](#병렬화)
- [크래시 도우미](#크래시-도우미)
- [포팅 규칙](#포팅-규칙)

## 빌드와 실행

```sh
zig build tools                 # zig-out/bin/xqt, zig-out/lib/libcrashshim.{dylib,so}, xqlite
zig-out/bin/xqt list            # interop 모듈, 플래너 케이스 파일, 쓰는 바이너리
zig-out/bin/xqt interop         # 모든 interop 모듈
zig-out/bin/xqt interop sql hot-journal
zig-out/bin/xqt planner         # tools/planner/*.txt (vtablog.txt 제외)
zig-out/bin/xqt planner tools/planner/window.txt -k code -v
zig-out/bin/xqt planner --known tools/planner/known-failures.list
zig-out/bin/xqt planner gen hard 1 8 15 > /tmp/c1.txt
zig-out/bin/xqt slt ref/sqllogictest/test -- --wal
zig-out/bin/xqt dialect-diff pg  # podman 컨테이너가 필요
zig-out/bin/xqt bench insert scan
zig-out/bin/xqt gen parser opcodes
zig-out/bin/xqt gen superjournal
zig-out/bin/xqt fetch sqlite
zig-out/bin/xqt help planner    # 명령별 옵션
```

| 명령 | 하는 일 | 파일 |
| --- | --- | --- |
| `interop [NAME...]` | sqlite3와 교차 검증. 이름 없이: 모든 모듈 | `interop.zig`, `interop/*.zig` |
| `planner [FILE...] [-k KINDS] [--known FILE]` | 쿼리 결과·실행 계획·바이트코드를 sqlite3와 비교 | `planner.zig` |
| `planner gen basic\|hard SEED NBLOCKS NQUERIES` | 무작위 플래너 케이스. 예전 `gen-basic`, `gen-hard` 생성기와 바이트까지 같은 출력 | `planner_gen.zig` |
| `slt [PATH...] [-- ARGS]` | sqllogictest를 스크립트마다 `xqlite slt` 프로세스로 | `slt.zig` |
| `dialect-diff pg\|mariadb\|oracle [CASES]` | 방언을 실제 서버와 차등 비교. 서버가 필요하므로 `zig build check`에는 없음 | `dialect_diff.zig` |
| `bench [WORKLOAD...]` | 같은 작업의 실행 시간(`--runs`/`RUNS`, `--rows`/`ROWS`) | `bench.zig` |
| `wasi [--wasm PATH] [--runtime PROG]` | wasm32-wasi 빌드를 wasmtime에서: sqlite3·네이티브 xqlite와 비교(`zig build test-wasi`) | `wasi.zig` |
| `gen fixtures\|parser\|opcodes` | `src/testdata`의 DB, `grammar.zig`, `opcodes.zig` 재생성 | `gen.zig` |
| `gen superjournal [DIR]` | `src/testdata/superjournal` 재생성 | `gen/superjournal.zig` |
| `fetch sqlite\|slt [--dest DIR]` | `ref/sqlite`, `ref/sqllogictest` 내려받기 | `fetch.zig` |
| `list` | interop 모듈, 플래너 케이스 파일, 고른 바이너리 | `main.zig` |
| `help [COMMAND]` | 사용법 | `main.zig` |

자세한 설명은 [테스트와 검증](../../docs/testing.md)에 있습니다.

공통 옵션은 `--` 앞이라면 명령 앞뒤 어디에 와도 됩니다.

| 옵션 | 뜻 |
| --- | --- |
| `-j N` | 동시에 돌릴 검사 수(기본: CPU 수) |
| `-v` | 통과한 검사의 로그도 출력. `planner`에서는 다른 부분을 출력 |
| `--keep` | 실패한 검사의 임시 디렉터리를 남기고 경로를 출력 |
| `--xq PATH`, `--sqlite3 PATH`, `--sq PATH`, `--crashshim PATH` | [바이너리 고르기](#바이너리-고르기) |

검사마다 끝나는 순간 결과를 한 덩어리로 출력합니다(`ok`, `FAIL`과 로그, `skip`과 이유). 그래서 병렬로 돌아도 출력이 섞이지 않습니다. 끝나는 순서는 실행마다 다르지만, 마지막 요약은 실패한 검사를 추가한 순서대로 나열하고 개수를 셉니다. 실패가 하나라도 있으면 종료 코드는 1입니다.

## 바이너리 고르기

바이너리는 `lib/Config.zig` 한 곳에서 정합니다. 순서는 명령줄 옵션, 환경 변수, 기본값입니다.

| 필드 | 옵션 | 환경 변수 | 기본값 |
| --- | --- | --- | --- |
| `cfg.xq` | `--xq` | `XQ` | `ROOT/zig-out/bin/xqlite` |
| `cfg.sqlite3` | `--sqlite3` | `SQLITE3` | `ROOT/zig-out/bin/sqlite3-ref`가 있으면 그것, 없으면 `PATH`의 `sqlite3` |
| `cfg.sq` | `--sq` | `SQ` | `ROOT/zig-out/bin/sqlite3-planner`가 있으면 그것, 없으면 `PATH`의 `sqlite3` (플래너 기준, `SQLITE_ENABLE_EXPLAIN_COMMENTS` 없는 3.54.1 빌드) |

두 기준 셸은 `zig build tools`가 `build.zig.zon`에 고정한 SQLite 3.54.1 아말감으로 빌드합니다([테스트와 검증](../../docs/testing.md#기준-sqlite3-셸)).
| `cfg.crashshim` | `--crashshim` | `XQT_CRASHSHIM` | `ROOT/zig-out/lib/libcrashshim.dylib`(Linux는 `.so`) |

`ROOT`는 빌드할 때 넣은 저장소 루트입니다. 예전 스크립트는 `sqlite3`를 `PATH`에서 찾는 것과 `SQLITE3`를 쓰는 것이 섞여 있었는데, xqt의 모든 interop 모듈은 `cfg.sqlite3` 하나를 씁니다. 예외는 `gen fixtures`입니다. 커밋한 fixture는 헤더에 3.44.4라는 버전이 들어 있으므로 `PATH`의 `sqlite3`(또는 `--fixtures-sqlite3 PATH`)를 씁니다.

## zig build check

```sh
zig build check   # 단위 테스트, xqt 자체의 테스트, xqt interop, xqt planner, fuzzcheck
zig build check -Dslt=true           # + sqllogictest (ref/sqllogictest, 몇 분)
zig build check -Dfuzz=true          # + 시드 퍼저 셋을 무작위 시드로 한 번씩
zig build check -Doptimize=ReleaseSafe
```

모든 단계가 병렬로 돕니다. `-Doptimize`는 interop과 planner가 쓰는 xqlite를 정하고, fuzzcheck(코퍼스마다 프로세스 하나), slt, 시드 퍼저는 늘 ReleaseSafe 빌드를 씁니다. `xqt`에는 같은 빌드의 xqlite(`--xq`)와 크래시 shim(`--crashshim`)을 넘기고, 빌드 루트에서 실행합니다(`build.zig`의 `addXqtRun`). 플래너는 `tools/planner/known-failures.list`의 알려진 차이를 `--known`으로 받습니다. 그 목록에 있는 실패는 `KNOWN`으로 출력하고 종료 코드에 넣지 않으며, 다시 같아진 항목은 `FIXED`로 실패시켜 목록을 지우게 합니다. 항목 하나는 실패 하나(파일, 종류, 쿼리)와 정확히 맞아야 하고, 목록에 없는 실패는 모두 실패입니다. 플래너는 `SQ`(`--sq`)로 주석 없는 기준 셸을 받아야 바이트코드가 맞습니다. `dialect-diff`(서버 필요), `bench`, `gen`, `fetch`는 `check`에 들어 있지 않습니다.

`xqt interop`은 이름 없이 모든 모듈을 돌리므로 **새 interop 모듈을 추가해도 `build.zig`는 고칠 필요가 없습니다.** 새 명령(예: `xqt foo`)을 `check`에 넣을 때만 `build.zig`에 다음 세 줄을 더합니다.

```zig
const foo_run = addXqtRun(b, xqt_exe, exe, crashshim);
foo_run.addArg("foo");
check_step.dependOn(&foo_run.step);
```

## 구조

```
tools/xqt/
  main.zig              명령 분기, xqt list, xqt help
  interop.zig           xqt interop: 모듈 목록(modules)과 실행
  interop/              모듈 하나 = 파일 하나 (xqt interop NAME)
    sql.zig             sql
    hot_journal.zig     hot-journal
    btree.zig           btree
    savepoint.zig       savepoint
    pragma.zig          pragma
    shell.zig           shell
    wal.zig             wal
    attach.zig          attach
    vacuum.zig          vacuum
    analyze.zig         analyze
    pg.zig              pg
    mariadb.zig         mariadb
    oracle.zig          oracle
    parts.zig           모듈이 아닌 도우미: 검사 하나의 작은 실행들을 병렬로(크래시 지점 등)
    base_db.zig         모듈이 아닌 도우미: 여러 검사가 나눠 쓰는 시작 DB를 한 번만 만듦
  planner.zig           xqt planner
  planner_gen.zig       xqt planner gen basic|hard (CPython random.Random의 포팅 포함)
  slt.zig               xqt slt
  dialect_diff.zig      xqt dialect-diff pg|mariadb|oracle
  bench.zig             xqt bench
  wasi.zig              xqt wasi
  gen.zig               xqt gen fixtures|parser|opcodes
  gen/superjournal.zig  xqt gen superjournal
  fetch.zig             xqt fetch sqlite|slt
  lib/                  라이브러리, 모듈에서는 @import("xqt")
    xqt.zig           Config, Suite, Check, proc, diff, pool, crash를 내보냄
    Config.zig        바이너리와 공통 옵션
    Suite.zig         검사 목록, 병렬 실행, 보고
    Check.zig         검사 하나가 받는 것: 임시 디렉터리, 로그, 프로세스·파일 도우미
    proc.zig          프로세스 실행(run)과 대화형 프로세스(spawn)
    diff.zig          짧은 unified diff
    pool.zig          작업 풀(pool.forEach)
    crash.zig         크래시 도우미
```

## 모듈과 검사 추가

새 모듈 `foo`는 `tools/xqt/interop/foo.zig` 파일 하나입니다.

```zig
const std = @import("std");
const xqt = @import("xqt");
const Check = xqt.Check;

pub const name = "foo";                     // xqt interop foo
pub const about = "한 줄 설명(xqt list)";

pub fn register(s: *xqt.Suite) !void {
    try s.add("xqlite writes, sqlite3 reads", xqliteWrites, .{});
    for ([_][]const u8{ "delete", "wal" }) |mode| {
        try s.add(try std.fmt.allocPrint(s.arena.allocator(), "journal_mode={s}", .{mode}), byMode, .{mode});
    }
}

fn xqliteWrites(c: *Check) !void {
    _ = try c.xqSql("a.db", "CREATE TABLE t(x); INSERT INTO t VALUES(1);");
    const ok = try c.sqlite3("a.db", "PRAGMA integrity_check");
    if (!c.expect(std.mem.eql(u8, ok, "ok\n"), "integrity_check: {s}", .{ok})) return;
    _ = c.expectSame("rows", "sqlite3", try c.sqlite3("a.db", "SELECT * FROM t"), "xqlite", try c.xqSql("a.db", "SELECT * FROM t"));
}

fn byMode(c: *Check, mode: []const u8) !void { ... }
```

그리고 `tools/xqt/interop.zig`의 `modules`에 한 줄을 넣습니다.

```zig
pub const modules = .{
    @import("interop/sql.zig"),
    @import("interop/hot_journal.zig"),
    // ...
    @import("interop/mariadb.zig"),
    @import("interop/foo.zig"),
};
```

모듈의 검사는 다른 모든 모듈의 검사와 한 풀에서 섞여 돕니다.

- 검사 함수는 `fn (c: *Check, args...) !void`입니다. `s.add(이름, 함수, .{인자...})`가 인자를 복사해 둡니다. 포인터를 넘기면 가리키는 것이 `Suite.run`이 끝날 때까지 살아 있어야 합니다.
- 검사 이름 앞에는 모듈 이름이 붙습니다(`foo: journal_mode=wal`). 이름을 만들 때 `s.arena.allocator()`를 쓰면 됩니다(`add`가 다시 복사하므로 다른 할당자도 괜찮습니다).
- 검사는 추가한 순서대로 시작합니다. 오래 걸리는 검사를 먼저 추가하면 전체 시간이 줄어듭니다.

## Check API

검사는 자기만의 임시 디렉터리(`c.dir`, `$TMPDIR/xqt-PID/SUITE/N-NAME`)에서 돕니다. 도우미에 넘기는 상대 경로와 실행하는 프로그램의 작업 디렉터리가 모두 이 디렉터리입니다. 통과하면 디렉터리를 지우고, 실패하면 `--keep`일 때만 남깁니다.

### 보고

| 함수 | 뜻 |
| --- | --- |
| `c.print(fmt, args)` | 로그에 한 줄. 실패하면(또는 `-v`) 결과와 함께 출력 |
| `c.fail(fmt, args)` | 실패를 기록하고 계속 |
| `return c.abort(fmt, args)` | 실패를 기록하고 검사를 끝냄(`set -e`의 `exit 1`, 셸의 `fail()`) |
| `return c.skip(fmt, args)` | 건너뜀(예: shim이 sqlite3에 닿지 않음) |
| `c.expect(cond, fmt, args) bool` | `cond`가 거짓이면 `fail` |
| `c.expectSame(what, want_name, want, got_name, got) bool` | 두 텍스트가 다르면 "WHAT differs"와 짧은 unified diff(`--- want_name`, `+++ got_name`) |
| `c.writeDiff(a_name, a, b_name, b)` | diff만 로그에 |
| `c.printNow(fmt, args)` | 결과를 기다리지 않고 지금 한 줄 출력(긴 검사의 진행 상황) |

검사 함수가 오류를 돌려주면 실패입니다(`error.CheckFailed`는 이미 보고한 실패, 다른 오류는 그 이름을 로그에 남김).

### 프로세스

| 함수 | 뜻 |
| --- | --- |
| `c.run(argv, .{ .cwd, .env, .stdin, .timeout_ms }) !proc.Result` | 끝까지 실행하고 종료 상태와 출력을 받음. 실패해도 오류가 아님 |
| `c.runOk(argv, opts) ![]const u8` | 종료 코드 0이어야 함(`set -e`). 아니면 명령과 표준 오류를 로그에 남기고 `error.CheckFailed`. 표준 출력을 돌려줌 |
| `c.sqlite3(db, sql)`, `c.sqlite3Args(args)` | `cfg.sqlite3`로 `runOk` |
| `c.xqSql(db, sql)`, `c.xq(args)` | `xqlite sql DB SQL`, `xqlite ARGS...`로 `runOk` |
| `c.command(program, args)` | `program`을 앞에 붙인 argv |
| `c.env(&.{ .{ "NAME", "value" } })` | xqt의 환경에 변수를 더한 환경(`.env`에 넘김) |
| `c.spawn(argv, .{ .cwd, .env, .output })` | 표준 입력 파이프를 연 채로 시작. `write`, `close`(EOF 후 대기), `kill`(SIGKILL 후 회수) |

`proc.Result`에는 `term`(시간 초과면 null), `stdout`, `stderr`가 있고 `ok()`, `exitCode()`, `timedOut()`, `{f}` 형식("exited with code 1")을 씁니다. `.stdin`에 바이트를 주면 별도 스레드가 써 넣고 닫습니다. 그 밖에는 `/dev/null`입니다. `.timeout_ms`가 지나면 SIGKILL로 끝냅니다. `.cwd = "."`이면 xqt를 실행한 디렉터리입니다(`slt`처럼 사용자가 준 상대 경로를 쓸 때).

`$(cmd)`는 끝의 줄바꿈을 지우므로 셸의 `[ "$(sqlite3 db 'PRAGMA integrity_check')" = ok ]`는 `std.mem.trimEnd(u8, out, "\n")`과 비교합니다.

### 파일

`c.path(name)`(검사 디렉터리 안의 절대 경로), `c.exists`, `c.fileSize`(없으면 null), `c.readFile`, `c.writeFile`, `c.copyFile`, `c.copyDir`, `c.remove`(파일이나 트리), `c.makeDir`, `c.sleep(ms)`가 있습니다.

### 할당자

- `c.arena`: 검사가 끝나면 해제. 프로세스 출력과 경로는 여기 있습니다.
- `c.keep`: Suite가 해제될 때까지 유지. 검사가 명령에 돌려줄 결과(`planner`의 실패 목록, `slt`의 스크립트 결과)를 여기 둡니다.

## 병렬화

셸 스크립트의 독립된 단계와 반복은 각각 검사 하나로 만듭니다. 예전 단계가 앞 단계의 파일을 이어서 쓴다면, 그 파일을 같은 문장으로 다시 만들어 의존을 끊습니다(`interop/sql.zig`의 3번 검사가 1, 2번의 DB를 다시 만드는 것처럼). 결과가 결정적이라면 의미가 같습니다. `randomblob()`처럼 결정적이지 않은 데이터를 두 검사가 공유해야 한다면 하나로 둡니다.

검사들의 결과를 모아서 따로 보고하는 명령은 `planner.zig`, `slt.zig`의 방식을 따릅니다.

- `Suite.init(..., .{ .name = "planner", .show = .failures })`: 검사별 `ok` 줄은 빼고, 도구 자체의 오류만 출력합니다(`.none`은 아무것도 출력하지 않음).
- 검사마다 결과를 담을 자리(`*Chunk`, `*Result`)를 인자로 넘기고, 검사는 `c.keep`으로 할당한 결과를 거기에 씁니다. `suite.run()`이 끝난 뒤 명령이 입력 순서대로 읽어 출력하므로 출력이 결정적입니다.
- 단계 사이에 의존이 있으면 Suite를 둘 만듭니다. `planner`는 모든 블록의 셋업을 먼저 병렬로 돌리고, 그다음 쿼리를 블록 안에서도 8개씩 나눠 각자 블록 디렉터리의 사본에서 돌립니다.

Suite 없이 단순히 병렬로 돌리려면 `xqt.pool.forEach(jobs, n, ctx, func)`를 씁니다.

### 검사 하나의 작은 실행들: interop/parts.zig

검사 하나가 서로 독립된 작은 실행 수백 개로 이루어진다면(DB 사본마다 문장 하나, 커밋의 쓰기마다 한 번씩 죽이기) 실행마다 검사를 만들지 않고 `interop/parts.zig`로 검사 안에서 병렬로 돌립니다. 출력은 검사 하나에 한 줄이고, 실패한 부분의 로그만 순서대로 붙습니다. `vacuum`과 `attach`가 이 방식입니다.

```zig
const parts = @import("parts.zig");

try parts.forEach(c, cases.len, &ctx, runCase);     // fn (*Check, Ctx, usize) !void
try parts.crashPoints(c, 200, &ctx, crashAt, .{});  // fn (*Check, Ctx, u32) !bool
```

- 부분마다 자기 `Check`(같은 도우미)와 디렉터리 `c.dir/N`를 받습니다. 통과하면 지우고, 실패하면 `--keep`일 때 남깁니다. `error.Skipped`는 돌지 않은 것으로 칩니다.
- `crashPoints`는 예전 `while not through: crash at i; i++` 반복과 같습니다. `point(part, ctx, at)`이 at번째 쓰기에서 한쪽을 죽이고 복구를 확인한 뒤, 죽지 않고 끝까지 갔으면 true를 돌려줍니다. 지점들을 순서대로 병렬로 시작하고, 처음으로 끝까지 간 지점 뒤의 결과는 버립니다. 아무것도 끝까지 가지 않았거나(`max`까지), 1번에서 바로 끝까지 갔으면(아무것도 죽지 않음, `.may_not_crash`가 아니면) 실패입니다.
- 검사 하나가 동시에 돌리는 부분은 `-j`의 1/8(올림)입니다. 다른 검사도 함께 돌기 때문입니다. 부분은 `std.heap.smp_allocator`로 할당합니다(Debug xqt의 할당자 잠금을 피함).
- `parts.combined`(표준 출력과 표준 오류를 한 흐름으로, `2>&1`), `parts.oneLine`, `parts.trimmed`도 있습니다.

여러 검사가 같은 시작 DB에서 출발한다면 `interop/base_db.zig`의 `BaseDb`를 씁니다. 처음 요청한 검사가 자기 디렉터리에서 한 번 만들고, 나머지는 기다렸다가 그 바이트의 사본을 받습니다(`pg`, `mariadb`, `oracle`).

## 크래시 도우미

`lib/crash.zig`:

```zig
const crash = xqt.crash;

fn sqliteDies(c: *Check, at: u32) !void {
    try crash.requireShim(c);                        // shim이 없거나 sqlite3에 닿지 않으면 skip
    const e = try crash.sqliteEnv(c, "-journal", at); // 이름이 -journal로 끝나는 파일의 at번째 변경에서 _exit(0)
    _ = try c.run(&.{ c.cfg.sqlite3, "main.db", txn }, .{ .env = e });
    ...
}

fn xqliteDies(c: *Check, n: u32) !void {
    const e = try crash.xqEnv(c, .journal, n, .{});  // XQLITE_TEST_CRASH=journal:N (.torn = true면 :torn)
    _ = try c.run(&.{ c.cfg.xq, "sql", "main.db", txn }, .{ .env = e });
}
```

- sqlite3 쪽은 `tools/crashshim.c`입니다. `zig build tools`(그리고 `zig build check`)가 `zig cc`로 공유 라이브러리를 빌드하고, `sqliteEnv`가 `DYLD_INSERT_LIBRARIES`(macOS) 또는 `LD_PRELOAD`와 `CRASH_SUFFIX`, `CRASH_AT`을 넣습니다. 예전 스크립트가 `CC`로 직접 빌드하던 것을 대신합니다.
- `requireShim`은 예전 스크립트의 탐침과 같습니다. `CRASH_SUFFIX=probe.db CRASH_AT=1`로 sqlite3를 돌려 `alive`가 나오면(preload가 닿지 않음) 건너뜁니다. 시스템 sqlite3(SIP)는 preload를 무시합니다.
- xqlite 쪽은 `XQLITE_TEST_CRASH=KIND:N[:torn]`(`pkg/vfs/src/crash.zig`)이나 `xqlite crash-write FILE BYTE`(`c.xq(&.{ "crash-write", db, "0xff" })`)입니다.
- 프로세스를 거래 도중에 죽이려면 `c.spawn`으로 셸을 열어 `write`로 문장을 보내고, 파일이 바뀌기를 기다린 뒤 `kill`합니다(`interop/hot_journal.zig`).

## 포팅 규칙

- 같은 SQL, 같은 비교, 같은 범위. 셸 변수의 문자열은 Zig의 `\\` 여러 줄 문자열로 그대로 옮기고, `"$a $b"`처럼 이어 붙인 것은 `a ++ " " ++ b`로 씁니다.
- `cmp`, `[ "$x" = "$y" ]`, `shasum` 비교는 `expectSame`이나 `std.mem.eql`로 합니다.
- 실패 메시지는 예전 스크립트의 `FAIL` 문구를 유지합니다.
- 모듈이나 명령을 더하거나 바꾸면 [docs/testing.md](../../docs/testing.md)를 고칩니다.
- 가변 전역(`var`)을 두지 않습니다. `tools/globals_test.zig`가 `tools/xqt`도 검사합니다. 상태는 검사 인자나 `Suite`로 넘깁니다.
