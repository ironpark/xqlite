#!/bin/sh
# Cross-checks VACUUM, VACUUM INTO and the backup API against sqlite3:
#   1. both engines VACUUM copies of the same database (rollback journal,
#      auto-vacuum, WAL; built by either engine) with page_size and
#      auto_vacuum changes, and the files are byte for byte the same;
#      each engine passes integrity_check on the other's
#   2. the same for VACUUM INTO, with a URI reserve=N
#   3. .backup, .save and .restore (the backup API) of the shells write
#      the same bytes, across page sizes, and each reads the other's copy
#   4. xqlite dies at every write of a VACUUM (XQLITE_TEST_CRASH) and
#      sqlite3 recovers the file to the bytes before or after the VACUUM
#      (or, in WAL mode, the same rows)
#   5. sqlite3 dies at every change of the file or journal in a VACUUM (a
#      preloaded library, built with $CC, as in interop-attach.sh) and
#      xqlite recovers
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

# Tables with holes, indexes (one UNIQUE over a blob), overflow pages in
# a table and a WITHOUT ROWID table, AUTOINCREMENT, sqlite_stat1, a view
# and a trigger, and header fields VACUUM keeps.
content="CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
CREATE INDEX tb ON t(b);
CREATE UNIQUE INDEX tc ON t(c, a);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<400)
INSERT INTO t SELECT i * 7, printf('%.*c', i % 150, 'v'), zeroblob(i % 11 * 700) FROM n;
DELETE FROM t WHERE a % 3 = 0;
CREATE TABLE w(k TEXT PRIMARY KEY, v BLOB) WITHOUT ROWID;
INSERT INTO w SELECT b || a, zeroblob(a % 5000) FROM t;
DELETE FROM w WHERE length(k) % 4 = 0;
CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, x);
INSERT INTO s(x) SELECT a FROM t WHERE a < 200;
CREATE TABLE r(x, y);
INSERT INTO r SELECT b, a FROM t WHERE a % 5 = 1;
CREATE VIEW tv AS SELECT a, b FROM t WHERE a > 10;
CREATE TRIGGER ttr AFTER DELETE ON t BEGIN INSERT INTO s(x) VALUES(old.a); END;
ANALYZE;
PRAGMA user_version = 42;
PRAGMA application_id = 1234;"
# The rows, to compare without the file layout.
rows="SELECT count(*), sum(a), sum(length(b)), sum(length(c)) FROM t;
SELECT count(*), sum(length(v)) FROM w;
SELECT count(*), sum(x) FROM s;
SELECT count(*) FROM r;
SELECT * FROM sqlite_sequence;
PRAGMA user_version;"

# build DIR SHELL PRAGMAS: a database main.db in a new directory DIR.
build() {
  rm -rf "$1" && mkdir "$1"
  (cd "$1" && $2 main.db "$3" "$content" > /dev/null)
}

# The integrity check of FILE by both engines, and its freelist: empty
# after a VACUUM (a backup copies the source's).
free=0
check_both() { # $1: label, $2: file
  for e in "$xq sql" "$sq"; do
    got=$($e "$2" "PRAGMA integrity_check; SELECT freelist_count = $free FROM pragma_freelist_count;" 2>&1 | tr '\n' ' ')
    if [ "$got" != "ok 1 " ]; then echo "FAIL $1: ${e%% *} on $2: $got"; fail=1; fi
  done
}

# Run SQL on a copy of SRC with each engine; the files must be the same.
same_file() { # $1: label, $2: source directory, $3: SQL, $4: file to compare
  rm -rf x s && cp -R "$2" x && cp -R "$2" s
  (cd x && "$xq" sql main.db "$3" > ../x.out 2>&1) || true
  (cd s && "$sq" main.db "$3" > ../s.out 2>&1) || true
  if ! cmp -s x.out s.out; then
    echo "FAIL $1: output"; diff x.out s.out | head -10; fail=1
  fi
  if ! cmp -s "x/$4" "s/$4"; then
    echo "FAIL $1: $4 differs"; cmp "x/$4" "s/$4" | head -3; fail=1
  fi
  check_both "$1" "x/$4"
  n_cases=$((n_cases + 1))
}

vacuums="VACUUM
VACUUM main
PRAGMA page_size=1024; VACUUM
PRAGMA page_size=512; VACUUM
PRAGMA page_size=65536; VACUUM
PRAGMA auto_vacuum=FULL; VACUUM
PRAGMA auto_vacuum=INCREMENTAL; PRAGMA page_size=2048; VACUUM
PRAGMA auto_vacuum=NONE; VACUUM
VACUUM; VACUUM
PRAGMA journal_mode=persist; VACUUM
PRAGMA journal_mode=truncate; PRAGMA page_size=8192; VACUUM
DELETE FROM t WHERE a > 1000; VACUUM"

echo "1) VACUUM writes the same bytes"
n_cases=0
build sq-plain "$sq" ""
build sq-auto "$sq" "PRAGMA auto_vacuum=FULL; PRAGMA page_size=2048;"
build sq-incr "$sq" "PRAGMA auto_vacuum=INCREMENTAL; PRAGMA page_size=16384;"
build sq-wal "$sq" "PRAGMA journal_mode=wal;"
build xq-plain "$xq sql" ""
build xq-auto "$xq sql" "PRAGMA auto_vacuum=FULL; PRAGMA page_size=1024;"
build xq-wal "$xq sql" "PRAGMA journal_mode=wal;"
for d in sq-plain sq-auto sq-incr sq-wal xq-plain xq-auto xq-wal; do
  echo "$vacuums" | while IFS= read -r v; do
    same_file "$d: $v" "$d" "$v" main.db
    [ $fail = 0 ] || exit 1
  done || fail=1
done
# An attached database, and its WAL.
same_file "attached" sq-plain "ATTACH 'main.db' AS m2; VACUUM m2" main.db
[ $fail = 0 ] && echo "   ok"

echo "2) VACUUM INTO writes the same bytes"
n_cases=0
for d in sq-plain sq-auto sq-wal xq-plain; do
  same_file "$d INTO" "$d" "VACUUM INTO 'out.db'" out.db
  same_file "$d INTO, page_size" "$d" "PRAGMA page_size=4096; PRAGMA auto_vacuum=2; VACUUM INTO 'out.db'" out.db
  same_file "$d INTO, reserve" "$d" "VACUUM INTO 'file:out.db?reserve=24'" out.db
  same_file "$d INTO, then VACUUM" "$d" "VACUUM INTO 'file:out.db?reserve=16'; ATTACH 'out.db' AS o; VACUUM o" out.db
  same_file "$d INTO, errors" "$d" "VACUUM INTO 'out.db'; VACUUM INTO 'out.db'; VACUUM INTO 1; VACUUM INTO NULL; VACUUM nosuch; VACUUM temp; BEGIN; VACUUM" out.db
done
[ $fail = 0 ] && echo "   ok"

echo "3) .backup, .save and .restore"
for d in sq-plain sq-auto xq-plain xq-wal; do
  free=$("$sq" "$d/main.db" "PRAGMA freelist_count")
  same_file "$d .backup" "$d" ".backup copy.db" copy.db
  same_file "$d .save" "$d" ".save --async copy.db" copy.db
  for sz in 512 4096 65536; do
    # Into a database of another page size, over content to drop.
    rm -rf r && mkdir r && cp "$d/main.db" r/src.db
    "$sq" r/main.db "PRAGMA page_size=$sz; CREATE TABLE junk(x); INSERT INTO junk VALUES(zeroblob(200000));"
    same_file "$d .restore over page_size $sz" r ".restore src.db" main.db
    # Each engine reads the other's backup.
    (cd r && "$xq" sql src.db ".backup x.db" && "$sq" src.db ".backup s.db")
    for f in x.db s.db; do
      got=$("$sq" "r/$f" "$rows" | shasum)
      if [ "$got" != "$("$xq" sql "r/src.db" "$rows" | shasum)" ]; then echo "FAIL $d: rows of $f"; fail=1; fi
    done
  done
done
free=$("$sq" sq-plain/main.db "PRAGMA freelist_count")
same_file ".backup DB FILE" sq-plain ".backup main copy.db" copy.db
free=0
[ $fail = 0 ] && echo "   ok"

# Crash tests on a smaller database, with a journal sync point to hit.
small="PRAGMA page_size=1024;
CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
CREATE INDEX tb ON t(b);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<150)
INSERT INTO t SELECT i, printf('%.*c', i % 90, 'v'), zeroblob(i % 4 * 400) FROM n;
DELETE FROM t WHERE a % 2 = 0;"
crash_vacuum="PRAGMA page_size=2048; VACUUM; SELECT 'vacuumed';"
mk_small() { # $1: journal mode
  rm -rf base && mkdir base
  "$sq" base/main.db "PRAGMA journal_mode=$1;" "$small" > /dev/null
  # The bytes after the VACUUM (the same for both engines, see 1).
  rm -rf after && cp -R base after
  "$sq" after/main.db "$crash_vacuum" > /dev/null
}

# After a crash, the reader ($2) finds the file as it was before the
# VACUUM or as after it: the bytes in rollback mode (after the commit,
# the file may not be truncated yet), the rows in WAL mode.
recovered() { # $1: label, $2: reader, $3: journal mode
  got=$($2 crash/main.db "PRAGMA integrity_check;" 2>&1 | tr '\n' ' ')
  if [ "$got" != "ok " ]; then echo "FAIL $1: $got"; fail=1; return 0; fi
  if [ "$3" = wal ]; then
    if [ "$($2 crash/main.db "$rows_small")" != "$($sq base/main.db "$rows_small")" ]; then echo "FAIL $1: rows"; fail=1; fi
  elif ! cmp -s crash/main.db base/main.db && ! head -c "$(wc -c < after/main.db | tr -d " ")" crash/main.db | cmp -s - after/main.db; then
    echo "FAIL $1: neither the old nor the vacuumed file"; fail=1
  fi
  return 0
}
rows_small="SELECT count(*), sum(a), sum(length(b)), sum(length(c)) FROM t;"

crash_loop() { # $1: writer function, $2: reader, $3: label, $4: journal mode
  i=1
  while [ $i -le 400 ]; do
    rm -rf crash && cp -R base crash
    out=$($1 $i 2>&1 || true)
    recovered "$3, journal_mode=$4, crash at $i" "$2" "$4"
    n_runs=$((n_runs + 1))
    case "$out" in *vacuumed) return 0 ;; esac
    i=$((i + 1))
  done
  echo "FAIL $3, journal_mode=$4: the VACUUM never got through"; fail=1
}

echo "4) xqlite crashes at each write of a VACUUM, sqlite3 recovers"
n_runs=0
xq_crash_db() { (cd crash && XQLITE_TEST_CRASH=db:$1 "$xq" sql main.db "$crash_vacuum"); }
xq_crash_journal() { (cd crash && XQLITE_TEST_CRASH=journal:$1 "$xq" sql main.db "$crash_vacuum"); }
xq_crash_wal() { (cd crash && XQLITE_TEST_CRASH=wal:$1 "$xq" sql main.db "$crash_vacuum"); }
for mode in delete persist; do
  mk_small $mode
  crash_loop xq_crash_db "$sq" "xqlite, db write" $mode
  crash_loop xq_crash_journal "$sq" "xqlite, journal write" $mode
done
mk_small wal
crash_loop xq_crash_wal "$sq" "xqlite, wal write" wal
crash_loop xq_crash_db "$sq" "xqlite, db write" wal
[ $fail = 0 ] && echo "   ok: $n_runs crashes"

echo "5) sqlite3 crashes at each change in a VACUUM, xqlite recovers"
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
sq_crash_db() { (cd crash && env "$preload=$shim" CRASH_SUFFIX=main.db CRASH_AT=$1 "$sq" main.db "$crash_vacuum"); }
sq_crash_journal() { (cd crash && env "$preload=$shim" CRASH_SUFFIX=main.db-journal CRASH_AT=$1 "$sq" main.db "$crash_vacuum"); }
sq_crash_wal() { (cd crash && env "$preload=$shim" CRASH_SUFFIX=main.db-wal CRASH_AT=$1 "$sq" main.db "$crash_vacuum"); }
# shellcheck disable=SC2086
if ! "$cc" $shim_flags -o "$shim" "$tmp/shim.c" -ldl 2>/dev/null && ! "$cc" $shim_flags -o "$shim" "$tmp/shim.c" 2>/dev/null; then
  echo "   skipped: cannot build the preload library with $cc"
elif [ "$(env "$preload=$shim" CRASH_SUFFIX=probe.db CRASH_AT=1 "$sq" probe.db "CREATE TABLE t(x); SELECT 'alive';" 2>&1)" = alive ]; then
  echo "   skipped: $preload does not reach $sq"
else
  n_runs=0
  for mode in delete persist; do
    mk_small $mode
    crash_loop sq_crash_db "$xq sql" "sqlite3, db write" $mode
    crash_loop sq_crash_journal "$xq sql" "sqlite3, journal write" $mode
  done
  mk_small wal
  crash_loop sq_crash_wal "$xq sql" "sqlite3, wal write" wal
  [ $fail = 0 ] && echo "   ok: $n_runs crashes"
fi

[ $fail = 0 ] || exit 1
echo "interop-vacuum: ok"
