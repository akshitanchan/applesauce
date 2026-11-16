#!/bin/bash
# Wrap dist/applesauce in dist/applesauce.app, sign the bundle, and check it.
# The app bundle gives applesauce its own icon in permission prompts and notifications.
# Needs dist/applesauce from scripts/build-universal.sh.
# usage: scripts/build-app.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

[[ -x dist/applesauce ]] || { echo "build-app.sh: dist/applesauce is missing. Run scripts/build-universal.sh first." >&2; exit 1; }

app=dist/applesauce.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp dist/applesauce "$app/Contents/MacOS/applesauce"

# Info.plist: the embedded one, plus the keys a bundle needs. LSUIElement keeps it out of the Dock.
cp Support/Info.plist "$app/Contents/Info.plist"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $(scripts/version.sh)" "$plist"

# The icon, in every size macOS asks for.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"

codesign --force -s - --identifier dev.applesauce "$app"
codesign --verify --strict --deep "$app"
details="$(codesign -dv "$app" 2>&1)"
echo "$details" | grep -q "^Identifier=dev.applesauce$" \
  || { echo "build-app.sh: identifier is not dev.applesauce" >&2; exit 1; }
"$app/Contents/MacOS/applesauce" --version >/dev/null
echo "built $app $("$app/Contents/MacOS/applesauce" --version)"
