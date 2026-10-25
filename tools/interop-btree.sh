#!/bin/sh
# Cross-checks the b-tree layer against sqlite3:
#   1. xqlite builds a table and an index from scratch; sqlite3 must find
#      the file intact and identical in content to the same build in SQL.
#   2. xqlite deletes, updates and inserts rows in a database built by
#      sqlite3; the result must match the same statements run by sqlite3.
#   3. xqlite's integrity check agrees with sqlite3's on those files.
# Requires sqlite3 on PATH and a prior `zig build`.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

n=3000
# printf('%.*c', 0, x) still prints one character, so no length is 0.
# The content `xqlite bt-fill` writes (see src/main.zig).
fill_sql="PRAGMA page_size=4096; PRAGMA auto_vacuum=0;
CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
CREATE INDEX t_b ON t(b);
WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<$n)
INSERT INTO t SELECT i, printf('v-%d', (i*7919)%$n),
  cast(printf('%.*c', CASE WHEN i%50=0 THEN 3000 ELSE i%20+1 END, 'p') AS BLOB) FROM s;
DELETE FROM t WHERE a%7=0;"
# What `xqlite bt-churn` does.
churn_sql="DELETE FROM t WHERE a%3=0;
UPDATE t SET c=cast(printf('%.*c', 1500+a, 'u') AS BLOB) WHERE a%3=1 AND a<200;
WITH RECURSIVE s(k) AS (SELECT 1 UNION ALL SELECT k+1 FROM s WHERE k<500)
INSERT INTO t SELECT 100000+k, 'new-'||k,
  cast(printf('%.*c', CASE WHEN k%10=0 THEN 2500 ELSE k%30+1 END, 'n') AS BLOB) FROM s;"

# More writes, done by sqlite3 on both files afterwards.
more_sql="DELETE FROM t WHERE a%4=1;
WITH RECURSIVE s(k) AS (SELECT 1 UNION ALL SELECT k+1 FROM s WHERE k<800)
INSERT INTO t SELECT 200000+k, printf('more-%d', k*31%800), zeroblob(k%5) FROM s;"

content() {
    sqlite3 "$1" "SELECT a, b, typeof(c), hex(c) FROM t ORDER BY a;
                  SELECT b, a FROM t INDEXED BY t_b WHERE b>'' ORDER BY b;" | shasum | cut -d' ' -f1
}
fail() { echo "FAIL: $*" >&2; exit 1; }
intact() {
    [ "$(sqlite3 "$1" 'PRAGMA integrity_check')" = ok ] || fail "sqlite3 integrity_check on $1"
    [ "$("$xq" check "$1")" = ok ] || fail "xqlite check on $1"
}

echo "1) xqlite writes a table and an index, sqlite3 reads them"
sqlite3 "$tmp/ref1.db" "$fill_sql"
"$xq" bt-fill "$tmp/x1.db" $n
intact "$tmp/x1.db"
[ "$(content "$tmp/x1.db")" = "$(content "$tmp/ref1.db")" ] || fail "content differs"
echo "   ok"

echo "2) xqlite modifies a database written by sqlite3"
sqlite3 "$tmp/ref2.db" "PRAGMA page_size=1024; $fill_sql" 2>/dev/null
cp "$tmp/ref2.db" "$tmp/x2.db"
sqlite3 "$tmp/ref2.db" "$churn_sql"
"$xq" bt-churn "$tmp/x2.db"
intact "$tmp/x2.db"
[ "$(content "$tmp/x2.db")" = "$(content "$tmp/ref2.db")" ] || fail "content differs"
# And sqlite3 can keep writing to the result.
sqlite3 "$tmp/x2.db" "$more_sql"
sqlite3 "$tmp/ref2.db" "$more_sql"
intact "$tmp/x2.db"
[ "$(content "$tmp/x2.db")" = "$(content "$tmp/ref2.db")" ] || fail "content differs after sqlite3 writes"
echo "   ok"

echo "3) both integrity checks report the same corruption"
cp "$tmp/ref1.db" "$tmp/bad.db"
# Point the first cell of page 3 past the end of the page.
printf '\377\377' | dd of="$tmp/bad.db" bs=1 seek=$((2*4096 + 8)) conv=notrunc 2>/dev/null
# sqlite3 adds a header line and index-versus-table checks, which belong to
# the SQL layer.
want="$(sqlite3 "$tmp/bad.db" 'PRAGMA integrity_check' 2>/dev/null |
    grep -v -e '^\*\*\* in database main \*\*\*$' -e '^wrong # of entries' -e '^row .* missing from index' || true)"
got="$("$xq" check "$tmp/bad.db")"
[ "$got" = "$want" ] || fail "integrity messages differ:
--- sqlite3
$want
--- xqlite
$got"
echo "   ok"
