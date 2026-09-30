# Melsi — integration contract

This file is the single source of truth for the seams between the layers.
If you change a seam, change this file in the same commit.

```
┌──────────────── Flutter app (app/) ────────────────┐
│ UI (lib/ui) ─ state (lib/state) ─ services         │
│      │                    │                         │
│  lib/core: parsers, subscription, ConfigBuilder     │
└──────┬──────────────────────────┬───────────────────┘
       │ sing-box JSON + engine JSON
       ▼                          ▼
 Mobile: MethodChannel      Desktop: melsi-core process
 Android VpnService /       (Go: sing-box + engine,
 iOS PacketTunnel           launched elevated)
 (libbox + melsicore, Go)
       │                          │
       └── HTTP 127.0.0.1 ────────┘
           Clash API :9790  (traffic, connections, delays, selector)
           Engine API :9791 (smart auto-select, game booster status)
```

## 0. Identifiers

| Thing | Value |
|---|---|
| Android applicationId / namespace | `app.melsi` |
| Android Kotlin package | `app.melsi` (`app/android/app/src/main/kotlin/app/melsi/`) |
| iOS/macOS app bundle id | `app.melsi` |
| iOS Packet Tunnel extension bundle id | `app.melsi.PacketTunnel` |
| App Group (iOS) | `group.app.melsi` |
| Go module | `github.com/zondaxxx/melsi/core` (dir `core/`), `go 1.25.5` |
| sing-box | `github.com/sagernet/sing-box v1.14.2` |
| Clash API default | `127.0.0.1:9790` |
| Engine API default | `127.0.0.1:9791` |
| Deep links | `melsi://import?url=<urlencoded>&name=<name>`, also accept `sing-box://import-remote-profile?url=`, `clash://install-config?url=`, `hiddify://import/<url>` |

## 1. Dart core API (`app/lib/core/`)

`models.dart` — data model (already written, extend compatibly).
`ProxyNode.chain` holds helper outbounds (e.g. the shadowtls wrapper for
SS+ShadowTLS); `ConfigBuilder` retags them.

```dart
// link_parser.dart
class LinkParser {
  /// One share link -> node, null if unsupported/invalid.
  /// Schemes: vmess:// vless:// trojan:// ss:// ssr:// snell:// hysteria://
  /// hy2:// hysteria2:// tuic:// anytls:// naive+https:// naive+quic://
  /// wireguard:// wg:// ssh:// socks:// socks5:// http:// https:// shadowtls://
  static ProxyNode? parseLink(String link, {String? subscriptionId});

  /// Whole subscription body: base64 list, plain list, Clash/Mihomo YAML,
  /// sing-box JSON (outbounds/endpoints), Xray JSON (best-effort),
  /// WireGuard .conf. Never throws; drops what it can't parse.
  static List<ProxyNode> parseContent(String content, {String? subscriptionId});
}

// subscription_fetcher.dart
class SubscriptionFetcher {
  SubscriptionFetcher({http.Client? client});
  /// GET with `User-Agent: <ua ?? 'Melsi/<ver> sing-box/1.14 (clash-verge; mihomo)'>`,
  /// parses headers subscription-userinfo, profile-title (plain or base64:),
  /// profile-update-interval, support-url, profile-web-page-url, announce.
  Future<SubscriptionFetchResult> fetch(String url, {String? userAgent, String? subscriptionId});
}

// country.dart
String? guessCountryCode(String nodeName);      // "🇩🇪 Frankfurt" -> "DE"
String flagEmoji(String countryCode);

// game_presets.dart
const List<GamePreset> kGamePresets;            // >= 25 popular games (PC + mobile)
GamePreset? gamePresetById(String id);

// config_builder.dart
class ConfigBuilder {
  static BuiltConfig build({
    required List<ProxyNode> nodes,        // candidates (already filtered)
    required String? selectedNodeId,       // manual pick (used when autoSelect off)
    required RoutingSettings routing,
    required GameSettings game,
    required AppSettings settings,
    required PlatformKind platform,
    required RuntimeEndpoints endpoints,
    required String cacheDir,              // for cache_file path
  });
}
```

### sing-box config conventions (produced by `ConfigBuilder`)

- Node outbound tags: sanitized unique display names; mapping returned in
  `BuiltConfig.nodeTags`.
- Selector `proxy`: all node tags, `default` = selected (or first),
  `interrupt_exist_connections: false`. The engine drives it when
  auto-select is on.
- Selector `game` (only when Game Mode on): all node tags (UDP-native first),
  engine drives it with `mode: game`.
- Outbound `direct` (type `direct`). Blocking uses rule action `reject`.
- `experimental.clash_api`: `external_controller` = `endpoints.clashApi`,
  `secret` = `endpoints.secret`. `experimental.cache_file` enabled at
  `<cacheDir>/cache.db`.
- Inbound `tun` tag `tun-in` (address `172.19.0.1/30` (+ `fdfe:dcba:9876::1/126` if ipv6),
  `auto_route: true`, `strict_route: settings.killSwitch`, `stack`).
  Android per-app → `include_package` / `exclude_package`.
  Desktop per-app → route rules `process_name`.
- Desktop `captureMode == systemProxy`: inbound `mixed` tag `mixed-in` on
  `127.0.0.1:<mixedPort>` (`0.0.0.0` if allowLan) with `set_system_proxy: true`, no tun.
  A mixed inbound is always added on desktop (so other apps can use it).
- Game Mode rules come first: game processes / packages / domains → `game`;
  download domains → `direct` (if `directDownloads`).
- Rule-sets are remote binary `.srs`, downloaded direct via a top-level
  `http_clients: [{tag: "direct-http", domain_resolver: "dns-direct"}]`,
  `route.default_http_client` and `rule_set[].http_client` (`download_detour`
  is deprecated in 1.14):
  - `geosite-category-ads-all`, `geosite-private`, `geosite-category-ru`, `geosite-steam` …
    `https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-<name>.srs`
  - `geoip-ru`: `https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs`
  - `geosite-ru-blocked`, `geoip-ru-blocked`:
    `https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs`
    `https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru-blocked.srs`
  - private IPs: use rule item `ip_is_private: true` (there is no geoip-private).

## 2. Engine config JSON (Dart → Go)

```json
{
  "clash_api": "127.0.0.1:9790",
  "secret": "random-hex",
  "control_listen": "127.0.0.1:9791",
  "log_level": "info",
  "groups": [
    {
      "selector": "proxy",
      "auto": true,
      "mode": "balanced",              // latency | balanced | stability | game
      "probe_url": "https://www.gstatic.com/generate_204",
      "interval_sec": 60,
      "timeout_ms": 3000,
      "candidates": [
        {"tag": "🇩🇪 DE-1", "type": "hysteria2", "udp_native": true}
      ]
    },
    {"selector": "game", "auto": true, "mode": "game", "...": "..."}
  ]
}
```

## 3. Engine control API (Go, `control_listen`)

All requests need `Authorization: Bearer <secret>`. JSON in/out.

| Method | Path | Body / result |
|---|---|---|
| GET | `/health` | `{"ok":true,"version":"<melsi>","sing_box":"1.14.2","uptime_sec":N}` |
| GET | `/status` | `{"groups":[GroupStatus]}` |
| POST | `/groups/{selector}/auto` | `{"auto":bool}` → GroupStatus |
| POST | `/groups/{selector}/mode` | `{"mode":"game"}` → GroupStatus |
| POST | `/groups/{selector}/probe` | force probe round now → GroupStatus (after probe) |
| POST | `/groups/{selector}/select` | `{"tag":"..."}` manual select; sets auto=false → GroupStatus |
| POST | `/stop` | desktop daemon only: shut down sing-box and exit → `{"ok":true}` |

`{selector}` is URL-path-escaped.

```json
GroupStatus = {
  "selector": "proxy", "auto": true, "mode": "balanced",
  "current": "🇩🇪 DE-1",
  "last_switch": {"from": "…", "to": "…", "reason": "jitter 3ms vs 21ms", "at": "RFC3339"},
  "nodes": [{"tag":"…","latency_ms":42,"jitter_ms":3,"loss":0.0,"score":48.1,
             "alive":true,"samples":12,"last_error":""}]
}
```

## 4. Desktop daemon (`melsi-core`)

```
melsi-core run --config <singbox.json> --engine <engine.json> [--log <file>]
melsi-core check --config <singbox.json>     # exit 0 if valid, error on stderr
melsi-core version                           # prints JSON {"melsi":..,"sing_box":..}
```

- Must run elevated for TUN (Windows: app manifest `requireAdministrator`;
  macOS: `osascript … with administrator privileges`; Linux: `pkexec`).
- Starts sing-box, then engine; `POST /stop` or SIGTERM/SIGINT stops both.
- Writes a pid file next to `--config` (`melsi-core.pid`).
- Binary shipped: Windows `melsi-core.exe` next to `melsi.exe`;
  macOS `Melsi.app/Contents/Resources/melsi-core`; Linux `bundle/melsi-core`
  (next to the `melsi` executable). Dart finds it via `Platform.resolvedExecutable`.

## 5. Mobile bridge

MethodChannel `app.melsi/vpn`:

| method | args | result |
|---|---|---|
| `prepare` | – | `bool` (Android VPN consent granted / iOS manager saved) |
| `start` | `{"config": String, "engine": String, "name": String}` | `null` (throws `PlatformException` on error) |
| `stop` | – | `null` |
| `status` | – | `"stopped" \| "connecting" \| "connected" \| "stopping"` |
| `coreVersion` | – | `String` (libbox version) |
| `installedApps` | – | Android: `List<Map>` `{"package","label","system":bool}` ; iOS: `[]` |
| `appIcon` | `{"package": String}` | Android: PNG `Uint8List` (≤96px) or null |

EventChannel `app.melsi/vpn/events` emits maps
`{"state": "<status>", "message": String?}` (message set on error).

Native side lifecycle: start libbox `CommandServer` + `StartOrReloadService(config)`,
then `Melsicore.startEngine(engineJson)`; on stop call `Melsicore.stopEngine()` first.

### gomobile

`libbox` + `melsicore` are bound together into one library:

```
gomobile bind -target android -androidapi 24 -javapkg=io.nekohasekai -libname=box \
  -trimpath -buildvcs=false -ldflags "-X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_naive_outbound,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0 \
  github.com/sagernet/sing-box/experimental/libbox github.com/zondaxxx/melsi/core/melsicore
```

(`sagernet/gomobile` fork; see `scripts/build-libbox.sh`.) Output:
Android `app/android/app/libs/libbox.aar` (Java: `io.nekohasekai.libbox.*`,
`io.nekohasekai.melsicore.Melsicore`), Apple `app/ios/Frameworks/Libbox.xcframework`
(Swift: `LibboxNewCommandServer`, `MelsicoreStartEngine`, …).

`melsicore` exported API (gomobile-compatible types only):

```go
func StartEngine(engineJSON string) error
func StopEngine()
func EngineStatus() string   // same JSON as GET /status
func Version() string        // melsi version
```

### iOS app group files (`group.app.melsi`)

The app writes `config.json` and `engine.json`. The extension writes
`version.json` (core versions) and `last_error.txt` (reason for the last
unexpected stop). The app sends the provider message `"reload"` to hot-reload
a connected tunnel; `"version"` and `"engineStatus"` are also answered.
