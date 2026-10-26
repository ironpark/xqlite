#!/bin/sh
# Cross-checks the `xqlite sql` shell against the sqlite3 command-line
# shell: the same scripts (every output mode, headers, nullvalue,
# separators, .tables/.schema/.indexes/.dump, errors) must give the same
# standard output, standard error and exit code, and the .dump output of
# xqlite must rebuild the database in sqlite3.
# Compares against $SQLITE3, else /tmp/xq-sqlite-build/sqlite3 (a 3.54.1
# build, the version xqlite ports), else sqlite3 on PATH; older shells
# format some output differently. Requires a prior `zig build`.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
default_sq=sqlite3
[ -x /tmp/xq-sqlite-build/sqlite3 ] && default_sq=/tmp/xq-sqlite-build/sqlite3
sq="${SQLITE3:-$default_sq}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/x" "$tmp/s"

cat > "$tmp/schema.sql" <<'EOF'
CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c REAL, d BLOB);
INSERT INTO t VALUES(1,'hello',1.5,x'00ff10');
INSERT INTO t VALUES(2,NULL,0.1,NULL);
INSERT INTO t VALUES(3,'it''s, "quoted"',1e100,'');
INSERT INTO t VALUES(4,'line1
line2',-2.5e-7,x'');
INSERT INTO t VALUES(5,'tab	here',123456789012345678,'x');
INSERT INTO t VALUES(6,'ünï ☃ wide 漢字',3.0,'ctl' || char(1) || 'z');
INSERT INTO t VALUES(7,'a long value that has to be wrapped in narrow columns',-0.0,42);
CREATE INDEX t_b ON t(b);
CREATE TABLE "odd name"("a b" TEXT, "select" INT);
INSERT INTO "odd name" VALUES('x y', 7);
CREATE TABLE s(id INTEGER PRIMARY KEY AUTOINCREMENT, v);
INSERT INTO s(v) VALUES('one'),('two');
CREATE TABLE w(k TEXT PRIMARY KEY, v) WITHOUT ROWID;
INSERT INTO w VALUES('a',1),('b',2.25),('c',NULL);
CREATE VIEW vt AS SELECT a, b FROM t WHERE a < 3;
CREATE UNIQUE INDEX s_v ON s(v);
CREATE INDEX w_v ON w(v) WHERE v IS NOT NULL;
EOF

# Every output mode, with and without headers.
{
  for m in list csv tabs line column quote insert box table markdown json \
           jobject html tcl ascii psql qbox split count off; do
    printf '.print == %s\n.mode %s\nSELECT * FROM t ORDER BY a;\n' "$m" "$m"
    printf '.headers on\nSELECT * FROM t WHERE a<3 ORDER BY a;\nSELECT 1 WHERE 0;\n'
    printf '.headers off\nSELECT k, v FROM w ORDER BY k;\n'
  done
} > "$tmp/modes.txt"

cat > "$tmp/dot.txt" <<'EOF'
.tables
.tables %e%
.indexes
.indexes s
.schema
.schema s
.schema --nosys
.schema sqlite_schema
.schema odd%
.schema "odd name"
.mode
.headers on
.separator ; "\n--\n"
SELECT * FROM w ORDER BY k;
.separator , \r\n
SELECT * FROM w ORDER BY k;
.separator |
.nullvalue <null>
SELECT b FROM t WHERE a=2;
.mode insert foo
.mode
SELECT * FROM "odd name";
.mode quote
SELECT * FROM w ORDER BY k;
.mode csv
.mode
.mode column
SELECT * FROM t WHERE 0;
.headers off
.mode column
SELECT * FROM t WHERE 0;
SELECT a, b FROM t ORDER BY a;
.mode line
SELECT a AS longername, b FROM t WHERE a < 3 ORDER BY a;
.mode list
.changes on
INSERT INTO w VALUES('d', 3);
UPDATE w SET v = v + 1 WHERE v > 1;
.changes off
.echo on
SELECT 1;
.echo off
.print hello   world 'x y' "tab\there"
.show
SELECT 1; SELECT 2,
  3;
SELECT 'a;b'; -- trailing
SELECT
  4
;
-- comment only
/* block */
SELECT 5; SELEC 6; SELECT 7;
SELECT * FROM nosuch;
INSERT INTO s(v) VALUES('one');
SELECT abs(-9223372036854775807-1);
SELECT 12345678901234567890123456789012345678901234567890, 1 +;
.bogus
.headers maybe
.bail
.mode nosuch
.mode box --wrap
.mode box --wrap 10
SELECT b, a FROM t ORDER BY a;
.mode table --border off
SELECT 1 AS a, 'xyz' AS b;
.mode box --limits 2,12,4
SELECT b AS longtitle, d FROM t ORDER BY a;
.mode line --limits 2,10
SELECT * FROM t WHERE a=4;
.mode qbox --sw 50
SELECT * FROM t ORDER BY a;
.mode list --quote relaxed
SELECT 'a', '1', 1, '', NULL;
.mode -v
.mode tty
.mode
.mode batch
.headers always
SELECT 1 WHERE 0;
.mode insert --multiinsert 60
SELECT * FROM t ORDER BY a;
.mode list
.bail on
SELECT 8;
SELECT bad syntax here;
SELECT 9;
EOF

cat > "$tmp/dump.txt" <<'EOF'
.dump
.dump t
.dump --data-only w
.dump --nosys
.dump s%
.mode tty
.dump w
.dump --bogus
EOF

fail=0
# Runs input file $2 through both shells on copies of database $3, in
# directories where both are named db; $1 labels the check.
check() {
  for d in x s; do rm -f "$tmp/$d/db"; cp "$3" "$tmp/$d/db"; done
  set +e
  (cd "$tmp/x" && "$xq" sql db < "$2" > out 2> err; echo "exit $?" >> out)
  (cd "$tmp/s" && "$sq" db < "$2" > out 2> err; echo "exit $?" >> out)
  set -e
  for f in out err; do
    if ! cmp -s "$tmp/x/$f" "$tmp/s/$f"; then
      echo "FAIL $1: std$f differs (< xqlite, > sqlite3)"
      diff "$tmp/x/$f" "$tmp/s/$f" | head -20
      fail=1
    fi
  done
}

# The sample database, written by sqlite3 and by xqlite.
"$sq" "$tmp/a.db" < "$tmp/schema.sql"
"$xq" sql "$tmp/b.db" < "$tmp/schema.sql"
for db in a b; do
  check "modes ($db.db)" "$tmp/modes.txt" "$tmp/$db.db"
  check "dot-commands ($db.db)" "$tmp/dot.txt" "$tmp/$db.db"
  check "dump ($db.db)" "$tmp/dump.txt" "$tmp/$db.db"
done

# SQL and dot-commands as command-line arguments.
args_check() {
  rm -f "$tmp/x/c.db" "$tmp/s/c.db"
  set +e
  (cd "$tmp/x" && "$xq" sql c.db "$@" > out 2> err; echo "exit $?" >> out)
  (cd "$tmp/s" && "$sq" c.db "$@" > out 2> err; echo "exit $?" >> out)
  set -e
  for f in out err; do
    if ! cmp -s "$tmp/x/$f" "$tmp/s/$f"; then
      echo "FAIL arguments $*: std$f differs"; diff "$tmp/x/$f" "$tmp/s/$f" | head -10; fail=1
    fi
  done
}
args_check "CREATE TABLE a(x); INSERT INTO a VALUES(1),(2)" ".mode csv" "SELECT x, 'p,q' FROM a"
args_check "SELECT 1; SELEC 2" "SELECT 3"
args_check ".bogus" "SELECT 3"
args_check ".mode box" "SELECT 1 AS one, NULL AS two"

# Reading files, nested errors, .bail, .exit and .quit.
printf 'SELECT 41;\nSELEC oops;\n.print in-file\n.read missing.sql\n' > "$tmp/x/inc.sql"
cp "$tmp/x/inc.sql" "$tmp/s/inc.sql"
printf '.read inc.sql\nSELECT 42;\n.bail on\n.read inc.sql\nSELECT 43;\n' > "$tmp/read.txt"
check "read" "$tmp/read.txt" "$tmp/a.db"
printf 'SELECT 1;\n.exit 3\nSELECT 2;\n' > "$tmp/exit.txt"
check "exit" "$tmp/exit.txt" "$tmp/a.db"
printf 'SELECT 1;\n.quit\nSELECT 2;\n' > "$tmp/quit.txt"
check "quit" "$tmp/quit.txt" "$tmp/a.db"
printf 'SELECT (1\n' > "$tmp/incomplete.txt"
check "incomplete input" "$tmp/incomplete.txt" "$tmp/a.db"

# The .dump of xqlite rebuilds the database in sqlite3, which dumps it
# back the same.
"$xq" sql "$tmp/b.db" .dump > "$tmp/xq.dump"
"$sq" "$tmp/r.db" < "$tmp/xq.dump"
ok=$("$sq" "$tmp/r.db" 'PRAGMA integrity_check')
if [ "$ok" != ok ]; then echo "FAIL dump round trip: integrity_check: $ok"; fail=1; fi
"$sq" "$tmp/r.db" .dump > "$tmp/sq.dump"
if ! cmp -s "$tmp/xq.dump" "$tmp/sq.dump"; then
  echo "FAIL dump round trip differs"; diff "$tmp/xq.dump" "$tmp/sq.dump" | head -20; fail=1
fi

[ $fail = 0 ] && echo "interop-shell: ok"
exit $fail
