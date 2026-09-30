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
  PlatformKind platform = PlatformKind.windows,
  void Function(BuiltConfig)? inspect,
}) {
  final b = ConfigBuilder.build(
    nodes: nodes ?? allNodes(),
    selectedNodeId: selected,
    routing: routing ?? RoutingSettings(),
    game: game ?? GameSettings(),
    settings: settings ?? AppSettings(),
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
      // SSR is dropped (removed from sing-box).
      final ssr = nodes.where((n) => n.type == 'shadowsocksr');
      expect(ssr, isNotEmpty);
      for (final n in ssr) {
        expect(built.nodeTags.containsKey(n.id), isFalse);
      }
      expect(built.nodeTags.length,
          nodes.where((n) => n.type != 'shadowsocksr').length);
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
  // Real validation with `sing-box check`. Set SING_BOX_BIN to a sing-box
  // 1.14 binary built with with_quic,with_wireguard,with_utls,with_clash_api
  // (+ with_gvisor). Naive nodes are included only if the binary was built
  // with with_naive_outbound.
  final bin = Platform.environment['SING_BOX_BIN'];
  group('sing-box check', () {
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
  }, skip: bin == null ? 'SING_BOX_BIN not set' : false);
}
