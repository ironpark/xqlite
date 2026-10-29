#!/bin/sh
# Cross-checks the MariaDB dialect against sqlite3: a database written by
# `xqlite sql` in the MariaDB dialect (STRICT tables, named CHECKs,
# DEFAULT and generated-column expressions, AUTO_INCREMENT, "t$i"
# indexes renamed with their table, views, the xq_catalog catalog) must
# pass sqlite3's integrity check, and sqlite3 and xqlite (in the SQLite
# dialect) must read the same rows and schema from it: what the schema
# keeps is SQLite text that means what the MariaDB statement meant. The
# expressions here need no engine function (xq_*), which sqlite3 lacks;
# those are checked inside xqlite (src/dialect/mariadb/test.zig).
# Requires sqlite3 on PATH (or $SQLITE3) and a prior `zig build`.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
sqlite3="${SQLITE3:-sqlite3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/maria.sql" <<'EOF'
.dialect mariadb
CREATE TABLE account (
  id int unsigned NOT NULL AUTO_INCREMENT,
  email varchar(80) NOT NULL,
  name varchar(40) NOT NULL DEFAULT (UCASE('anon')),
  balance decimal(12,2) DEFAULT 0 CHECK (balance >= 0),
  half double AS (balance / 2) STORED,
  label varchar(60) AS (CONCAT(name, ':', IF(balance > 100, 'big', 'small'))) VIRTUAL,
  meta json,
  created_at datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_email (email),
  KEY idx_name (name, balance DESC),
  CONSTRAINT chk_email CHECK (email LIKE '%@%' AND CHAR_LENGTH(email) > 3)
) ENGINE=InnoDB AUTO_INCREMENT=10 DEFAULT CHARSET=utf8mb4;
CREATE TABLE entry (
  id int AUTO_INCREMENT PRIMARY KEY,
  account_id int unsigned NOT NULL,
  amount int NOT NULL,
  ratio double DEFAULT (7 / 2),
  memo varchar(20) COLLATE utf8mb4_bin,
  KEY (memo),
  FOREIGN KEY (account_id) REFERENCES account (id) ON DELETE CASCADE,
  CHECK (amount BETWEEN -1000 AND 1000 || amount = 9999)
);
INSERT INTO account (email, balance, meta) VALUES ('a@x.org', 10, '{"n": 1}'), ('B@x.org', 250.5, NULL), ('c@x.org', 0, '[]');
INSERT INTO entry (account_id, amount, memo) VALUES (10, 5, 'Aa'), (10, -7, 'aa'), (11, 9999, NULL), (12, 1, 'z');
UPDATE account SET balance = balance + 1 WHERE email = 'A@X.ORG';
CREATE VIEW totals AS SELECT a.email, count(e.id) AS n, sum(e.amount) AS total, GREATEST(a.balance, 100) / 4 AS g, a.email LIKE 'a\_%' AS under FROM account a LEFT JOIN entry e ON e.account_id = a.id GROUP BY a.email ORDER BY a.email;
RENAME TABLE entry TO ledger;
ALTER TABLE ledger ADD COLUMN tag varchar(8) DEFAULT 'tag';
CREATE TABLE gone (x int); DROP TABLE gone;
EOF
queries="SELECT id, email, name, balance, half, label, meta, length(created_at) FROM account ORDER BY id;
SELECT id, account_id, amount, ratio, memo, tag FROM ledger ORDER BY id;
SELECT * FROM totals;
SELECT count(*) FROM ledger WHERE memo = 'aa';
SELECT * FROM xq_catalog ORDER BY tbl, col, key;
SELECT * FROM sqlite_sequence ORDER BY name;
SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;"

fail=0
"$xq" sql "$tmp/maria.db" < "$tmp/maria.sql" > /dev/null
ok=$("$sqlite3" "$tmp/maria.db" 'PRAGMA integrity_check')
if [ "$ok" != ok ]; then echo "FAIL integrity_check: $ok"; fail=1; fi
fk=$("$sqlite3" "$tmp/maria.db" 'PRAGMA foreign_key_check')
if [ -n "$fk" ]; then echo "FAIL foreign_key_check: $fk"; fail=1; fi
"$xq" sql "$tmp/maria.db" "$queries" > "$tmp/xq.out"
"$sqlite3" "$tmp/maria.db" "$queries" > "$tmp/sq.out"
if ! cmp -s "$tmp/xq.out" "$tmp/sq.out"; then
  echo "FAIL results differ"; diff "$tmp/xq.out" "$tmp/sq.out" | head -20; fail=1
fi
# The indexes were renamed with their table.
idx=$("$sqlite3" "$tmp/maria.db" "SELECT group_concat(name, ' ') FROM (SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name)")
if [ "$idx" != 'account$idx_name account$uq_email ledger$memo' ]; then echo "FAIL index names: $idx"; fail=1; fi
# sqlite3 enforces the STRICT types, the CHECKs and the unique key
# (case-insensitively, as MariaDB).
for bad in "INSERT INTO account(email) VALUES ('nobody')" \
           "INSERT INTO account(email, balance) VALUES ('d@x.org', -1)" \
           "INSERT INTO account(email, meta) VALUES ('e@x.org', 'not json')" \
           "INSERT INTO account(email) VALUES ('C@X.ORG')" \
           "INSERT INTO ledger(account_id, amount) VALUES (10, 5000)" \
           "INSERT INTO ledger(account_id, amount) VALUES (10, 'x')"; do
  if "$sqlite3" "$tmp/maria.db" "$bad" 2>/dev/null; then echo "FAIL sqlite3 accepted: $bad"; fail=1; fi
done
# sqlite3's rows get the defaults and generated values the MariaDB
# dialect's do, and the AUTO_INCREMENT counter moves on.
"$sqlite3" "$tmp/maria.db" "INSERT INTO account(email, balance) VALUES ('s@x.org', 300); INSERT INTO ledger(account_id, amount) VALUES (13, 2)"
got=$(printf '.dialect mariadb\nSELECT id, name, half, label FROM account WHERE email = %s;\nSELECT ratio, tag FROM ledger WHERE account_id = 13;\nINSERT INTO account (email) VALUES (%s);\nSELECT LAST_INSERT_ID();\n' "'S@X.ORG'" "'t@x.org'" | "$xq" sql "$tmp/maria.db")
if [ "$got" != "$(printf '13|ANON|150.0|ANON:big\n3.5|tag\n14')" ]; then echo "FAIL read back: $got"; fail=1; fi
ok=$("$sqlite3" "$tmp/maria.db" 'PRAGMA integrity_check')
if [ "$ok" != ok ]; then echo "FAIL integrity_check after writes: $ok"; fail=1; fi

[ $fail = 0 ] && echo "interop-mariadb: ok"
exit $fail
