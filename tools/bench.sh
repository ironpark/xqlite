#!/bin/sh
# Times the same workloads in xqlite and sqlite3 and prints both, with
# the ratio. Each workload runs RUNS times (default 3) and the fastest run
# counts. Build xqlite first with `zig build -Doptimize=ReleaseFast`.
#
# usage: tools/bench.sh [workload...]   (default: all)
# SQLITE3 names the sqlite3 shell, XQLITE the xqlite binary (zig-out);
# ROWS sets the table size (1000000).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="${XQLITE:-$root/zig-out/bin/xqlite}"
if [ -n "${SQLITE3:-}" ]; then sq="$SQLITE3"
elif [ -x /tmp/xq-sqlite-build/sqlite3 ]; then sq=/tmp/xq-sqlite-build/sqlite3
else sq=sqlite3; fi
runs="${RUNS:-3}"
rows="${ROWS:-1000000}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fill="CREATE TABLE t(a INTEGER PRIMARY KEY, b INT, c TEXT); BEGIN; WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<$rows) INSERT INTO t SELECT i, i*7%1000, 'row'||i FROM r; COMMIT;"

# Column-heavy tables: w has 20 columns, the rows of o spill onto
# overflow pages (b is larger than a page, c comes after it).
wcols=""; wvals=""; k=1
while [ $k -le 20 ]; do
    wcols="$wcols${wcols:+, }c$k INT"; wvals="$wvals${wvals:+, }i*$k%1000"
    k=$((k + 1))
done
fill2="CREATE TABLE w($wcols); CREATE TABLE o(a INTEGER PRIMARY KEY, b BLOB, c INT); BEGIN; WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<$((rows / 2))) INSERT INTO w SELECT $wvals FROM r; WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<$((rows / 100))) INSERT INTO o SELECT i, zeroblob(6000), i FROM r; COMMIT;"

# name|needs the filled table (1), the column-heavy tables (2) or an
# empty file (0)|SQL
workloads="insert|0|$fill
index|1|CREATE INDEX tb ON t(b);
scan|1|SELECT count(*), sum(b), max(length(c)) FROM t;
groupby|1|SELECT b, count(*) FROM t GROUP BY b ORDER BY 2 DESC LIMIT 3;
sort|1|SELECT sum(x) FROM (SELECT a+b AS x FROM t ORDER BY c LIMIT 100000);
pklookup|1|WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<200000) SELECT sum((SELECT c FROM t WHERE a=i*3) IS NOT NULL) FROM r;
update|1|CREATE INDEX tb ON t(b); UPDATE t SET b=b+1 WHERE a%3=0;
delete|1|DELETE FROM t WHERE a%5=0;
cte|0|WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM r WHERE i<5000000) SELECT sum(i*2+1), max(i%7) FROM r;
printf|1|SELECT sum(length(printf('%d-%s', a, c))) FROM t;
json|1|SELECT sum(length(json_object('a',a,'b',c))) FROM t;
window|1|SELECT sum(r) FROM (SELECT row_number() OVER (PARTITION BY b ORDER BY a) r FROM t);
wide|2|SELECT sum(c20), sum(c19) FROM w;
overflow|2|SELECT sum(length(b)), sum(c) FROM o;"

"$sq" "$tmp/base.db" "$fill" >/dev/null
"$sq" "$tmp/base2.db" "$fill2" >/dev/null

now() { python3 -c 'import time; print(time.time())'; }

# best ENGINE NEEDS SQL: the fastest of $runs runs, in seconds.
best() {
    b=""
    i=0
    while [ $i -lt "$runs" ]; do
        rm -f "$tmp/w.db" "$tmp/w.db-journal" "$tmp/w.db-wal" "$tmp/w.db-shm"
        [ "$2" = 1 ] && cp "$tmp/base.db" "$tmp/w.db"
        [ "$2" = 2 ] && cp "$tmp/base2.db" "$tmp/w.db"
        s=$(now)
        $1 "$tmp/w.db" "$3" >/dev/null
        e=$(now)
        b=$(python3 -c "t=$e-$s; b='$b'; print(f'{t:.3f}' if not b or t<float(b) else b)")
        i=$((i + 1))
    done
    echo "$b"
}

printf '%-10s %8s %8s %6s\n' workload xqlite sqlite3 ratio
echo "$workloads" | while IFS='|' read -r name needs sql; do
    if [ $# -gt 0 ]; then
        case " $* " in *" $name "*) ;; *) continue ;; esac
    fi
    x=$(best "$xq sql" "$needs" "$sql")
    s=$(best "$sq" "$needs" "$sql")
    printf '%-10s %8s %8s %6s\n' "$name" "$x" "$s" "$(python3 -c "print(f'{$x/$s:.2f}')")"
done
