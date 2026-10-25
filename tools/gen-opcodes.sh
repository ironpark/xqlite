#!/bin/sh
# Regenerates src/vdbe/opcodes.zig: runs SQLite's mkopcodeh.tcl and
# mkopcodec.tcl over parse.h and vdbe.c (from ref/sqlite, see
# tools/fetch-sqlite.sh) and converts the result to Zig. Needs tclsh and
# a C compiler (for lemon, to make parse.h).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="$root/ref/sqlite"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cc="${CC:-/usr/bin/cc}"

cp "$ref/tool/lempar.c" "$ref/src/parse.y" "$tmp/"
"$cc" -O2 -o "$tmp/lemon" "$ref/tool/lemon.c"
(cd "$tmp" && ./lemon -S parse.y >/dev/null)
cat "$tmp/parse.h" "$ref/src/vdbe.c" | tclsh "$ref/tool/mkopcodeh.tcl" > "$tmp/opcodes.h"
tclsh "$ref/tool/mkopcodec.tcl" "$tmp/opcodes.h" > "$tmp/opcodes.c"
mkdir -p "$root/src/vdbe"
zig run "$root/tools/vdbe/opcodes2zig.zig" -- \
    "$tmp/opcodes.h" "$tmp/opcodes.c" "$(cat "$ref/VERSION")" \
    > "$root/src/vdbe/opcodes.zig"
zig fmt "$root/src/vdbe/opcodes.zig" >/dev/null
echo "wrote src/vdbe/opcodes.zig"
