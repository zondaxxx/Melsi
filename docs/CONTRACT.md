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
| App Group (iOS) | `group.app.melsi`, or another group from the signed entitlements |
| Go module | `github.com/zondaxxx/melsi/core` (dir `core/`), `go 1.26.0` |
| sing-box | `github.com/sagernet/sing-box v1.14.2` |
| Compatibility adapters | `github.com/metacubex/mihomo v1.19.32` |
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
  /// wireguard:// wg:// awg:// amneziawg:// ssh:// socks:// socks5:// http:// https:// shadowtls://
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
    ChainSettings? chain,                  // fixed entry, selectable exit
    required PlatformKind platform,
    required RuntimeEndpoints endpoints,
    required String cacheDir,              // for cache_file path
  });
}
```

### sing-box config conventions (produced by `ConfigBuilder`)

- SSR and AmneziaWG are emitted as `type: "mihomo"` outbounds
  with a `proxy` object in Mihomo format. Core choice is automatic per node.
  Plain WireGuard remains a sing-box endpoint. AmneziaWG remains ineligible
  as a chain entry but can be a selectable exit.
- Compatibility sockets use the injected sing-box dialer, including platform
  socket protection and detours. Server names resolve through `dns-direct`;
  UDP/WireGuard destinations use the sing-box DNS router. Missing resolvers
  fail instead of falling back to a separate Mihomo resolver.
- REALITY/Vision and XHTTP use embedded Xray-core v26.3.27 on every platform:
  `type: "xray"`, `outbound: {protocol, settings, streamSettings}` and sing-box
  dialer options. This avoids the old REALITY client version advertised by
  sing-box/Mihomo, which current Xray servers can reject. Xray owns only the
  proxy protocol; sing-box still owns TUN, DNS, routing and selection.
- XHTTP modes are `auto`, `packet-up`, `stream-up`, `stream-one`; normalized
  options and XMUX are restored to Xray's `xhttpSettings.extra` / `xmux`.
  Unknown extras and separate download settings are rejected. sing-box-specific
  TLS record fragmentation is unavailable on XHTTP. Non-REALITY XHTTP with
  explicit `insecure: true` stays on Mihomo because Xray removed `allowInsecure`;
  ordinary TLS nodes with that option remain native instead of breaking startup.
- Embedded Xray UDP preserves packet boundaries and deadlines. Payloads above
  7526 bytes are rejected explicitly: the upstream XUDP writer otherwise silently
  drops them. Closed destination streams are evicted and recreated on the next
  datagram. The adapter closes physical sockets and unregisters its protected
  dialer on shutdown; upstream Xray's process-global HTTP pool metadata cannot
  be purged through its public API.

- Node outbound tags: sanitized unique display names; mapping returned in
  `BuiltConfig.nodeTags`.
- Selector `proxy`: all selectable node tags, `default` = selected (or first),
  `interrupt_exist_connections: false`. The engine drives it when
  auto-select is on.
- Selector `game` (only when Game Mode on): all selectable node tags (UDP-native first),
  engine drives it with `mode: game`.
- When Double VPN is active, both selectors and engine candidate lists exclude
  the entry. Each exit's outermost dial (including dependency helpers) detours
  through the entry; the entry itself stays unchanged. WireGuard endpoints
  can be exits, not entries. A missing entry or fewer than two usable nodes
  disables the chain. `BuiltConfig.entryTag` / `chainActive` report the built
  topology, not just the requested setting.
- Outbound `direct` (type `direct`). Blocking uses rule action `reject`.
- `experimental.clash_api`: `external_controller` = `endpoints.clashApi`,
  `secret` = `endpoints.secret`. `experimental.cache_file` enabled at
  `<cacheDir>/cache.db` with `cache_id` `auto` or `manual:<selectedNodeId>`
  as separate auto/manual cache namespaces. The engine explicitly restores
  `groups[].selected` in manual mode: a live A→B switch can store B in A's
  namespace, and sing-box prefers that cached selection over `default`.
  `store_dns` is on unless memory saver is set. Memory saver also sets
  the TUN `udp_timeout` to `30s`. `routing.blockQuic` adds a `quic` reject
  rule after sniff. `settings.multiplex` allows provider-declared multiplex
  options on shadowsocks, vmess, vless, and trojan without flow or REALITY;
  it never invents h2mux support for an ordinary server. Memory saver and
  disabling the setting remove imported multiplex options too.
- `settings.core`: `singBox` (default), `mihomo` (supported proxies become
  `type: mihomo` outbounds), or `xray`. REALITY/Vision, XHTTP and gRPC with
  explicit authority use embedded Xray regardless of this preference.
  On mobile, selecting Xray uses the embedded adapter for every translatable
  node, with no additional process or localhost port. Embedded outbounds also
  preserve chain detours through the sing-box protected dialer.
  On desktop without a chain, explicitly selecting Xray keeps the existing
  bundled process: translatable nodes become local SOCKS outbounds and
  `BuiltConfig.xray` contains Xray JSON. The desktop runner starts `xray`
  (`MELSI_XRAY`, adjacent to `melsi-core`, or on `PATH`) before the tunnel and
  excludes its process from the TUN.
  An unexpected exit of that Xray process fails the desktop session and stops
  its tunnel. A cancelled or timed-out configuration check cannot launch a
  daemon afterward; validation timeouts are failures, not successful checks.
- Inbound `tun` tag `tun-in` (address `172.19.0.1/30` (+ `fdfe:dcba:9876::1/126` if ipv6),
  `auto_route: true`, `strict_route: settings.killSwitch`, `stack`).
  Android per-app → `include_package` / `exclude_package`.
  Desktop per-app → route rules `process_name`.
- Desktop `captureMode == systemProxy`: inbound `mixed` tag `mixed-in` on
  `127.0.0.1:<mixedPort>` (`0.0.0.0` if allowLan) with `set_system_proxy: true`, no tun.
  A mixed inbound is always added on desktop (so other apps can use it).
- After DNS handling, LAN bypass and explicit blocks, measurement hosts from
  `ConfigBuilder.probeHosts` route through `proxy` and resolve through
  `dns-remote`, before presets and application rules. Explicit custom domain
  blocks still take precedence. These probes measure the tunnel even with a
  direct-routing preset; they are not an all-traffic leak test.
- Game Mode rules precede ordinary per-app and preset rules: game processes / packages / domains → `game`;
  download domains → `direct` (if `directDownloads`).
- Android/iOS game presets are filtered by mobile package support, regardless
  of screen width. Saved PC selections are preserved but generate no mobile
  game rules. World of Tanks Blitz has a separate mobile preset.
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

### Feature lifecycle and persistence

- `Features` owns feature services, the command registry and injected HTTP,
  clock and clipboard dependencies. `init()` loads services once and hooks VPN
  status / resume events; `dispose()` removes hooks and releases resources.
- Feature data lives under `AppState.sections`, keyed by service name. Backup
  restore calls `replaceFromJson()` then `Features.reloadAll()`; readers must
  reset absent sections and ignore asynchronous results from earlier loads.
- Backup format 1 contains JSON state and metadata, without the local runtime
  API secret. Restore validates state before replacement and retains the local
  secret for an existing native tunnel. Backups are not encrypted.
- `finishOnboarding()` both persists completion and signals an already mounted
  welcome screen. Ordinary imports can finish the import step without skipping
  the user's final onboarding choices.
- IP lookups are tied to the connection generation and active node. Switching
  servers clears the old exit verdict immediately; refreshes are throttled.
  Desktop system-proxy probes and speed tests use the local mixed proxy.
- The daemon's `/health` confirms process availability, not internet access.
  Failed URL probes retain `last_error`; Logs displays changes for the selected
  node without repeating an unchanged error on every status poll. Desktop
  saved diagnostics include bounded core and Xray log tails.

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
      "selected": "🇩🇪 DE-1",          // optional; enforced at startup only when auto=false
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
- `--log` is the primary log destination; an unavailable console cannot stop
  file logging. Startup errors are saved before the log sink closes.
- Binary shipped: Windows `melsi-core.exe` next to `melsi.exe`;
  macOS `Melsi.app/Contents/Resources/melsi-core`; Linux `bundle/melsi-core`
  (next to the `melsi` executable). Dart finds it via `Platform.resolvedExecutable`.
  Release builds compile this binary from the tagged commit (`scripts/build-core.sh`).
- Desktop release artifacts also ship official Xray-core (`scripts/fetch-xray.sh`,
  pinned version, SHA256 of the release zip) beside that binary, plus
  `XRAY-LICENSE` (MPL-2.0): Windows `xray.exe`, macOS `Contents/Resources/xray`
  (arm64+x64 universal), Linux `xray`. Phones do not ship it.

## 5. Mobile bridge

MethodChannel `app.melsi/vpn`:

| method | args | result |
|---|---|---|
| `prepare` | – | `bool` (Android VPN consent granted / iOS manager saved) |
| `start` | `{"config": String, "engine": String, "name": String}` | `null` (throws `PlatformException` on error) |
| `stop` | – | `null` |
| `status` | – | `"stopped" \| "connecting" \| "connected" \| "stopping"` |
| `coreVersion` | – | `String` (libbox version) |
| `readLog` | `{"maxLines": int}` (1–400) | iOS: saved tunnel lifecycle/stop diagnostics; other mobile bridges may return no implementation |
| `installedApps` | – | Android: `List<Map>` `{"package","label","system":bool}` ; iOS: `[]` |
| `appIcon` | `{"package": String}` | Android: PNG `Uint8List` (≤96px) or null |

EventChannel `app.melsi/vpn/events` emits maps
`{"state": "<status>", "message": String?}` (message set on error).

Native side lifecycle: start libbox `CommandServer` + `StartOrReloadService(config)`,
then `Melsicore.startEngine(engineJson)`; on stop call `Melsicore.stopEngine()` first.
On iOS device sleep, pause both libbox and the engine; wake resumes both.
Engine pause cancels probe work without marking nodes dead or stopping the
tunnel. The mobile bridge preserves this pause across a service reload.
Automatic rounds in manual mode check only the selected server; explicit
probe requests still check every candidate. Concurrent probes share one limit
across proxy/game groups: two on mobile, eight on desktop.
iOS enables system On Demand recovery only after a successful user connection.
An explicit stop persists recovery disabled before stopping the provider.
Preference updates are serialized and checked against the connection attempt,
so an older connect cannot re-enable recovery after a newer stop.

### gomobile

`libbox` + `melsicore` are bound together into one library:

Use `scripts/build-libbox.sh`: it runs `core/tools/prepare-mobile` to create
isolated build sources in ignored `core/dist/mobile-build-*`. The pinned
sing-box source is copied there and only libbox's outbound registry entry is
patched to `compat.OutboundRegistry()`. A temporary Melsi `go.mod` supplies
the local replacement, which gomobile carries into generated modules. CI
checks `libbox.CheckConfig` with a compatibility outbound from these sources.

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
func PauseEngine()           // suspend probes, retain tunnel and selection
func ResumeEngine()          // resume probes, safe when stopped
func EngineStatus() string   // same JSON as GET /status
func Version() string        // melsi version
```

### iOS app group files

Official and CI builds declare `group.app.melsi` in `Runner.entitlements` and
`PacketTunnel.entitlements`. At runtime the app and the PacketTunnel extension
select one container, in the same order:

1. `group.app.melsi`, when that container exists and is writable.
2. Otherwise an App Group present in both signed entitlements (the embedded
   provisioning profile is the fallback). The lists are intersected and sorted
   so both processes pick the same id. The app also passes the chosen id as
   the `appGroup` start option.

A GBox (or similar) re-sign replaces the embedded entitlements with the
profile's groups, for example `group.5c65ddfeba24ae58.1`. The profile does not
need a group named `group.app.melsi`. It does need one App Group on both the
app and the PacketTunnel extension; discovery uses that group for
`config.json`, `engine.json`, `version.json`, `last_error.txt`, and
`command.sock`.

The app writes `config.json` and `engine.json`. The extension writes
`version.json` (core versions), `last_error.txt` (core failure), and `last_stop.txt`
(system stop reason). `tunnel_lifecycle.jsonl` keeps at most 64 lifecycle/health
events, including physical memory samples every 30 seconds, without server
configuration or credentials. It remains writable after the first device
unlock and is available through `readLog` on the existing Logs screen.
A missing stop callback does not prove a memory-pressure kill. The app sends
the provider message `"reload"` to hot-reload
a connected tunnel; `"version"` and `"engineStatus"` are also answered.
`command.sock` stays in the shared container when the path fits `sockaddr_un`.
The one-character fallback directory is created only when that directory is
writable.
