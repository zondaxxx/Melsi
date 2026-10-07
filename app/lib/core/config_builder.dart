// Builds the sing-box 1.14 configuration + Melsi engine configuration.
//
// Layout of the generated sing-box config (see docs/CONTRACT.md §1):
//
//   log · dns · inbounds (tun-in / mixed-in) · outbounds (direct, proxy,
//   [game], node outbounds, shadowtls helpers) · endpoints (WireGuard nodes)
//   · route · experimental (clash_api + cache_file) · http_clients
//
// Route rule order (first match wins, `route-options` / `sniff` are
// non-final):
//   1. sniff
//   2. hijack-dns (protocol dns OR port 53)
//   3. private IPs -> direct                      (bypassLan)
//   4. custom block domains, ads rule-set -> reject
//   5. Game Mode: download CDNs -> direct, then game processes / packages /
//      domains -> `game` selector
//   6. desktop per-app routing (process_name)
//   7. anti-DPI route-options (see below)
//   8. custom proxy / direct domain suffixes
//   9. preset rules, then `final`
//
// Anti-DPI (settings.antiDpi) — what it does and why:
//   * Traffic that goes through a proxy node is encrypted end-to-end inside
//     the tunnel; fragmenting the *inner* ClientHello is useless. What DPI can
//     see is the node's OWN TLS handshake, so every TCP+TLS node (not REALITY,
//     whose SNI is an allowed decoy anyway, and not QUIC protocols) gets
//     `tls.record_fragment: true` (cheap, splits the ClientHello into several
//     TLS records).
//   * The real win is DIRECT traffic to sites throttled/filtered by SNI-based
//     DPI. For that we emit `route-options` rules:
//       - custom direct domains -> `tls_fragment: true` (TCP segmentation,
//         the GoodbyeDPI/zapret trick; slower, so only for listed domains);
//       - preset `direct`: rule-set geosite-ru-blocked -> `tls_fragment`;
//       - presets whose `final` is direct (blockedOnly/direct): a catch-all
//         TCP/443 `tls_record_fragment: true` placed right before `final`, so
//         it only touches connections that fall through to direct.
//     Proxied connections never hit these route-options rules except the
//     custom-direct / ru-blocked ones in presets where they go direct anyway.
//
// Double VPN (chain) — "fixed entry, selectable exit", zero Go changes:
//   * One node is the entry. Every other node dials THROUGH it with sing-box
//     `detour` on its outermost dial (the shadowtls helper when the node has
//     one, else the outbound itself; WireGuard endpoints get it too). The
//     entry outbound stays plain — it is the only handshake the ISP sees.
//   * The `proxy` / `game` selectors and the engine's candidate lists
//     exclude the entry, so auto-select keeps picking the *exit*; latencies
//     the engine measures are end-to-end (entry + exit) by construction.
//   * A detoured outbound gets neither TCP Fast Open (the inner connection
//     is a stream inside the entry's tunnel) nor `record_fragment` (DPI only
//     sees the entry's ClientHello).
//   * The chain is silently inactive when the entry is the only usable node
//     or an endpoint type (WireGuard can't carry a detour target): the
//     output is then identical to "no chain".

import 'dart:convert';

import 'game_presets.dart';
import 'models.dart';
import 'compatibility_core.dart';
import 'xray_config.dart';

class ConfigBuilder {
  ConfigBuilder._();

  static const tagProxy = 'proxy';
  static const tagGame = 'game';
  static const tagDirect = 'direct';
  static const tagTun = 'tun-in';
  static const tagMixed = 'mixed-in';
  static const dnsLocal = 'dns-local';
  static const dnsDirect = 'dns-direct';
  static const dnsRemote = 'dns-remote';
  static const httpClientTag = 'direct-http';

  static const _reservedTags = {
    tagProxy, tagGame, tagDirect, tagTun, tagMixed, dnsLocal, dnsDirect,
    dnsRemote, 'block', 'dns', 'dns-out', 'GLOBAL', 'REJECT', 'DIRECT',
  };

  /// Rule-sets shipped in `assets/rulesets/` (see [build]'s
  /// `bundledRuleSetDir`).
  static const bundledRuleSets = {
    'geosite-category-ads-all', 'geosite-category-ru', 'geoip-ru',
    'geosite-ru-blocked', 'geoip-ru-blocked',
  };

  /// Not compiled into the desktop `melsi-core` (naive needs cronet/cgo).
  static const desktopUnsupportedTypes = {'naive'};

  /// Hosts the app itself talks to for measurements (public IP lookup,
  /// speed test, DNS check). They are always routed through the proxy so
  /// the answer describes the tunnel, whatever the routing preset says.
  static const probeHosts = [
    'ipwho.is',
    'ip.sb',
    'ipinfo.io',
    'speed.cloudflare.com',
    'dns.google',
  ];

  static const _tcpTypes = {
    'shadowsocks', 'vmess', 'vless', 'trojan', 'anytls', 'shadowtls',
    'http', 'socks', 'ssh', 'snell',
  };

  static BuiltConfig build({
    required List<ProxyNode> nodes,
    required String? selectedNodeId,
    required RoutingSettings routing,
    required GameSettings game,
    required AppSettings settings,
    required PlatformKind platform,
    required RuntimeEndpoints endpoints,
    required String cacheDir,
    String? bundledRuleSetDir,
    ChainSettings? chain,
  }) {
    final isDesktop = platform == PlatformKind.windows ||
        platform == PlatformKind.macos ||
        platform == PlatformKind.linux;
    final isAndroid = platform == PlatformKind.android;
    final isIos = platform == PlatformKind.ios;
    final lowLatency = game.enabled && game.lowLatencyStack;

    // ---------------------------------------------------------- nodes
    final usable = nodes
        .where((n) =>
            !(isDesktop && desktopUnsupportedTypes.contains(n.type)) &&
            n.type != 'unknown')
        .toList();
    final nodeTags = <String, String>{};
    final usedTags = <String>{..._reservedTags};
    final outbounds = <Map<String, dynamic>>[];
    final endpointsList = <Map<String, dynamic>>[];
    final nodeOutbounds = <Map<String, dynamic>>[];
    final tagToNode = <String, ProxyNode>{};

    // Tags first: an exit built before the entry still needs the entry's
    // tag for its detour, so tagging is a pass of its own.
    final ordered = <ProxyNode>[];
    for (final n in usable) {
      if (nodeTags.containsKey(n.id)) continue;
      final tag = _uniqueTag(_sanitizeTag(n.name), usedTags);
      nodeTags[n.id] = tag;
      tagToNode[tag] = n;
      ordered.add(n);
    }

    // ---------------------------------------------------------- chain
    final entryTag =
        chain?.enabled == true ? nodeTags[chain!.entryNodeId] : null;
    final entryNode = entryTag == null ? null : tagToNode[entryTag];
    final chainActive = entryNode != null &&
        !entryNode.protocol.isEndpoint &&
        ordered.length > 1;
    // Xray dials from outside the TUN. A chain detour would have to live
    // inside sing-box, so a double-VPN session stays on sing-box outbounds.
    final useXray = settings.core == VpnCore.xray && isDesktop && !chainActive;
    final useMihomo = settings.core == VpnCore.mihomo;
    final xrayCandidates = <({ProxyNode node, String tag})>[];

    for (final n in ordered) {
      final tag = nodeTags[n.id]!;
      final ob = _deepCopy(n.outbound)..['tag'] = tag;
      final helpers = <Map<String, dynamic>>[];
      final deps = n.chain;
      if (deps != null) {
        // Placeholder -> real tag for every helper, then rewrite detours on
        // the outbound AND between helpers (a helper may dial another).
        final renamed = <String, String>{};
        for (final dep in deps) {
          final depTag = _uniqueTag('$tag-${dep['type']}', usedTags);
          final placeholder = dep['tag'];
          if (placeholder is String) renamed[placeholder] = depTag;
          helpers.add(_deepCopy(dep)..['tag'] = depTag);
        }
        for (final h in [ob, ...helpers]) {
          final det = h['detour'];
          if (det is String && renamed.containsKey(det)) h['detour'] = renamed[det];
        }
      }
      if (chainActive && tag != entryTag) {
        _outermost(ob, helpers)['detour'] = entryTag;
      }
      // Tune after the detour is in place: a detoured dial skips TFO and
      // record fragmentation.
      for (final h in helpers) {
        _tune(h, settings, lowLatency && !isIos);
        nodeOutbounds.add(CompatibilityCore.wrap(h));
      }
      _tune(ob, settings, lowLatency && !isIos);
      final handToXray = useXray &&
          (n.chain == null || n.chain!.isEmpty) &&
          XrayConfig.outbound(n, tag) != null;
      if (handToXray) {
        xrayCandidates.add((node: n, tag: tag));
        continue;
      }
      if (useMihomo && helpers.isEmpty) {
        final clash = CompatibilityCore.clashProxy(ob);
        if (clash != null) {
          outbounds.add({
            'type': 'mihomo',
            'tag': tag,
            'domain_resolver': {'server': 'dns-direct'},
            if (ob['detour'] != null) 'detour': ob['detour'],
            'proxy': {...clash, 'name': tag},
          });
          continue;
        }
      }
      if (settings.multiplex &&
          !settings.memorySaver &&
          !n.protocol.isEndpoint &&
          !CompatibilityCore.needsMihomo(ob) &&
          _tcpTypes.contains(ob['type'])) {
        ob['multiplex'] = {
          'enabled': true,
          'protocol': 'h2mux',
          'max_connections': 4,
          'min_streams': 4,
          'padding': false,
        };
      }
      if (CompatibilityCore.needsMihomo(ob)) {
        outbounds.add(CompatibilityCore.wrap(ob));
      } else if (n.protocol.isEndpoint) {
        endpointsList.add(ob);
      } else {
        outbounds.add(ob);
      }
    }
    final xrayPlan = xrayCandidates.isEmpty
        ? null
        : XrayConfig.build(xrayCandidates, logLevel: settings.logLevel);
    if (xrayPlan != null) {
      for (final member in xrayPlan.members) {
        outbounds.add({
          'type': 'socks',
          'tag': member.tag,
          'server': '127.0.0.1',
          'server_port': member.port,
          'version': '5',
        });
      }
    }
    final allTags = nodeTags.values.toList();

    // Selectable members: every node but the entry. The entry is a hop, not
    // a destination — offering it as an exit would loop it onto itself.
    final exitTags =
        chainActive ? allTags.where((t) => t != entryTag).toList() : allTags;

    // ---------------------------------------------------------- selectors
    final proxyMembers = exitTags.isEmpty ? [tagDirect] : exitTags;
    final selectedTag =
        selectedNodeId == null ? null : nodeTags[selectedNodeId];
    final proxySelector = <String, dynamic>{
      'type': 'selector',
      'tag': tagProxy,
      'outbounds': proxyMembers,
      // A selection that became the entry falls back to the first exit.
      'default': selectedTag != null && proxyMembers.contains(selectedTag)
          ? selectedTag
          : proxyMembers.first,
      'interrupt_exist_connections': false,
    };

    List<String> gameOrder = const [];
    Map<String, dynamic>? gameSelector;
    if (game.enabled) {
      gameOrder = [...exitTags];
      if (game.preferUdpProtocols) {
        final udp = gameOrder
            .where((t) => tagToNode[t]!.protocol.udpNative)
            .toList();
        final rest = gameOrder
            .where((t) => !tagToNode[t]!.protocol.udpNative)
            .toList();
        gameOrder = [...udp, ...rest];
      }
      final members = gameOrder.isEmpty ? [tagDirect] : gameOrder;
      final pinned =
          game.gameNodeId == null ? null : nodeTags[game.gameNodeId];
      gameSelector = {
        'type': 'selector',
        'tag': tagGame,
        'outbounds': members,
        'default': pinned != null && members.contains(pinned) ? pinned : members.first,
        'interrupt_exist_connections': false,
      };
    }

    final allOutbounds = <Map<String, dynamic>>[
      {'type': 'direct', 'tag': tagDirect},
      proxySelector,
      ?gameSelector,
      ...outbounds,
      ...nodeOutbounds,
    ];

    // ---------------------------------------------------------- game data
    final presets = game.enabled
        ? game.gameIds
            .map(gamePresetById)
            .whereType<GamePreset>()
            .where((preset) => preset.supportsPlatform(platform))
            .toList()
        : <GamePreset>[];
    final gameProcesses = <String>{};
    final gamePackages = <String>{};
    final gameDomains = <String>{};
    final downloadDomains = <String>{};
    final gameGeosites = <String>{};
    for (final p in presets) {
      gameProcesses.addAll(p.desktopProcesses);
      gamePackages.addAll(p.androidPackages);
      gameDomains.addAll(p.domainSuffixes);
      downloadDomains.addAll(p.downloadDomainSuffixes);
      gameGeosites.addAll(p.geositeRuleSets);
    }
    if (game.enabled) {
      for (final a in game.customApps) {
        if (a.id.trim().isEmpty) continue;
        if (isAndroid) {
          gamePackages.add(a.id.trim());
        } else if (isDesktop) {
          gameProcesses.add(a.id.trim());
        }
      }
    }

    // ---------------------------------------------------------- rule sets
    final ruleSets = <String, Map<String, dynamic>>{};
    String rs(String tag) {
      ruleSets[tag] ??= {
        'type': 'remote',
        'tag': tag,
        'format': 'binary',
        'url': _ruleSetUrl(tag),
        'http_client': httpClientTag,
        // Used when nothing is cached yet, so the first start doesn't depend
        // on reaching GitHub.
        if (bundledRuleSetDir != null && bundledRuleSets.contains(tag))
          'initial_path': '$bundledRuleSetDir/$tag.srs',
      };
      return tag;
    }

    // ---------------------------------------------------------- route rules
    final rules = <Map<String, dynamic>>[];
    rules.add({'action': 'sniff'});
    if (routing.blockQuic) {
      rules.add({'protocol': 'quic', 'action': 'reject'});
    }
    rules.add({
      'type': 'logical',
      'mode': 'or',
      'rules': [
        {'protocol': 'dns'},
        {'port': 53},
      ],
      'action': 'hijack-dns',
    });
    if (xrayPlan != null) {
      // Xray's own sockets must leave the machine, not re-enter the TUN.
      rules.add({
        'process_name': ['xray', 'xray.exe'],
        'outbound': tagDirect,
      });
    }
    if (routing.bypassLan) {
      rules.add({'ip_is_private': true, 'outbound': tagDirect});
    }
    final block = _domains(routing.blockDomains);
    if (block.isNotEmpty) {
      rules.add({'domain_suffix': block, 'action': 'reject'});
    }
    // Measurement hosts always go through the tunnel (see [probeHosts]);
    // placed before every preset so "direct" presets still measure the
    // proxy — the user asked for the tunnel's numbers, not the ISP's.
    rules.add({'domain_suffix': probeHosts, 'outbound': tagProxy});
    if (routing.blockAds) {
      rules.add({
        'rule_set': [rs('geosite-category-ads-all')],
        'action': 'reject',
      });
    }

    // Game Mode
    if (game.enabled) {
      if (game.directDownloads && downloadDomains.isNotEmpty) {
        rules.add({
          'domain_suffix': downloadDomains.toList(),
          'outbound': tagDirect,
        });
      }
      if (isDesktop && gameProcesses.isNotEmpty) {
        rules.add({
          'process_name': gameProcesses.toList(),
          'outbound': tagGame,
        });
      }
      if (isAndroid && gamePackages.isNotEmpty) {
        rules.add({
          'package_name': gamePackages.toList(),
          'outbound': tagGame,
        });
      }
      if (gameDomains.isNotEmpty) {
        rules.add({
          'domain_suffix': gameDomains.toList(),
          'outbound': tagGame,
        });
      }
      if (gameGeosites.isNotEmpty) {
        rules.add({
          'rule_set': gameGeosites.map((g) => rs('geosite-$g')).toList(),
          'outbound': tagGame,
        });
      }
    }

    // Desktop per-app routing. Android is handled by the TUN
    // include/exclude_package lists; iOS has no per-app support.
    final appIds = routing.appRules
        .map((a) => a.id.trim())
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList();
    final desktopProcessRules = isDesktop &&
        routing.appMode != AppRoutingMode.off &&
        appIds.isNotEmpty;
    if (desktopProcessRules) {
      if (routing.appMode == AppRoutingMode.onlySelected) {
        rules.add({
          'process_name': appIds,
          'invert': true,
          'outbound': tagDirect,
        });
      } else {
        rules.add({'process_name': appIds, 'outbound': tagDirect});
      }
    }

    // Anti-DPI for direct traffic.
    final direct = _domains(routing.directDomains);
    final proxyDomains = _domains(routing.proxyDomains);
    if (settings.antiDpi) {
      if (direct.isNotEmpty) {
        rules.add({
          'domain_suffix': direct,
          'network': 'tcp',
          'action': 'route-options',
          'tls_fragment': true,
        });
      }
      if (routing.preset == RoutingPreset.direct) {
        rules.add({
          'rule_set': [rs('geosite-ru-blocked')],
          'network': 'tcp',
          'action': 'route-options',
          'tls_fragment': true,
        });
      }
    }

    if (proxyDomains.isNotEmpty) {
      rules.add({'domain_suffix': proxyDomains, 'outbound': tagProxy});
    }
    if (direct.isNotEmpty) {
      rules.add({'domain_suffix': direct, 'outbound': tagDirect});
    }

    // Presets
    String finalOutbound;
    String dnsFinal;
    final dnsRules = <Map<String, dynamic>>[];
    switch (routing.preset) {
      case RoutingPreset.global:
        finalOutbound = tagProxy;
        dnsFinal = dnsRemote;
      case RoutingPreset.smartRu:
        rules.add({'domain_suffix': _ruTlds, 'outbound': tagDirect});
        rules.add({
          'rule_set': [rs('geosite-category-ru')],
          'outbound': tagDirect,
        });
        rules.add({
          'rule_set': [rs('geoip-ru')],
          'outbound': tagDirect,
        });
        finalOutbound = tagProxy;
        dnsFinal = dnsRemote;
      case RoutingPreset.blockedOnly:
        rules.add({
          'rule_set': [rs('geosite-ru-blocked')],
          'outbound': tagProxy,
        });
        rules.add({
          'rule_set': [rs('geoip-ru-blocked')],
          'outbound': tagProxy,
        });
        finalOutbound = tagDirect;
        dnsFinal = dnsDirect;
      case RoutingPreset.direct:
        finalOutbound = tagDirect;
        dnsFinal = dnsDirect;
    }
    if (settings.antiDpi && finalOutbound == tagDirect) {
      // Only reached by connections that fall through to `final: direct`.
      rules.add({
        'network': 'tcp',
        'port': 443,
        'action': 'route-options',
        'tls_record_fragment': true,
      });
    }

    // ---------------------------------------------------------- DNS
    final strategy = settings.ipv6 ? 'prefer_ipv4' : 'ipv4_only';
    final dnsServers = <Map<String, dynamic>>[
      {'type': 'local', 'tag': dnsLocal},
      _dnsServer(settings.directDns, dnsDirect,
          fallback: 'https://77.88.8.8/dns-query', resolver: dnsLocal),
      _dnsServer(settings.remoteDns, dnsRemote,
          fallback: 'https://1.1.1.1/dns-query',
          resolver: dnsDirect,
          detour: tagProxy),
    ];
    if (block.isNotEmpty) {
      dnsRules.add({'domain_suffix': block, 'action': 'reject'});
    }
    dnsRules.add({'domain_suffix': probeHosts, 'server': dnsRemote});
    if (routing.blockAds) {
      dnsRules.add({
        'rule_set': [rs('geosite-category-ads-all')],
        'action': 'reject',
      });
    }
    if (game.enabled && game.directDownloads && downloadDomains.isNotEmpty) {
      dnsRules.add({
        'domain_suffix': downloadDomains.toList(),
        'server': dnsDirect,
      });
    }
    if (game.enabled && gameDomains.isNotEmpty) {
      dnsRules.add({
        'domain_suffix': gameDomains.toList(),
        'server': dnsRemote,
      });
    }
    if (proxyDomains.isNotEmpty) {
      dnsRules.add({'domain_suffix': proxyDomains, 'server': dnsRemote});
    }
    if (direct.isNotEmpty) {
      dnsRules.add({'domain_suffix': direct, 'server': dnsDirect});
    }
    switch (routing.preset) {
      case RoutingPreset.smartRu:
        dnsRules.add({'domain_suffix': _ruTlds, 'server': dnsDirect});
        dnsRules.add({
          'rule_set': [rs('geosite-category-ru')],
          'server': dnsDirect,
        });
      case RoutingPreset.blockedOnly:
        dnsRules.add({
          'rule_set': [rs('geosite-ru-blocked')],
          'server': dnsRemote,
        });
      case RoutingPreset.global:
      case RoutingPreset.direct:
        break;
    }

    final dns = <String, dynamic>{
      'servers': dnsServers,
      'rules': dnsRules,
      'final': dnsFinal,
      'strategy': strategy,
    };

    // ---------------------------------------------------------- inbounds
    final inbounds = <Map<String, dynamic>>[];
    final useTun =
        !(isDesktop && settings.captureMode == CaptureMode.systemProxy);
    if (useTun) {
      var stack = settings.tunStack.name;
      if (lowLatency && isDesktop) stack = 'system';
      final tun = <String, dynamic>{
        'type': 'tun',
        'tag': tagTun,
        'address': [
          '172.19.0.1/30',
          if (settings.ipv6) 'fdfe:dcba:9876::1/126',
        ],
        'mtu': settings.mtu,
        'auto_route': true,
        'strict_route': settings.killSwitch,
        'stack': stack,
        if (settings.memorySaver) 'udp_timeout': '30s',
      };
      if (isAndroid &&
          routing.appMode != AppRoutingMode.off &&
          appIds.isNotEmpty) {
        if (routing.appMode == AppRoutingMode.onlySelected) {
          tun['include_package'] = {
            ...appIds,
            if (game.enabled) ...gamePackages,
          }.toList();
        } else {
          final excluded =
              appIds.where((a) => !gamePackages.contains(a)).toList();
          if (excluded.isNotEmpty) tun['exclude_package'] = excluded;
        }
      }
      inbounds.add(tun);
    }
    if (isDesktop) {
      inbounds.add({
        'type': 'mixed',
        'tag': tagMixed,
        'listen': settings.allowLan ? '0.0.0.0' : '127.0.0.1',
        'listen_port': settings.mixedPort,
        if (settings.captureMode == CaptureMode.systemProxy)
          'set_system_proxy': true,
      });
    }

    // ---------------------------------------------------------- route
    final usesProcess = xrayPlan != null ||
        (isDesktop &&
            (desktopProcessRules || (game.enabled && gameProcesses.isNotEmpty)));
    final route = <String, dynamic>{
      'rules': rules,
      if (ruleSets.isNotEmpty) 'rule_set': ruleSets.values.toList(),
      'final': finalOutbound,
      'auto_detect_interface': true,
      'default_domain_resolver': {'server': dnsDirect, 'strategy': strategy},
      'default_http_client': httpClientTag,
      if (usesProcess) 'find_process': true,
    };

    final config = <String, dynamic>{
      'log': {'level': settings.logLevel.name, 'timestamp': true},
      'dns': dns,
      'inbounds': inbounds,
      'outbounds': allOutbounds,
      if (endpointsList.isNotEmpty) 'endpoints': endpointsList,
      'route': route,
      'http_clients': [
        {'tag': httpClientTag, 'domain_resolver': dnsDirect},
      ],
      'experimental': {
        'clash_api': {
          'external_controller': endpoints.clashApi,
          'secret': endpoints.secret,
        },
        'cache_file': {
          'enabled': true,
          'path': _joinPath(cacheDir, 'cache.db'),
          // Selector memory is keyed by this id. A manual pick gets its own
          // namespace so a previous outbound cannot be restored over `default`.
          'cache_id': settings.autoSelect ? 'auto' : 'manual:${selectedNodeId ?? 'none'}',
          if (!settings.memorySaver) 'store_dns': true,
        },
      },
    };

    // ---------------------------------------------------------- engine
    // Through a chain, UDP is native only when BOTH hops carry it natively.
    final entryUdp = chainActive ? entryNode.protocol.udpNative : true;
    Map<String, dynamic> cand(String tag) {
      final n = tagToNode[tag]!;
      return {
        'tag': tag,
        'type': n.type,
        'udp_native': n.protocol.udpNative && entryUdp,
      };
    }

    final engine = <String, dynamic>{
      'clash_api': endpoints.clashApi,
      'secret': endpoints.secret,
      'control_listen': endpoints.engineApi,
      'log_level': settings.logLevel.name,
      'groups': [
        {
          'selector': tagProxy,
          'auto': settings.autoSelect,
          'mode': settings.smartMode.name,
          'probe_url': settings.probeUrl,
          'interval_sec': settings.probeIntervalSec,
          'timeout_ms': 3000,
          'candidates': exitTags.map(cand).toList(),
        },
        if (game.enabled)
          {
            'selector': tagGame,
            'auto': game.gameNodeId == null ||
                !nodeTags.containsKey(game.gameNodeId),
            'mode': SmartMode.game.name,
            'probe_url': settings.probeUrl,
            'interval_sec': settings.probeIntervalSec,
            'timeout_ms': 3000,
            'candidates': gameOrder.map(cand).toList(),
          },
      ],
    };

    const enc = JsonEncoder.withIndent('  ');
    return BuiltConfig(
      singBox: enc.convert(config),
      engine: enc.convert(engine),
      nodeTags: nodeTags,
      entryTag: chainActive ? entryTag : null,
      chainActive: chainActive,
      xray: xrayPlan?.json,
    );
  }

  // ------------------------------------------------------------ helpers

  static const _ruTlds = ['ru', 'su', 'xn--p1ai'];

  static String _ruleSetUrl(String tag) {
    switch (tag) {
      case 'geoip-ru':
        return 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs';
      case 'geosite-ru-blocked':
        return 'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs';
      case 'geoip-ru-blocked':
        return 'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru-blocked.srs';
    }
    if (tag.startsWith('geoip-')) {
      return 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/$tag.srs';
    }
    return 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/$tag.srs';
  }

  /// The dial that actually opens the socket for a node: the last helper in
  /// its detour chain (e.g. the shadowtls wrapper), or the outbound itself.
  /// That is where a chain entry detour belongs — one hop below and the
  /// helper would dial around the entry.
  static Map<String, dynamic> _outermost(
      Map<String, dynamic> ob, List<Map<String, dynamic>> helpers) {
    final byTag = {for (final h in helpers) h['tag'] as String: h};
    var cur = ob;
    final seen = <String>{};
    while (true) {
      final det = cur['detour'];
      final next = det is String ? byTag[det] : null;
      if (next == null || !seen.add(det as String)) return cur;
      cur = next;
    }
  }

  /// Per-node tweaks: TCP Fast Open (Game Mode low-latency) and TLS record
  /// fragmentation (anti-DPI) for TCP-based nodes. Neither applies to a
  /// detoured dial: TFO needs a real socket, and the ClientHello of a
  /// connection inside another tunnel is invisible to DPI anyway.
  static void _tune(
      Map<String, dynamic> ob, AppSettings settings, bool tfo) {
    final type = ob['type'];
    if (!_tcpTypes.contains(type)) return;
    final hasDetour = ob['detour'] is String;
    // anytls rejects tcp_fast_open ("not supported with anytls outbound").
    if (tfo && !hasDetour && type != 'anytls') ob['tcp_fast_open'] = true;
    if (settings.antiDpi && !hasDetour) {
      final tls = ob['tls'];
      if (tls is Map &&
          tls['enabled'] == true &&
          tls['reality'] == null &&
          tls['fragment'] != true) {
        ob['tls'] = {...tls, 'record_fragment': true};
      }
    }
  }

  static List<String> _domains(List<String> raw) {
    final out = <String>{};
    for (var d in raw) {
      d = d.trim().toLowerCase();
      if (d.isEmpty) continue;
      d = d.replaceFirst(RegExp(r'^[a-z]+://'), '');
      d = d.split('/').first;
      if (d.startsWith('*.')) d = d.substring(2);
      if (d.startsWith('.')) d = d.substring(1);
      if (d.isEmpty) continue;
      out.add(_punycodeDomain(d));
    }
    return out.toList();
  }

  static Map<String, dynamic> _dnsServer(String spec, String tag,
      {required String fallback, String? resolver, String? detour}) {
    var s = spec.trim();
    if (s.isEmpty) s = fallback;
    final server = <String, dynamic>{'tag': tag};
    String host;
    int? port;
    String? path;
    String type;
    if (s == 'local' || s == 'system') {
      return {'type': 'local', 'tag': tag};
    }
    final m = RegExp(r'^([a-z0-9+]+)://(.*)$').firstMatch(s);
    String rest;
    if (m != null) {
      final scheme = m.group(1)!;
      rest = m.group(2)!;
      type = switch (scheme) {
        'https' => 'https',
        'h3' || 'http3' => 'h3',
        'tls' || 'dot' => 'tls',
        'quic' || 'doq' => 'quic',
        'tcp' => 'tcp',
        _ => 'udp',
      };
    } else {
      rest = s;
      type = 'udp';
    }
    final slash = rest.indexOf('/');
    if (slash >= 0) {
      path = rest.substring(slash);
      rest = rest.substring(0, slash);
    }
    if (rest.startsWith('[')) {
      final end = rest.indexOf(']');
      host = rest.substring(1, end);
      if (rest.length > end + 2) port = int.tryParse(rest.substring(end + 2));
    } else if (':'.allMatches(rest).length == 1) {
      final ci = rest.indexOf(':');
      host = rest.substring(0, ci);
      port = int.tryParse(rest.substring(ci + 1));
    } else {
      host = rest;
    }
    server['type'] = type;
    server['server'] = host;
    if (port != null) server['server_port'] = port;
    if ((type == 'https' || type == 'h3') &&
        path != null &&
        path != '/dns-query') {
      server['path'] = path;
    }
    if (detour != null) server['detour'] = detour;
    if (!_isIpLiteral(host) && resolver != null) {
      server['domain_resolver'] = resolver;
    }
    return server;
  }

  static bool _isIpLiteral(String h) =>
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h) || h.contains(':');

  static String _sanitizeTag(String name) {
    var s = name
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length > 64) s = s.substring(0, 64).trim();
    return s.isEmpty ? 'node' : s;
  }

  static String _uniqueTag(String base, Set<String> used) {
    var tag = base;
    var i = 2;
    while (used.contains(tag)) {
      tag = '$base $i';
      i++;
    }
    used.add(tag);
    return tag;
  }

  static String _joinPath(String dir, String file) {
    if (dir.isEmpty) return file;
    final sep = dir.contains('\\') && !dir.contains('/') ? '\\' : '/';
    return dir.endsWith(sep) ? '$dir$file' : '$dir$sep$file';
  }

  static Map<String, dynamic> _deepCopy(Map m) =>
      jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

  /// Converts non-ASCII labels (e.g. `рф`, `пример.рф`) to punycode, as
  /// sing-box matches the ASCII form of domains.
  static String _punycodeDomain(String domain) {
    return domain.split('.').map((label) {
      if (label.codeUnits.every((c) => c < 0x80)) return label;
      return 'xn--${_punycodeEncode(label)}';
    }).join('.');
  }

  // RFC 3492 punycode encoder.
  static String _punycodeEncode(String input) {
    const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
    const initialBias = 72, initialN = 128;
    final cps = input.runes.toList();
    final out = StringBuffer();
    for (final c in cps) {
      if (c < 0x80) out.writeCharCode(c);
    }
    final b = out.length;
    var h = b;
    if (b > 0) out.write('-');
    var n = initialN, delta = 0, bias = initialBias;
    String digit(int d) =>
        String.fromCharCode(d < 26 ? d + 97 : d - 26 + 48);
    int adapt(int delta, int numPoints, bool first) {
      delta = first ? delta ~/ damp : delta ~/ 2;
      delta += delta ~/ numPoints;
      var k = 0;
      while (delta > ((base - tMin) * tMax) ~/ 2) {
        delta ~/= base - tMin;
        k += base;
      }
      return k + (((base - tMin + 1) * delta) ~/ (delta + skew));
    }

    while (h < cps.length) {
      var m = 0x7FFFFFFF;
      for (final c in cps) {
        if (c >= n && c < m) m = c;
      }
      delta += (m - n) * (h + 1);
      n = m;
      for (final c in cps) {
        if (c < n) delta++;
        if (c == n) {
          var q = delta;
          for (var k = base;; k += base) {
            final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
            if (q < t) break;
            out.write(digit(t + (q - t) % (base - t)));
            q = (q - t) ~/ (base - t);
          }
          out.write(digit(q));
          bias = adapt(delta, h + 1, h == b);
          delta = 0;
          h++;
        }
      }
      delta++;
      n++;
    }
    return out.toString();
  }
}
