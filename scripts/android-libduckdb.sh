#!/usr/bin/env bash
# Downloads the libduckdb our CI builds for Android
# (.github/workflows/libduckdb-android.yml, a release on this repository) and
# unpacks libduckdb.so and its headers into DIR, checked against
# scripts/libduckdb-android.sha256. The Android build of the ixpipe_duckdb
# NIF links it (mix.exs), and the APK ships it beside the NIF.
#
#   scripts/android-libduckdb.sh <triple or ABI> DIR
set -euo pipefail

VERSION=${LIBDUCKDB_VERSION:-v2.0.0}
REPO=${LIBDUCKDB_REPO:-tznc/ixpipe}
case $1 in
  x86_64 | x86_64-linux-android) abi=x86_64 ;;
  arm64 | arm64-v8a | aarch64-linux-android) abi=arm64-v8a ;;
  *) echo "unknown Android ABI $1" >&2; exit 1 ;;
esac
dir=$2
here=$(cd "$(dirname "$0")" && pwd)
asset=libduckdb-$VERSION-android-$abi.tar.gz
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --retry 3 -o "$tmp/$asset" \
  "https://github.com/$REPO/releases/download/libduckdb-$VERSION/$asset"
expected=$(grep " $asset\$" "$here/libduckdb-android.sha256" | cut -d' ' -f1 || true)
if [[ -z $expected ]]; then
  echo "no checksum for $asset in scripts/libduckdb-android.sha256" >&2
  exit 1
fi
echo "$expected  $tmp/$asset" | sha256sum -c --quiet
mkdir -p "$dir"
tar -xzf "$tmp/$asset" -C "$dir" --strip-components 1
echo "libduckdb $VERSION for $abi in $dir"
