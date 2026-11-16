#!/bin/bash
# Stage dist/npm/ and pack it into dist/applesauce-<version>.tgz.
# Needs dist/applesauce.app from scripts/build-universal.sh.
# usage: scripts/pack-npm.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

[[ -x dist/applesauce.app/Contents/MacOS/applesauce ]] || { echo "pack-npm.sh: dist/applesauce.app is missing. Run scripts/build-universal.sh first." >&2; exit 1; }
scripts/version.sh --check >/dev/null
version="$(scripts/version.sh)"

rm -rf dist/npm
mkdir -p dist/npm
cp npm/package.json dist/npm/package.json
cp -R dist/applesauce.app dist/npm/applesauce.app
cp README.md LICENSE dist/npm/

# --ignore-scripts: the package has no scripts, and none may run here.
tarball="$(cd dist/npm && npm pack --ignore-scripts --pack-destination "$root/dist" --silent)"
echo "packed dist/$tarball"

# The binary must stay executable and unchanged inside the tarball.
[[ "$tarball" == "applesauce-$version.tgz" ]] || { echo "pack-npm.sh: unexpected file name $tarball" >&2; exit 1; }
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
tar -xzf "dist/$tarball" -C "$check"
binary="$check/package/applesauce.app/Contents/MacOS/applesauce"
[[ -x "$binary" ]] || { echo "pack-npm.sh: the app's binary is not executable in the tarball" >&2; exit 1; }
cmp dist/applesauce.app/Contents/MacOS/applesauce "$binary" || { echo "pack-npm.sh: binary changed in the tarball" >&2; exit 1; }
codesign --verify --strict --deep "$check/package/applesauce.app"
tar -tzvf "dist/$tarball"
