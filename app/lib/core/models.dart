// Shared data model for Melsi. Every layer (parsers, config builder, state,
// UI) codes against these types. Keep them plain, immutable-ish and
// JSON-serialisable so they can be persisted as a single file.

import 'dart:convert';

/// Protocol families we understand. `outbound['type']` always holds the
/// sing-box type string; this enum is only for UI grouping/badges.
enum ProxyProtocol {
  vmess,
  vless,
  trojan,
  shadowsocks,
  shadowsocksr,
  snell,
  hysteria,
  hysteria2,
  tuic,
  anytls,
  shadowtls,
  naive,
  wireguard,
  ssh,
  socks,
  http,
  tor,
  openvpn,
  openconnect,
  tailscale,
  unknown;

  static ProxyProtocol fromSingBoxType(String type) {
    switch (type) {
      case 'vmess':
        return vmess;
      case 'vless':
        return vless;
      case 'trojan':
        return trojan;
      case 'shadowsocks':
        return shadowsocks;
      case 'shadowsocksr':
        return shadowsocksr;
      case 'snell':
        return snell;
      case 'hysteria':
        return hysteria;
      case 'hysteria2':
        return hysteria2;
      case 'tuic':
        return tuic;
      case 'anytls':
        return anytls;
      case 'shadowtls':
        return shadowtls;
      case 'naive':
        return naive;
      case 'wireguard':
        return wireguard;
      case 'ssh':
        return ssh;
      case 'socks':
        return socks;
      case 'http':
        return http;
      case 'tor':
        return tor;
      case 'openvpn-client':
        return openvpn;
      case 'openconnect':
        return openconnect;
      case 'tailscale':
        return tailscale;
      default:
        return unknown;
    }
  }

  /// Human label for badges ("VLESS", "Hysteria2", ...).
  String get label => switch (this) {
        vmess => 'VMess',
        vless => 'VLESS',
        trojan => 'Trojan',
        shadowsocks => 'Shadowsocks',
        shadowsocksr => 'ShadowsocksR',
        snell => 'Snell',
        hysteria => 'Hysteria',
        hysteria2 => 'Hysteria2',
        tuic => 'TUIC',
        anytls => 'AnyTLS',
        shadowtls => 'ShadowTLS',
        naive => 'Naive',
        wireguard => 'WireGuard',
        ssh => 'SSH',
        socks => 'SOCKS',
        http => 'HTTP',
        tor => 'Tor',
        openvpn => 'OpenVPN',
        openconnect => 'OpenConnect',
        tailscale => 'Tailscale',
        unknown => 'Unknown',
      };

  /// QUIC/UDP-native protocols — preferred by Game Mode.
  bool get udpNative => switch (this) {
        hysteria || hysteria2 || tuic || wireguard || openvpn => true,
        _ => false,
      };

  /// WireGuard / OpenVPN / OpenConnect / Tailscale are sing-box *endpoints*
  /// (top-level `endpoints` array), not outbounds.
  bool get isEndpoint => switch (this) {
        wireguard || openvpn || openconnect || tailscale => true,
        _ => false,
      };
}

/// One server. [outbound] is a complete sing-box outbound/endpoint object
/// (everything except `tag`, which the config builder assigns).
class ProxyNode {
  ProxyNode({
    required this.id,
    required this.name,
    required this.outbound,
    this.subscriptionId,
    this.rawLink,
    this.countryCode,
  });

  /// Stable id: hash of the canonical outbound JSON (see [computeId]).
  final String id;
  String name;
  final Map<String, dynamic> outbound;

  /// null for manually added nodes.
  final String? subscriptionId;
  final String? rawLink;

  /// ISO 3166-1 alpha-2, guessed from the name (flag emoji / keywords).
  String? countryCode;

  String get type => outbound['type'] as String? ?? 'unknown';
  ProxyProtocol get protocol => ProxyProtocol.fromSingBoxType(type);
  String get server => outbound['server'] as String? ??
      ((outbound['peers'] as List?)?.firstOrNull as Map?)?['address']
          as String? ??
      '';
  int get port => (outbound['server_port'] as num?)?.toInt() ??
      (((outbound['peers'] as List?)?.firstOrNull as Map?)?['port'] as num?)
          ?.toInt() ??
      0;

  static String computeId(Map<String, dynamic> outbound) {
    final canonical = jsonEncode(_sortKeys(outbound));
    // FNV-1a 64-bit, hex. Deterministic across platforms, no deps.
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final unit in utf8.encode(canonical)) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  static Object? _sortKeys(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _sortKeys(v[k])};
    }
    if (v is List) return v.map(_sortKeys).toList();
    return v;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'outbound': outbound,
        if (subscriptionId != null) 'subscriptionId': subscriptionId,
        if (rawLink != null) 'rawLink': rawLink,
        if (countryCode != null) 'countryCode': countryCode,
      };

  factory ProxyNode.fromJson(Map<String, dynamic> j) => ProxyNode(
        id: j['id'] as String,
        name: j['name'] as String,
        outbound: Map<String, dynamic>.from(j['outbound'] as Map),
        subscriptionId: j['subscriptionId'] as String?,
        rawLink: j['rawLink'] as String?,
        countryCode: j['countryCode'] as String?,
      );
}

class Subscription {
  Subscription({
    required this.id,
    required this.name,
    this.url,
    this.updatedAt,
    this.upload,
    this.download,
    this.total,
    this.expire,
    this.updateIntervalHours = 12,
    this.userAgent,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
  });

  final String id;
  String name;

  /// null for "local" groups (pasted content / manual nodes).
  String? url;
  DateTime? updatedAt;

  /// From the `subscription-userinfo` header (bytes / unix time).
  int? upload;
  int? download;
  int? total;
  DateTime? expire;
  int updateIntervalHours;
  String? userAgent;

  /// From `support-url`, `profile-web-page-url`, `announce` headers.
  String? supportUrl;
  String? webPageUrl;
  String? announce;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'updatedAt': updatedAt?.toIso8601String(),
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire?.toIso8601String(),
        'updateIntervalHours': updateIntervalHours,
        'userAgent': userAgent,
        'supportUrl': supportUrl,
        'webPageUrl': webPageUrl,
        'announce': announce,
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String?,
        updatedAt: _date(j['updatedAt']),
        upload: (j['upload'] as num?)?.toInt(),
        download: (j['download'] as num?)?.toInt(),
        total: (j['total'] as num?)?.toInt(),
        expire: _date(j['expire']),
        updateIntervalHours: (j['updateIntervalHours'] as num?)?.toInt() ?? 12,
        userAgent: j['userAgent'] as String?,
        supportUrl: j['supportUrl'] as String?,
        webPageUrl: j['webPageUrl'] as String?,
        announce: j['announce'] as String?,
      );
}

/// Result of downloading + parsing a subscription URL.
class SubscriptionFetchResult {
  SubscriptionFetchResult({
    required this.nodes,
    this.title,
    this.upload,
    this.download,
    this.total,
    this.expire,
    this.updateIntervalHours,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
  });

  final List<ProxyNode> nodes;
  final String? title;
  final int? upload;
  final int? download;
  final int? total;
  final DateTime? expire;
  final int? updateIntervalHours;
  final String? supportUrl;
  final String? webPageUrl;
  final String? announce;
}

// ---------------------------------------------------------------- routing

enum RoutingPreset {
  /// Everything through the proxy (LAN/private stays direct).
  global,

  /// Russian sites & RU IPs direct, everything else proxied.
  smartRu,

  /// Only known-blocked (in RU) domains/IPs proxied, the rest direct.
  blockedOnly,

  /// Everything direct except custom proxy rules / game routing.
  direct,
}

/// How [RoutingSettings.appRules] is interpreted.
enum AppRoutingMode {
  off,

  /// Only the selected apps go through the VPN.
  onlySelected,

  /// Selected apps bypass the VPN.
  bypassSelected,
}

/// One app for per-app routing. On Android [id] is the package name, on
/// desktop the process executable name (e.g. `cs2.exe`, `Telegram`).
class AppRule {
  AppRule({required this.id, this.label});
  final String id;
  final String? label;

  Map<String, dynamic> toJson() => {'id': id, 'label': label};
  factory AppRule.fromJson(Map<String, dynamic> j) =>
      AppRule(id: j['id'] as String, label: j['label'] as String?);
}

class RoutingSettings {
  RoutingSettings({
    this.preset = RoutingPreset.smartRu,
    this.appMode = AppRoutingMode.off,
    List<AppRule>? appRules,
    this.blockAds = true,
    this.bypassLan = true,
    List<String>? directDomains,
    List<String>? proxyDomains,
    List<String>? blockDomains,
  })  : appRules = appRules ?? [],
        directDomains = directDomains ?? [],
        proxyDomains = proxyDomains ?? [],
        blockDomains = blockDomains ?? [];

  RoutingPreset preset;
  AppRoutingMode appMode;
  List<AppRule> appRules;
  bool blockAds;
  bool bypassLan;

  /// Domain suffixes (`example.com` matches subdomains too).
  List<String> directDomains;
  List<String> proxyDomains;
  List<String> blockDomains;

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        'appMode': appMode.name,
        'appRules': appRules.map((e) => e.toJson()).toList(),
        'blockAds': blockAds,
        'bypassLan': bypassLan,
        'directDomains': directDomains,
        'proxyDomains': proxyDomains,
        'blockDomains': blockDomains,
      };

  factory RoutingSettings.fromJson(Map<String, dynamic> j) => RoutingSettings(
        preset: _enum(RoutingPreset.values, j['preset'], RoutingPreset.smartRu),
        appMode: _enum(AppRoutingMode.values, j['appMode'], AppRoutingMode.off),
        appRules: (j['appRules'] as List? ?? [])
            .map((e) => AppRule.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        blockAds: j['blockAds'] as bool? ?? true,
        bypassLan: j['bypassLan'] as bool? ?? true,
        directDomains: _strings(j['directDomains']),
        proxyDomains: _strings(j['proxyDomains']),
        blockDomains: _strings(j['blockDomains']),
      );
}

// ---------------------------------------------------------------- games

/// Built-in game definition (see `core/game_presets.dart`).
class GamePreset {
  const GamePreset({
    required this.id,
    required this.name,
    this.androidPackages = const [],
    this.desktopProcesses = const [],
    this.domainSuffixes = const [],
    this.downloadDomainSuffixes = const [],
    this.geositeRuleSets = const [],
  });

  final String id;
  final String name;
  final List<String> androidPackages;

  /// Windows `.exe` names and macOS/Linux process names.
  final List<String> desktopProcesses;

  /// Match-making / game-server / anti-cheat domains (routed via the game
  /// selector).
  final List<String> domainSuffixes;

  /// Launcher/CDN download domains — sent DIRECT when
  /// [GameSettings.directDownloads] is on, so patches don't eat the tunnel.
  final List<String> downloadDomainSuffixes;

  /// Tags of SagerNet geosite rule-sets (e.g. `steam`), optional.
  final List<String> geositeRuleSets;
}

class GameSettings {
  GameSettings({
    this.enabled = false,
    Set<String>? gameIds,
    List<AppRule>? customApps,
    this.directDownloads = true,
    this.preferUdpProtocols = true,
    this.lowLatencyStack = true,
    this.gameNodeId,
  })  : gameIds = gameIds ?? {},
        customApps = customApps ?? [];

  bool enabled;

  /// Selected [GamePreset.id]s.
  Set<String> gameIds;

  /// Extra user-picked apps/processes treated as games.
  List<AppRule> customApps;

  /// Route launcher/CDN downloads direct.
  bool directDownloads;

  /// Smart engine prefers Hysteria2/TUIC/WireGuard for the game group.
  bool preferUdpProtocols;

  /// Use `system` TUN stack + TCP Fast Open for lower latency.
  bool lowLatencyStack;

  /// Pinned node for games; null = engine picks (game scoring).
  String? gameNodeId;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'gameIds': gameIds.toList(),
        'customApps': customApps.map((e) => e.toJson()).toList(),
        'directDownloads': directDownloads,
        'preferUdpProtocols': preferUdpProtocols,
        'lowLatencyStack': lowLatencyStack,
        'gameNodeId': gameNodeId,
      };

  factory GameSettings.fromJson(Map<String, dynamic> j) => GameSettings(
        enabled: j['enabled'] as bool? ?? false,
        gameIds: _strings(j['gameIds']).toSet(),
        customApps: (j['customApps'] as List? ?? [])
            .map((e) => AppRule.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        directDownloads: j['directDownloads'] as bool? ?? true,
        preferUdpProtocols: j['preferUdpProtocols'] as bool? ?? true,
        lowLatencyStack: j['lowLatencyStack'] as bool? ?? true,
        gameNodeId: j['gameNodeId'] as String?,
      );
}

// ---------------------------------------------------------------- settings

/// Smart auto-select scoring profile (mirrors the Go engine `mode`).
enum SmartMode {
  /// Lowest latency wins.
  latency,

  /// Latency + jitter + loss, with hysteresis. Default.
  balanced,

  /// Heavily penalises loss and flapping; switches rarely.
  stability,

  /// Jitter/loss first, UDP-native protocols preferred.
  game,
}

enum TunStack { system, gvisor, mixed }

enum LogLevel { trace, debug, info, warn, error }

/// Desktop only: how traffic is captured.
enum CaptureMode { tun, systemProxy }

class AppSettings {
  AppSettings({
    this.autoSelect = true,
    this.smartMode = SmartMode.balanced,
    this.probeUrl = 'https://www.gstatic.com/generate_204',
    this.probeIntervalSec = 60,
    this.remoteDns = 'https://1.1.1.1/dns-query',
    this.directDns = 'https://77.88.8.8/dns-query',
    this.tunStack = TunStack.mixed,
    this.killSwitch = false,
    this.antiDpi = false,
    this.ipv6 = false,
    this.mtu = 9000,
    this.allowLan = false,
    this.mixedPort = 7890,
    this.captureMode = CaptureMode.tun,
    this.logLevel = LogLevel.warn,
    this.connectOnLaunch = false,
    this.themeMode = 'system',
    this.locale,
  });

  bool autoSelect;
  SmartMode smartMode;
  String probeUrl;
  int probeIntervalSec;

  /// DNS server URLs: `https://…/dns-query`, `tls://1.1.1.1`, `quic://…`,
  /// `udp://8.8.8.8` or a bare IP.
  String remoteDns;
  String directDns;
  TunStack tunStack;

  /// strict_route: nothing leaks if the tunnel drops.
  bool killSwitch;

  /// TLS ClientHello fragmentation against DPI.
  bool antiDpi;
  bool ipv6;
  int mtu;

  /// Expose the mixed proxy port on the LAN.
  bool allowLan;
  int mixedPort;
  CaptureMode captureMode;
  LogLevel logLevel;
  bool connectOnLaunch;

  /// 'system' | 'light' | 'dark'
  String themeMode;

  /// 'ru' | 'en' | null (system)
  String? locale;

  Map<String, dynamic> toJson() => {
        'autoSelect': autoSelect,
        'smartMode': smartMode.name,
        'probeUrl': probeUrl,
        'probeIntervalSec': probeIntervalSec,
        'remoteDns': remoteDns,
        'directDns': directDns,
        'tunStack': tunStack.name,
        'killSwitch': killSwitch,
        'antiDpi': antiDpi,
        'ipv6': ipv6,
        'mtu': mtu,
        'allowLan': allowLan,
        'mixedPort': mixedPort,
        'captureMode': captureMode.name,
        'logLevel': logLevel.name,
        'connectOnLaunch': connectOnLaunch,
        'themeMode': themeMode,
        'locale': locale,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        autoSelect: j['autoSelect'] as bool? ?? true,
        smartMode: _enum(SmartMode.values, j['smartMode'], SmartMode.balanced),
        probeUrl:
            j['probeUrl'] as String? ?? 'https://www.gstatic.com/generate_204',
        probeIntervalSec: (j['probeIntervalSec'] as num?)?.toInt() ?? 60,
        remoteDns: j['remoteDns'] as String? ?? 'https://1.1.1.1/dns-query',
        directDns: j['directDns'] as String? ?? 'https://77.88.8.8/dns-query',
        tunStack: _enum(TunStack.values, j['tunStack'], TunStack.mixed),
        killSwitch: j['killSwitch'] as bool? ?? false,
        antiDpi: j['antiDpi'] as bool? ?? false,
        ipv6: j['ipv6'] as bool? ?? false,
        mtu: (j['mtu'] as num?)?.toInt() ?? 9000,
        allowLan: j['allowLan'] as bool? ?? false,
        mixedPort: (j['mixedPort'] as num?)?.toInt() ?? 7890,
        captureMode:
            _enum(CaptureMode.values, j['captureMode'], CaptureMode.tun),
        logLevel: _enum(LogLevel.values, j['logLevel'], LogLevel.warn),
        connectOnLaunch: j['connectOnLaunch'] as bool? ?? false,
        themeMode: j['themeMode'] as String? ?? 'system',
        locale: j['locale'] as String?,
      );
}

// ---------------------------------------------------------------- build

enum PlatformKind { android, ios, macos, windows, linux }

/// Where the Clash API and the Melsi engine control API listen.
class RuntimeEndpoints {
  const RuntimeEndpoints({
    this.clashApi = '127.0.0.1:9790',
    this.engineApi = '127.0.0.1:9791',
    required this.secret,
  });

  final String clashApi;
  final String engineApi;
  final String secret;
}

/// Output of `ConfigBuilder.build`.
class BuiltConfig {
  const BuiltConfig({
    required this.singBox,
    required this.engine,
    required this.nodeTags,
  });

  /// sing-box 1.14 configuration JSON.
  final String singBox;

  /// Melsi engine configuration JSON (docs/CONTRACT.md §2).
  final String engine;

  /// node id -> outbound tag used in [singBox].
  final Map<String, String> nodeTags;
}

// ---------------------------------------------------------------- helpers

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

List<String> _strings(Object? v) =>
    (v as List? ?? const []).map((e) => e.toString()).toList();

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
