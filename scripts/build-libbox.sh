#!/usr/bin/env bash
# Bind sing-box's libbox together with melsicore into one mobile library
# (docs/CONTRACT.md §5).
#
#   scripts/build-libbox.sh android   -> app/android/app/libs/libbox.aar
#   scripts/build-libbox.sh apple     -> app/ios/Frameworks/Libbox.xcframework
#
# The bind runs from inside core/ so both packages resolve through
# core/go.mod (core/tools/tools.go pins libbox and the gomobile runtime).
#
# Env:
#   MELSI_VERSION     version embedded in melsicore (default: scripts/version.sh)
#   ANDROID_HOME      Android SDK (or ANDROID_SDK_ROOT); needs platforms/android-*
#   ANDROID_NDK_HOME  Android NDK (default: newest $ANDROID_HOME/ndk/*)
#   ANDROID_API       min API for the bind (default: 24 = app minSdk; naive needs >= 23)
#   ANDROID_TARGET    gomobile target (default: android = arm, arm64, 386, amd64)
#   APPLE_TARGET      gomobile targets (default: ios,iossimulator,macos)
#   LIBBOX_OUT        override the output path (.aar / .xcframework)
#   LIBBOX_DEBUG=1    keep symbols (drops -s -w)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

PLATFORM="${1:-}"
case "$PLATFORM" in
  android | apple) ;;
  *)
    echo "usage: $0 android|apple" >&2
    exit 2
    ;;
esac

cd "$CORE"

# gomobile must match the bind runtime pinned in core/go.mod.
GOMOBILE_VERSION="$(go list -m -f '{{.Version}}' github.com/sagernet/gomobile)"
SING_BOX_VERSION="$(go list -m -f '{{.Version}}' github.com/sagernet/sing-box | sed 's/^v//')"
GOBIN_DIR="$(go env GOPATH)/bin"
export PATH="$GOBIN_DIR:$PATH"

echo ">> installing gomobile/gobind ${GOMOBILE_VERSION}"
go install "github.com/sagernet/gomobile/cmd/gomobile@${GOMOBILE_VERSION}"
go install "github.com/sagernet/gomobile/cmd/gobind@${GOMOBILE_VERSION}"
go mod download

MELSI_MOBILE_SOURCE="$(go run ./tools/prepare-mobile)"
cd "$MELSI_MOBILE_SOURCE"

if [[ -z "${MELSI_VERSION:-}" ]]; then
  MELSI_VERSION="$(bash "$ROOT/scripts/version.sh" 2>/dev/null || true)"
  MELSI_VERSION="${MELSI_VERSION:-0.0.0-dev}"
fi

LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=${SING_BOX_VERSION}"
LDFLAGS+=" -X github.com/zondaxxx/melsi/core/version.Melsi=${MELSI_VERSION}"
LDFLAGS+=" -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0"
if [[ "${LIBBOX_DEBUG:-0}" != "1" ]]; then
  LDFLAGS+=" -s -w -buildid="
fi

TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_naive_outbound,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0"
PACKAGES=(
  github.com/sagernet/sing-box/experimental/libbox
  github.com/zondaxxx/melsi/core/melsicore
)
COMMON=(-v -trimpath -buildvcs=false -ldflags "$LDFLAGS" -libname=box)

build_android() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk" ]]; then
    for candidate in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" "/usr/local/lib/android/sdk"; do
      if [[ -d "$candidate" ]]; then
        sdk="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$sdk" || ! -d "$sdk" ]]; then
    echo "Android SDK not found; set ANDROID_HOME" >&2
    exit 1
  fi
  export ANDROID_HOME="$sdk"
  if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "${ANDROID_NDK_HOME}" ]]; then
    local ndk
    ndk="$(ls -1d "$sdk"/ndk/*/ 2>/dev/null | sort -V | tail -n1 || true)"
    if [[ -z "$ndk" ]]; then
      echo "Android NDK not found; set ANDROID_NDK_HOME or install ndk;<ver> via sdkmanager" >&2
      exit 1
    fi
    export ANDROID_NDK_HOME="${ndk%/}"
  fi
  echo ">> ANDROID_HOME=$ANDROID_HOME ANDROID_NDK_HOME=$ANDROID_NDK_HOME"

  gomobile init

  local out="${LIBBOX_OUT:-$ROOT/app/android/app/libs/libbox.aar}"
  mkdir -p "$(dirname "$out")"
  rm -f "$out" "${out%.aar}-sources.jar"
  gomobile bind "${COMMON[@]}" \
    -target "${ANDROID_TARGET:-android}" \
    -androidapi "${ANDROID_API:-24}" \
    -javapkg=io.nekohasekai \
    -tags "$TAGS" \
    -o "$out" \
    "${PACKAGES[@]}"
  ls -la "$out"
}

build_apple() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "apple bind requires macOS with Xcode" >&2
    exit 1
  fi
  gomobile init

  local out="${LIBBOX_OUT:-$ROOT/app/ios/Frameworks/Libbox.xcframework}"
  mkdir -p "$(dirname "$out")"
  rm -rf "$out"
  gomobile bind "${COMMON[@]}" \
    -target "${APPLE_TARGET:-ios,iossimulator,macos}" \
    -tags-not-macos=with_low_memory \
    -iosversion=15.0 \
    -macosversion=13.0 \
    -tags "${TAGS},with_dhcp,grpcnotrace" \
    -o "$out" \
    "${PACKAGES[@]}"
  ls -la "$out"
}

"build_${PLATFORM}"
