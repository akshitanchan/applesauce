#!/bin/bash
# Print the version from Sources/AppleSauceCore/Version.swift.
# With --check, fail when another file disagrees.
# usage: scripts/version.sh [--check]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

version="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$root/Sources/AppleSauceCore/Version.swift")"
[[ -n "$version" ]] || { echo "version.sh: no version in Version.swift" >&2; exit 1; }

case "${1:-}" in
"")
  echo "$version"
  ;;
--check)
  plist="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Support/Info.plist")"
  npm_version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$root/npm/package.json")"
  mcpb_version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$root/mcpb/manifest.json")"
  status=0
  printf '%-34s %s\n' "Sources/AppleSauceCore/Version.swift" "$version"
  for entry in "Support/Info.plist:$plist" "npm/package.json:$npm_version" "mcpb/manifest.json:$mcpb_version"; do
    file="${entry%%:*}"
    found="${entry#*:}"
    printf '%-34s %s\n' "$file" "${found:-missing}"
    [[ "$found" == "$version" ]] || status=1
  done
  if [[ $status -ne 0 ]]; then
    echo "version.sh: versions differ. Make them match Version.swift." >&2
    exit 1
  fi
  echo "versions match"
  ;;
*)
  echo "usage: scripts/version.sh [--check]" >&2
  exit 2
  ;;
esac
