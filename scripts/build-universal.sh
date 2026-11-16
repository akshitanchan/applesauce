#!/bin/bash
# Build a universal (arm64 + x86_64) release binary, sign it, and check it.
# Output: dist/applesauce
# usage: scripts/build-universal.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

swift build -c release --arch arm64 --arch x86_64

# Older SwiftPM versions fail on --show-bin-path with two archs, so fall back to the folder they use.
bin_path="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null || true)"
built=""
found="$(find .build -path '*Products/Release/applesauce' -type f -perm -u+x 2>/dev/null | head -n 1)"
for candidate in "$bin_path/applesauce" ".build/apple/Products/Release/applesauce" "$found"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then built="$candidate"; break; fi
done
[[ -n "$built" ]] || { echo "build-universal.sh: cannot find the built binary" >&2; exit 1; }
echo "binary: $built"
mkdir -p dist
cp "$built" dist/applesauce
scripts/sign.sh dist/applesauce

archs="$(lipo -archs dist/applesauce)"
echo "archs: $archs"
for arch in arm64 x86_64; do
  [[ " $archs " == *" $arch "* ]] || { echo "build-universal.sh: $arch is missing" >&2; exit 1; }
done

details="$(codesign -dv dist/applesauce 2>&1)"
echo "$details" | grep -E "^(Identifier|Info.plist|Signature)"
echo "$details" | grep -q "^Identifier=dev.applesauce$" \
  || { echo "build-universal.sh: identifier is not dev.applesauce" >&2; exit 1; }
echo "$details" | grep -q "^Info.plist entries=" \
  || { echo "build-universal.sh: Info.plist is not bound to the signature" >&2; exit 1; }
codesign --verify --strict dist/applesauce

echo "built dist/applesauce $(dist/applesauce --version)"
