#!/bin/bash
# Stage dist/npm/ and pack it into dist/applesauce-<version>.tgz.
# Needs dist/applesauce from scripts/build-universal.sh.
# usage: scripts/pack-npm.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

[[ -x dist/applesauce ]] || { echo "pack-npm.sh: dist/applesauce is missing. Run scripts/build-universal.sh first." >&2; exit 1; }
scripts/version.sh --check >/dev/null
version="$(scripts/version.sh)"

rm -rf dist/npm
mkdir -p dist/npm/bin
cp npm/package.json dist/npm/package.json
cp dist/applesauce dist/npm/bin/applesauce
cp README.md LICENSE dist/npm/
chmod 755 dist/npm/bin/applesauce

# --ignore-scripts: the package has no scripts, and none may run here.
tarball="$(cd dist/npm && npm pack --ignore-scripts --pack-destination "$root/dist" --silent)"
echo "packed dist/$tarball"

# The binary must stay executable and unchanged inside the tarball.
[[ "$tarball" == "applesauce-$version.tgz" ]] || { echo "pack-npm.sh: unexpected file name $tarball" >&2; exit 1; }
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
tar -xzf "dist/$tarball" -C "$check"
[[ -x "$check/package/bin/applesauce" ]] || { echo "pack-npm.sh: bin/applesauce is not executable in the tarball" >&2; exit 1; }
cmp dist/applesauce "$check/package/bin/applesauce" || { echo "pack-npm.sh: binary changed in the tarball" >&2; exit 1; }
codesign --verify --strict "$check/package/bin/applesauce"
tar -tzvf "dist/$tarball"
