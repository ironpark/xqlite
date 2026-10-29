#!/bin/sh
# Differential test of the PostgreSQL dialect: runs each case of
# tools/dialect/pg-cases.txt in a PostgreSQL server (psql) and in
# `xqlite sql` with `.dialect postgres`, and compares the results: rows,
# column names (of results with rows) and the "ERROR:" lines.
#
# The server is reached with $PG_PSQL, by default a container:
#   podman run -d --name xq-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine
#   tools/dialect/pg-diff.sh [cases-file]
# Each case starts from an empty public schema. Requires a prior
# `zig build`.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
xq="$root/zig-out/bin/xqlite"
cases="${1:-$root/tools/dialect/pg-cases.txt}"
psql="${PG_PSQL:-podman exec -i xq-pg psql -U postgres}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One file per case, and their names.
awk -v dir="$tmp" '
  /^-- case:/ { n++; f = sprintf("%s/%03d.sql", dir, n); sub(/^-- case: */, ""); print > (dir "/" sprintf("%03d", n) ".name"); next }
  n > 0 { print > f }
' "$cases"

# psql prints a header and "(N rows)" for every result: keep the header
# only above rows, as the shell does. Errors become "ERROR: message".
# Booleans print as t/f, which the dialect returns as integers 1/0.
norm_pg() {
  awk -F'|' -v OFS='|' '
    /^(psql:[^ ]* )?ERROR: / { sub(/^(psql:[^ ]* )?ERROR: +/, "ERROR: "); print; next }
    /^(LINE [0-9]+:|DETAIL:|HINT:|CONTEXT:|NOTICE:|psql:)/ { skip = 1; next }
    skip && /^ / { next }
    { skip = 0 }
    /^\([0-9]+ rows?\)$/ { n = $0; gsub(/[^0-9]/, "", n); if (n + 0 > 0) printf "%s", buf; buf = ""; next }
    { for (i = 1; i <= NF; i++) { if ($i == "t") $i = 1; else if ($i == "f") $i = 0 } buf = buf $0 "\n" }
    END { printf "%s", buf }
  '
}

norm_xq() {
  awk '
    /^(Parse error|Error|Runtime error) near line [0-9]+: / { sub(/^[^:]*: /, "ERROR: "); print; skip = 1; next }
    skip && /^  / { next }
    { skip = 0; print }
  '
}

fail=0
total=0
for f in "$tmp"/*.sql; do
  total=$((total + 1))
  name=$(cat "${f%.sql}.name")
  { echo "SET client_min_messages = warning; DROP SCHEMA public CASCADE; CREATE SCHEMA public;"; cat "$f"; } |
    $psql -q -A -F'|' 2>&1 | norm_pg > "$tmp/pg.out"
  { echo ".dialect postgres"; echo ".headers on"; cat "$f"; } |
    "$xq" sql 2>&1 | norm_xq > "$tmp/xq.out"
  if ! cmp -s "$tmp/pg.out" "$tmp/xq.out"; then
    echo "DIFF $name"
    diff "$tmp/pg.out" "$tmp/xq.out" | sed 's/^/  /' | head -40
    fail=$((fail + 1))
  fi
done
echo "pg-diff: $((total - fail))/$total cases agree"
[ $fail = 0 ]
