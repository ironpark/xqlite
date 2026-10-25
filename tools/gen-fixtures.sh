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
