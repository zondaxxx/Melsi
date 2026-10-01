#!/usr/bin/env bash
# Build a drag-to-Applications DMG.
# Usage: packaging/macos/build-dmg.sh <path/to/App.app> <output.dmg>
# Uses create-dmg (brew install create-dmg) for a styled window; falls back to
# a plain `hdiutil create` image if create-dmg is missing or fails.
# Optional background: packaging/macos/dmg-background.png (660x400).
set -euo pipefail

app="${1:?path to .app required}"
out="${2:?output .dmg required}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="$(basename "$app")"
volname="Melsi"

mkdir -p "$(dirname "$out")"
rm -f "$out"

if command -v create-dmg >/dev/null 2>&1; then
  args=(
    --volname "$volname"
    --window-pos 200 120
    --window-size 660 400
    --icon-size 128
    --icon "$name" 170 190
    --hide-extension "$name"
    --app-drop-link 490 190
    --no-internet-enable
  )
  vol_icon="$app/Contents/Resources/AppIcon.icns"
  [[ -f "$vol_icon" ]] && args+=(--volicon "$vol_icon")
  [[ -f "$here/dmg-background.png" ]] && args+=(--background "$here/dmg-background.png")

  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  ditto "$app" "$stage/$name"
  # create-dmg drives Finder via AppleScript; on headless CI that can time
  # out, so retry once with --skip-jenkins (no window styling) before giving up.
  if create-dmg "${args[@]}" "$out" "$stage" \
     || { rm -f "$out"; create-dmg "${args[@]}" --skip-jenkins "$out" "$stage"; }; then
    echo "$out"
    exit 0
  fi
  echo "warning: create-dmg failed, falling back to hdiutil" >&2
  rm -f "$out"
fi

plain="$(mktemp -d)"
ditto "$app" "$plain/$name"
ln -s /Applications "$plain/Applications"
hdiutil create -volname "$volname" -srcfolder "$plain" -ov -format UDZO -fs HFS+ "$out"
rm -rf "$plain"
echo "$out"
