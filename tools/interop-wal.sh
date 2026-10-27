#!/bin/sh
# Cross-checks WAL mode (journal_mode=WAL) between xqlite and sqlite3:
#   1. WAL databases written by one engine, with frames not yet
#      checkpointed, read and checkpointed by the other; leaving WAL mode
#   2. checkpoint modes and their result rows, wal_autocheckpoint, page
#      sizes 512..65536, auto_vacuum
#   3. crash recovery: a process dies mid-transaction, mid-commit, right
#      after the commit frame and mid-checkpoint; each engine recovers a
#      copy of what is left, and both must agree with the expected content
#   4. both engines on one database at once: snapshots that outlive other
#      engines' commits, writer contention and busy_timeout, checkpoints
#      next to readers, and a randomized stress run of several processes
#      checked against invariants
# SQLITE3 names the reference shell, which should be 3.54.1 (default:
# /tmp/xq-sqlite-build/sqlite3 if present, else sqlite3 on PATH); a prior
# `zig build` is needed. STRESS_TXNS sets the transactions per stress
# process (default 3000; 4 processes).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
default_sq=sqlite3
[ -x /tmp/xq-sqlite-build/sqlite3 ] && default_sq=/tmp/xq-sqlite-build/sqlite3
sq="${SQLITE3:-$default_sq}"
stress_txns="${STRESS_TXNS:-3000}"
tmp="$(mktemp -d)"
pids=""
cleanup() {
    for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# E ENGINE DB ARGS...: run the shell of ENGINE (x or s) on DB.
E() {
    engine=$1
    shift
    if [ "$engine" = x ]; then "$xq" sql "$@"; else "$sq" "$@"; fi
}
# Q: E without the line that .dbconfig prints.
Q() { E "$@" | grep -v '^ *no_ckpt_on_close'; }
other() { if [ "$1" = x ]; then echo s; else echo x; fi; }
name() { if [ "$1" = x ]; then echo xqlite; else echo sqlite3; fi; }

# Keeps the WAL on close (the last connection would checkpoint it).
nockpt=".dbconfig no_ckpt_on_close on"

# copy SRC DST: the database and whatever WAL and -shm it has.
copy() {
    rm -f "$2" "$2-wal" "$2-shm"
    cp "$1" "$2"
    [ ! -e "$1-wal" ] || cp "$1-wal" "$2-wal"
    [ ! -e "$1-shm" ] || cp "$1-shm" "$2-shm"
}
sum() { shasum | cut -d' ' -f1; }
fsize() { if [ -e "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
# dump ENGINE DB: a hash of the .dump of DB by ENGINE (which checkpoints
# and removes the WAL on close).
dump() { E "$1" "$2" .dump | sum; }
check() { # LABEL ENGINE DB
    ok=$(E "$2" "$3" "PRAGMA integrity_check")
    [ "$ok" = ok ] || fail "$1: $(name "$2") integrity_check: $ok"
}
frames() { # the frames in WAL $1 of page size $2
    if [ -e "$1" ] && [ "$(fsize "$1")" -gt 32 ]; then echo $(( ($(fsize "$1") - 32) / ($2 + 24) )); else echo 0; fi
}
versions() { "$xq" dbinfo "$1" | awk '/write format|read format/ { printf "%s", $3 }'; }

# agree LABEL DB WANT: the copies of DB that each engine recovers and dumps
# must agree with each other, and with hash WANT if given.
agree() {
    copy "$2" "$tmp/agree-x.db"
    copy "$2" "$tmp/agree-s.db"
    dx=$(dump x "$tmp/agree-x.db")
    ds=$(dump s "$tmp/agree-s.db")
    [ "$dx" = "$ds" ] || fail "$1: xqlite and sqlite3 read different content"
    [ -z "${3:-}" ] || [ "$dx" = "$3" ] || fail "$1: content differs from the expected"
    # Each engine checkpointed its copy: the other must accept the result.
    check "$1 (checkpointed by xqlite)" s "$tmp/agree-x.db"
    check "$1 (checkpointed by sqlite3)" x "$tmp/agree-s.db"
}

schema="CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
CREATE INDEX t_b ON t(b);
CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;"
fill="WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1500)
INSERT INTO t SELECT i, 'v' || (i*7919 % 1500), zeroblob(i % 700) FROM n;
INSERT INTO w SELECT b, count(*) FROM t GROUP BY b;"
churn() { # deterministic changes, round $1
    echo "DELETE FROM t WHERE a % 7 = $1;
UPDATE t SET b = b || '.$1', c = zeroblob(($1 * 97 + a) % 900) WHERE a % 5 = $(($1 % 5));
INSERT INTO t SELECT a + 10000 * ($1 + 1), 'n$1-' || a, zeroblob(a % 300) FROM t WHERE a < 200;
UPDATE w SET v = v + $1 WHERE k > 'v7';
DELETE FROM w WHERE k LIKE '%$1';"
}

# ===================================================================== 1

echo "1) WAL files of one engine read by the other"
for writer in x s; do
    db="$tmp/w-$writer.db"
    E $writer "$db" "PRAGMA journal_mode=WAL" "$schema" "$fill" > /dev/null
    [ "$(versions "$db")" = 22 ] || fail "$(name $writer): header versions are $(versions "$db"), not 2/2"
    E $writer "$db" "$nockpt" "$(churn 1)" > /dev/null
    [ "$(frames "$db-wal" 4096)" -gt 10 ] || fail "$(name $writer) left no frames"
    agree "WAL of $(name $writer)" "$db"
done

# Both engines writing in turn, each leaving its frames to the other.
db="$tmp/turns.db"
E s "$db" "PRAGMA journal_mode=WAL" "$schema" "$fill" > /dev/null
for round in 2 3 4 5 6 7; do
    writer=x
    [ $((round % 2)) = 0 ] || writer=s
    E $writer "$db" "$nockpt" "$(churn $round)" > /dev/null
    agree "turn $round by $(name $writer)" "$db"
done

# Leaving WAL mode with frames pending: checkpoint, delete the WAL,
# rewrite the header versions.
for leaver in x s; do
    db="$tmp/leave-$leaver.db"
    E $(other $leaver) "$db" "PRAGMA journal_mode=WAL" "$schema" "$fill" > /dev/null
    E $(other $leaver) "$db" "$nockpt" "$(churn 3)" > /dev/null
    copy "$db" "$tmp/leave-ref.db"
    want=$(dump s "$tmp/leave-ref.db")
    out=$(E $leaver "$db" "PRAGMA journal_mode=DELETE")
    [ "$out" = delete ] || fail "$(name $leaver) journal_mode=DELETE: $out"
    [ ! -e "$db-wal" ] || fail "$(name $leaver) left the WAL behind"
    [ "$(versions "$db")" = 11 ] || fail "$(name $leaver): header versions are $(versions "$db"), not 1/1"
    out=$(E $(other $leaver) "$db" "PRAGMA journal_mode")
    [ "$out" = delete ] || fail "$(name $(other $leaver)) sees journal_mode=$out"
    [ "$(dump $(other $leaver) "$db")" = "$want" ] || fail "content changed leaving WAL mode"
    check "after leaving WAL mode" $(other $leaver) "$db"
done

# A database file without write permission opens read-only, in rollback
# and in WAL mode (with a writable WAL and -shm next to it).
for mode in DELETE WAL; do
    db="$tmp/ro-$mode.db"
    E s "$db" "PRAGMA journal_mode=$mode" "$schema" "$fill" > /dev/null
    E s "$db" "$nockpt" "$(churn 1)" > /dev/null
    chmod 444 "$db"
    for e in x s; do
        Q $e "$db" "$nockpt" "SELECT count(*), sum(a) FROM t" "INSERT INTO t VALUES(-1, 'x', 1)" \
            "SELECT count(*) FROM t" > "$tmp/ro-$e.out" 2>&1 || echo "exit $?" >> "$tmp/ro-$e.out"
    done
    cmp -s "$tmp/ro-x.out" "$tmp/ro-s.out" || {
        diff "$tmp/ro-x.out" "$tmp/ro-s.out" >&2
        fail "read-only $mode database: results differ"
    }
    grep -q "attempt to write a readonly database" "$tmp/ro-x.out" || fail "read-only $mode database: $(cat "$tmp/ro-x.out")"
done
echo "   ok"

# ===================================================================== 2

echo "2) checkpoints, wal_autocheckpoint, page sizes, auto_vacuum"
# same_ckpt LABEL DB SQL: each engine runs SQL (which checkpoints) on its
# own copy of DB; the outputs and the resulting files must be identical.
same_ckpt() {
    copy "$2" "$tmp/ckpt-x.db"
    copy "$2" "$tmp/ckpt-s.db"
    rx=$(E x "$tmp/ckpt-x.db" "$3")
    rs=$(E s "$tmp/ckpt-s.db" "$3")
    [ "$rx" = "$rs" ] || fail "$1: '$3' gives $rx and $rs"
    cmp -s "$tmp/ckpt-x.db" "$tmp/ckpt-s.db" || fail "$1: checkpointed files differ"
}
base="$tmp/ckpt.db"
E s "$base" "PRAGMA journal_mode=WAL" "$schema" "$fill" > /dev/null
E s "$base" "$nockpt" "$(churn 1)" > /dev/null
for mode in PASSIVE FULL RESTART TRUNCATE NOOP; do
    for e in x s; do
        copy "$base" "$tmp/ckpt-$e.db"
        E $e "$tmp/ckpt-$e.db" "$nockpt" "PRAGMA wal_checkpoint($mode)" "$(churn 2)" \
            "PRAGMA wal_checkpoint($mode)" "PRAGMA main.wal_checkpoint" "INSERT INTO t VALUES(99999, 'x', 1)" \
            "PRAGMA wal_checkpoint($mode)" > "$tmp/ckpt-$e.out" 2>&1
        fsize "$tmp/ckpt-$e.db-wal" >> "$tmp/ckpt-$e.out"
        fsize "$tmp/ckpt-$e.db" >> "$tmp/ckpt-$e.out"
    done
    cmp -s "$tmp/ckpt-x.out" "$tmp/ckpt-s.out" || {
        diff "$tmp/ckpt-x.out" "$tmp/ckpt-s.out" >&2
        fail "wal_checkpoint($mode): results differ"
    }
    agree "wal_checkpoint($mode)" "$tmp/ckpt-x.db" "$(dump s "$tmp/ckpt-s.db")"
done
# The same commits with an autocheckpoint every N frames.
for n in 1 10 100; do
    for e in x s; do
        rm -f "$tmp/ac-$e.db"*
        {
            echo "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=$n; PRAGMA wal_autocheckpoint;"
            echo "$schema"
            i=0
            while [ $i -lt 30 ]; do
                echo "INSERT INTO t VALUES($i, 'r$i', zeroblob($i * 211 % 5000));"
                echo "PRAGMA wal_checkpoint(NOOP);"
                i=$((i + 1))
            done
        } | E $e "$tmp/ac-$e.db" "$nockpt" > "$tmp/ac-$e.out" 2>&1
    done
    cmp -s "$tmp/ac-x.out" "$tmp/ac-s.out" || {
        diff "$tmp/ac-x.out" "$tmp/ac-s.out" | head -20 >&2
        fail "wal_autocheckpoint=$n: WAL sizes differ"
    }
done
for ps in 512 1024 2048 4096 8192 16384 32768 65536; do
    for writer in x s; do
        db="$tmp/ps-$ps-$writer.db"
        E $writer "$db" "PRAGMA page_size=$ps" "PRAGMA journal_mode=WAL" "$schema" "$fill" > /dev/null
        E $writer "$db" "$nockpt" "$(churn 4)" > /dev/null
        [ "$(Q $(other $writer) "$db" "$nockpt" "PRAGMA page_size")" = $ps ] || fail "page_size=$ps not kept"
        E $(other $writer) "$db" "$nockpt" "$(churn 5)" > /dev/null
        agree "page_size=$ps, $(name $writer) first" "$db"
        same_ckpt "page_size=$ps" "$db" "PRAGMA wal_checkpoint(TRUNCATE)"
    done
done
for av in full incremental; do
    for writer in x s; do
        db="$tmp/av-$av-$writer.db"
        E $writer "$db" "PRAGMA page_size=1024" "PRAGMA auto_vacuum=$av" "PRAGMA journal_mode=WAL" "$schema" "$fill" > /dev/null
        E $writer "$db" "$nockpt" "DELETE FROM t WHERE a > 300" "PRAGMA incremental_vacuum(50)" > /dev/null
        E $(other $writer) "$db" "$nockpt" "DELETE FROM t WHERE a < 100" "PRAGMA incremental_vacuum" > /dev/null
        same_ckpt "auto_vacuum=$av" "$db" \
            "PRAGMA auto_vacuum; PRAGMA page_count; PRAGMA freelist_count; PRAGMA wal_checkpoint(TRUNCATE)"
        check "auto_vacuum=$av" s "$tmp/ckpt-x.db"
    done
done
echo "   ok"

# ===================================================================== 3

echo "3) crash recovery"
# A database with 1000 pages of 1024 bytes, fully checkpointed.
make_db() {
    rm -f "$1" "$1-wal" "$1-shm"
    E s "$1" "PRAGMA page_size=1024" "PRAGMA journal_mode=WAL" "CREATE TABLE t(x)" \
        "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<2000)
         INSERT INTO t SELECT zeroblob(300) FROM c" > /dev/null
}
update="UPDATE t SET x = zeroblob(301)"

# A shell reading commands from a FIFO; its output goes to $tmp/NAME.out.
start() { # NAME ENGINE DB FD
    rm -f "$tmp/$1.in" "$tmp/$1.out"
    mkfifo "$tmp/$1.in"
    if [ "$2" = x ]; then
        "$xq" sql "$3" < "$tmp/$1.in" > "$tmp/$1.out" 2>&1 &
    else
        "$sq" "$3" < "$tmp/$1.in" > "$tmp/$1.out" 2>&1 &
    fi
    eval "pid_$1=\$!"
    pids="$pids $!"
    eval "exec $4> \"\$tmp/\$1.in\""
}
say() { eval "printf '%s\n' \"\$2\" >&$1"; } # FD TEXT
stop() { # NAME FD
    say "$2" ".quit"
    eval "exec $2>&-"
    eval "wait \$pid_$1" || true
}
# kill_shell NAME FD: what a crash does to the shell NAME.
kill_shell() {
    eval "kill -9 \$pid_$1"
    eval "wait \$pid_$1" 2>/dev/null || true
    eval "exec $2>&-"
}

# xqlite dies at a write to the WAL ($XQLITE_TEST_CRASH, see xqlite's
# usage): its header is write 1, frame N writes 2N and 2N+1 (header and
# page). The crash comes after N frames of a spill of an open transaction
# (cache too small), or part way through or right after the frames of a
# commit; or it tears the page of the commit frame in half.
make_db "$tmp/c.db"
want_before=$(dump s "$tmp/c.db")
copy "$tmp/c.db" "$tmp/c-after.db"
E s "$tmp/c-after.db" "$nockpt" "$update" > /dev/null
n_commit=$(frames "$tmp/c-after.db-wal" 1024)
want_after=$(dump s "$tmp/c-after.db")
for case in "spill:10:PRAGMA cache_size=10:before" "commit:$((n_commit / 2))::before" \
    "commit-frame:$n_commit::after" "torn-commit-frame:$n_commit:torn:before"; do
    label=${case%%:*}
    rest=${case#*:}
    at=${rest%%:*}
    rest=${rest#*:}
    arg=${rest%%:*}
    expect=${rest#*:}
    crash="wal:$((2 * at + 1))"
    pragma=
    whole=$at
    if [ "$arg" = torn ]; then
        crash="$crash:torn"
        whole=$((at - 1))
    else
        pragma=$arg
    fi
    make_db "$tmp/c.db"
    XQLITE_TEST_CRASH=$crash "$xq" sql "$tmp/c.db" ${pragma:+"$pragma"} "$update" "SELECT 'not crashed'" > "$tmp/c.out" 2>&1 || true
    ! grep -q 'not crashed' "$tmp/c.out" || fail "xqlite $label: did not crash"
    [ "$(frames "$tmp/c.db-wal" 1024)" = "$whole" ] || fail "xqlite $label: $(frames "$tmp/c.db-wal" 1024) whole frames, not $whole"
    want=$want_before
    [ "$expect" = before ] || want=$want_after
    agree "xqlite crash ($label)" "$tmp/c.db" "$want"
done

# xqlite dies part way through a checkpoint, at (or tearing) its 300th
# write to the database file: the file is half updated, but the WAL is
# intact.
for crash in db:300 db:300:torn; do
    make_db "$tmp/k.db"
    E s "$tmp/k.db" "$nockpt" "$update" > /dev/null
    db_before=$(sum < "$tmp/k.db")
    XQLITE_TEST_CRASH=$crash "$xq" sql "$tmp/k.db" "PRAGMA wal_checkpoint" > "$tmp/k.out" 2>&1 || true
    [ ! -s "$tmp/k.out" ] || fail "xqlite did not crash mid-checkpoint ($crash): $(cat "$tmp/k.out")"
    [ "$(sum < "$tmp/k.db")" != "$db_before" ] || fail "the checkpoint wrote nothing ($crash)"
    agree "xqlite crash mid-checkpoint ($crash)" "$tmp/k.db" "$want_after"
done

# sqlite3 killed mid-transaction, after spilling into the WAL.
make_db "$tmp/s.db"
size0=$(fsize "$tmp/s.db-wal")
start s s "$tmp/s.db" 3
say 3 "PRAGMA cache_size=10; BEGIN; $update; UPDATE t SET x = zeroblob(302);"
i=0
while [ "$(fsize "$tmp/s.db-wal")" -le $((size0 + 100 * 1048)) ]; do
    i=$((i + 1))
    [ $i -lt 200 ] || fail "sqlite3 never spilled"
    sleep 0.05
done
kill_shell s 3
agree "sqlite3 killed mid-transaction" "$tmp/s.db" "$want_before"

# sqlite3 killed while it checkpoints a large WAL (where exactly it dies
# varies; the content must not).
make_db "$tmp/m.db"
E s "$tmp/m.db" "$nockpt" "PRAGMA cache_size=-100000" "$update" "UPDATE t SET x = zeroblob(303)" \
    "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<40000) INSERT INTO t SELECT zeroblob(50) FROM c" > /dev/null
copy "$tmp/m.db" "$tmp/m-ref.db"
want=$(dump s "$tmp/m-ref.db")
db_before=$(sum < "$tmp/m.db")
start m s "$tmp/m.db" 3
say 3 "PRAGMA wal_checkpoint;"
i=0
while [ "$(sum < "$tmp/m.db")" = "$db_before" ] && [ $i -lt 400 ]; do
    i=$((i + 1))
    sleep 0.01
done
kill_shell m 3
agree "sqlite3 killed mid-checkpoint" "$tmp/m.db" "$want"
echo "   ok"

# ===================================================================== 4

echo "4) concurrent xqlite and sqlite3 processes"
wait_for() { # NAME TEXT
    i=0
    until grep -q -- "$2" "$tmp/$1.out" 2>/dev/null; do
        i=$((i + 1))
        [ $i -lt 400 ] || fail "timed out waiting for '$2' from $1: $(cat "$tmp/$1.out")"
        sleep 0.05
    done
}
row() { grep -- "^$2|" "$tmp/$1.out" | head -1 | cut -d'|' -f2-; } # NAME TAG

for reader in x s; do
    writer=$(other $reader)
    db="$tmp/cc-$reader.db"
    rm -f "$db"*
    E s "$db" "PRAGMA journal_mode=WAL" "CREATE TABLE t(x)" \
        "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<100) INSERT INTO t SELECT i FROM c" > /dev/null
    rn=$(name $reader)
    wn=$(name $writer)

    # A reader keeps its snapshot across commits and checkpoints by the
    # other engine, and sees them once its transaction ends.
    start r $reader "$db" 3
    say 3 "BEGIN; SELECT 'r1', count(*), sum(x) FROM t;"
    wait_for r "^r1|"
    E $writer "$db" "INSERT INTO t VALUES(1000)" "UPDATE t SET x = x + 1 WHERE x < 10" > /dev/null ||
        fail "$wn could not write next to a $rn reader"
    ck=$(E $writer "$db" "PRAGMA wal_checkpoint")
    [ "${ck%%|*}" = 0 ] || fail "$wn: passive checkpoint next to a reader: $ck"
    ck=$(E $writer "$db" "PRAGMA busy_timeout=200" "PRAGMA wal_checkpoint(RESTART)" | tail -1)
    [ "${ck%%|*}" = 1 ] || fail "$wn: RESTART should be busy with a $rn reader: $ck"
    say 3 "SELECT 'r2', count(*), sum(x) FROM t;"
    wait_for r "^r2|"
    say 3 "COMMIT; SELECT 'r3', count(*), sum(x) FROM t;"
    wait_for r "^r3|"
    [ "$(row r r1)" = "100|5050" ] || fail "$rn snapshot: $(row r r1)"
    [ "$(row r r2)" = "100|5050" ] || fail "$rn lost its snapshot: $(row r r2)"
    [ "$(row r r3)" = "101|6059" ] || fail "$rn after commit: $(row r r3)"
    stop r 3
    ck=$(E $writer "$db" "PRAGMA wal_checkpoint(RESTART)")
    [ "${ck%%|*}" = 0 ] || fail "$wn: RESTART after the reader left: $ck"

    # Writers contend: busy at once without a timeout, waiting with one.
    start h $reader "$db" 3
    say 3 "BEGIN IMMEDIATE; INSERT INTO t VALUES(2000); SELECT 'held';"
    wait_for h "^held"
    if E $writer "$db" "INSERT INTO t VALUES(2001)" > "$tmp/busy.out" 2>&1; then
        fail "$wn wrote while $rn held the write lock"
    fi
    grep -q "database is locked" "$tmp/busy.out" || fail "$wn: $(cat "$tmp/busy.out")"
    E $writer "$db" "PRAGMA busy_timeout=10000" "INSERT INTO t VALUES(2002)" "SELECT 'waited'" > "$tmp/wait.out" 2>&1 &
    waiter=$!
    pids="$pids $waiter"
    sleep 0.3
    say 3 "COMMIT; SELECT 'committed';"
    wait_for h "^committed"
    wait $waiter || fail "$wn: busy_timeout did not wait: $(cat "$tmp/wait.out")"
    grep -q waited "$tmp/wait.out" || fail "$wn: $(cat "$tmp/wait.out")"
    stop h 3
    [ "$(E $reader "$db" "SELECT count(*) FROM t WHERE x >= 2000")" = 2 ] || fail "contended writes lost"
    check "contention ($rn holds)" $writer "$db"
done

# The stress run: 4 processes, 2 per engine, on one database. Transfers
# between accounts keep the total balance constant and log one row each;
# readers check the total twice inside one snapshot; checkpoints of every
# mode run in between. One process per engine uses a tiny cache, so that
# transactions spill frames into the WAL before they commit.
db="$tmp/stress.db"
E s "$db" "PRAGMA journal_mode=WAL" \
    "CREATE TABLE acct(id INTEGER PRIMARY KEY, bal INTEGER NOT NULL)" \
    "CREATE TABLE log(id INTEGER PRIMARY KEY, proc, seq, note BLOB)" "CREATE INDEX log_ps ON log(proc, seq)" \
    "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<200) INSERT INTO acct SELECT i, 1000 FROM c" > /dev/null
gen() { # PROC SEED CACHE SYNC
    awk -v proc="$1" -v seed="$2" -v cache="$3" -v sync="$4" -v n="$stress_txns" 'BEGIN {
        srand(seed)
        printf "PRAGMA busy_timeout=60000;\nPRAGMA cache_size=%d;\nPRAGMA synchronous=%s;\n", cache, sync
        split("PASSIVE FULL RESTART TRUNCATE", modes, " ")
        for (s = 1; s <= n; s++) {
            r = rand()
            if (r < 0.70) {
                a = int(rand() * 200) + 1; b = int(rand() * 200) + 1; v = int(rand() * 100)
                printf "BEGIN IMMEDIATE;\nUPDATE acct SET bal = bal - %d WHERE id = %d;\n", v, a
                if (rand() < 0.1) printf "UPDATE log SET note = zeroblob(%d) WHERE id %% 37 = %d;\n", int(rand() * 900), s % 37
                printf "UPDATE acct SET bal = bal + %d WHERE id = %d;\n", v, b
                printf "INSERT INTO log(proc, seq, note) VALUES(%d, %d, zeroblob(%d));\nCOMMIT;\n", proc, s, int(rand() * 500)
            } else if (r < 0.95) {
                printf "BEGIN;\nSELECT \047sum\047, sum(bal) FROM acct;\nSELECT count(*) FROM log WHERE proc = %d;\n", proc
                printf "SELECT \047sum\047, sum(bal) FROM acct;\nCOMMIT;\n"
            } else {
                printf "PRAGMA wal_checkpoint(%s);\n", modes[int(rand() * 4) + 1]
            }
        }
    }'
}
gen 1 11 10 FULL > "$tmp/st1.sql"
gen 2 22 2000 NORMAL > "$tmp/st2.sql"
gen 3 33 10 NORMAL > "$tmp/st3.sql"
gen 4 44 2000 FULL > "$tmp/st4.sql"
started=$(date +%s)
"$xq" sql "$db" < "$tmp/st1.sql" > "$tmp/st1.out" 2> "$tmp/st1.err" &
p1=$!
"$sq" "$db" < "$tmp/st2.sql" > "$tmp/st2.out" 2> "$tmp/st2.err" &
p2=$!
"$xq" sql "$db" < "$tmp/st3.sql" > "$tmp/st3.out" 2> "$tmp/st3.err" &
p3=$!
"$sq" "$db" < "$tmp/st4.sql" > "$tmp/st4.out" 2> "$tmp/st4.err" &
p4=$!
pids="$pids $p1 $p2 $p3 $p4"
for p in $p1 $p2 $p3 $p4; do wait $p || true; done
elapsed=$(($(date +%s) - started))
for i in 1 2 3 4; do
    [ ! -s "$tmp/st$i.err" ] || fail "stress process $i: $(head -5 "$tmp/st$i.err")"
done
want_log=$(cat "$tmp"/st*.sql | grep -c '^INSERT INTO log')
n_txn=$(cat "$tmp"/st*.sql | grep -c '^COMMIT;')
bad=$(cat "$tmp"/st*.out | grep '^sum|' | grep -vc '^sum|200000$' || true)
[ "$bad" = 0 ] || fail "stress: $bad snapshots saw a wrong total"
n_snap=$(cat "$tmp"/st*.out | grep -c '^sum|')
for e in x s; do
    out=$(Q $e "$db" "$nockpt" "PRAGMA integrity_check" "SELECT sum(bal), count(*) FROM acct" "SELECT count(*), count(DISTINCT proc || '.' || seq) FROM log")
    [ "$out" = "ok
200000|200
$want_log|$want_log" ] || fail "stress: $(name $e) finds: $out"
done
agree "after the stress run" "$db"
echo "   ok: $n_txn transactions ($want_log writes, $n_snap snapshot checks) by 2+2 processes in ${elapsed}s"

echo "interop-wal: ok"
