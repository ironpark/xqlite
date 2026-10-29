#!/bin/sh
# Cross-checks ANALYZE and PRAGMA optimize against sqlite3: on the same
# data, xqlite and sqlite3 must write the same sqlite_stat1 rows (rowids
# included), and a database analyzed by either must give the same query
# plans and PRAGMA optimize decisions when read by the other.
# Needs a prior `zig build`. SQLITE3 names the reference shell, which
# should be 3.54.1 (default: /tmp/xq-sqlite-build/sqlite3 if present,
# else sqlite3 on PATH).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
default_sq=sqlite3
[ -x /tmp/xq-sqlite-build/sqlite3 ] && default_sq=/tmp/xq-sqlite-build/sqlite3
sq="${SQLITE3:-$default_sq}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# More than 30 tables, so that the schema hash has its largest bucket
# array; skewed columns, partial, expression, NOCASE, UNIQUE and WITHOUT
# ROWID indexes, an empty table, a view, dropped tables.
schema="CREATE TABLE t(a INTEGER PRIMARY KEY, b, c, d TEXT COLLATE NOCASE, e);
CREATE INDEX t_b ON t(b);
CREATE INDEX t_c ON t(c);
CREATE INDEX t_bc ON t(b, c);
CREATE UNIQUE INDEX t_d ON t(d);
CREATE INDEX t_e ON t(e) WHERE e IS NOT NULL;
CREATE INDEX t_x ON t(c % 7, b);
CREATE TABLE w(x, y, z, PRIMARY KEY(x, y)) WITHOUT ROWID;
CREATE INDEX w_z ON w(z);
CREATE TABLE plain(p, q);
CREATE TABLE empty(a);
CREATE INDEX empty_a ON empty(a);
CREATE VIEW v AS SELECT * FROM t;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<5000)
INSERT INTO t SELECT i, i % 2, i % 700, 'v' || i, CASE WHEN i % 25 = 0 THEN i % 9 END FROM n;
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<800)
INSERT INTO w SELECT i % 30, i, i % 11 FROM n;
INSERT INTO plain VALUES (1, 2), (3, 4);"
i=0
while [ $i -lt 36 ]; do
  schema="$schema
CREATE TABLE m$i(k, v); CREATE INDEX m${i}_k ON m$i(k); INSERT INTO m$i VALUES ($i, 1), ($i, 2), ($i + 1, 3);"
  i=$((i + 1))
done
schema="$schema
DROP TABLE m3; DROP TABLE m17; DROP TABLE m30;"

plans="EXPLAIN QUERY PLAN SELECT * FROM t WHERE b = 1 AND c = 5;
EXPLAIN QUERY PLAN SELECT * FROM t WHERE b = 1 AND c > 690;
EXPLAIN QUERY PLAN SELECT * FROM t WHERE b = 0 AND e = 3;
EXPLAIN QUERY PLAN SELECT * FROM t, w WHERE t.c = w.z AND w.x = 3;
EXPLAIN QUERY PLAN SELECT * FROM w WHERE z = 1 AND x = 3;
EXPLAIN QUERY PLAN SELECT * FROM t WHERE c % 7 = 1 AND b = 0 AND c = 8;
PRAGMA optimize(-1);"
stat="SELECT rowid, * FROM sqlite_stat1;"

"$sq" "$tmp/base.db" "$schema"
for f in sq xq sqlim xqlim; do cp "$tmp/base.db" "$tmp/$f.db"; done

# 1. The same rows of sqlite_stat1, without and with analysis_limit.
"$sq" "$tmp/sq.db" "ANALYZE; $stat" > "$tmp/sq.stat"
"$xq" sql "$tmp/xq.db" "ANALYZE; $stat" > "$tmp/xq.stat"
"$sq" "$tmp/sqlim.db" "PRAGMA analysis_limit=100; ANALYZE; ANALYZE m5; $stat" > "$tmp/sqlim.stat"
"$xq" sql "$tmp/xqlim.db" "PRAGMA analysis_limit=100; ANALYZE; ANALYZE m5; $stat" > "$tmp/xqlim.stat"
for f in "" lim; do
  if ! cmp -s "$tmp/sq$f.stat" "$tmp/xq$f.stat"; then
    echo "FAIL sqlite_stat1 rows differ ($f)"; diff "$tmp/sq$f.stat" "$tmp/xq$f.stat" | head -20; fail=1
  fi
  ok=$("$sq" "$tmp/xq$f.db" 'PRAGMA integrity_check')
  if [ "$ok" != ok ]; then echo "FAIL integrity_check ($f): $ok"; fail=1; fi
done

# 2. Each reads the other's statistics: the same plans as with its own.
"$sq" "$tmp/sq.db" "$plans" > "$tmp/sq-own.plan"
"$sq" "$tmp/xq.db" "$plans" > "$tmp/sq-xq.plan"
"$xq" sql "$tmp/xq.db" "$plans" > "$tmp/xq-own.plan"
"$xq" sql "$tmp/sq.db" "$plans" > "$tmp/xq-sq.plan"
for f in sq-xq xq-own xq-sq; do
  if ! cmp -s "$tmp/sq-own.plan" "$tmp/$f.plan"; then
    echo "FAIL plans differ ($f)"; diff "$tmp/sq-own.plan" "$tmp/$f.plan" | head -20; fail=1
  fi
done

# 3. PRAGMA optimize after the data changed, by each on the other's file.
change="INSERT INTO plain SELECT a, b FROM t; CREATE INDEX plain_p ON plain(p); DELETE FROM w WHERE y > 20;"
"$sq" "$tmp/xq.db" "$change PRAGMA optimize; $stat" > "$tmp/sq-opt.stat"
"$xq" sql "$tmp/sq.db" "$change PRAGMA optimize; $stat" > "$tmp/xq-opt.stat"
if ! cmp -s "$tmp/sq-opt.stat" "$tmp/xq-opt.stat"; then
  echo "FAIL PRAGMA optimize differs"; diff "$tmp/sq-opt.stat" "$tmp/xq-opt.stat" | head -20; fail=1
fi
for f in sq xq; do
  ok=$("$sq" "$tmp/$f.db" 'PRAGMA integrity_check')
  if [ "$ok" != ok ]; then echo "FAIL integrity_check ($f, optimized): $ok"; fail=1; fi
done

[ $fail = 0 ] && echo "interop-analyze: ok"
exit $fail
