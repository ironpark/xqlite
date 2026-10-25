#!/bin/sh
# Regenerates src/parse/grammar.zig from SQLite's grammar: builds lemon and
# mkkeywordhash from ref/sqlite (tools/fetch-sqlite.sh), runs them on
# parse.y, and converts the parser tables, rule names and keyword list to
# Zig with tools/parser/lemon2zig.zig.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="$root/ref/sqlite"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc="${CC:-/usr/bin/cc}"

cp "$ref/tool/lempar.c" "$ref/src/parse.y" "$tmp/"
"$cc" -O2 -o "$tmp/lemon" "$ref/tool/lemon.c"
"$cc" -O2 -o "$tmp/mkkeywordhash" "$ref/tool/mkkeywordhash.c"
(cd "$tmp" && ./lemon -S parse.y >/dev/null)
"$tmp/mkkeywordhash" > "$tmp/keywordhash.h"
"$cc" -I"$tmp" -o "$tmp/keywords" "$root/tools/parser/keywords.c"
"$tmp/keywords" > "$tmp/keywords.txt"

zig run "$root/tools/parser/lemon2zig.zig" -- \
    "$tmp/parse.c" "$tmp/parse.h" "$tmp/keywords.txt" "$(cat "$ref/VERSION")" \
    > "$root/src/parse/grammar.zig"
zig fmt "$root/src/parse/grammar.zig" >/dev/null
echo "wrote src/parse/grammar.zig"
