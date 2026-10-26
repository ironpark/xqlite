#!/bin/sh
# Cross-checks the SQL layer against sqlite3: the same statements run by
# `xqlite sql` and by sqlite3 on databases written by either, which must
# pass sqlite3's integrity check and give the same query results.
# Requires sqlite3 on PATH and a prior `zig build`.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

schema="CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL);
CREATE INDEX t_b ON t(b);
CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, x UNIQUE);
CREATE VIEW vt AS SELECT b, count(*) AS n FROM t GROUP BY b;"
fill="WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<2000)
INSERT INTO t SELECT n, 'name' || (n % 97), n * 1.5 FROM c;
INSERT INTO w SELECT b, count(*) FROM t GROUP BY b;
INSERT INTO s(x) SELECT a FROM t WHERE a % 3 = 0;"
churn="DELETE FROM t WHERE a % 7 = 0;
UPDATE t SET b = upper(b), c = c + 1 WHERE a % 5 = 0;
UPDATE w SET v = v * 10 WHERE k > 'name5';
DELETE FROM w WHERE k LIKE '%3';
DELETE FROM s WHERE id > 600;
INSERT INTO s(x) VALUES('new');
CREATE INDEX t_c ON t(c);
CREATE TABLE gone(z); INSERT INTO gone SELECT a FROM t; DROP TABLE gone;"
queries="SELECT count(*), sum(a), min(b), max(b), total(c) FROM t;
SELECT k, v FROM w ORDER BY k LIMIT 5;
SELECT * FROM sqlite_sequence;
SELECT max(id), count(*) FROM s;
SELECT * FROM vt ORDER BY n DESC, b LIMIT 3;
SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;"

fail=0
check() { # $1: label, $2: file
  ok=$(sqlite3 "$2" 'PRAGMA integrity_check')
  if [ "$ok" != ok ]; then echo "FAIL $1: integrity_check: $ok"; fail=1; fi
  "$xq" sql "$2" "$queries" > "$tmp/xq.out"
  sqlite3 "$2" "$queries" > "$tmp/sq.out"
  if ! cmp -s "$tmp/xq.out" "$tmp/sq.out"; then
    echo "FAIL $1: results differ"; diff "$tmp/xq.out" "$tmp/sq.out" | head -20; fail=1
  fi
}

# 1. xqlite writes everything.
"$xq" sql "$tmp/a.db" "$schema $fill $churn"
check "written by xqlite" "$tmp/a.db"

# 2. sqlite3 builds, xqlite changes.
sqlite3 "$tmp/b.db" "$schema $fill"
"$xq" sql "$tmp/b.db" "$churn"
check "sqlite3 file changed by xqlite" "$tmp/b.db"

# 3. Both orders give the same content as sqlite3 alone.
sqlite3 "$tmp/c.db" "$schema $fill $churn"
sqlite3 "$tmp/c.db" "$queries" > "$tmp/ref.out"
"$xq" sql "$tmp/a.db" "$queries" > "$tmp/a.out"
"$xq" sql "$tmp/b.db" "$queries" > "$tmp/b.out"
for f in a b; do
  if ! cmp -s "$tmp/$f.out" "$tmp/ref.out"; then
    echo "FAIL $f.db differs from sqlite3 alone"; diff "$tmp/$f.out" "$tmp/ref.out" | head -20; fail=1
  fi
done

# 4. The same on an auto-vacuum database (DROP moves root pages).
sqlite3 "$tmp/d.db" "PRAGMA auto_vacuum=FULL; $schema $fill"
"$xq" sql "$tmp/d.db" "$churn"
check "auto-vacuum file changed by xqlite" "$tmp/d.db"

[ $fail = 0 ] && echo "interop-sql: ok"
exit $fail
