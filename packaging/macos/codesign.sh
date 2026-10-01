#!/usr/bin/env bash
# Sign Melsi.app.
# Usage: packaging/macos/codesign.sh <path/to/App.app> [identity]
#   identity "-" (default) -> ad-hoc signature (runs locally after the user
#                             clears quarantine / right-click > Open)
#   "Developer ID Application: ..." -> hardened runtime + timestamp, ready
#                             for notarization. Nested code is signed
#                             inside-out (melsi-core, frameworks, dylibs, app).
set -euo pipefail

app="${1:?path to .app required}"
identity="${2:--}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
entitlements="${MACOS_ENTITLEMENTS:-$root/app/macos/Runner/Release.entitlements}"

if [[ "$identity" == "-" ]]; then
  codesign --force --deep --sign - "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  exit 0
fi

sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }

# 1. Loose executables and dylibs (melsi-core lives in Contents/Resources).
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then sign "$f"; fi
done < <(find "$app/Contents/Resources" "$app/Contents/MacOS" -type f -perm -u+x -print0 2>/dev/null)
while IFS= read -r -d '' f; do sign "$f"; done \
  < <(find "$app/Contents" -type f -name '*.dylib' -print0)

# 2. Frameworks (deepest first).
if [[ -d "$app/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' fw; do sign "$fw"; done \
    < <(find "$app/Contents/Frameworks" -depth -name '*.framework' -print0)
fi

# 3. The app itself.
if [[ -f "$entitlements" ]]; then
  sign --entitlements "$entitlements" "$app"
else
  sign "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
