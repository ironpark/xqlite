#!/bin/sh
# Cross-checks PRAGMA against sqlite3: each pragma runs through `xqlite
# sql` and through sqlite3 on the same database and must print the same
# rows. Files whose header PRAGMA changed (page_size, auto_vacuum,
# user_version, journal_mode, ...) must pass sqlite3's integrity check.
# Needs a prior `zig build`. SQLITE3 names the reference shell, which
# should be 3.54.1 (default: /tmp/xq-sqlite-build/sqlite3 if present,
# else sqlite3 on PATH).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
default_sq=sqlite3
[ -x /tmp/xq-sqlite-build/sqlite3 ] && default_sq=/tmp/xq-sqlite-build/sqlite3
sq="${SQLITE3:-$default_sq}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# Table r has two foreign keys referencing the same parent.
schema="CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE u(name TEXT UNIQUE COLLATE NOCASE);
CREATE TABLE c(x INTEGER NOT NULL DEFAULT 0, y TEXT DEFAULT 'abc', z REAL CHECK(z >= 0),
  pid INTEGER REFERENCES p(id) ON DELETE CASCADE, pname TEXT REFERENCES u(name) ON UPDATE SET NULL,
  g AS (x * 2), PRIMARY KEY(x, y));
CREATE INDEX c_z ON c(z DESC, y);
CREATE INDEX c_part ON c(pid) WHERE pid > 0;
CREATE TABLE w(k TEXT PRIMARY KEY, v BLOB, n INT, UNIQUE(n, k)) WITHOUT ROWID;
CREATE TABLE s(a INT, b TEXT, c ANY) STRICT;
CREATE TABLE e(u, v, FOREIGN KEY(u, v) REFERENCES w(k, n) ON DELETE RESTRICT);
CREATE TABLE q(s, t, FOREIGN KEY(t, s) REFERENCES c(y, x));
CREATE TABLE r(a INTEGER REFERENCES p(id), b INTEGER REFERENCES p(id) ON DELETE SET NULL);
CREATE VIEW vw AS SELECT x, y FROM c;
INSERT INTO p VALUES(1, 'one'), (2, 'two');
INSERT INTO u VALUES('one');
INSERT INTO c(x, y, z, pid, pname) VALUES(1, 'a', 1.5, 1, 'one'), (2, 'b', 2, 3, 'nine'), (3, 'c', NULL, NULL, NULL);
INSERT INTO w VALUES('k1', x'01', 1);
INSERT INTO s VALUES(1, 'x', 2.5);
INSERT INTO e VALUES('k1', 1), ('k2', 2), (NULL, 3);
INSERT INTO q VALUES(1, 'a'), (1, 'b'), (5, NULL);
INSERT INTO r VALUES(1, 2), (3, NULL), (2, 4);"

# Pragmas whose output is the same in both (the order of table_list
# follows SQLite's hash table, so it is sorted).
same="PRAGMA table_info(c);
PRAGMA table_xinfo(c);
PRAGMA table_info(vw);
PRAGMA table_info(w);
PRAGMA table_xinfo(s);
PRAGMA main.table_info(p);
PRAGMA table_info(nosuch);
PRAGMA index_list(c);
PRAGMA index_list(w);
PRAGMA index_list(p);
PRAGMA index_info(c_z);
PRAGMA index_xinfo(c_z);
PRAGMA index_xinfo(c_part);
PRAGMA index_info(w);
PRAGMA index_xinfo(sqlite_autoindex_u_1);
PRAGMA index_xinfo(sqlite_autoindex_w_2);
PRAGMA foreign_key_list(c);
PRAGMA foreign_key_list(e);
PRAGMA foreign_key_check(c);
PRAGMA foreign_key_check(q);
PRAGMA foreign_key_list(q);
PRAGMA foreign_key_list(r);
PRAGMA foreign_key_check(r);
PRAGMA foreign_keys;
PRAGMA foreign_keys=ON;
PRAGMA foreign_keys;
PRAGMA reverse_unordered_selects;
PRAGMA case_sensitive_like=1;
PRAGMA count_changes;
PRAGMA short_column_names;
PRAGMA full_column_names;
PRAGMA legacy_alter_table;
PRAGMA writable_schema;
PRAGMA ignore_check_constraints;
PRAGMA query_only;
PRAGMA automatic_index;
PRAGMA cell_size_check;
PRAGMA defer_foreign_keys;
PRAGMA user_version;
PRAGMA schema_version;
PRAGMA application_id;
PRAGMA data_version;
PRAGMA freelist_count;
PRAGMA page_size;
PRAGMA page_count;
PRAGMA max_page_count;
PRAGMA max_page_count=100000;
PRAGMA cache_size;
PRAGMA cache_size=-4000;
PRAGMA cache_size;
PRAGMA default_cache_size;
PRAGMA cache_spill=OFF; PRAGMA cache_spill;
PRAGMA cache_size=50; PRAGMA cache_spill=200; PRAGMA cache_spill;
PRAGMA auto_vacuum;
PRAGMA encoding;
PRAGMA journal_mode;
PRAGMA journal_size_limit;
PRAGMA wal_autocheckpoint;
PRAGMA wal_autocheckpoint=100;
PRAGMA wal_checkpoint;
PRAGMA wal_checkpoint(TRUNCATE);
PRAGMA locking_mode;
PRAGMA synchronous;
PRAGMA synchronous=NORMAL;
PRAGMA synchronous;
PRAGMA secure_delete;
PRAGMA secure_delete=FAST;
PRAGMA temp_store;
PRAGMA temp_store=MEMORY;
PRAGMA temp_store;
PRAGMA mmap_size;
PRAGMA busy_timeout=250;
PRAGMA threads;
PRAGMA analysis_limit=50;
PRAGMA soft_heap_limit;
PRAGMA shrink_memory;
PRAGMA no_such_pragma;
PRAGMA database_list;
PRAGMA integrity_check;
PRAGMA integrity_check(c);
PRAGMA quick_check;
PRAGMA main.integrity_check(1);"
sorted="PRAGMA table_list;
PRAGMA foreign_key_check;
PRAGMA table_list(c);
PRAGMA temp.table_list;"

compare() { # $1: label, $2: file, $3: statements, $4: sort output
  printf '%s\n' "$3" | while IFS= read -r stmt; do
    "$xq" sql "$2" "$stmt" > "$tmp/xq.out" 2>&1 || true
    "$sq" "$2" "$stmt" > "$tmp/sq.out" 2>&1 || true
    if [ "$4" = 2 ]; then
      # Only the functions both have: sqlite3's shell adds its own.
      sort "$tmp/xq.out" -o "$tmp/xq.out"
      sort "$tmp/sq.out" | comm -12 - "$tmp/xq.out" > "$tmp/both.out"
      mv "$tmp/both.out" "$tmp/sq.out"
    fi
    if [ "$4" = 1 ]; then
      sort "$tmp/xq.out" -o "$tmp/xq.out"
      sort "$tmp/sq.out" -o "$tmp/sq.out"
    fi
    # sqlite3 shows full paths, xqlite the path as given.
    sed 's#|[^|]*/\([^/|]*\)$#|\1#' "$tmp/sq.out" > "$tmp/sq2.out"
    mv "$tmp/sq2.out" "$tmp/sq.out"
    if ! cmp -s "$tmp/xq.out" "$tmp/sq.out"; then
      echo "FAIL $1: $stmt"
      diff "$tmp/xq.out" "$tmp/sq.out" | head -10
      echo x >> "$tmp/failed"
    fi
  done
}

integrity() { # $1: label, $2: file
  ok=$("$sq" "$2" 'PRAGMA integrity_check')
  if [ "$ok" != ok ]; then echo "FAIL $1: sqlite3 integrity_check: $ok"; fail=1; fi
  ok=$("$xq" sql "$2" 'PRAGMA integrity_check')
  if [ "$ok" != ok ]; then echo "FAIL $1: xqlite integrity_check: $ok"; fail=1; fi
}

# 1. Introspection of a database written by sqlite3 (each statement runs
# on its own connection, so settings do not carry over).
cd "$tmp"
"$sq" a.db "$schema"
compare "sqlite3 file" a.db "$same" 0
compare "sqlite3 file" a.db "$sorted" 1
compare "sqlite3 file" a.db "PRAGMA function_list" 2

# 2. The same schema written by xqlite.
"$xq" sql b.db "$schema"
compare "xqlite file" b.db "$same" 0
integrity "xqlite file" b.db

# 3. Header pragmas written by xqlite, read back by both.
"$xq" sql h.db "PRAGMA page_size=8192; PRAGMA auto_vacuum=INCREMENTAL; $schema
PRAGMA user_version=42; PRAGMA application_id=1234; PRAGMA default_cache_size=500;
DELETE FROM c; PRAGMA incremental_vacuum(1);" > /dev/null
compare "header pragmas" h.db "PRAGMA page_size;
PRAGMA auto_vacuum;
PRAGMA user_version;
PRAGMA application_id;
PRAGMA default_cache_size;
PRAGMA freelist_count;
PRAGMA page_count;
PRAGMA schema_version" 0
integrity "header pragmas" h.db

# 4. Full auto-vacuum, and journal modes.
"$xq" sql f.db "PRAGMA auto_vacuum=FULL; $schema DROP TABLE e; DELETE FROM c;" > /dev/null
compare "auto_vacuum=full" f.db "PRAGMA auto_vacuum;
PRAGMA page_count;
PRAGMA freelist_count" 0
integrity "auto_vacuum=full" f.db
# The shell turns on defensive mode, which refuses journal_mode=OFF.
for mode in persist truncate off wal delete; do
  "$xq" sql j.db ".dbconfig defensive off" "PRAGMA journal_mode=$mode; CREATE TABLE IF NOT EXISTS t(a); INSERT INTO t VALUES('$mode');" |
    grep -v '^ *defensive' > "$tmp/jm.out"
  if [ "$(cat "$tmp/jm.out")" != "$mode" ]; then echo "FAIL journal_mode=$mode: $(cat "$tmp/jm.out")"; fail=1; fi
  integrity "journal_mode=$mode" j.db
done
compare "journal modes" j.db "SELECT group_concat(a) FROM t" 0

# 5. Errors found by integrity_check: a NULL in a NOT NULL column and a
# missing index entry, made with writable_schema.
sqw() { "$sq" -cmd ".dbconfig defensive off" "$@" > /dev/null; }
sqw bad.db "CREATE TABLE t(a INTEGER PRIMARY KEY, b NOT NULL, c);
CREATE INDEX t_c ON t(c);
INSERT INTO t VALUES(1, 1, 10), (2, 2, 20), (3, 3, 30);
PRAGMA writable_schema=ON;
UPDATE sqlite_schema SET sql='CREATE TABLE t(a INTEGER PRIMARY KEY, b, c)' WHERE name='t';
UPDATE sqlite_schema SET sql='CREATE INDEX t_c ON t(b)' WHERE name='t_c';"
sqw bad.db "INSERT INTO t VALUES(4, NULL, 40);"
sqw bad.db "PRAGMA writable_schema=ON;
UPDATE sqlite_schema SET sql='CREATE TABLE t(a INTEGER PRIMARY KEY, b NOT NULL, c)' WHERE name='t';
UPDATE sqlite_schema SET sql='CREATE INDEX t_c ON t(c)' WHERE name='t_c';"
compare "corrupt file" bad.db "PRAGMA integrity_check;
PRAGMA quick_check;
PRAGMA integrity_check(2)" 0

[ -f "$tmp/failed" ] && fail=1
[ $fail = 0 ] && echo "interop-pragma: ok"
exit $fail
