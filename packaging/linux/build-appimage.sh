#!/usr/bin/env bash
# Build an AppImage from a Flutter Linux release bundle.
#
# Usage: packaging/linux/build-appimage.sh <bundle_dir> <version> [arch] [out_dir]
#   arch: x86_64 (default) | aarch64
#
# Downloads appimagetool (continuous) if it is not on PATH. Runs it with
# APPIMAGE_EXTRACT_AND_RUN=1 so FUSE is not needed on CI.
# Note: an AppImage cannot carry file capabilities, so melsi-core is started
# via pkexec when TUN is used.
set -euo pipefail

bundle="${1:?bundle dir required}"
version="${2:?version required}"
arch="${3:-x86_64}"
out_dir="${4:-dist}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -x "$bundle/melsi" ]] || { echo "error: $bundle/melsi not found" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
appdir="$work/Melsi.AppDir"
mkdir -p "$appdir"
cp -a "$bundle/." "$appdir/"

cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/melsi" "$@"
RUN
chmod 0755 "$appdir/AppRun"

sed -e 's|^Exec=.*|Exec=melsi %u|' "$here/melsi.desktop" > "$appdir/melsi.desktop"

icon=""
for c in \
  "$root/app/linux/packaging/melsi.png" \
  "$root/app/assets/icon/icon.png" \
  "$root/app/assets/icon.png" \
  "$root/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"; do
  if [[ -f "$c" ]]; then icon="$c"; break; fi
done
[[ -n "$icon" ]] || { echo "error: no icon found" >&2; exit 1; }
cp "$icon" "$appdir/melsi.png"
ln -s melsi.png "$appdir/.DirIcon"

tool="$(command -v appimagetool || true)"
if [[ -z "$tool" ]]; then
  tool="$work/appimagetool"
  curl -fsSL -o "$tool" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$(uname -m).AppImage"
  chmod +x "$tool"
fi

mkdir -p "$out_dir"
out="$out_dir/Melsi-${version}-linux-${arch}.AppImage"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$arch" "$tool" --no-appstream "$appdir" "$out" >&2
echo "$out"
