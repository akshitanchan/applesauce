#!/bin/bash
# Ad-hoc sign the applesauce binary so its embedded Info.plist is bound to the signature.
# A linker-only signature leaves the plist unbound, and macOS then shows no privacy prompt.
# usage: scripts/sign.sh <path-to-binary>
set -euo pipefail
bin="${1:?usage: scripts/sign.sh <path-to-binary>}"
codesign --force --sign - --identifier dev.applesauce "$bin"
codesign --display --verbose=2 "$bin" 2>&1 | grep -E "Identifier|Info.plist"
