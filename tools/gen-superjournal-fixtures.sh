#!/bin/sh
# Regenerates src/testdata/superjournal: what sqlite3 leaves on disk when
# it dies during the commit of a transaction over three databases (main,
# a and b) in journal_mode=DELETE, at four points:
#
#   pending      the last change before the super-journal is deleted:
#                the super-journal and every journal exist, b's journal
#                does not name the super-journal yet (must roll back)
#   committed-0  the super-journal is deleted, every journal is left
#   committed-1  main's journal is deleted too
#   committed-2  a's journal is deleted too (all three must be committed)
#
# sqlite3 is killed with tools/crashshim.c (see tools/interop-attach.sh).
# The files are made in /tmp/xqsj, so the super-journal name inside the
# journals is /private/tmp/xqsj/main.db-mj... on macOS. Each state
# directory also holds the super-journal, if any, as "super".
# Requires sqlite3 (SQLITE3) and a C compiler (CC).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
sq="${SQLITE3:-sqlite3}"
cc="${CC:-cc}"
out="$root/src/testdata/superjournal"
work=/tmp/xqsj
case "$(uname)" in
  Darwin) shim="$work.shim.dylib"; "$cc" -dynamiclib -o "$shim" "$root/tools/crashshim.c"; preload=DYLD_INSERT_LIBRARIES ;;
  *) shim="$work.shim.so"; "$cc" -shared -fPIC -o "$shim" "$root/tools/crashshim.c" -ldl; preload=LD_PRELOAD ;;
esac

# Crash at change $1 of a journal; leaves the files in $work.
crash() {
  rm -rf "$work" && mkdir "$work" && cd "$work"
  for f in main a b; do
    "$sq" $f.db "PRAGMA page_size=512; CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); INSERT INTO t VALUES(1, 'old'), (2, 'old');"
  done
  env "$preload=$shim" CRASH_SUFFIX=-journal CRASH_AT=$1 "$sq" main.db "ATTACH 'a.db' AS a; ATTACH 'b.db' AS b;
    BEGIN; UPDATE t SET b = 'new'; UPDATE a.t SET b = 'new'; UPDATE b.t SET b = 'new'; COMMIT;" > /dev/null 2>&1 || true
}

save() { # $1: state name
  rm -rf "${out:?}/$1" && mkdir -p "$out/$1"
  for f in main.db a.db b.db main.db-journal a.db-journal b.db-journal; do
    [ -e "$work/$f" ] && cp "$work/$f" "$out/$1/"
  done
  for f in "$work"/main.db-mj*; do
    [ -e "$f" ] && cp "$f" "$out/$1/super"
  done
  return 0
}

# The first crash point that leaves no super-journal is the unlink of
# main's journal: the super-journal was deleted just before.
i=1
while :; do
  crash $i
  if ! ls "$work"/main.db-mj* > /dev/null 2>&1 && grep -a -q -e -mj "$work/main.db-journal" 2>/dev/null; then break; fi
  i=$((i + 1))
  [ $i -le 100 ] || { echo "no crash point found" >&2; exit 1; }
done
save committed-0
crash $((i - 1)); save pending
crash $((i + 1)); save committed-1
crash $((i + 2)); save committed-2
rm -rf "$work" "$shim"
ls -R "$out"
