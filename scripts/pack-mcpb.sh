#!/bin/bash
# Stage dist/mcpb/ and pack it into dist/applesauce-<version>.mcpb with the official CLI.
# Needs dist/applesauce from scripts/build-universal.sh. Uses npx, installs nothing globally.
# usage: scripts/pack-mcpb.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Pinned: a newer CLI can change the manifest rules. Change it on purpose.
mcpb_cli="@anthropic-ai/mcpb@2.1.2"

[[ -x dist/applesauce ]] || { echo "pack-mcpb.sh: dist/applesauce is missing. Run scripts/build-universal.sh first." >&2; exit 1; }
scripts/version.sh --check >/dev/null
version="$(scripts/version.sh)"

rm -rf dist/mcpb
mkdir -p dist/mcpb/server
cp mcpb/manifest.json dist/mcpb/manifest.json
cp dist/applesauce dist/mcpb/server/applesauce
cp LICENSE README.md dist/mcpb/
cp assets/icon.png assets/icon-dark.png dist/mcpb/
chmod 755 dist/mcpb/server/applesauce

out="dist/applesauce-$version.mcpb"
rm -f "$out"
npx --yes "$mcpb_cli" validate dist/mcpb/manifest.json
npx --yes "$mcpb_cli" pack dist/mcpb "$out"

# The binary must stay executable and unchanged inside the bundle.
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
unzip -q "$out" -d "$check"
[[ -x "$check/server/applesauce" ]] || { echo "pack-mcpb.sh: server/applesauce is not executable in the bundle" >&2; exit 1; }
cmp dist/applesauce "$check/server/applesauce" || { echo "pack-mcpb.sh: binary changed in the bundle" >&2; exit 1; }
codesign --verify --strict "$check/server/applesauce"
unzip -Z "$out"
echo "packed $out"
