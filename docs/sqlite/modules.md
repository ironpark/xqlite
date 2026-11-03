# 내장 모듈과 확장

[SQLite 호환](README.md)의 일부입니다.

| 모듈 | 위치 | 등록 |
| --- | --- | --- |
| `pragma_*` 테이블 값 함수 | `src/sql/pragma.zig` | 항상 |
| `json_each`, `json_tree`, `jsonb_each`, `jsonb_tree` | `src/sql/func/json.zig` | 항상 |
| `bytecode()`, `tables_used()` | `src/vdbe/vdbevtab.zig` | 항상 |
| `generate_series()` (`ext/misc/series.c` 포팅) | `src/ext/series.zig` | 셸(`xqlite sql`)이 등록합니다. sqlite3 셸과 같습니다. |
| `vtablog` (`ext/misc/vtablog.c` 포팅, 메서드 호출을 출력) | `src/ext/vtablog.zig` | 셸에서 `XQ_VTABLOG` 환경 변수가 있을 때만 등록합니다. 차등 테스트용입니다. |

반대 방향의 확장도 있습니다. 방언으로 만든 데이터베이스의 스키마는 엔진 함수(`xq_*`)와 방언의 collation을 부르는데, 평범한 sqlite3에는 그것이 없습니다. `zig build ext`가 만드는 `libxqlite_ext`를 sqlite3(`.load`), Python의 `sqlite3`, 시스템 SQLite를 쓰는 프로그램에 올리면 같은 구현으로 계산합니다. SQLite 방언의 동작과 바이트코드는 이것과 상관없이 그대로이고, 엔진 함수 하나 `xq_ext_version()`(확장과 같은 ABI 버전)이 더해졌을 뿐입니다([sqlite3용 확장](../extension.md)).
