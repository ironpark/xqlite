#!/bin/sh
# Downloads the sqllogictest scripts (about 1.2 GB) and the source of the C
# runner, from the GitHub mirror of https://sqlite.org/sqllogictest (the
# fossil site asks browsers to verify themselves, so scripts cannot fetch it).
# Output: ref/sqllogictest (git-ignored).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/ref/sqllogictest"
url="${SLT_REPO:-https://github.com/gregrahn/sqllogictest.git}"

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
echo "cloning $url"
git clone --depth 1 "$url" "$dest"
echo "sqllogictest -> $dest"
