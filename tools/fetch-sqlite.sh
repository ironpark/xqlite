#!/bin/sh
# Downloads the canonical SQLite source tree used as the porting reference.
# Output: ref/sqlite (git-ignored). Override the version with SQLITE_VERSION / SQLITE_YEAR.
set -eu

SQLITE_YEAR="${SQLITE_YEAR:-2026}"
# Keep in sync with sqlite_version_number in src/root.zig.
SQLITE_VERSION="${SQLITE_VERSION:-3540100}"

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/ref/sqlite"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="https://www.sqlite.org/$SQLITE_YEAR/sqlite-src-$SQLITE_VERSION.zip"
echo "fetching $url"
curl -fsSL -o "$tmp/src.zip" "$url"
unzip -q "$tmp/src.zip" -d "$tmp"

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
mv "$tmp/sqlite-src-$SQLITE_VERSION" "$dest"
echo "$SQLITE_VERSION" > "$dest/.xqlite-version"
echo "sqlite $SQLITE_VERSION -> $dest"
