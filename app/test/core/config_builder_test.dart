import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/config_builder.dart';
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/models.dart';

import 'samples.dart';

List<ProxyNode> allNodes({bool includeNaive = true}) {
  final nodes = <ProxyNode>[
    ...LinkParser.parseContent(kSampleLinks.values.join('\n')),
    ...LinkParser.parseContent(kClashYaml),
    ...LinkParser.parseContent(kSingBoxJson),
    ...LinkParser.parseContent(kWireGuardConf),
    ...LinkParser.parseContent(kXrayJson),
  ];
  return includeNaive ? nodes : nodes.where((n) => n.type != 'naive').toList();
}

const _endpoints = RuntimeEndpoints(secret: 'deadbeef');

Map<String, dynamic> buildJson({
  List<ProxyNode>? nodes,
  String? selected,
  RoutingSettings? routing,
  GameSettings? game,
  AppSettings? settings,
  ChainSettings? chain,
  PlatformKind platform = PlatformKind.windows,
  void Function(BuiltConfig)? inspect,
}) {
  final b = ConfigBuilder.build(
    nodes: nodes ?? allNodes(),
    selectedNodeId: selected,
    routing: routing ?? RoutingSettings(),
    game: game ?? GameSettings(),
    settings: settings ?? AppSettings(),
    chain: chain,
    platform: platform,
    endpoints: _endpoints,
    cacheDir: '/tmp/melsi-test',
  );
  inspect?.call(b);
  return jsonDecode(b.singBox) as Map<String, dynamic>;
}

List<Map<String, dynamic>> rulesOf(Map<String, dynamic> c) =>
    (c['route']['rules'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> outboundByTag(Map<String, dynamic> c, String tag) =>
    [...c['outbounds'] as List, ...(c['endpoints'] as List? ?? [])]
        .cast<Map<String, dynamic>>()
        .firstWhere((o) => o['tag'] == tag);

void main() {
  group('structure', () {
    test('basic layout, tags, selectors, experimental', () {
      final nodes = allNodes();
      late BuiltConfig built;
      final c = buildJson(nodes: nodes, inspect: (b) => built = b);
      final tags = [
        ...(c['outbounds'] as List).map((o) => o['tag']),
        ...(c['endpoints'] as List).map((o) => o['tag']),
      ];
      expect(tags.toSet().length, tags.length, reason: 'unique tags');
      expect(tags, containsAll(['direct', 'proxy']));
      expect(tags, isNot(contains('game')));
      final ssr = nodes.where((n) => n.type == 'shadowsocksr');
      expect(ssr, isNotEmpty);
      for (final n in ssr) {
        expect(outboundByTag(c, built.nodeTags[n.id]!)['type'], 'mihomo');
      }
      // Naive is not compiled into the desktop core (default platform here).
      expect(built.nodeTags.length,
          nodes.where((n) => n.type != 'naive').length);
      final proxy = outboundByTag(c, 'proxy');
      expect(proxy['type'], 'selector');
      expect(proxy['interrupt_exist_connections'], false);
      expect((proxy['outbounds'] as List).length, built.nodeTags.length);
      expect(proxy['default'], (proxy['outbounds'] as List).first);
      // WireGuard nodes are endpoints.
      for (final e in c['endpoints'] as List) {
        expect(e['type'], 'wireguard');
      }
      expect(c['experimental']['clash_api'],
          {'external_controller': '127.0.0.1:9790', 'secret': 'deadbeef'});
      expect(c['experimental']['cache_file'],
          {'enabled': true, 'path': '/tmp/melsi-test/cache.db'});
      expect(c['route']['auto_detect_interface'], true);
      expect(c['route']['default_domain_resolver']['server'], 'dns-direct');
      final tun = (c['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
      expect(tun['tag'], 'tun-in');
      expect(tun['address'], ['172.19.0.1/30']);
      expect(tun['auto_route'], true);
      expect(tun['strict_route'], false);
      expect(tun['stack'], 'mixed');
      final mixed =
          (c['inbounds'] as List).firstWhere((i) => i['type'] == 'mixed');
      expect(mixed['listen'], '127.0.0.1');
      expect(mixed['listen_port'], 7890);
      expect(mixed['set_system_proxy'], isNull);
      final rules = rulesOf(c);
      expect(rules[0], {'action': 'sniff'});
      expect(rules[1]['action'], 'hijack-dns');
      expect(rules[2], {'ip_is_private': true, 'outbound': 'direct'});
    });

    test('duplicate names get suffixes, selected default honoured', () {
      final a = LinkParser.parseLink(kSampleLinks['tuic']!)!..name = 'Same';
      final b = LinkParser.parseLink(kSampleLinks['anytls']!)!..name = 'Same';
      final p = LinkParser.parseLink(kSampleLinks['hy2_simple']!)!..name = 'proxy';
      late BuiltConfig built;
      final c = buildJson(
          nodes: [a, b, p], selected: b.id, inspect: (x) => built = x);
      expect(built.nodeTags[a.id], 'Same');
      expect(built.nodeTags[b.id], 'Same 2');
      expect(built.nodeTags[p.id], 'proxy 2');
      expect(outboundByTag(c, 'proxy')['default'], 'Same 2');
    });

    test('no nodes still valid', () {
      final c = buildJson(nodes: []);
      expect(outboundByTag(c, 'proxy')['outbounds'], ['direct']);
      expect(c.containsKey('endpoints'), isFalse);
    });

    test('presets', () {
      for (final preset in RoutingPreset.values) {
        final c = buildJson(routing: RoutingSettings(preset: preset));
        final rules = rulesOf(c);
        final sets = (c['route']['rule_set'] as List? ?? [])
            .map((r) => r['tag'])
            .toList();
        switch (preset) {
          case RoutingPreset.global:
            expect(c['route']['final'], 'proxy');
            expect(c['dns']['final'], 'dns-remote');
          case RoutingPreset.smartRu:
            expect(c['route']['final'], 'proxy');
            expect(sets, containsAll(['geosite-category-ru', 'geoip-ru']));
            expect(
                rules.any((r) =>
                    (r['domain_suffix'] as List?)?.contains('xn--p1ai') ==
                    true),
                isTrue);
          case RoutingPreset.blockedOnly:
            expect(c['route']['final'], 'direct');
            expect(c['dns']['final'], 'dns-direct');
            expect(sets,
                containsAll(['geosite-ru-blocked', 'geoip-ru-blocked']));
          case RoutingPreset.direct:
            expect(c['route']['final'], 'direct');
        }
        for (final rs in c['route']['rule_set'] as List? ?? []) {
          expect(rs['type'], 'remote');
          expect(rs['format'], 'binary');
          expect((rs['url'] as String).endsWith('.srs'), isTrue);
          expect(rs['http_client'], 'direct-http');
        }
      }
    });

    test('custom domains, ads, bypassLan off', () {
      final c = buildJson(
        routing: RoutingSettings(
          blockAds: true,
          bypassLan: false,
          directDomains: ['https://Yandex.ru/', '*.пример.рф'],
          proxyDomains: ['.youtube.com'],
          blockDomains: ['ads.example.com'],
        ),
      );
      final rules = rulesOf(c);
      expect(rules.any((r) => r['ip_is_private'] == true), isFalse);
      expect(rules, anyElement(equals({
        'domain_suffix': ['ads.example.com'],
        'action': 'reject'
      })));
      expect(rules, anyElement(equals({
        'rule_set': ['geosite-category-ads-all'],
        'action': 'reject'
      })));
      expect(rules, anyElement(equals({
        'domain_suffix': ['youtube.com'],
        'outbound': 'proxy'
      })));
      expect(rules, anyElement(equals({
        'domain_suffix': ['yandex.ru', 'xn--e1afmkfd.xn--p1ai'],
        'outbound': 'direct'
      })));
    });

    test('game mode: selector, rules order, TFO, engine', () {
      final nodes = allNodes();
      late BuiltConfig built;
      final c = buildJson(
        nodes: nodes,
        game: GameSettings(
          enabled: true,
          gameIds: {'cs2', 'pubg_mobile', 'fortnite'},
          customApps: [AppRule(id: 'mygame.exe')],
        ),
        platform: PlatformKind.windows,
        inspect: (b) => built = b,
      );
      final game = outboundByTag(c, 'game');
      final members = (game['outbounds'] as List).cast<String>();
      // UDP-native first.
      final firstTcp = members.indexWhere((t) {
        final n = nodes.firstWhere((n) => built.nodeTags[n.id] == t);
        return !n.protocol.udpNative;
      });
      for (final t in members.sublist(firstTcp)) {
        final n = nodes.firstWhere((n) => built.nodeTags[n.id] == t);
        expect(n.protocol.udpNative, isFalse);
      }
      expect(game['default'], members.first);
      final rules = rulesOf(c);
      final dl = rules.indexWhere((r) =>
          (r['domain_suffix'] as List?)?.contains('steamcontent.com') == true);
      final proc = rules.indexWhere((r) => r['process_name'] != null);
      expect(dl, greaterThan(0));
      expect(rules[dl]['outbound'], 'direct');
      expect(proc, greaterThan(dl));
      expect(rules[proc]['outbound'], 'game');
      expect(rules[proc]['process_name'],
          containsAll(['cs2.exe', 'FortniteClient-Win64-Shipping.exe', 'mygame.exe']));
      expect(rules.any((r) => r['package_name'] != null), isFalse);
      expect(c['route']['find_process'], true);
      // system stack on desktop in low-latency mode
      final tun = (c['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
      expect(tun['stack'], 'system');
      // TFO on TCP nodes only
      for (final o in (c['outbounds'] as List).cast<Map>()) {
        if (o['type'] == 'vless' && o['detour'] == null) {
          expect(o['tcp_fast_open'], true);
        }
        if (o['type'] == 'hysteria2' || o['type'] == 'tuic') {
          expect(o['tcp_fast_open'], isNull);
        }
      }
      final engine = jsonDecode(built.engine) as Map<String, dynamic>;
      expect(engine['clash_api'], '127.0.0.1:9790');
      expect(engine['control_listen'], '127.0.0.1:9791');
      final groups = (engine['groups'] as List).cast<Map>();
      expect(groups.map((g) => g['selector']), ['proxy', 'game']);
      expect(groups[0]['auto'], true);
      expect(groups[0]['mode'], 'balanced');
      expect(groups[1]['mode'], 'game');
      expect(groups[1]['auto'], true);
      expect((groups[1]['candidates'] as List).first['udp_native'], true);
      expect(groups[0]['candidates'].length, built.nodeTags.length);
    });

    test('game mode on android uses package_name and keeps mixed stack', () {
      final c = buildJson(
        game: GameSettings(enabled: true, gameIds: {'pubg_mobile', 'cs2'}),
        platform: PlatformKind.android,
      );
      final rules = rulesOf(c);
      expect(rules.any((r) => r['process_name'] != null), isFalse);
      final pkg = rules.firstWhere((r) => r['package_name'] != null);
      expect(pkg['package_name'], contains('com.tencent.ig'));
      expect(pkg['outbound'], 'game');
      final tun = (c['inbounds'] as List).single;
      expect(tun['stack'], 'mixed');
      expect(c['inbounds'].any((i) => i['type'] == 'mixed'), isFalse);
    });

    test('ios: no process/package rules, no per-app', () {
      final c = buildJson(
        platform: PlatformKind.ios,
        game: GameSettings(enabled: true, gameIds: {'pubg_mobile', 'cs2'}),
        routing: RoutingSettings(
            appMode: AppRoutingMode.onlySelected,
            appRules: [AppRule(id: 'org.telegram.messenger')]),
      );
      final rules = rulesOf(c);
      expect(rules.any((r) => r['process_name'] != null), isFalse);
      expect(rules.any((r) => r['package_name'] != null), isFalse);
      final tun = (c['inbounds'] as List).single;
      expect(tun['include_package'], isNull);
      expect(rules.any((r) => r['outbound'] == 'game'), isTrue);
    });

    test('mobile ignores restored PC game domain and download rules', () {
      for (final platform in [PlatformKind.android, PlatformKind.ios]) {
        final config = buildJson(
          platform: platform,
          game: GameSettings(enabled: true, gameIds: {'cs2', 'steam', 'pubg_mobile'}),
        );
        final domains = rulesOf(config)
            .expand((rule) => (rule['domain_suffix'] as List?) ?? const [])
            .toSet();
        expect(domains, isNot(contains('steamserver.net')));
        expect(domains, isNot(contains('steamcontent.com')));
        expect(domains, isNot(contains('steampowered.com')));
        expect(rulesOf(config).any((rule) => rule['outbound'] == 'game'), isTrue);
      }
    });

    test('per-app android include/exclude', () {
      var c = buildJson(
        platform: PlatformKind.android,
        routing: RoutingSettings(
            appMode: AppRoutingMode.onlySelected,
            appRules: [AppRule(id: 'org.telegram.messenger')]),
        game: GameSettings(enabled: true, gameIds: {'standoff2'}),
      );
      var tun = (c['inbounds'] as List).single;
      expect(tun['include_package'],
          ['org.telegram.messenger', 'com.axlebolt.standoff2']);
      c = buildJson(
        platform: PlatformKind.android,
        routing: RoutingSettings(
            appMode: AppRoutingMode.bypassSelected,
            appRules: [AppRule(id: 'ru.sberbankmobile')]),
      );
      tun = (c['inbounds'] as List).single;
      expect(tun['exclude_package'], ['ru.sberbankmobile']);
    });

    test('per-app desktop process rules', () {
      var rules = rulesOf(buildJson(
        platform: PlatformKind.macos,
        routing: RoutingSettings(
            appMode: AppRoutingMode.onlySelected,
            appRules: [AppRule(id: 'Telegram')]),
      ));
      expect(rules, anyElement(equals({
        'process_name': ['Telegram'],
        'invert': true,
        'outbound': 'direct'
      })));
      rules = rulesOf(buildJson(
        platform: PlatformKind.linux,
        routing: RoutingSettings(
            appMode: AppRoutingMode.bypassSelected,
            appRules: [AppRule(id: 'firefox')]),
      ));
      expect(rules, anyElement(equals({
        'process_name': ['firefox'],
        'outbound': 'direct'
      })));
    });

    test('kill switch, ipv6, system proxy, allow lan', () {
      final c = buildJson(
        settings: AppSettings(
            killSwitch: true,
            ipv6: true,
            captureMode: CaptureMode.systemProxy,
            allowLan: true,
            mixedPort: 2080),
      );
      final inbounds = (c['inbounds'] as List).cast<Map>();
      expect(inbounds.any((i) => i['type'] == 'tun'), isFalse);
      expect(inbounds.single['listen'], '0.0.0.0');
      expect(inbounds.single['listen_port'], 2080);
      expect(inbounds.single['set_system_proxy'], true);
      expect(c['dns']['strategy'], 'prefer_ipv4');
      final c2 = buildJson(settings: AppSettings(killSwitch: true, ipv6: true));
      final tun = (c2['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
      expect(tun['strict_route'], true);
      expect(tun['address'], ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
    });

    test('anti-DPI', () {
      final c = buildJson(
        settings: AppSettings(antiDpi: true),
        routing: RoutingSettings(
            preset: RoutingPreset.direct, directDomains: ['rutracker.org']),
      );
      final rules = rulesOf(c);
      final ro = rules.where((r) => r['action'] == 'route-options').toList();
      expect(ro.any((r) =>
          r['tls_fragment'] == true &&
          (r['domain_suffix'] as List?)?.contains('rutracker.org') == true), isTrue);
      expect(ro.any((r) =>
          r['tls_fragment'] == true &&
          (r['rule_set'] as List?)?.contains('geosite-ru-blocked') == true), isTrue);
      expect(rules.last['tls_record_fragment'], true);
      // TLS nodes get record fragmentation, reality ones don't.
      for (final o in (c['outbounds'] as List).cast<Map>()) {
        final tls = o['tls'];
        if (tls is Map && o['type'] == 'trojan') {
          expect(tls['record_fragment'], true);
        }
        if (tls is Map && tls['reality'] != null) {
          expect(tls['record_fragment'], isNull);
        }
      }
      final g = buildJson(settings: AppSettings(antiDpi: true));
      expect(rulesOf(g).any((r) => r['action'] == 'route-options'), isFalse);
    });

    test('dns servers', () {
      final c = buildJson(
          settings: AppSettings(
              remoteDns: 'tls://dns.google', directDns: 'udp://77.88.8.8'));
      final servers = (c['dns']['servers'] as List).cast<Map>();
      expect(servers[0], {'type': 'local', 'tag': 'dns-local'});
      expect(servers[1], {'tag': 'dns-direct', 'type': 'udp', 'server': '77.88.8.8'});
      expect(servers[2], {
        'tag': 'dns-remote',
        'type': 'tls',
        'server': 'dns.google',
        'detour': 'proxy',
        'domain_resolver': 'dns-direct',
      });
      final d = buildJson();
      final s = (d['dns']['servers'] as List).cast<Map>();
      expect(s[1]['type'], 'https');
      expect(s[1]['server'], '77.88.8.8');
      expect(s[2]['server'], '1.1.1.1');
      expect(d['dns']['strategy'], 'ipv4_only');
    });

    test('shadowtls chain gets renamed', () {
      final n = LinkParser.parseLink(kSampleLinks['ss_shadowtls']!)!;
      final c = buildJson(nodes: [n]);
      final ss = outboundByTag(c, 'SS ShadowTLS');
      final stls = outboundByTag(c, ss['detour'] as String);
      expect(stls['type'], 'shadowtls');
      expect(stls['server'], 'stls.example.com');
      expect(outboundByTag(c, 'proxy')['outbounds'], ['SS ShadowTLS']);
    });
  });

  // ------------------------------------------------------------------------
  // Real validation with `melsi-core check`. Set MELSI_CORE_BIN to the
  // binary produced by scripts/build-core.sh. Naive nodes are included only if the binary was built
  // with with_naive_outbound.
  final bin = Platform.environment['MELSI_CORE_BIN'];
  group('probe hosts', () {
    test('explicit blocks take precedence over measurement exceptions', () {
      final config = buildJson(routing: RoutingSettings(blockDomains: ['ipwho.is']));
      for (final rules in [rulesOf(config), (config['dns']['rules'] as List).cast<Map<String, dynamic>>()]) {
        final block = rules.indexWhere((rule) => rule['action'] == 'reject' &&
            (rule['domain_suffix'] as List?)?.contains('ipwho.is') == true);
        final probe = rules.indexWhere((rule) =>
            (rule['domain_suffix'] as List?)?.contains('speed.cloudflare.com') == true);
        expect(block, greaterThanOrEqualTo(0));
        expect(block, lessThan(probe));
      }
    });

    test('measurement hosts are proxied before any preset rule, under every preset', () {
      for (final preset in RoutingPreset.values) {
        final c = buildJson(routing: RoutingSettings(preset: preset));
        final rules = rulesOf(c);
        final i = rules.indexWhere((r) =>
            r['outbound'] == 'proxy' &&
            r['domain_suffix'] is List &&
            (r['domain_suffix'] as List).contains('speed.cloudflare.com'));
        expect(i, greaterThanOrEqualTo(0), reason: '$preset: probe rule missing');
        // Preset rules (rule_set / geoip / final fallbacks) all come later.
        final firstPreset = rules.indexWhere((r) => r.containsKey('rule_set'));
        if (firstPreset >= 0) expect(i, lessThan(firstPreset), reason: '$preset');
        final dns = (c['dns']['rules'] as List).cast<Map<String, dynamic>>();
        expect(
            dns.any((r) =>
                r['server'] == 'dns-remote' &&
                (r['domain_suffix'] as List?)?.contains('ipwho.is') == true),
            isTrue,
            reason: '$preset: probe DNS rule missing');
      }
    });
  });

  group('melsi-core check', () {
    late bool hasNaive;
    late Directory tmp;
    setUpAll(() {
      final v = Process.runSync(bin!, ['version']);
      hasNaive = v.stdout.toString().contains('with_naive_outbound');
      tmp = Directory.systemTemp.createTempSync('melsi-sb-check');
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    var counter = 0;
    void check(String label, BuiltConfig b) {
      final f = File('${tmp.path}/c${counter++}.json')
        ..writeAsStringSync(b.singBox);
      final r = Process.runSync(bin!, ['check', '-c', f.path],
          environment: {'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': ''});
      final err = '${r.stdout}${r.stderr}';
      expect(r.exitCode, 0, reason: '$label\n$err\n${f.path}');
      expect(err.toLowerCase().contains('deprecated'), isFalse,
          reason: '$label: deprecation warning\n$err');
    }

    test('matrix: presets x game x platforms x killSwitch/antiDpi', () {
      final nodes = allNodes(includeNaive: hasNaive);
      expect(nodes.map((n) => n.type).toSet(),
          containsAll(<String>{
            'vmess', 'vless', 'trojan', 'shadowsocks', 'snell', 'hysteria',
            'hysteria2', 'tuic', 'anytls', 'wireguard', 'ssh', 'socks',
            'http', 'shadowsocksr',
          }));
      var n = 0;
      for (final preset in RoutingPreset.values) {
        for (final gameOn in [false, true]) {
          for (final platform in PlatformKind.values) {
            for (final flags in [(false, false), (true, true)]) {
              final routing = RoutingSettings(
                preset: preset,
                directDomains: ['yandex.ru', 'пример.рф'],
                proxyDomains: ['youtube.com'],
                blockDomains: ['doubleclick.net'],
                appMode: n % 3 == 0
                    ? AppRoutingMode.onlySelected
                    : (n % 3 == 1
                        ? AppRoutingMode.bypassSelected
                        : AppRoutingMode.off),
                appRules: [
                  AppRule(
                      id: platform == PlatformKind.android
                          ? 'org.telegram.messenger'
                          : 'Telegram.exe')
                ],
              );
              final game = GameSettings(
                enabled: gameOn,
                gameIds: {'cs2', 'pubg_mobile', 'genshin', 'steam', 'wot'},
                customApps: [AppRule(id: 'custom.game')],
                lowLatencyStack: n.isEven,
                gameNodeId: n % 4 == 0 ? nodes[3].id : null,
              );
              final settings = AppSettings(
                killSwitch: flags.$1,
                antiDpi: flags.$2,
                ipv6: flags.$1,
                tunStack: TunStack.values[n % 3],
                captureMode: n % 5 == 0 ? CaptureMode.systemProxy : CaptureMode.tun,
                logLevel: LogLevel.values[n % 5],
                smartMode: SmartMode.values[n % 4],
              );
              final b = ConfigBuilder.build(
                nodes: nodes,
                selectedNodeId: nodes[n % nodes.length].id,
                routing: routing,
                game: game,
                settings: settings,
                platform: platform,
                endpoints: _endpoints,
                cacheDir: tmp.path,
              );
              check(
                  '${preset.name} game=$gameOn ${platform.name} '
                  'ks/dpi=${flags.$1}',
                  b);
              n++;
            }
          }
        }
      }
      expect(n, 80);
    });

    test('edge cases', () {
      for (final dns in [
        ('https://dns.google/dns-query', 'https://77.88.8.8/dns-query'),
        ('tls://1.1.1.1', 'udp://77.88.8.8'),
        ('quic://dns.adguard-dns.com', 'tcp://8.8.8.8:53'),
        ('h3://1.1.1.1/dns-query', '77.88.8.8'),
        ('8.8.8.8', 'local'),
      ]) {
        check(
            'dns $dns',
            ConfigBuilder.build(
              nodes: allNodes(includeNaive: hasNaive),
              selectedNodeId: null,
              routing: RoutingSettings(),
              game: GameSettings(),
              settings: AppSettings(remoteDns: dns.$1, directDns: dns.$2),
              platform: PlatformKind.linux,
              endpoints: _endpoints,
              cacheDir: tmp.path,
            ));
      }
      // No nodes at all.
      check(
          'empty',
          ConfigBuilder.build(
            nodes: const [],
            selectedNodeId: null,
            routing: RoutingSettings(preset: RoutingPreset.global),
            game: GameSettings(enabled: true, gameIds: {'cs2'}),
            settings: AppSettings(),
            platform: PlatformKind.android,
            endpoints: _endpoints,
            cacheDir: tmp.path,
          ));
      // Every node on its own (catches per-protocol schema errors).
      for (final node in allNodes(includeNaive: hasNaive)) {
        check(
            'single ${node.type} ${node.name}',
            ConfigBuilder.build(
              nodes: [node],
              selectedNodeId: node.id,
              routing: RoutingSettings(preset: RoutingPreset.global),
              game: GameSettings(),
              settings: AppSettings(antiDpi: true),
              platform: PlatformKind.windows,
              endpoints: _endpoints,
              cacheDir: tmp.path,
            ));
      }
    });
  }, skip: bin == null ? 'MELSI_CORE_BIN not set' : false);

  // ------------------------------------------------------------------------
  group('chain', () {
    List<Map<String, dynamic>> engineGroups(BuiltConfig b) =>
        ((jsonDecode(b.engine) as Map<String, dynamic>)['groups'] as List)
            .cast<Map<String, dynamic>>();

    test('exits detour through the entry; selectors and engine exclude it', () {
      final nodes = allNodes();
      // A TLS-over-TCP entry: the one handshake DPI sees, so it is the one
      // that keeps TFO and record fragmentation.
      final entry = nodes.firstWhere((n) => n.name == 'Trojan WS' || n.type == 'trojan');
      final stls = nodes.firstWhere((n) => n.name == 'SS ShadowTLS');
      late BuiltConfig built;
      final c = buildJson(
        nodes: nodes,
        selected: entry.id,
        chain: ChainSettings(enabled: true, entryNodeId: entry.id),
        settings: AppSettings(antiDpi: true),
        game: GameSettings(enabled: true, gameIds: {'cs2'}, lowLatencyStack: true),
        inspect: (b) => built = b,
      );
      final entryTag = built.nodeTags[entry.id]!;
      expect(built.chainActive, isTrue);
      expect(built.entryTag, entryTag);

      // Every node but the entry dials through it; the entry stays plain.
      // A node with helpers (shadowtls) carries the detour on its outermost
      // helper, so walk each node's own detour chain to its end.
      final nodeTagSet = built.nodeTags.values.toSet();
      for (final e in built.nodeTags.entries) {
        final o = outboundByTag(c, e.value);
        if (e.key == entry.id) {
          expect(o['detour'], isNull, reason: 'entry ${e.value}');
          continue;
        }
        var outer = o;
        while (outer['detour'] is String && !nodeTagSet.contains(outer['detour'])) {
          outer = outboundByTag(c, outer['detour'] as String);
        }
        expect(outer['detour'], entryTag, reason: e.value);
        // Detoured dials get neither TFO nor record fragmentation.
        expect(outer['tcp_fast_open'], isNull, reason: e.value);
        final tls = outer['tls'];
        if (tls is Map) expect(tls['record_fragment'], isNull, reason: e.value);
      }
      // The shadowtls helper is the outermost dial: it carries the detour,
      // its Shadowsocks user keeps dialling the (renamed) helper.
      final ss = outboundByTag(c, built.nodeTags[stls.id]!);
      final helper = outboundByTag(c, ss['detour'] as String);
      expect(helper['type'], 'shadowtls');
      expect(helper['detour'], entryTag);
      expect(helper['tcp_fast_open'], isNull);
      // WireGuard exits (endpoints) get the detour too.
      for (final e in c['endpoints'] as List) {
        expect(e['detour'], entryTag, reason: '${e['tag']}');
      }
      // The entry keeps TFO and record fragmentation.
      final eo = outboundByTag(c, entryTag);
      expect(eo['tcp_fast_open'], true);
      expect((eo['tls'] as Map)['record_fragment'], true);

      // Selectors: members = every node but the entry; the selection that
      // became the entry falls back to the first exit.
      final allTags = built.nodeTags.values.toList();
      final exits = allTags.where((t) => t != entryTag).toList();
      final proxy = outboundByTag(c, 'proxy');
      expect(proxy['outbounds'], exits);
      expect(proxy['default'], exits.first);
      final game = outboundByTag(c, 'game');
      expect(game['outbounds'], isNot(contains(entryTag)));
      expect((game['outbounds'] as List).toSet(), exits.toSet());
      // Engine candidates: same exclusion in both groups; UDP is native only
      // when both hops are (trojan entry -> never).
      for (final g in engineGroups(built)) {
        final cands = (g['candidates'] as List).cast<Map>();
        expect(cands.map((x) => x['tag']), isNot(contains(entryTag)));
        expect(cands.length, exits.length, reason: '${g['selector']}');
        for (final x in cands) {
          expect(x['udp_native'], false, reason: '${x['tag']}');
        }
      }
    });

    test('udp_native survives a UDP-native entry', () {
      final nodes = allNodes();
      final entry = nodes.firstWhere((n) => n.type == 'hysteria2');
      late BuiltConfig built;
      buildJson(
        nodes: nodes,
        chain: ChainSettings(enabled: true, entryNodeId: entry.id),
        game: GameSettings(enabled: true, gameIds: {'cs2'}),
        inspect: (b) => built = b,
      );
      final g = engineGroups(built)[1];
      final cands = (g['candidates'] as List).cast<Map>();
      final tuic = cands.firstWhere((x) => x['type'] == 'tuic');
      final vless = cands.firstWhere((x) => x['type'] == 'vless');
      expect(tuic['udp_native'], true);
      expect(vless['udp_native'], false);
      // A pinned game node that became the entry falls back too.
      late BuiltConfig pinned;
      final c = buildJson(
        nodes: nodes,
        chain: ChainSettings(enabled: true, entryNodeId: entry.id),
        game: GameSettings(enabled: true, gameIds: {'cs2'}, gameNodeId: entry.id),
        inspect: (b) => pinned = b,
      );
      final game = outboundByTag(c, 'game');
      expect(game['default'], (game['outbounds'] as List).first);
      final pinnedCands = (engineGroups(pinned)[1]['candidates'] as List).cast<Map>();
      expect(pinnedCands.map((x) => x['tag']), isNot(contains(pinned.entryTag)));
    });

    test('inactive chains produce the same output as no chain', () {
      final nodes = allNodes();
      final vless = nodes.firstWhere((n) => n.type == 'vless');
      final wg = nodes.firstWhere((n) => n.type == 'wireguard');
      BuiltConfig build(List<ProxyNode> ns, ChainSettings? chain) =>
          ConfigBuilder.build(
            nodes: ns,
            selectedNodeId: ns.first.id,
            routing: RoutingSettings(),
            game: GameSettings(enabled: true, gameIds: {'cs2'}),
            settings: AppSettings(antiDpi: true),
            platform: PlatformKind.windows,
            endpoints: _endpoints,
            cacheDir: '/tmp/melsi-test',
            chain: chain,
          );
      void same(String label, List<ProxyNode> ns, ChainSettings chain) {
        final a = build(ns, chain);
        final b = build(ns, null);
        expect(a.singBox, b.singBox, reason: label);
        expect(a.engine, b.engine, reason: label);
        expect(a.chainActive, isFalse, reason: label);
        expect(a.entryTag, isNull, reason: label);
        expect(a.singBox, isNot(contains('"detour": "${a.nodeTags[chain.entryNodeId]}"')));
      }

      // Entry is the only node.
      same('entry only', [vless], ChainSettings(enabled: true, entryNodeId: vless.id));
      // WireGuard can't be an entry.
      same('wireguard entry', nodes, ChainSettings(enabled: true, entryNodeId: wg.id));
      // Switched off, or no / unknown entry.
      same('disabled', nodes, ChainSettings(enabled: false, entryNodeId: vless.id));
      same('no entry', nodes, ChainSettings(enabled: true));
      same('unknown entry', nodes, ChainSettings(enabled: true, entryNodeId: 'nope'));
      final naive = nodes.firstWhere((node) => node.type == 'naive');
      same('unsupported entry', nodes, ChainSettings(enabled: true, entryNodeId: naive.id));
    });

    test('an active chain still passes every existing structural check', () {
      final nodes = allNodes();
      final entry = nodes.firstWhere((n) => n.type == 'vless');
      late BuiltConfig built;
      final c = buildJson(
        nodes: nodes,
        chain: ChainSettings(enabled: true, entryNodeId: entry.id),
        inspect: (b) => built = b,
      );
      final tags = [
        ...(c['outbounds'] as List).map((o) => o['tag']),
        ...(c['endpoints'] as List).map((o) => o['tag']),
      ];
      expect(tags.toSet().length, tags.length, reason: 'unique tags');
      // Every detour points at an existing tag.
      for (final o in [...c['outbounds'] as List, ...c['endpoints'] as List]) {
        final d = o['detour'];
        if (d != null) expect(tags, contains(d), reason: '${o['tag']}');
      }
      expect(built.nodeTags.length, greaterThan(1));
      expect(rulesOf(c).first, {'action': 'sniff'});
    });

    test('sing-box check accepts chained configs', () {
      final tmp = Directory.systemTemp.createTempSync('melsi-chain-check');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final hasNaive =
          Process.runSync(bin!, ['version']).stdout.toString().contains('with_naive_outbound');
      final nodes = allNodes(includeNaive: hasNaive);
      var i = 0;
      for (final entry in nodes.where((n) => !n.protocol.isEndpoint)) {
        for (final platform in [PlatformKind.windows, PlatformKind.android]) {
          final b = ConfigBuilder.build(
            nodes: nodes,
            selectedNodeId: entry.id,
            routing: RoutingSettings(preset: RoutingPreset.global),
            game: GameSettings(enabled: i.isEven, gameIds: {'cs2'}),
            settings: AppSettings(antiDpi: true),
            platform: platform,
            endpoints: _endpoints,
            cacheDir: tmp.path,
            chain: ChainSettings(enabled: true, entryNodeId: entry.id),
          );
          if (!b.chainActive) continue;
          final f = File('${tmp.path}/c${i++}.json')..writeAsStringSync(b.singBox);
          final r = Process.runSync(bin, ['check', '-c', f.path],
              environment: {'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': ''});
          final err = '${r.stdout}${r.stderr}';
          expect(r.exitCode, 0, reason: 'entry ${entry.name} ${platform.name}\n$err');
        }
      }
      expect(i, greaterThan(0));
    }, skip: bin == null ? 'MELSI_CORE_BIN not set' : false);
  });
}
