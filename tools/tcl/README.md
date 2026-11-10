# SQLite의 TCL 테스트

SQLite가 자기 저장소에 두고 쓰는 TCL 테스트(`test/*.test`, 파일 1199개)를 xqlite의 C ABI(`libxqlite3`)에서 돌리는 하네스입니다. 같은 하네스를 SQLite 3.54.1에도 링크해 함께 돌리므로, 테스트 케이스마다 두 쪽에서 통과하는지, 하네스가 통과시킬 수 없는 것인지(두 쪽 모두 실패), xqlite에서만 실패하는지(비호환)를 나눕니다.

다른 테스트 도구는 [테스트와 검증](../../docs/testing.md)에 정리되어 있습니다.

## 준비

```sh
zig build tools
zig-out/bin/xqt fetch sqlite     # ref/sqlite: test/*.test, tester.tcl, test*.c, 헤더, lemon
zig-out/bin/xqt fetch tcl        # ref/tcl: Tcl 8.6.17 (약 1분)
zig build testfixture            # zig-out/bin/testfixture-xqlite, testfixture-sqlite (약 2분)
```

macOS의 tclsh는 8.5인데 SQLite 3.54의 테스트는 Tcl 8.6 이상이 필요합니다. `xqt fetch tcl`은 시스템에 아무것도 설치하지 않습니다. SourceForge(tcl-lang.org가 내려받기를 두는 곳)에서 `tcl-core8.6.17-src.tar.gz`를 받아 고정해 둔 SHA-256(`fetch.zig`의 `tcl_sha256`, SourceForge가 공개한 MD5로 확인한 값)과 비교하고, `ref/tcl/src`가 아닌 임시 디렉터리에서 시스템 C 컴파일러로 빌드해 `ref/tcl`에 설치합니다. 손으로 하면 다음과 같습니다.

```sh
tar xzf tcl-core8.6.17-src.tar.gz && cd tcl8.6.17/unix
sh configure --prefix=$PWD/../../ref/tcl --disable-shared CC=cc
make -j8 && make install        # ref/tcl/bin/tclsh8.6, lib/libtcl8.6.a, lib/tclConfig.sh, include/tcl.h
```

`zig build testfixture`의 옵션은 `-Dsqlite-src`(기본 `ref/sqlite`), `-Dtcl-prefix`(기본 `ref/tcl`), `-Dtcl-optimize`(`libxqlite3`의 최적화, 기본 ReleaseSafe)입니다. 둘 중 하나가 없으면 그 경로를 알려 주고 실패합니다.

## 실행

```sh
zig-out/bin/xqt -j 6 tcl                          # test/*.test 전부(--set all)
zig-out/bin/xqt -j 6 tcl --set veryquick          # permutations.test의 veryquick
zig-out/bin/xqt tcl ref/sqlite/test/select1.test  # 파일이나 디렉터리
zig-out/bin/xqt -j 6 tcl --log /tmp/tcl.log       # 파일마다의 결과와 실패한 테스트 전부
```

| 옵션 | 뜻 |
| --- | --- |
| `--set all\|quick\|veryquick` | 경로를 주지 않을 때 돌릴 파일. `all`(기본)은 다른 파일을 돌리는 스크립트(`all.test`, `permutations.test` ...)를 뺀 `test/*.test` 전부, `quick`·`veryquick`은 `permutations.test`의 같은 이름의 집합(파일 목록을 `tcl.zig`에 옮겨 둠) |
| `--timeout S` | 파일·픽스처마다의 시간 제한(기본 300초). 넘으면 SIGKILL하고 `timeout` |
| `--fixture P`, `--ref P` | 두 픽스처(기본 `zig-out/bin/testfixture-xqlite`, `testfixture-sqlite`) |
| `--no-ref` | xqlite만 돌림(분류 없이 실패를 원인별로) |
| `--faultsim` | tester.tcl이 OOM 주입용 malloc 래퍼를 설치하게 함([아래](#하네스의-한계)) |
| `--tcl-library D` | Tcl 스크립트 라이브러리(기본 `ref/tcl/lib/tcl8.6`, `$TCL_LIBRARY`로 넘김) |
| `--log FILE`, `--top N` | 전체 목록, 출력할 원인 수(기본 40) |

파일 하나와 픽스처 하나가 검사 하나이고, 검사마다 자기 임시 디렉터리에서 `testfixture FILE`을 돌립니다(테스트가 `test.db` 같은 파일을 현재 디렉터리에 만듦). `-j N`개가 동시에 돕니다. 출력은 tester.tcl의 기본(`--verbose=1`) 형식에서 읽습니다.

- `NAME... Ok`는 통과, `! NAME expected: [E]` / `! NAME got: [G]`와 `NAME...` 다음 줄의 `Error: MESSAGE`는 실패입니다.
- `N errors out of M tests`가 나오면 끝까지 돈 것입니다(`ok`, 실패가 있으면 `fail`). 그 전에 끝나면 `error`(스크립트의 Tcl 오류, 이유는 표준 오류의 첫 줄), 시그널이면 `crash`, 시간을 넘기면 `timeout`입니다.
- `Unfreed memory: ...`(모든 연결을 닫은 뒤 `sqlite3_memory_used()`가 0이 아님)는 따로 셉니다.

### 결과 읽기

테스트 이름마다 두 픽스처의 결과를 맞춥니다. 한 파일에서 같은 이름이 여러 번 돌면 한 번이라도 실패하면 실패입니다.

| 분류 | 뜻 |
| --- | --- |
| pass on both | 두 쪽 모두 통과 |
| fail on both (harness) | 두 쪽 모두 실패: 하네스가 SQLite의 내부를 갖지 않아서(아래), 또는 SQLite 쪽 빌드 옵션 때문 |
| fail on xqlite only | xqlite만 실패: 비호환. 원인별로 묶어 출력 |
| fail on sqlite only | SQLite만 실패(드묾) |
| run on sqlite only | xqlite에서 그 파일이 먼저 멈춰(오류, 크래시) 돌지 못한 테스트 |

원인은 실패 메시지에서 숫자와 따옴표 안의 이름을 지워 묶습니다. 테스트 스크립트가 오류를 냈으면 `error: MESSAGE`, catchsql 형식(`1 {MESSAGE}`)의 결과는 `unexpected error`(오류가 없어야 함), `missing error`(오류가 나야 함), `other error`(다른 메시지), 그 밖은 `wrong result`입니다. xqlite에서만 멈춘 파일은 그 이유(`ERROR: ...`, `CRASH: ...`, `TIMEOUT`)로 따로 묶습니다.

## 하네스 구성

SQLite의 testfixture는 `tclsqlite.c`와 `test*.c` 도우미를 SQLite 자신의 소스와 함께 컴파일한 것이라, 도우미들이 내부 함수(`sqlite3ErrName`, `sqlite3OsRead`, `sqlite3ValueNew` ...)를 부르고 내부 구조체(`db->mutex`, `Vdbe`, `Btree`)를 읽습니다. 하네스는 같은 도우미를 공개 API만 내보내는 라이브러리에 링크합니다. `libxqlite3`가 그렇고, SQLite의 아말감도 내부 함수가 `static`이라 마찬가지입니다. 두 픽스처는 아래의 같은 소스로 빌드하고 라이브러리만 다릅니다(`build.zig`의 `addTcl()`).

| 소스 | 처리 |
| --- | --- |
| `tclsqlite.c`, `test4.c`, `test6.c`, `test8.c`, `test9.c`, `test_*.c` 35개, `ext/misc`의 확장 28개, `ext/expert`, `ext/qrf` | 고치지 않고 컴파일(`-DSQLITE_TEST -DSQLITE_CORE -DSQLITE_PRIVATE=`, main.mk의 `TESTFIXTURE_FLAGS`에서 내부 빌드용을 뺀 것) |
| `test1.c` | `tools/tcl/patch_test1.zig`가 내부 구조체를 읽는 몇 곳을 공개 API로 바꾼 사본(`db->mutex` → `sqlite3_db_mutex(db)`, `db->mallocFailed` → `0`, UTF 변환용 값, `sqlite3_stmt_scanstatus -debug`). 바꿀 곳이 하나라도 없으면 빌드가 실패 |
| `test2.c`(페이저), `test3.c`(B-tree), `test5.c`(`Mem`), `test_btree.c`, rtree, fts3/fts5, session, rbu, recover, intck | 빼고, 초기화 함수는 아무것도 하지 않는 것으로(`shim.c`). 두 라이브러리 어느 쪽에도 없는 모듈이거나 SQLite의 내부 그 자체를 시험하는 것 |
| `tools/tcl/shim.c` | 내부 도우미를 공개 API 위에 다시 씀: 오류 이름, `sqlite3_file`·`sqlite3_vfs`를 통한 `sqlite3Os*`, 문자 표, 메모리 도우미, `test_journal.c`용 비트맵, `test1.c`의 UTF-8/16 변환용 값. SQLITE_TEST 빌드의 코어가 세는 카운터(`sqlite_search_count` 등)는 0에 머무는 변수. 대신할 수 없는 내부 함수는 부르면 이름을 말하고 멈추는 스텁(그 함수를 쓰는 명령·SQL 함수는 바꿔 두어 실제로는 불리지 않음) |
| `xqtclTestInit`(`shim.c`, `TCLSH_INIT_PROC`) | `test_tclsh.c`의 `sqlite3TestInit()` 뒤에 내부를 읽는 명령(`uses_stmt_journal`, `sqlite3_pager_refcounts`)을 오류를 내는 것으로, `test2.c`의 `sqlite3_test_control_pending_byte`, `fake_big_file`, 연결 변수를 다시 만듦. `test_func.c`의 `test_decode`, `test_extract`(SQLite의 `Mem`을 라이브러리에 넘김)는 오류를 내는 SQL 함수로 덮어씀. `SQLITE_FCNTL_FILE_POINTER`로 받은 파일을 바로 쓰는 `atomic_batch_write`(파일이 없으면 0), `vfs_shmlock`, `vfs_set_readmark`, `test_write_db`(파일이 없으면 Tcl 오류)는 감쌈. libxqlite3는 기본 VFS의 파일 포인터를 주지 않아, 그대로면 저널·WAL·페이저 파일 대부분이 첫머리의 `atomic_batch_write`에서 크래시함. `$xqtcl_engine`이 `xqlite`나 `sqlite` |
| 헤더 | `sqliteInt.h`가 부르는 `parse.h`(lemon)와 `opcodes.h`(`mkopcodeh.tcl`, `tools/tcl/opcodes.tcl`로 표준 입력을 만들어)를 main.mk처럼 생성. `sqlite3.h`는 각 라이브러리의 것 |

SQLite 쪽 아말감은 기본 빌드에 `libxqlite3`가 가진 선택 기능(`SQLITE_ENABLE_COLUMN_METADATA`, `NORMALIZE`, `BYTECODE_VTAB`, `CARRAY`, `SNAPSHOT`)만 켜고, `test_config.c`도 같은 옵션으로 컴파일하므로 `sqlite_options`(`ifcapable`)가 두 픽스처에서 같습니다. SQLite의 testfixture와 달리 `SQLITE_DEFAULT_PAGE_SIZE=1024`, `SQLITE_NO_SYNC`, FTS·rtree·dbstat·`sqlite_dbpage` 등은 켜지 않습니다(xqlite에 없는 것은 두 쪽 모두에서 빠지도록).

## 하네스의 한계

두 쪽 모두에서 실패하는 테스트의 대부분은 다음 때문입니다.

- **SQLITE_TEST 카운터**: `sqlite_search_count`, `sqlite_sort_count`, `sqlite_like_count`, `sqlite3_xferopt_count`, `sqlite_open_file_count` 등은 SQLite가 SQLITE_TEST로 빌드될 때 코어가 셉니다. 두 라이브러리 모두 세지 않으므로 늘 0입니다(`where*.test`, `count.test`, `insert4.test`의 많은 테스트).
- **기본 페이지 크기**: SQLite의 testfixture는 `SQLITE_DEFAULT_PAGE_SIZE=1024`로 빌드되고, 파일 크기나 페이지 수를 보는 테스트가 그것을 전제합니다. 하네스는 두 쪽 모두 4096입니다.
- **OOM·I/O 오류 주입**: tester.tcl은 파일마다 `test_malloc.c`의 malloc 래퍼(`SQLITE_CONFIG_GETMALLOC`으로 받은 메서드를 감쌈)를 설치합니다. `libxqlite3`의 `GETMALLOC` 메서드는 `sqlite3_malloc()`을 다시 불러 래퍼로 돌아오므로 첫 할당에서 스택이 넘칩니다(비호환: SQLite는 하부의 메서드를 줌). 그래서 하네스는 `--faultsim` 없이는 래퍼를 설치하지 않고(`install_malloc_faultsim`이 아무것도 하지 않음), `do_malloc_test`·`do_faultsim_test`의 OOM 테스트는 두 쪽 모두 실패합니다. I/O 오류 주입(`sqlite_io_error_pending`)은 SQLite의 os_unix.c 안에 있으므로 두 쪽 모두 동작하지 않습니다.
- **내부 명령**: `btree_*`, `pager_*`, `page_*`, `sqlite3_shared_cache_report`, `uses_stmt_journal`, `sqlite3_pager_refcounts` 등이 없거나 오류를 냅니다. 이를 쓰는 파일은 두 쪽에서 같이 멈춥니다.
- **크래시 시뮬레이션**: `test6.c`의 crash VFS는 들어 있지만, `crashsql`은 자식 testfixture를 띄우므로 같은 픽스처로 돕니다.
