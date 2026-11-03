# 저장 방식

[MariaDB 호환](README.md)의 일부입니다.

DDL은 SQLite 텍스트로 렌더링해 `ir.stmt.lowerSqliteText()`로 내립니다. 그래서 sqlite3가 그대로 열고 `PRAGMA integrity_check`를 통과합니다.

## 테이블과 카탈로그

- 테이블은 `STRICT`입니다.
- 열은 저장 타입(`INTEGER`/`REAL`/`TEXT`/`BLOB`)으로 만듭니다.
- MariaDB 선언 타입(`int(10) unsigned`, `varchar(20)`, `enum('a','b')` ...), 기본값, `AUTO_INCREMENT`, `ON UPDATE CURRENT_TIMESTAMP`는 같은 문장 안에서 `xq_catalog`에 기록합니다.
- `SHOW COLUMNS`, `DESCRIBE`, `SHOW CREATE TABLE`, `information_schema`가 `xq_catalog`를 읽습니다.

## 타입 대응

| MariaDB 타입 | 저장 타입 |
| --- | --- |
| `TINYINT`, `SMALLINT`, `MEDIUMINT`, `INT`, `BIGINT`, `BIT`, `YEAR` | `INTEGER` |
| `DECIMAL(p,0)`, p ≤ 18(`DECIMAL`만 쓰면 `DECIMAL(10,0)`) | `INTEGER` |
| 그 밖의 `DECIMAL`, `FLOAT`, `DOUBLE` | `REAL` |
| `BINARY`, `VARBINARY`, `TINYBLOB`, `BLOB`, `MEDIUMBLOB`, `LONGBLOB` | `BLOB` |
| `CHAR`, `VARCHAR`, `*TEXT`, `ENUM`, `SET`, `DATE`, `DATETIME`, `TIMESTAMP`, `TIME` | `TEXT` |

| 별칭 | 뜻 |
| --- | --- |
| `JSON` | `longtext` + `CHECK(json_valid(...))` |
| `BOOL`, `BOOLEAN` | `tinyint(1)` |
| `SERIAL` | `bigint unsigned NOT NULL AUTO_INCREMENT UNIQUE` |
| `INTEGER`, `INT1`~`INT8`, `DEC`, `NUMERIC`, `FIXED`, `REAL`, `NCHAR`, `NVARCHAR`, `LONG`, `CLOB` ... | MariaDB와 같은 기본 타입 |

## Collation

- 문자열 열에는 언제나 명시적 `COLLATE`를 적습니다.
- 기본·`*_ci` collation은 `NOCASE`입니다.
- `*_bin`·`binary`·`*_cs`는 `BINARY`입니다.
- 날짜·JSON 열은 `BINARY`입니다.
- 그래서 `UNIQUE` 키도 MariaDB처럼 대소문자를 구분하지 않습니다.
- `NOCASE`는 ASCII만 접습니다(`'é' = 'É'`는 거짓).

## `AUTO_INCREMENT`

- SQLite의 `INTEGER PRIMARY KEY AUTOINCREMENT`(sqlite_sequence)입니다.
- 열은 PRIMARY KEY여야 합니다. PRIMARY KEY 없는 테이블이면 그 테이블의 유일한 UNIQUE 키여도 됩니다.
- NULL과 0(`NO_AUTO_VALUE_ON_ZERO`가 아니면)은 다음 값을 만듭니다.
- 더 큰 값을 직접 넣으면 카운터가 따라갑니다.
- 지운 값은 다시 쓰지 않습니다.
- `AUTO_INCREMENT=n`은 sqlite_sequence를 미리 채우고, `TRUNCATE`는 되돌립니다.
- `LAST_INSERT_ID()`는 `last_insert_rowid()`입니다.

## 인덱스 이름

- MariaDB 인덱스 이름은 테이블마다, SQLite 인덱스 이름은 스키마마다 유일합니다.
- 그래서 테이블 `t`의 인덱스 `i`는 SQLite 인덱스 `"t$i"`입니다.
- `KEY`/`INDEX`/`UNIQUE` 정의는 테이블을 만든 직후 같은 문장 안에서(`OP_SqlExec`) 만듭니다.
- `RENAME TABLE t TO u`(와 `ALTER TABLE ... RENAME`)는 인덱스 이름도 `"u$i"`로 바꿉니다.
- 이름을 바꿀 때는 SQLite의 ALTER TABLE처럼 같은 문장 안에서 `sqlite_schema`의 인덱스 행(이름과 CREATE INDEX 텍스트)을 고쳐 쓰고 스키마를 다시 읽습니다. b-tree는 그대로입니다.
- 바뀐 뒤에는 `SHOW INDEX`, `SHOW CREATE TABLE`, `DROP INDEX i ON u`가 새 이름으로 찾습니다.

## CHECK 이름

- 열의 `CHECK`는 열 이름을 붙입니다.
- 이름 없는 테이블 `CHECK`는 `CONSTRAINT_<n>`입니다.
- 둘 다 MariaDB와 같은 이름이고, 오류는 ``CONSTRAINT `price` failed for `main`.`p` ``처럼 나옵니다(4025, [제약 위반](databases.md#제약-위반)).
