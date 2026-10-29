#!/bin/sh
# Differential test of the MariaDB dialect: runs each case of
# tools/dialect/maria-cases.txt in a MariaDB server (the mariadb client,
# batch mode) and in `xqlite sql` with `.dialect mariadb`, and compares
# the results: rows, column names (of results with rows) and the
# "ERROR:" lines.
#
# The server is reached with $MARIA_CLIENT, by default a container:
#   podman run -d --name xq-maria -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:11
#   tools/dialect/maria-diff.sh [cases-file]
# Each case starts from an empty database called main (xqlite's schema),
# with utf8mb4_general_ci as the collation. Numbers with a fraction are
# compared without trailing zeros (MariaDB's DECIMAL prints 3.5000, the
# dialect's REAL 3.5). Requires a prior `zig build`.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
xq="$root/zig-out/bin/xqlite"
cases="${1:-$root/tools/dialect/maria-cases.txt}"
client="${MARIA_CLIENT:-podman exec -i xq-maria mariadb -uroot}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One file per case, and their names.
awk -v dir="$tmp" '
  /^-- case:/ { n++; f = sprintf("%s/%03d.sql", dir, n); sub(/^-- case: */, ""); print > (dir "/" sprintf("%03d", n) ".name"); next }
  n > 0 { print > f }
' "$cases"

# Fields with a fraction lose their trailing zeros (and a trailing dot).
norm_num='{ for (i = 1; i <= NF; i++) if ($i ~ /^-?[0-9]+\.[0-9]+$/) { sub(/0+$/, "", $i); sub(/\.$/, "", $i) } print }'

# The client prints tab-separated rows with a header line per result
# (none for an empty one) and, with --force, the statement that failed
# between dashed lines; errors become "ERROR: message".
norm_maria() {
  awk -F'\t' -v OFS='|' '
    /^--------------$/ { echoed = !echoed; if (!echoed) blank = 1; next }
    echoed { next }
    blank && /^$/ { blank = 0; next }
    { blank = 0 }
    /^ERROR [0-9]+ \([0-9A-Z]+\)( at line [0-9]+)?: / { sub(/^ERROR [0-9]+ \([0-9A-Z]+\)( at line [0-9]+)?: /, "ERROR: "); print; next }
    { $1 = $1; print }
  ' | awk -F'|' -v OFS='|' "$norm_num"
}

norm_xq() {
  awk '
    /^(Parse error|Error|Runtime error) near line [0-9]+: / { sub(/^[^:]*: /, "ERROR: "); print; skip = 1; next }
    skip && /^  / { next }
    { skip = 0; print }
  ' | awk -F'|' -v OFS='|' "$norm_num"
}

fail=0
total=0
for f in "$tmp"/*.sql; do
  total=$((total + 1))
  name=$(cat "${f%.sql}.name")
  { echo "DROP DATABASE IF EXISTS main; CREATE DATABASE main CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; USE main; SET NAMES utf8mb4 COLLATE utf8mb4_general_ci;"; cat "$f"; } |
    $client --batch --raw --force --unbuffered 2>&1 | norm_maria > "$tmp/maria.out"
  { echo ".dialect mariadb"; echo ".headers on"; echo ".nullvalue NULL"; cat "$f"; } |
    "$xq" sql 2>&1 | norm_xq > "$tmp/xq.out"
  if ! cmp -s "$tmp/maria.out" "$tmp/xq.out"; then
    echo "DIFF $name"
    diff "$tmp/maria.out" "$tmp/xq.out" | sed 's/^/  /' | head -40
    fail=$((fail + 1))
  fi
done
echo "maria-diff: $((total - fail))/$total cases agree"
[ $fail = 0 ]
