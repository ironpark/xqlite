#!/bin/sh
# Cross-checks ATTACH and multi-database transactions against sqlite3:
#   1. each engine attaches files the other wrote and changes them; the
#      rows and integrity_check of every file match
#   2. the statements of a script over attached databases (pragmas,
#      sqlite_schema, temp triggers, views, DETACH, errors) print the same
#   3. a transaction over three files committed by one engine is read
#      back by the other, in each rollback journal mode
#   4. xqlite dies at every write of such a commit (XQLITE_TEST_CRASH),
#      and sqlite3 recovers both files to the old or both to the new rows
#      and deletes the super-journal
#   5. sqlite3 dies at every write, truncation or delete of such a commit
#      (a preloaded library, built with $CC, ends the process at the Nth
#      one), and xqlite recovers
# Requires a prior `zig build`. SQLITE3 names the sqlite3 shell (default:
# /tmp/xq-sqlite-build/sqlite3 if it exists, else sqlite3 on PATH).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
sq="${SQLITE3:-}"
if [ -z "$sq" ]; then
  if [ -x /tmp/xq-sqlite-build/sqlite3 ]; then sq=/tmp/xq-sqlite-build/sqlite3; else sq=sqlite3; fi
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
fail=0

schema="CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);
CREATE INDEX t_b ON t(b);
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<500)
INSERT INTO t SELECT n, 'v' || (n % 31) FROM c;"
change="ATTACH 'aux.db' AS aux;
CREATE TABLE IF NOT EXISTS aux.u(x INTEGER PRIMARY KEY, y UNIQUE, z);
INSERT OR REPLACE INTO aux.u(y, z) SELECT b || '-' || a, a * 2 FROM main.t WHERE a % 3 = 0;
DELETE FROM aux.u WHERE x % 7 = 0;
UPDATE main.t SET b = upper(b) WHERE a IN (SELECT z FROM aux.u);
CREATE INDEX IF NOT EXISTS aux.uz ON u(z);"
queries="ATTACH 'aux.db' AS aux;
SELECT count(*), sum(a), min(b), max(b) FROM t;
SELECT count(*), sum(x), min(y), max(z) FROM aux.u;
SELECT count(*) FROM t JOIN aux.u ON u.z = t.a;
SELECT name, type FROM aux.sqlite_schema ORDER BY name;
PRAGMA aux.integrity_check;
PRAGMA integrity_check;"

same() { # $1: label, $2: statements (in the current directory)
  "$xq" sql main.db "$2" > "$tmp/xq.out" 2>&1 || true
  "$sq" main.db "$2" > "$tmp/sq.out" 2>&1 || true
  if ! cmp -s "$tmp/xq.out" "$tmp/sq.out"; then
    echo "FAIL $1"; diff "$tmp/xq.out" "$tmp/sq.out" | head -20; fail=1
  fi
}

echo "1) attach each other's files"
mkdir one && cd one
"$sq" main.db "$schema"
"$xq" sql main.db "$change"
same "xqlite changed sqlite3's files" "$queries"
"$sq" main.db "$change"
"$xq" sql main.db "$change"
same "both changed the files" "$queries"
cd .. && mkdir two && cd two
"$xq" sql main.db "$schema"
"$sq" main.db "$change"
"$xq" sql main.db "$change"
same "xqlite's files changed by both" "$queries"
cd ..
[ $fail = 0 ] && echo "   ok"

echo "2) the same output for a script over attached databases"
mkdir script && cd script
"$sq" main.db "$schema"
"$sq" aux.db "CREATE TABLE u(x INTEGER PRIMARY KEY, y); INSERT INTO u VALUES(1, 'a'), (2, 'b');"
same "attach script" "ATTACH 'aux.db' AS aux;
ATTACH 'aux.db' AS aux;
ATTACH 'other.db' AS MAIN;
ATTACH 'x.db' AS temp;
ATTACH 'file:aux.db?mode=ro' AS ro;
SELECT * FROM ro.u;
ATTACH ':memory:' AS m;
ATTACH '' AS e;
ATTACH 'file:nope.db?mode=rw' AS n;
ATTACH 'file:aux.db?mode=bogus' AS n;
ATTACH 'nodir/x.db' AS n;
PRAGMA database_list;
SELECT seq, name FROM pragma_database_list;
PRAGMA aux.table_info(u);
SELECT * FROM pragma_table_info('u', 'aux');
PRAGMA aux.user_version = 9;
PRAGMA aux.user_version;
PRAGMA aux.page_count;
PRAGMA aux.journal_mode;
PRAGMA aux.journal_mode = wal;
INSERT INTO aux.u VALUES(3, 'c');
PRAGMA aux.wal_checkpoint;
PRAGMA aux.journal_mode = delete;
SELECT name, sql FROM aux.sqlite_master;
CREATE VIEW aux.v AS SELECT y FROM u;
CREATE VIEW aux.v2 AS SELECT * FROM main.t;
SELECT * FROM aux.v;
CREATE TEMP TRIGGER tr AFTER INSERT ON aux.u BEGIN INSERT INTO m.log VALUES(new.y); END;
CREATE TABLE m.log(y);
INSERT INTO aux.u VALUES(4, 'd');
SELECT * FROM m.log;
CREATE TRIGGER aux.tr2 AFTER INSERT ON u BEGIN INSERT INTO main.t VALUES(1, 2); END;
BEGIN; INSERT INTO aux.u VALUES(5, 'e'); DETACH aux; COMMIT;
DETACH aux;
DETACH aux;
DETACH main;
SELECT name, tbl_name FROM temp.sqlite_schema;
PRAGMA database_list;"
cd ..
[ $fail = 0 ] && echo "   ok"

# The journal mode is the connection's: it is set again for the commit.
txn() { # $1: journal mode
  echo "ATTACH 'a.db' AS a; ATTACH 'b.db' AS b; PRAGMA journal_mode=$1;
BEGIN; UPDATE t SET b = 'new'; UPDATE a.t SET b = 'new'; UPDATE b.t SET b = 'new'; COMMIT;
SELECT 'committed';"
}
check3="ATTACH 'a.db' AS a; ATTACH 'b.db' AS b;
SELECT (SELECT group_concat(DISTINCT b) FROM main.t) || (SELECT group_concat(DISTINCT b) FROM a.t) || (SELECT group_concat(DISTINCT b) FROM b.t);
PRAGMA main.integrity_check; PRAGMA a.integrity_check; PRAGMA b.integrity_check;"
three() { # $1: shell, $2: journal mode: three files with the same table
  for f in main a b; do
    $1 $f.db "PRAGMA journal_mode=$2; PRAGMA page_size=1024; CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT);
      WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<300)
      INSERT INTO t SELECT n, 'old' FROM c;" > /dev/null
  done
}

echo "3) a transaction over three files"
for mode in delete persist truncate; do
  for writer in xq sq; do
    rm -rf txn && mkdir txn && cd txn
    if [ $writer = xq ]; then three "$sq" $mode; "$xq" sql main.db "$(txn $mode)" > /dev/null; reader="$sq"
    else three "$xq sql" $mode; "$sq" main.db "$(txn $mode)" > /dev/null; reader="$xq sql"; fi
    got=$($reader main.db "$check3" | tr '\n' ' ')
    if [ "$got" != "newnewnew ok ok ok " ]; then echo "FAIL $mode, written by $writer: $got"; fail=1; fi
    if ls ./*-mj* > /dev/null 2>&1; then echo "FAIL $mode, written by $writer: super-journal left"; fail=1; fi
    cd ..
  done
done
[ $fail = 0 ] && echo "   ok"

# After a crash at write $2 of a commit, the other engine ($3) must find
# all three files old or all new. (A crash before a journal names the
# super-journal orphans it, in sqlite3 too.)
recovered() { # $1: label, $2: crash point, $3: reader
  got=$($3 main.db "$check3" | tr '\n' ' ')
  case "$got" in
    "oldoldold ok ok ok "|"newnewnew ok ok ok ") ;;
    *) echo "FAIL $1, crash at $2: $got"; fail=1 ;;
  esac
  return 0
}

# Crash the writer ($1, run as "$1 CRASH_POINT") at each write of the
# commit in turn, until a run gets through it; $2 reads back.
crash_loop() { # $1: writer function, $2: reader, $3: label
  i=1
  while [ $i -le 200 ]; do
    rm -rf crash && mkdir crash && cd crash
    three "$sq" $mode
    out=$($1 $i 2>&1 || true)
    recovered "$3, journal_mode=$mode" "$i" "$2"
    cd ..
    n_runs=$((n_runs + 1))
    case "$out" in *committed) return 0 ;; esac
    i=$((i + 1))
  done
  echo "FAIL $3, journal_mode=$mode: the commit never got through"; fail=1
}

echo "4) xqlite crashes at each write of the commit, sqlite3 recovers"
xq_crash_db() { XQLITE_TEST_CRASH=db:$1 "$xq" sql main.db "$(txn $mode)"; }
xq_crash_journal() { XQLITE_TEST_CRASH=journal:$1 "$xq" sql main.db "$(txn $mode)"; }
n_runs=0
for mode in delete persist truncate; do
  crash_loop xq_crash_db "$sq" "xqlite, db write"
  crash_loop xq_crash_journal "$sq" "xqlite, journal write"
done
[ $fail = 0 ] && echo "   ok: $n_runs crashes"

echo "5) sqlite3 crashes at each change of a file in the commit, xqlite recovers"
cc="${CC:-cc}"
cat > "$tmp/shim.c" <<'C'
/* _exit(0) at the CRASH_AT-th change (a write, a truncation or an unlink)
** of a file whose name ends with CRASH_SUFFIX. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
static int matches(const char *path){
  const char *suffix = getenv("CRASH_SUFFIX");
  size_t n, m;
  if( suffix==0 ) return 0;
  n = strlen(path); m = strlen(suffix);
  return n>=m && strcmp(path+n-m, suffix)==0;
}
static int fd_matches(int fd){
  char path[4096];
#ifdef __APPLE__
  if( fcntl(fd, F_GETPATH, path)==-1 ) return 0;
#else
  { char link[64]; ssize_t got;
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    got = readlink(link, path, sizeof(path)-1);
    if( got<0 ) return 0;
    path[got] = 0; }
#endif
  return matches(path);
}
static void tick(int hit){
  static int count = 0;
  const char *at = getenv("CRASH_AT");
  if( at && hit && ++count==atoi(at) ) _exit(0);
}
#ifdef __APPLE__
static ssize_t my_pwrite(int fd, const void *b, size_t n, off_t o){ tick(fd_matches(fd)); return pwrite(fd, b, n, o); }
static ssize_t my_write(int fd, const void *b, size_t n){ tick(fd_matches(fd)); return write(fd, b, n); }
static int my_ftruncate(int fd, off_t n){ tick(fd_matches(fd)); return ftruncate(fd, n); }
static int my_unlink(const char *path){ tick(matches(path)); return unlink(path); }
__attribute__((used)) static struct { const void *a, *b; } interposers[]
  __attribute__((section("__DATA,__interpose"))) = {
  { (const void*)my_pwrite, (const void*)pwrite },
  { (const void*)my_write, (const void*)write },
  { (const void*)my_ftruncate, (const void*)ftruncate },
  { (const void*)my_unlink, (const void*)unlink },
};
#else
#define NEXT(name, type) static type real; if( !real ) real = (type)dlsym(RTLD_NEXT, name)
ssize_t pwrite(int fd, const void *b, size_t n, off_t o){
  NEXT("pwrite", ssize_t(*)(int, const void*, size_t, off_t));
  tick(fd_matches(fd)); return real(fd, b, n, o);
}
ssize_t pwrite64(int fd, const void *b, size_t n, off_t o){
  NEXT("pwrite64", ssize_t(*)(int, const void*, size_t, off_t));
  tick(fd_matches(fd)); return real(fd, b, n, o);
}
ssize_t write(int fd, const void *b, size_t n){
  NEXT("write", ssize_t(*)(int, const void*, size_t));
  tick(fd_matches(fd)); return real(fd, b, n);
}
int ftruncate(int fd, off_t n){
  NEXT("ftruncate", int(*)(int, off_t));
  tick(fd_matches(fd)); return real(fd, n);
}
int ftruncate64(int fd, off_t n){
  NEXT("ftruncate64", int(*)(int, off_t));
  tick(fd_matches(fd)); return real(fd, n);
}
int unlink(const char *path){
  NEXT("unlink", int(*)(const char*));
  tick(matches(path)); return real(path);
}
#endif
C
case "$(uname)" in
  Darwin) shim="$tmp/shim.dylib"; shim_flags="-dynamiclib"; preload=DYLD_INSERT_LIBRARIES ;;
  *) shim="$tmp/shim.so"; shim_flags="-shared -fPIC"; preload=LD_PRELOAD ;;
esac
sq_crash_db() { env "$preload=$shim" CRASH_SUFFIX=.db CRASH_AT=$1 "$sq" main.db "$(txn $mode)"; }
sq_crash_journal() { env "$preload=$shim" CRASH_SUFFIX=-journal CRASH_AT=$1 "$sq" main.db "$(txn $mode)"; }
# shellcheck disable=SC2086
if ! "$cc" $shim_flags -o "$shim" "$tmp/shim.c" -ldl 2>/dev/null && ! "$cc" $shim_flags -o "$shim" "$tmp/shim.c" 2>/dev/null; then
  echo "   skipped: cannot build the preload library with $cc"
elif [ "$(env "$preload=$shim" CRASH_SUFFIX=probe.db CRASH_AT=1 "$sq" probe.db "CREATE TABLE t(x); SELECT 'alive';" 2>&1)" = alive ]; then
  echo "   skipped: $preload does not reach $sq"
else
  n_runs=0
  for mode in delete persist truncate; do
    crash_loop sq_crash_db "$xq sql" "sqlite3, db write"
    crash_loop sq_crash_journal "$xq sql" "sqlite3, journal write"
  done
  [ $fail = 0 ] && echo "   ok: $n_runs crashes"
fi

[ $fail = 0 ] || exit 1
echo "interop-attach: ok"
