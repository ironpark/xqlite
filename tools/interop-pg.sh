#!/bin/sh
# Cross-checks the PostgreSQL dialect against sqlite3: a database written
# by `xqlite sql` in the PostgreSQL dialect (STRICT tables, CHECKs,
# identity sequences, the xq_catalog/xq_sequence catalog, views, indexes)
# must pass sqlite3's integrity check, and sqlite3 and xqlite (in the
# SQLite dialect) must read the same rows and schema from it.
# Requires sqlite3 on PATH and a prior `zig build`.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
xq="$root/zig-out/bin/xqlite"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/pg.sql" <<'EOF'
.dialect postgres
CREATE TABLE account (
  id bigserial PRIMARY KEY,
  email varchar(80) NOT NULL UNIQUE,
  active boolean NOT NULL DEFAULT true,
  balance numeric(12,2) DEFAULT 0 CHECK (balance >= 0),
  created_at timestamptz DEFAULT now(),
  meta jsonb
);
CREATE TABLE entry (
  id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id bigint REFERENCES account (id) ON DELETE CASCADE,
  amount int NOT NULL,
  memo text COLLATE "C"
);
CREATE INDEX ON entry (account_id, amount DESC);
CREATE UNIQUE INDEX account_lower_email ON account (lower(email));
CREATE SEQUENCE ticket START WITH 100 INCREMENT BY 10;
INSERT INTO account (email, balance, meta) SELECT 'user' || n || '@example.com', n * 1.5, '{"n": ' || n || '}' FROM generate_series(1, 300) AS g(n);
INSERT INTO entry (account_id, amount, memo) SELECT 1 + n % 300, n, 'm' || n FROM generate_series(1, 2000) AS g(n);
UPDATE account SET active = false WHERE id % 7 = 0 RETURNING id;
DELETE FROM entry e USING account a WHERE a.id = e.account_id AND NOT a.active;
INSERT INTO account (email) VALUES ('user1@example.com') ON CONFLICT (email) DO UPDATE SET balance = account.balance + 1;
CREATE VIEW totals AS SELECT a.email, count(e.id) AS n, sum(e.amount) AS total FROM account a LEFT JOIN entry e ON e.account_id = a.id GROUP BY a.email ORDER BY total DESC NULLS LAST;
SELECT nextval('ticket'), nextval('ticket');
ALTER TABLE entry ADD COLUMN tag varchar(8);
CREATE TABLE gone (x int); DROP TABLE gone;
EOF
queries="SELECT count(*), sum(id), sum(balance), sum(active) FROM account;
SELECT count(*), sum(amount), min(memo), max(memo) FROM entry;
SELECT * FROM totals LIMIT 5;
SELECT * FROM xq_catalog ORDER BY tbl, col, key;
SELECT * FROM xq_sequence ORDER BY name;
SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name;"

fail=0
"$xq" sql "$tmp/pg.db" < "$tmp/pg.sql" > /dev/null
ok=$(sqlite3 "$tmp/pg.db" 'PRAGMA integrity_check')
if [ "$ok" != ok ]; then echo "FAIL integrity_check: $ok"; fail=1; fi
fk=$(sqlite3 "$tmp/pg.db" 'PRAGMA foreign_key_check')
if [ -n "$fk" ]; then echo "FAIL foreign_key_check: $fk"; fail=1; fi
"$xq" sql "$tmp/pg.db" "$queries" > "$tmp/xq.out"
sqlite3 "$tmp/pg.db" "$queries" > "$tmp/sq.out"
if ! cmp -s "$tmp/xq.out" "$tmp/sq.out"; then
  echo "FAIL results differ"; diff "$tmp/xq.out" "$tmp/sq.out" | head -20; fail=1
fi
# sqlite3 enforces the STRICT types and the checks of the PostgreSQL types.
for bad in "INSERT INTO entry(account_id, amount) VALUES (1, 'x')" \
           "INSERT INTO entry(account_id, amount, tag) VALUES (1, 1, 'too long tag')" \
           "INSERT INTO entry(account_id, amount) VALUES (1, 3000000000)" \
           "UPDATE account SET active = 2 WHERE id = 1"; do
  if sqlite3 "$tmp/pg.db" "$bad" 2>/dev/null; then echo "FAIL sqlite3 accepted: $bad"; fail=1; fi
done
# The PostgreSQL dialect reads back what sqlite3 changed. The next id is
# 302: the INSERT ... ON CONFLICT DO UPDATE took 301, as in PostgreSQL.
sqlite3 "$tmp/pg.db" "UPDATE account SET balance = balance + 1 WHERE id = 2"
got=$(printf '.dialect postgres\nSELECT balance FROM account WHERE id = 2;\nINSERT INTO account (email) VALUES ($$new@x$$) RETURNING id;\n' | "$xq" sql "$tmp/pg.db")
if [ "$got" != "$(printf '4.0\n302')" ]; then echo "FAIL read back: $got"; fail=1; fi

[ $fail = 0 ] && echo "interop-pg: ok"
exit $fail
