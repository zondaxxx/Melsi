#!/usr/bin/env bash
# Download the pinned official Xray-core build and verify its SHA256.
#
#   scripts/fetch-xray.sh [goos] [goarch|universal]
#
# Official release: https://github.com/XTLS/Xray-core/releases/tag/v26.3.27
# The SHA256 is the SHA2-256 line of that release's .dgst file.
#
# Writes:
#   core/dist/xray-<goos>-<goarch>[.exe]
#   core/dist/xray-darwin-universal   (darwin universal, via lipo)
#   core/dist/XRAY-LICENSE            (MPL-2.0 text from the zip)
#
# Geo databases in the zip are not installed. Melsi only needs the binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/core/dist}"
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"

GOOS_T="${1:-$(go env GOOS 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')}"
GOARCH_T="${2:-$(go env GOARCH 2>/dev/null || uname -m)}"
case "$GOOS_T" in
  Darwin) GOOS_T=darwin ;;
  Linux) GOOS_T=linux ;;
  MINGW*|MSYS*|Windows_NT) GOOS_T=windows ;;
esac
case "$GOARCH_T" in
  x86_64) GOARCH_T=amd64 ;;
  aarch64|arm64) GOARCH_T=arm64 ;;
esac

# asset zip, pinned sha256, name inside the zip, output filename
spec_for() {
  local goos="$1" goarch="$2"
  case "${goos}/${goarch}" in
    linux/amd64)
      echo "Xray-linux-64.zip 23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae xray xray-linux-amd64"
      ;;
    windows/amd64)
      echo "Xray-windows-64.zip d004c39288ce9ada487c6f398c7c545f7d749e44bdfdd59dbc9f865afba4e1ad xray.exe xray-windows-amd64.exe"
      ;;
    darwin/amd64)
      echo "Xray-macos-64.zip f5b0471d3459eff1b82e48af0aeac186abcc3298210070afbbbd8437a4e8b203 xray xray-darwin-amd64"
      ;;
    darwin/arm64)
      echo "Xray-macos-arm64-v8a.zip 2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf xray xray-darwin-arm64"
      ;;
    *)
      echo "error: no pinned Xray asset for ${goos}/${goarch}" >&2
      exit 1
      ;;
  esac
}

sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

fetch_one() {
  local goos="$1" goarch="$2"
  local asset expect inner outname
  read -r asset expect inner outname < <(spec_for "$goos" "$goarch")
  local tmp zip got
  tmp="$(mktemp -d)"
  zip="$tmp/$asset"
  echo ">> Xray ${XRAY_VERSION} ${goos}/${goarch} <- ${asset}"
  curl -fL --retry 3 --retry-delay 2 -o "$zip" "${BASE_URL}/${asset}"
  got="$(sha256_of "$zip")"
  if [[ "$got" != "$expect" ]]; then
    echo "error: SHA256 mismatch for ${asset}" >&2
    echo "  expected ${expect}" >&2
    echo "  got      ${got}" >&2
    rm -rf "$tmp"
    exit 1
  fi
  unzip -q -j -o "$zip" "$inner" LICENSE -d "$tmp/out"
  [[ -f "$tmp/out/$inner" && -f "$tmp/out/LICENSE" ]] || {
    echo "error: ${asset} did not contain ${inner} and LICENSE" >&2
    rm -rf "$tmp"
    exit 1
  }
  mkdir -p "$OUT_DIR"
  install -m 0755 "$tmp/out/$inner" "$OUT_DIR/$outname"
  install -m 0644 "$tmp/out/LICENSE" "$OUT_DIR/XRAY-LICENSE"
  rm -rf "$tmp"
  echo ">> ${OUT_DIR}/$outname"
}

if [[ "$GOARCH_T" == "universal" ]]; then
  if [[ "$GOOS_T" != "darwin" ]]; then
    echo "universal is only supported for darwin" >&2
    exit 1
  fi
  if ! command -v lipo >/dev/null 2>&1; then
    echo "lipo not found (a universal Xray binary needs a macOS host)" >&2
    exit 1
  fi
  fetch_one darwin amd64
  fetch_one darwin arm64
  lipo -create -output "$OUT_DIR/xray-darwin-universal" \
    "$OUT_DIR/xray-darwin-amd64" "$OUT_DIR/xray-darwin-arm64"
  chmod 0755 "$OUT_DIR/xray-darwin-universal"
  lipo -info "$OUT_DIR/xray-darwin-universal"
else
  fetch_one "$GOOS_T" "$GOARCH_T"
fi
