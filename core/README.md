# Melsi core (Go)

Go side of Melsi, built on sing-box 1.14.2 with Mihomo 1.19.32 outbound adapters. Seams are defined in
[`docs/CONTRACT.md`](../docs/CONTRACT.md) §2–§5.

| Path | What |
|---|---|
| `engine/` | Smart Auto-Select + Game Booster. Probes candidates through the Clash API (`/proxies/{tag}/delay`), keeps rolling stats per node (EWMA latency, jitter, loss over 20 samples, consecutive failures), scores them per mode, and drives the selector (`PUT /proxies/{selector}`) with hysteresis and immediate failover. Also serves the control API (§3). |
| `melsicore/` | gomobile-exported bridge: `StartEngine`, `StopEngine`, `EngineStatus`, `Version`. Bound together with `libbox`. |
| `cmd/melsi-core/` | Desktop daemon (§4): sing-box in-process + engine. `run`, `check`, `version`. |
| `version/` | Melsi and sing-box version strings. |
| `compat/` | In-process Mihomo adapters for SSR, VLESS XHTTP and AmneziaWG, using the sing-box dialer and DNS router. Includes loopback TCP/UDP integration tests. |
| `tools/prepare-mobile/` | Creates isolated mobile build sources with the compatibility outbound registered in libbox. Never edits the module cache or tracked Go module files. |
| `tools/` | `//go:build tools` imports that keep `libbox` and the gomobile runtime in `go.mod`. |

The engine talks to sing-box only over HTTP, so the same code runs in the
desktop daemon and in the mobile tunnel process.

## Scoring

Lower is better; nodes that are down score +Inf (reported as `score: -1`, `alive: false`).

| mode | score |
|---|---|
| latency | ewma |
| balanced | ewma + 2·jitter + 800·loss |
| stability | ewma + 3·jitter + 2000·loss + 25·flaps |
| game | (ewma + 4·jitter + 3000·loss) × 0.85 if `udp_native` |

A node is dead after 2 consecutive failed samples. Each round takes 3
samples per node (8 nodes in parallel). The group switches when the current
node is dead (immediately), or when the best node is >20% **and** >10 ms
better and the minimum dwell has passed (30 s latency/balanced, 120 s
stability/game). While the current node is dead the group re-probes every 5 s.
`auto: false` keeps probing but never switches.

## Build & test

Go ≥ 1.25.5 is required (`GOTOOLCHAIN=auto` fetches it).

```bash
cd core
go test ./...          # engine + melsicore unit tests (fake Clash API)
go vet ./...

# desktop daemon -> core/dist/melsi-core-<os>-<arch>[.exe]
../scripts/build-core.sh                    # host
../scripts/build-core.sh windows amd64
../scripts/build-core.sh darwin universal   # macOS host only (lipo)

# mobile library (libbox + melsicore)
../scripts/build-libbox.sh android   # needs ANDROID_HOME + NDK, JDK 17
../scripts/build-libbox.sh apple     # macOS + Xcode
```

Desktop builds use `CGO_ENABLED=0` and the tags
`with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0`.
The naive outbound is **not** in desktop builds (it needs cronet via cgo;
on Windows `MELSI_NAIVE=1` adds it via purego, but `libcronet.dll` must then
ship next to `melsi-core.exe`).

`scripts/build-libbox.sh` first prepares a copy of the pinned sing-box source
under `core/dist/mobile-build-*` and patches its libbox registry in that copy.
It then binds from a temporary Melsi module whose local replacement points to
the copy. This also carries the replacement into gomobile's generated modules.
The integration generator fails if the upstream registry entry point changes.

To verify the mobile registry without an Android SDK or Xcode:

```bash
mobile_source="$(go run ./tools/prepare-mobile)"
(cd "$mobile_source" && go test -tags melsi_mobile_registry -ldflags=-checklinkname=0 ./compat -run TestMobileRegistry -v)
```

Separate XHTTP download servers are rejected. sing-box TLS record fragmentation
does not apply to Mihomo's XHTTP TLS transport. Compatibility nodes use the
same route selectors and detours as native sing-box nodes.

## Daemon smoke test

```bash
melsi-core run --config singbox.json --engine engine.json --log melsi.log
curl -H "Authorization: Bearer $SECRET" 127.0.0.1:9791/health
curl -H "Authorization: Bearer $SECRET" -X POST 127.0.0.1:9791/stop
```
