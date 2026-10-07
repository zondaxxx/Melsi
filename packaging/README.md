# Packaging

CI lives in `.github/workflows/build.yml`; it calls the scripts below. Every
artifact is named `Melsi-<version>-<platform>-<arch>.<ext>`, where `<version>`
comes from `scripts/version.sh` (tag `v1.2.3` gives `1.2.3`; otherwise the
pubspec version plus `-<short sha>`).

| Platform | Script | Output |
|---|---|---|
| Linux | `linux/build-deb.sh <bundle> <ver> amd64 dist` | `.deb`: `/opt/melsi`, `/usr/bin/melsi`, desktop entry, URL handlers |
| Linux | `linux/build-appimage.sh <bundle> <ver> x86_64 dist` | `.AppImage` |
| macOS | `macos/codesign.sh <App.app> [identity]` | ad-hoc (`-`) or Developer ID + hardened runtime |
| macOS | `macos/build-dmg.sh <App.app> <out.dmg>` | DMG from create-dmg, or from hdiutil if create-dmg fails |
| macOS | `macos/notarize.sh <out.dmg>` | notarytool + staple |
| Windows | `windows/melsi.iss` (`iscc /DAppVersion=… /DSourceDir=… /DOutputDir=…`) | `-setup.exe` |

## Linux: TUN without a password prompt

sing-box TUN needs `CAP_NET_ADMIN`. The `.deb` `postinst` runs

    setcap cap_net_admin,cap_net_bind_service,cap_net_raw+ep /opt/melsi/melsi-core

so `melsi-core` can create the TUN device without `pkexec`. The tar.gz and
AppImage builds cannot carry file capabilities. With those builds the app falls
back to `pkexec`, or you can run the `setcap` command above on the extracted
`melsi-core` yourself.

## CI secrets (all optional)

| Secret | Used for |
|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | Android release signing. Without them, APKs use the debug key. |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID Application signing. Without them, the app is ad-hoc signed. |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Notarization of the DMG. This also requires the certificate secrets. |

The iOS IPA is always unsigned. The Packet Tunnel extension needs a team that
has the Network Extension entitlement, so re-sign the IPA with one. The
unsigned build declares the App Group `group.app.melsi`. After a re-sign
(GBox and similar tools) the app uses that group when its container is
writable, and otherwise a group from the provisioning profile. The profile's
group id does not have to be `group.app.melsi`; the app and the PacketTunnel
extension must both be signed with that group.
Windows arm64 is not built because Flutter needs an arm64 host for it.

## Xray-core

Desktop release jobs run `scripts/fetch-xray.sh` before packaging. It downloads
the pinned XTLS/Xray-core release, checks the zip SHA256, and installs `xray`
(or `xray.exe`) next to `melsi-core`, plus `XRAY-LICENSE`. The macOS binary is
a universal lipo of the arm64 and x64 official builds. Phones do not get a
binary; the app refuses to connect while Xray is selected.

The same jobs overwrite `melsi-core` in the bundle with the binary
`scripts/build-core.sh` just produced, so the shipped daemon is the one from
that commit.
