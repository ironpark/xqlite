#!/bin/sh
# Regenerates the databases in src/testdata with the sqlite3 shell. The
# content is deterministic; tests check it against the same formulas.
set -eu
cd "$(dirname "$0")/../src/testdata"

# $1: file, $2: auto_vacuum mode (0 or 1). Some builds (Android's) default
# to auto_vacuum=1, so it is always set explicitly.
gen() {
  rm -f "$1"
  sqlite3 "$1" <<SQL
PRAGMA page_size=1024;
PRAGMA auto_vacuum=$2;
CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT, c BLOB, d REAL);
CREATE INDEX t_b ON t(b);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<1000)
INSERT INTO t
  SELECT i,
         printf('row-%05d', (i*7919)%1000),
         CASE WHEN i%97=0 THEN cast(printf('%.*c', 2000+i, char(65+i%26)) AS BLOB)
              ELSE cast(i*i AS TEXT) END,
         i*0.5
  FROM n;
DELETE FROM t WHERE a%5=0 OR a BETWEEN 300 AND 420;
SQL
  sqlite3 "$1" 'PRAGMA integrity_check' | grep -qx ok
}

gen btree.db 0
gen autovacuum.db 1

# The schema and rows src/sql/sql_test.zig queries.
rm -f sql.db
sqlite3 sql.db <<'SQL'
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT, c REAL);
INSERT INTO t1 VALUES(1,'one',1.5),(2,'two',2.5),(3,'three',NULL),(4,'four',4.0),(5,'five',-1);
CREATE INDEX t1_b ON t1(b);
CREATE TABLE t2(x, y);
INSERT INTO t2 VALUES(1,'a'),(2,'b'),(2,'c'),(9,'z');
CREATE TABLE wr(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID;
INSERT INTO wr VALUES('b',2),('a',1),('c',3);
SQL
