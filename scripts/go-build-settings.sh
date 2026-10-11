#!/usr/bin/env bash
# Shared by desktop builds and native regression tests: matching tags and
# trimpath settings let both reuse the same compiled dependencies.
MELSI_DESKTOP_GO_FLAGS=(-trimpath -buildvcs=false)

melsi_desktop_go_tags() {
  local tags="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0"
  if [[ "$1" == "windows" && "${MELSI_NAIVE:-0}" == "1" ]]; then
    tags+=",with_naive_outbound,with_purego"
  fi
  printf '%s\n' "$tags"
}
