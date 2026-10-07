import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/config_builder.dart';
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/models.dart';

import '../ui/fakes.dart';
import 'samples.dart';

ProxyNode _node(String link) => LinkParser.parseLink(link)!;

Map<String, dynamic> _sing(BuiltConfig b) =>
    jsonDecode(b.singBox) as Map<String, dynamic>;

BuiltConfig _build({
  required List<ProxyNode> nodes,
  required AppSettings settings,
  String? selected,
  PlatformKind platform = PlatformKind.linux,
  RoutingSettings? routing,
}) => ConfigBuilder.build(
  nodes: nodes,
  selectedNodeId: selected ?? nodes.first.id,
  routing: routing ?? RoutingSettings(),
  game: GameSettings(),
  settings: settings,
  platform: platform,
  endpoints: const RuntimeEndpoints(secret: 'deadbeef'),
  cacheDir: '/tmp/melsi-test',
);

void main() {
  test(
    'manual selection owns the cache namespace and the selector default',
    () {
      final a = _node(kSampleVless);
      final b = _node(
        kSampleVless
            .replaceAll('nl1.example.com', 'de1.example.com')
            .replaceAll('Netherlands', 'Germany'),
      );
      final built = _build(
        nodes: [a, b],
        selected: b.id,
        settings: AppSettings(autoSelect: false),
      );
      final config = _sing(built);
      final proxy = (config['outbounds'] as List).cast<Map>().firstWhere(
        (o) => o['tag'] == 'proxy',
      );
      expect(proxy['default'], built.nodeTags[b.id]);
      expect(
        config['experimental']['cache_file']['cache_id'],
        'manual:${b.id}',
      );
      final engine = jsonDecode(built.engine) as Map;
      expect(engine['groups'][0]['selected'], built.nodeTags[b.id]);
    },
  );

  test('Mihomo core wraps a plain VLESS and leaves the selector in sing-box', () {
    final node = _node(
      'vless://$kUuid@203.0.113.10:443?encryption=none&security=none&type=tcp#Plain',
    );
    final built = _build(
      nodes: [node],
      settings: AppSettings(core: VpnCore.mihomo),
    );
    final tag = built.nodeTags[node.id]!;
    final config = _sing(built);
    final outbound = (config['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == tag,
    );
    expect(outbound['type'], 'mihomo');
    expect(outbound['proxy']['type'], 'vless');
    expect(outbound['proxy']['uuid'], isNotEmpty);
    expect(
      (config['outbounds'] as List).any(
        (o) => o['tag'] == 'proxy' && o['type'] == 'selector',
      ),
      isTrue,
    );
    expect(built.xray, isNull);
  });

  test('VLESS REALITY Vision uses embedded Xray across platforms and core choices', () {
    const link =
        'vless://bf000d23-0752-40b4-affe-68f7707a9661@85.95.240.151:2087?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179e30d4fc2&type=tcp#Reality';
    final node = _node(link);
    for (final platform in PlatformKind.values) {
      for (final settings in [
        AppSettings(),
        AppSettings(multiplex: true),
        AppSettings(core: VpnCore.mihomo, multiplex: true),
      ]) {
        final built = _build(
          nodes: [node],
          settings: settings,
          platform: platform,
        );
        final tag = built.nodeTags[node.id]!;
        final config = _sing(built);
        final outbound = (config['outbounds'] as List).cast<Map>().firstWhere(
          (o) => o['tag'] == tag,
        );
        expect(
          outbound['type'],
          'xray',
          reason: '${settings.core} ${settings.multiplex}',
        );
        expect(outbound.containsKey('multiplex'), isFalse);
        final xray = outbound['outbound'] as Map;
        expect(xray.containsKey('mux'), isFalse);
        final server = xray['settings']['vnext'][0];
        expect(server['users'][0]['flow'], 'xtls-rprx-vision');
        expect(server['address'], '85.95.240.151');
        expect(server['port'], 2087);
        final stream = xray['streamSettings'] as Map;
        expect(stream['security'], 'reality');
        expect(stream['realitySettings'], {
          'serverName': 'www.microsoft.com',
          'fingerprint': 'chrome',
          'publicKey': 'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc',
          'shortId': '6ba85179e30d4fc2',
        });
        expect(built.xray, isNull);
      }
    }

    final ss = _node(kSampleLinks['ss_sip002_b64']!);
    final muxed = _build(nodes: [ss], settings: AppSettings(multiplex: true));
    final muxOutbound = (_sing(muxed)['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['tag'] == muxed.nodeTags[ss.id]);
    expect(muxOutbound['type'], 'shadowsocks');
    expect(muxOutbound.containsKey('multiplex'), isFalse);

    final ssh = _node(kSampleLinks['ssh']!);
    final sshBuilt = _build(
      nodes: [ssh],
      settings: AppSettings(multiplex: true),
    );
    final sshOutbound = (_sing(sshBuilt)['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['tag'] == sshBuilt.nodeTags[ssh.id]);
    expect(sshOutbound['type'], 'ssh');
    expect(sshOutbound.containsKey('multiplex'), isFalse);
  });

  test('Xray core on desktop publishes socks hops and an Xray document', () {
    final node = _node(kSampleVless);
    final built = _build(
      nodes: [node],
      settings: AppSettings(core: VpnCore.xray, autoSelect: false),
    );
    final tag = built.nodeTags[node.id]!;
    final config = _sing(built);
    final outbound = (config['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == tag,
    );
    expect(outbound['type'], 'socks');
    expect(outbound['server'], '127.0.0.1');
    expect(outbound['server_port'], 28100);
    final rules = (config['route']['rules'] as List).cast<Map>();
    expect(
      rules.any((r) => r['process_name'] != null && r['outbound'] == 'direct'),
      isTrue,
    );
    final xray = jsonDecode(built.xray!) as Map<String, dynamic>;
    expect(xray['inbounds'], hasLength(1));
    expect((xray['inbounds'] as List).first['port'], 28100);
    final remote = (xray['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == tag,
    );
    expect(remote['protocol'], 'vless');
    expect(remote['streamSettings']['security'], 'reality');
  });

  test('Xray on a phone is embedded without an external process', () {
    final node = _node(kSampleVless);
    final built = _build(
      nodes: [node],
      settings: AppSettings(core: VpnCore.xray),
      platform: PlatformKind.android,
    );
    expect(built.xray, isNull);
    final tag = built.nodeTags[node.id]!;
    final config = _sing(built);
    final outbound = (config['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == tag,
    );
    expect(outbound['type'], 'xray');
  });

  test('memory saver and QUIC block change real sing-box fields', () {
    final node = _node(kSampleVless);
    final saved = _build(
      nodes: [node],
      settings: AppSettings(memorySaver: true, multiplex: true),
      routing: RoutingSettings(blockQuic: true),
    );
    final config = _sing(saved);
    expect(
      config['experimental']['cache_file'].containsKey('store_dns'),
      isFalse,
    );
    final tun = (config['inbounds'] as List).firstWhere(
      (i) => i['type'] == 'tun',
    );
    expect(tun['udp_timeout'], '30s');
    final rules = (config['route']['rules'] as List).cast<Map>();
    expect(
      rules.any((r) => r['protocol'] == 'quic' && r['action'] == 'reject'),
      isTrue,
    );
    final tag = saved.nodeTags[node.id]!;
    final outbound = (config['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == tag,
    );
    expect(outbound.containsKey('multiplex'), isFalse);

    final plain = _node(
      'vless://$kUuid@203.0.113.10:443?encryption=none&security=none&type=tcp#Plain',
    );
    final muxed = _build(
      nodes: [plain],
      settings: AppSettings(multiplex: true),
    );
    final muxConfig = _sing(muxed);
    final muxOutbound = (muxConfig['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == muxed.nodeTags[plain.id],
    );
    expect(muxOutbound.containsKey('multiplex'), isFalse);
  });

  test('multiplex keeps provider settings and removes incompatible imported values', () {
    final node = _node(kSampleLinks['ss_sip002_b64']!);
    node.outbound['multiplex'] = {
      'enabled': true,
      'protocol': 'smux',
      'padding': true,
      'max_connections': 2,
    };
    final built = _build(nodes: [node], settings: AppSettings(multiplex: true));
    final outbound = (_sing(built)['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == built.nodeTags[node.id],
    );
    expect(outbound['multiplex'], node.outbound['multiplex']);

    final reality = _node(kSampleVless);
    reality.outbound['multiplex'] = {'enabled': true, 'protocol': 'h2mux'};
    for (final n in [node, reality]) {
      for (final settings in [
        AppSettings(),
        AppSettings(memorySaver: true, multiplex: true),
      ]) {
        final b = _build(nodes: [n], settings: settings);
        final o = (_sing(b)['outbounds'] as List).cast<Map>().firstWhere(
          (o) => o['tag'] == b.nodeTags[n.id],
        );
        expect(o.containsKey('multiplex'), isFalse);
      }
    }
    final b = _build(nodes: [reality], settings: AppSettings(multiplex: true));
    final o = (_sing(b)['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == b.nodeTags[reality.id],
    );
    expect(o.containsKey('multiplex'), isFalse);
  });
}
