import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/compatibility_core.dart';
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/models.dart';

import 'config_builder_test.dart' show buildJson, outboundByTag;
import 'samples.dart';

String xhttpLink(String mode, {Map<String, dynamic>? extra}) =>
    'vless://$kUuid@edge.example.com:443?type=xhttp&mode=$mode&security=tls'
    '&sni=cdn.example.com&host=cdn.example.com&path=%2Ftunnel'
    '${extra == null ? '' : '&extra=${Uri.encodeComponent(jsonEncode(extra))}'}#XHTTP';

final amneziaConf = kWireGuardConf.replaceFirst('[Interface]', '''[Interface]
Jc = 4
Jmin = 40
Jmax = 70
S1 = 10
S2 = 20
H1 = 11-12
H2 = 21-22
H3 = 31-32
H4 = 41-42
I1 = <r 32>''');

void main() {
  test('SSR preserves cipher, authentication and obfuscation', () {
    final node = LinkParser.parseLink(kSampleLinks['ssr']!)!;
    final wrapped = CompatibilityCore.wrap({...node.outbound, 'tag': 'SSR'});
    expect(wrapped['type'], 'mihomo');
    expect(wrapped['proxy']['type'], 'ssr');
    expect(wrapped['proxy']['cipher'], 'aes-256-cfb');
    expect(wrapped['proxy']['protocol'], 'auth_aes128_md5');
    expect(wrapped['proxy']['obfs'], 'tls1.2_ticket_auth');
    expect(wrapped['proxy']['obfs-param'], node.outbound['obfs_param']);
    expect(wrapped['domain_resolver'], {'server': 'dns-direct'});
  });

  for (final mode in ['auto', 'packet-up', 'stream-up', 'stream-one']) {
    test('VLESS XHTTP $mode retains transport and TLS', () {
      final node = LinkParser.parseLink(xhttpLink(mode))!;
      final wrapped = CompatibilityCore.wrap({...node.outbound, 'tag': mode});
      expect(wrapped['type'], 'xray');
      final proxy = wrapped['outbound'];
      final stream = proxy['streamSettings'];
      expect(stream['network'], 'xhttp');
      expect(stream['xhttpSettings']['path'], '/tunnel');
      expect(stream['xhttpSettings']['host'], 'cdn.example.com');
      expect(stream['xhttpSettings']['mode'], mode);
      expect(stream['security'], 'tls');
      expect(stream['tlsSettings']['serverName'], 'cdn.example.com');
      expect(stream['tlsSettings']['allowInsecure'], false);
      expect(proxy['settings']['vnext'][0]['users'][0]['id'], kUuid);
    });
  }

  test('XHTTP extra and XMUX preserve explicit options', () {
    final node = LinkParser.parseLink(
      xhttpLink(
        'packet-up',
        extra: {
          'noGRPCHeader': true,
          'xPaddingBytes': '100-200',
          'headers': {'X-Test': 'value'},
          'xmux': {
            'maxConcurrency': '8-16',
            'hMaxRequestTimes': 100,
            'hKeepAlivePeriod': 30,
          },
        },
      ),
    )!;
    final transport = CompatibilityCore.wrap({
      ...node.outbound,
      'tag': 'test',
    })['outbound']['streamSettings']['xhttpSettings'];
    final extra = transport['extra'] as Map;
    expect(extra['noGRPCHeader'], true);
    expect(extra['xPaddingBytes'], '100-200');
    expect(extra['headers'], {'X-Test': 'value'});
    expect(extra['xmux'], {
      'maxConcurrency': '8-16',
      'hMaxRequestTimes': 100,
      'hKeepAlivePeriod': 30,
    });
  });

  test('explicitly unverified XHTTP TLS keeps its compatible adapter', () {
    final node = LinkParser.parseLink('${xhttpLink('stream-up').split('#').first}&allowInsecure=1#SelfSigned')!;
    final wrapped = CompatibilityCore.wrap({...node.outbound, 'tag': 'SelfSigned'});
    expect(wrapped['type'], 'mihomo');
    expect(wrapped['proxy']['skip-cert-verify'], true);
    expect(wrapped['proxy']['network'], 'xhttp');
  });

  test('unsupported XHTTP variants fail instead of silently using TCP', () {
    expect(LinkParser.parseLink(xhttpLink('unknown')), isNull);
    expect(
      LinkParser.parseLink(xhttpLink('auto').replaceFirst('vless:', 'trojan:')),
      isNull,
    );
    expect(
      LinkParser.parseLink(
        xhttpLink(
          'auto',
          extra: {
            'downloadSettings': {'address': 'other.example.com'},
          },
        ),
      ),
      isNull,
    );
    expect(
      LinkParser.parseLink(xhttpLink('auto', extra: {'unknown': true})),
      isNull,
    );
  });

  test(
    'Clash XHTTP import preserves settings and rejects unsupported downloads',
    () {
      final proxy = {
        'name': 'XHTTP',
        'type': 'vless',
        'server': 'edge.example.com',
        'port': 443,
        'uuid': kUuid,
        'tls': true,
        'network': 'xhttp',
        'xhttp-opts': {
          'path': '/tunnel',
          'mode': 'stream-up',
          'x-padding-bytes': '20-50',
        },
      };
      final node = LinkParser.parseContent(
        jsonEncode({
          'proxies': [proxy],
        }),
      ).single;
      expect(node.outbound['transport']['mode'], 'stream-up');
      expect(node.outbound['transport']['options']['x-padding-bytes'], '20-50');
      proxy['xhttp-opts'] = {
        'download-settings': {'server': 'elsewhere.example.com'},
      };
      expect(
        LinkParser.parseContent(
          jsonEncode({
            'proxies': [proxy],
          }),
        ),
        isEmpty,
      );
    },
  );

  test('AmneziaWG conf keeps range headers and does not become plain WG', () {
    final node = LinkParser.parseContent(amneziaConf).single;
    expect(node.protocol, ProxyProtocol.amneziawg);
    expect(node.protocol.isEndpoint, true);
    final proxy = CompatibilityCore.wrap({
      ...node.outbound,
      'tag': 'AWG',
    })['proxy'];
    expect(proxy['type'], 'wireguard');
    expect(proxy['amnezia-wg-option']['h1'], '11-12');
    expect(proxy['amnezia-wg-option']['i1'], '<r 32>');
    expect(proxy['amnezia-wg-option']['jc'], 4);
    expect(proxy['private-key'], kWgPriv);
    expect(proxy['peers'], isNotEmpty);
    expect(proxy['ip'], isNot(contains('/')));
    expect(
      LinkParser.parseContent(
        amneziaConf.replaceFirst('Jc = 4', 'Jc = invalid'),
      ),
      isEmpty,
    );
  });

  test('AWG aliases require parameters; ordinary WireGuard stays native', () {
    final original = kSampleLinks['wireguard']!;
    final source = original.split('#').first;
    for (final scheme in ['awg', 'amneziawg', 'wireguard']) {
      final link = source.replaceFirst('wireguard:', '$scheme:');
      final node = LinkParser.parseLink('$link&Jc=4&H1=11-12')!;
      expect(node.type, 'amneziawg');
    }
    expect(
      LinkParser.parseLink(source.replaceFirst('wireguard:', 'awg:')),
      isNull,
    );
    final plain = LinkParser.parseLink(original)!;
    expect(plain.protocol, ProxyProtocol.wireguard);
    expect(CompatibilityCore.needsMihomo(plain.outbound), false);
  });

  test('Clash AmneziaWG keeps explicit version and custom headers', () {
    final nodes = LinkParser.parseContent(
      jsonEncode({
        'proxies': [
          {
            'name': 'AWG',
            'type': 'wireguard',
            'server': '127.0.0.1',
            'port': 51820,
            'private-key': kWgPriv,
            'public-key': kWgPub,
            'ip': '10.0.0.2',
            'amnezia-wg-option': {'version': 2, 'jc': 4, 'h1': '11-12'},
          },
        ],
      }),
    );
    expect(nodes.single.outbound['amnezia'], {
      'version': 2,
      'jc': 4,
      'h1': '11-12',
    });
  });

  for (final platform in PlatformKind.values) {
    test('$platform keeps SSR, XHTTP and AWG in selectors', () {
      final nodes = [
        LinkParser.parseLink(kSampleLinks['ssr']!)!,
        LinkParser.parseLink(xhttpLink('auto'))!,
        LinkParser.parseContent(amneziaConf).single,
      ];
      late BuiltConfig built;
      final config = buildJson(
        nodes: nodes,
        platform: platform,
        inspect: (value) => built = value,
      );
      expect(built.nodeTags.length, 3);
      for (final node in nodes) {
        expect(
          outboundByTag(config, built.nodeTags[node.id]!)['type'],
          node.outbound['transport']?['type'] == 'xhttp' ? 'xray' : 'mihomo',
        );
      }
      expect(
        outboundByTag(config, 'proxy')['outbounds'],
        containsAll(built.nodeTags.values),
      );
    });
  }

  test('compatibility nodes preserve a chain detour', () {
    final entry = LinkParser.parseLink(kSampleLinks['ssr']!)!;
    final exit = LinkParser.parseLink(xhttpLink('stream-up'))!;
    late BuiltConfig built;
    final config = buildJson(
      nodes: [entry, exit],
      selected: exit.id,
      chain: ChainSettings(enabled: true, entryNodeId: entry.id),
      inspect: (value) => built = value,
    );
    expect(built.chainActive, true);
    final outbound = outboundByTag(config, built.nodeTags[exit.id]!);
    expect(outbound['type'], 'xray');
    expect(outbound['detour'], isNotNull);
    expect(outbound['tcp_fast_open'], isNull);
  });
}
