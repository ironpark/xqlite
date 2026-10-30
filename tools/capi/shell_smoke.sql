-- Fed to SQLite's own shell (shell.c) built on libxqlite3 by
-- `zig build capi-shell`; the output must match shell_smoke.expected.
.print -- version
SELECT sqlite_version();
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL);
INSERT INTO t(name, score) VALUES ('ada', 9.5), ('linus', 7.25), ('grace', NULL);
.print -- list
SELECT * FROM t ORDER BY id;
.headers on
.mode box
SELECT name, score FROM t WHERE score > 7 ORDER BY score DESC;
.mode csv
SELECT id, name FROM t;
.mode json
SELECT id, name, score FROM t WHERE id = 1;
.mode list
.headers off
.print -- schema
.schema t
.tables
.print -- dump
.dump t
.print -- functions and extensions of the shell
SELECT shell_add_schema('CREATE TABLE x(a)', 'main', 'x');
SELECT group_concat(value, ',') FROM generate_series(1, 5);
SELECT sha3('abc', 256) = sha3('abc');
SELECT decimal_add('0.1', '0.2');
.print -- errors
SELECT * FROM nosuch;
SELECT 1 +;
.print -- dialect
PRAGMA xq_dialect = 'postgres';
SELECT 'x' || 42::text;
PRAGMA xq_dialect = 'sqlite';
.print -- done
