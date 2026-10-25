#!/bin/sh
# Cross-checks rollback-journal crash recovery between xqlite and sqlite3:
#   1. xqlite crashes mid-commit, sqlite3 rolls the hot journal back.
#   2. sqlite3 is killed mid-transaction, xqlite rolls the hot journal back.
# Requires sqlite3 on PATH and a prior `zig build`.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_db() {
    sqlite3 "$1" "PRAGMA page_size=1024; PRAGMA journal_mode=delete; CREATE TABLE t(x);
        WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<2000)
        INSERT INTO t SELECT randomblob(200) FROM c;" >/dev/null
}
dump() { sqlite3 "$1" .dump | shasum | cut -d' ' -f1; }
raw() { shasum < "$1" | cut -d' ' -f1; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "1) xqlite leaves a hot journal, sqlite3 rolls it back"
db="$tmp/a.db"
make_db "$db"
before="$(dump "$db")"
"$xq" crash-write "$db" 0xff
[ -s "$db-journal" ] || fail "no journal left behind"
[ "$(sqlite3 "$db" 'PRAGMA integrity_check')" = ok ] || fail "integrity_check"
[ "$(dump "$db")" = "$before" ] || fail "content differs after rollback"
[ ! -e "$db-journal" ] || fail "journal not deleted"
echo "   ok"

echo "2) sqlite3 leaves a hot journal, xqlite rolls it back"
db="$tmp/b.db"
make_db "$db"
before="$(dump "$db")"
raw_before="$(raw "$db")"
mkfifo "$tmp/in"
sqlite3 "$db" < "$tmp/in" &
pid=$!
exec 3>"$tmp/in"
# A tiny cache forces sqlite3 to spill modified pages into the database file
# before the transaction ends.
echo "PRAGMA cache_size=5; BEGIN; UPDATE t SET x=randomblob(200);" >&3
i=0
while [ "$(raw "$db")" = "$raw_before" ]; do
    i=$((i + 1)); [ $i -lt 100 ] || fail "sqlite3 never spilled"
    sleep 0.1
done
sleep 0.5
kill -9 $pid
wait $pid 2>/dev/null || true
exec 3>&-
[ -s "$db-journal" ] || fail "no journal left behind"
"$xq" recover "$db"
[ ! -e "$db-journal" ] || fail "journal not deleted"
[ "$(sqlite3 "$db" 'PRAGMA integrity_check')" = ok ] || fail "integrity_check"
[ "$(dump "$db")" = "$before" ] || fail "content differs after rollback"
echo "   ok"
