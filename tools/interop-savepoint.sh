#!/bin/sh
# Cross-checks savepoints and statement transactions against sqlite3: the
# same scripts of SAVEPOINT / RELEASE / ROLLBACK TO and statements that
# fail midway inside a transaction, run by `xqlite sql` and by sqlite3 in
# each journal mode and with a cache small enough to spill, must print the
# same results and leave a database that passes the integrity check.
# SQLITE3 names the sqlite3 shell (default: sqlite3 on PATH); a prior
# `zig build` is required.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
sq="${SQLITE3:-sqlite3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# randomblob() lengths are compared, not contents.
body="CREATE TABLE t(a INTEGER PRIMARY KEY, b, c UNIQUE);
CREATE INDEX tb ON t(b);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<3000)
  INSERT INTO t SELECT i, randomblob(100+i%400), i FROM n;
BEGIN;
UPDATE t SET b = randomblob(300) WHERE a % 2 = 0;
SAVEPOINT s1;
DELETE FROM t WHERE a % 3 = 0;
SAVEPOINT s2;
INSERT INTO t SELECT a+10000, randomblob(700), c+10000 FROM t WHERE a < 1500;
UPDATE t SET c = c + 1 WHERE a > 2900;
SELECT 'mid', count(*), sum(length(b)) FROM t;
ROLLBACK TO s2;
SELECT 'rb2', count(*), sum(length(b)) FROM t;
INSERT INTO t SELECT a+20000, randomblob(50), c+20000 FROM t WHERE a < 100;
ROLLBACK TO s1;
SELECT 'rb1', count(*), sum(length(b)) FROM t;
INSERT INTO t SELECT a+30000, b, c FROM t WHERE a < 10;
SELECT 'after-fail', count(*) FROM t;
RELEASE s1;
COMMIT;
SAVEPOINT outer1;
INSERT INTO t VALUES(50000, 'x', 50000);
SAVEPOINT inner1;
DELETE FROM t WHERE a < 1000;
RELEASE outer1;
SELECT 'end', count(*), sum(length(b)) FROM t;
RELEASE nosuch;
PRAGMA integrity_check;"

fail=0
for mode in delete persist truncate off; do
  for cache in 5 2000; do
    script="PRAGMA journal_mode=$mode;
PRAGMA cache_size=$cache;
$body"
    rm -f "$tmp"/x.db* "$tmp"/s.db*
    printf '%s\n' "$script" | "$xq" sql "$tmp/x.db" > "$tmp/xq.out" 2>&1 || true
    # The sqlite3 shell turns on defensive mode, which refuses
    # journal_mode=OFF.
    { echo ".dbconfig defensive off"; printf '%s\n' "$script"; } | "$sq" "$tmp/s.db" 2>&1 |
      grep -v '^ *defensive' | sed 's/line \([0-9]*\)/line N/' > "$tmp/sq.out" || true
    sed 's/line \([0-9]*\)/line N/' "$tmp/xq.out" > "$tmp/xq.norm"
    if ! cmp -s "$tmp/xq.norm" "$tmp/sq.out"; then
      echo "FAIL journal_mode=$mode cache_size=$cache"; diff "$tmp/sq.out" "$tmp/xq.norm" | head -20; fail=1
    fi
    ok=$("$sq" "$tmp/x.db" 'PRAGMA integrity_check')
    if [ "$ok" != ok ]; then echo "FAIL journal_mode=$mode cache_size=$cache: integrity_check: $ok"; fail=1; fi
  done
done

[ $fail = 0 ] && echo "interop-savepoint: ok"
exit $fail
