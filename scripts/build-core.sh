#!/usr/bin/env bash
# Build the melsi-core desktop daemon.
#
#   scripts/build-core.sh [goos] [goarch|universal]
#
# Defaults to the host platform. Output: core/dist/melsi-core-<goos>-<goarch>[.exe]
# (the name app/*/CMakeLists.txt and CI look for). `darwin universal` (macOS
# host with lipo) builds amd64+arm64 and merges them into
# core/dist/melsi-core-darwin-universal.
#
# Env:
#   MELSI_VERSION  version embedded in the binary (default: scripts/version.sh)
#   MELSI_NAIVE=1  windows only: include the naive outbound (purego). The
#                  binary then needs libcronet.dll next to it at runtime.
#   OUT_DIR        output directory (default: <repo>/core/dist)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
OUT_DIR="${OUT_DIR:-$CORE/dist}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

GOOS_T="${1:-$(go env GOOS)}"
GOARCH_T="${2:-$(go env GOARCH)}"

DESKTOP_TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0"

if [[ -z "${MELSI_VERSION:-}" ]]; then
  MELSI_VERSION="$(bash "$ROOT/scripts/version.sh" 2>/dev/null || true)"
  MELSI_VERSION="${MELSI_VERSION:-0.0.0-dev}"
fi
SING_BOX_VERSION="$(cd "$CORE" && go list -m -f '{{.Version}}' github.com/sagernet/sing-box | sed 's/^v//')"

LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=${SING_BOX_VERSION}"
LDFLAGS+=" -X github.com/zondaxxx/melsi/core/version.Melsi=${MELSI_VERSION}"
LDFLAGS+=" -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid="

build_one() {
  local goos="$1" goarch="$2" out="$3"
  local tags="$DESKTOP_TAGS"
  if [[ "$goos" == "windows" && "${MELSI_NAIVE:-0}" == "1" ]]; then
    tags+=",with_naive_outbound,with_purego"
  fi
  local ldflags="$LDFLAGS"
  # GUI subsystem: no console window pops up when the app spawns the daemon.
  # Redirected stdout/stderr still work.
  if [[ "$goos" == "windows" ]]; then
    ldflags+=" -H windowsgui"
  fi
  mkdir -p "$(dirname "$out")"
  echo ">> melsi-core ${MELSI_VERSION} (sing-box ${SING_BOX_VERSION}) ${goos}/${goarch} -> ${out}"
  (cd "$CORE" && CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -v -trimpath -buildvcs=false -tags "$tags" -ldflags "$ldflags" -o "$out" ./cmd/melsi-core)
}

exe=""
[[ "$GOOS_T" == "windows" ]] && exe=".exe"

if [[ "$GOARCH_T" == "universal" ]]; then
  if [[ "$GOOS_T" != "darwin" ]]; then
    echo "universal is only supported for darwin" >&2
    exit 1
  fi
  if ! command -v lipo >/dev/null 2>&1; then
    echo "lipo not found (universal binaries need a macOS host)" >&2
    exit 1
  fi
  build_one darwin amd64 "$OUT_DIR/melsi-core-darwin-amd64"
  build_one darwin arm64 "$OUT_DIR/melsi-core-darwin-arm64"
  lipo -create -output "$OUT_DIR/melsi-core-darwin-universal" \
    "$OUT_DIR/melsi-core-darwin-amd64" "$OUT_DIR/melsi-core-darwin-arm64"
  lipo -info "$OUT_DIR/melsi-core-darwin-universal"
else
  build_one "$GOOS_T" "$GOARCH_T" "$OUT_DIR/melsi-core-${GOOS_T}-${GOARCH_T}${exe}"
fi
