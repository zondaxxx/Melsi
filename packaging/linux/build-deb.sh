#!/usr/bin/env bash
# Build a Debian package from a Flutter Linux release bundle.
#
# Usage: packaging/linux/build-deb.sh <bundle_dir> <version> [deb_arch] [out_dir]
#   bundle_dir  build/linux/<x64|arm64>/release/bundle (must contain `melsi`
#               and should contain `melsi-core`)
#   version     e.g. 1.2.3 or 1.0.0-abc1234 (hyphens become '~' for dpkg)
#   deb_arch    amd64 (default) | arm64
#   out_dir     default: dist
#
# Layout: /opt/melsi/<bundle>, /usr/bin/melsi -> /opt/melsi/melsi,
# /usr/share/applications/melsi.desktop, hicolor icon.
# postinst grants melsi-core CAP_NET_ADMIN (+bind/raw) so sing-box TUN works
# without a pkexec prompt.
set -euo pipefail

bundle="${1:?bundle dir required}"
version="${2:?version required}"
arch="${3:-amd64}"
out_dir="${4:-dist}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -x "$bundle/melsi" ]] || { echo "error: $bundle/melsi not found or not executable" >&2; exit 1; }
if [[ ! -f "$bundle/melsi-core" ]]; then
  echo "warning: $bundle/melsi-core missing; TUN mode will not work" >&2
fi

# dpkg versions must start with a digit; '-' would be read as a Debian revision.
deb_version="${version//-/\~}"
[[ "$deb_version" =~ ^[0-9] ]] || deb_version="0~${deb_version}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="$work/melsi_${deb_version}_${arch}"

install -d "$pkg/DEBIAN" "$pkg/opt/melsi" "$pkg/usr/bin" \
  "$pkg/usr/share/applications" "$pkg/usr/share/icons/hicolor/256x256/apps" \
  "$pkg/usr/share/doc/melsi"

cp -a "$bundle/." "$pkg/opt/melsi/"
chmod 0755 "$pkg/opt/melsi/melsi"
[[ -f "$pkg/opt/melsi/melsi-core" ]] && chmod 0755 "$pkg/opt/melsi/melsi-core"
[[ -f "$pkg/opt/melsi/xray" ]] && chmod 0755 "$pkg/opt/melsi/xray"
ln -s /opt/melsi/melsi "$pkg/usr/bin/melsi"

# .desktop: prefer the app's own file, otherwise generate one.
desktop_src="$root/app/linux/packaging/melsi.desktop"
if [[ -f "$desktop_src" ]]; then
  install -m 0644 "$desktop_src" "$pkg/usr/share/applications/melsi.desktop"
else
  install -m 0644 "$here/melsi.desktop" "$pkg/usr/share/applications/melsi.desktop"
fi

# Icon: first existing candidate wins.
icon=""
for c in \
  "$root/app/linux/packaging/melsi.png" \
  "$root/app/assets/icon/icon.png" \
  "$root/app/assets/icon.png" \
  "$root/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"; do
  if [[ -f "$c" ]]; then icon="$c"; break; fi
done
if [[ -n "$icon" ]]; then
  install -m 0644 "$icon" "$pkg/usr/share/icons/hicolor/256x256/apps/melsi.png"
else
  echo "warning: no icon found" >&2
fi

cat > "$pkg/usr/share/doc/melsi/copyright" <<'COPY'
Melsi VPN client. Bundles sing-box (GPL-3.0-or-later),
https://github.com/SagerNet/sing-box

Desktop packages also bundle Xray-core (MPL-2.0),
https://github.com/XTLS/Xray-core
The license text is /opt/melsi/XRAY-LICENSE.
COPY

installed_size="$(du -sk "$pkg" | cut -f1)"

cat > "$pkg/DEBIAN/control" <<CTRL
Package: melsi
Version: ${deb_version}
Architecture: ${arch}
Maintainer: Melsi <noreply@melsi.app>
Installed-Size: ${installed_size}
Depends: libgtk-3-0 | libgtk-3-0t64, libcap2-bin
Recommends: libayatana-appindicator3-1, pkexec | policykit-1
Section: net
Priority: optional
Homepage: https://github.com/zondaxxx/melsi
Description: Melsi VPN client
 Cross-platform proxy/VPN client built on sing-box with smart
 server auto-selection and a game booster mode.
CTRL

cat > "$pkg/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  if [ -f /opt/melsi/melsi-core ] && command -v setcap >/dev/null 2>&1; then
    setcap cap_net_admin,cap_net_bind_service,cap_net_raw+ep /opt/melsi/melsi-core || \
      echo "melsi: setcap failed; melsi-core will be started via pkexec instead" >&2
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  fi
fi
exit 0
POST

cat > "$pkg/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "upgrade" ]; then
  pkill -x melsi-core 2>/dev/null || true
fi
exit 0
PRERM

cat > "$pkg/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
fi
exit 0
POSTRM
chmod 0755 "$pkg/DEBIAN/postinst" "$pkg/DEBIAN/prerm" "$pkg/DEBIAN/postrm"

mkdir -p "$out_dir"
out="$out_dir/Melsi-${version}-linux-${arch}.deb"
dpkg-deb --root-owner-group --build -Zxz "$pkg" "$out" >/dev/null
echo "$out"
