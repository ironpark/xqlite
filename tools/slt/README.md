# sqllogictest

[sqllogictest](https://sqlite.org/sqllogictest/)는 SQLite 팀이 여러 DB 엔진을 서로 비교하려고 만든 테스트 모음입니다. 스크립트 622개에 쿼리가 약 590만 개 들어 있고, 각 쿼리의 기대 결과는 SQLite가 낸 값입니다.

다른 테스트 도구는 [테스트와 검증](../../docs/testing.md)에 정리되어 있습니다.

## 준비

```sh
./tools/fetch-slt.sh                        # ref/sqllogictest에 스크립트와 C 실행기 소스(약 1.2GB)
zig build -Doptimize=ReleaseSafe            # 안전 검사를 켠 채 빠르게
```

## 실행

```sh
zig-out/bin/xqlite slt ref/sqllogictest/test/select1.test           # 스크립트 하나
zig-out/bin/xqlite slt -v --integrity-check FILE                    # 실패한 레코드의 SQL, 문장마다 integrity_check
zig-out/bin/xqlite slt --wal FILE                                   # WAL 모드(파일 DB)로
./tools/slt/run.py ref/sqllogictest/test                            # 전부 병렬로, 실패를 원인별로 묶어 출력
./tools/slt/run.py --log /tmp/slt.log ref/sqllogictest/test/index   # 실패 줄 전체를 파일로
./tools/slt/run.py ref/sqllogictest/test/index -- --wal             # WAL 모드로 전부
```

- `xqlite slt`는 C 실행기 `sqllogictest.c`의 verify 모드와 SQLite 엔진(`slt_sqlite.c`)을 옮긴 것입니다. 값 표시(`I`는 32비트 정수, `R`은 `%.3f`, `T`는 출력할 수 없는 문자를 `@`로 바꿈), 정렬(`nosort`/`rowsort`/`valuesort`), 해시 기준(`hash-threshold`, 기본 8), 레이블 비교, `skipif`/`onlyif`(엔진 이름은 `sqlite`)를 그대로 따릅니다.
- C 실행기와 다른 점은 넷입니다.
  - 스크립트를 여러 개 받을 수 있고, 스크립트마다 새 데이터베이스(기본은 메모리, `--db FILE`이면 그 파일을 지우고 새로 만듦)를 씁니다.
  - 결과가 틀린 쿼리는 값 개수와 상관없이 오류 하나로 셉니다.
  - `--journal-mode MODE`(`--wal`은 `--journal-mode wal`)를 주면 스크립트마다 `PRAGMA journal_mode=MODE`로 시작합니다. 파일 DB가 필요하므로 `--db`가 없으면 `/tmp/xqlite-slt-PID-N.db`를 스크립트마다 만들고 지웁니다(병렬 실행에서도 겹치지 않음).
  - 실패 줄에 엔진의 오류 메시지를 붙입니다. 그래서 `run.py`가 실패를 원인별로 묶을 수 있습니다.
- `run.py`는 스크립트마다 프로세스를 따로 띄웁니다. 패닉은 `CRASH`로, 시간 초과(`--timeout`, 기본 600초)는 `TIMEOUT`으로 집계합니다.

## C 실행기로 대조

실행기 자체가 맞는지 확인하거나, 실패가 SQLite에서도 나는지 보려면 C 실행기를 3.54.1 아말감에 링크해 빌드합니다.

```sh
cd ref/sqllogictest/src
clang -O2 -w -DOMIT_ODBC=1 -DSQLITE_NO_SYNC=1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
  -I/path/to/sqlite-amalgamation -o /tmp/slt-ref/sqllogictest \
  sqllogictest.c md5.c /path/to/sqlite-amalgamation/sqlite3.c -lm
./tools/slt/run.py --ref /tmp/slt-ref/sqllogictest ref/sqllogictest/test
```

`--ref`를 주면 실패한 스크립트를 C 실행기로도 돌립니다. 같은 줄에서 C 실행기도 실패하면 그 실패는 xqlite의 실패에서 빼고 따로 셉니다.
