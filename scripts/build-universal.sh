#!/bin/bash
# Build a universal (arm64 + x86_64) release binary, sign it, and check it.
# Output: dist/applesauce
# usage: scripts/build-universal.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Build each arch on its own, then join them. A two-arch `swift build` goes through Xcode's build system,
# and Swift 6.1 exits with an error there even when the build succeeds.
# Some Swift versions write both archs to the same folder, so each slice is copied out before the next build.
mkdir -p dist/slices
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch"
  built="$(swift build -c release --arch "$arch" --show-bin-path)/applesauce"
  [[ -x "$built" ]] || { echo "build-universal.sh: no $arch binary at $built" >&2; exit 1; }
  cp "$built" "dist/slices/applesauce-$arch"
  echo "$arch: $(lipo -archs "dist/slices/applesauce-$arch")"
done
lipo -create dist/slices/applesauce-arm64 dist/slices/applesauce-x86_64 -output dist/applesauce
rm -rf dist/slices
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
scripts/build-app.sh
