import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/xray_config.dart';

import 'samples.dart';

String xhttpLink(String mode, {Map<String, dynamic>? extra}) =>
    'vless://$kUuid@edge.example.com:443?type=xhttp&mode=$mode'
    '&security=reality&sni=cdn.example.com&host=front.example.com'
    '&path=%2Ftunnel&fp=firefox&pbk=$kRealityPbk&sid=0123456789abcdef'
    '${extra == null ? '' : '&extra=${Uri.encodeComponent(jsonEncode(extra))}'}';

void main() {
  for (final mode in ['auto', 'packet-up', 'stream-up', 'stream-one']) {
    test('Xray preserves XHTTP $mode and REALITY parameters', () {
      final node = LinkParser.parseLink(xhttpLink(mode))!;
      expect(XrayConfig.supports(node), isTrue);
      final outbound = XrayConfig.outbound(node, 'selected')!;
      expect(outbound['settings']['vnext'].single['users'].single['id'], kUuid);
      expect(outbound['streamSettings'], {
        'network': 'xhttp',
        'security': 'reality',
        'realitySettings': {
          'serverName': 'cdn.example.com',
          'fingerprint': 'firefox',
          'publicKey': kRealityPbk,
          'shortId': '0123456789abcdef',
        },
        'xhttpSettings': {
          'host': 'front.example.com',
          'path': '/tunnel',
          'mode': mode,
        },
      });
      final roundTrip = LinkParser.parseContent(
        jsonEncode({
          'outbounds': [outbound],
        }),
      ).single;
      expect(roundTrip.outbound, node.outbound);
    });
  }

  test('XHTTP URI retains post buffering, headers and all XMUX settings', () {
    final extra = {
      'noGRPCHeader': true,
      'xPaddingBytes': '100-200',
      'scMaxBufferedPosts': 64,
      'scMaxEachPostBytes': 65536,
      'headers': {'X-Transport': 'synthetic'},
      'xmux': {
        'maxConcurrency': '8-16',
        'cMaxReuseTimes': 50,
        'hMaxRequestTimes': 100,
        'hMaxReusableSecs': 300,
        'hKeepAlivePeriod': 30,
      },
    };
    final node = LinkParser.parseLink(xhttpLink('stream-up', extra: extra));
    expect(node, isNotNull);
    expect(node!.outbound['transport']['options']['sc-max-buffered-posts'], 64);
    final outbound = XrayConfig.outbound(node, 'xhttp')!;
    expect(outbound['streamSettings']['xhttpSettings']['extra'], extra);
    final roundTrip = LinkParser.parseContent(
      jsonEncode({
        'outbounds': [outbound],
      }),
    ).single;
    expect(roundTrip.outbound, node.outbound);
  });

  test('XHTTP maxConnections is restored as an Xray number', () {
    final node = LinkParser.parseLink(
      xhttpLink(
        'stream-one',
        extra: {
          'xmux': {'maxConnections': 2},
        },
      ),
    )!;
    final outbound = XrayConfig.outboundFromMap(node.outbound, 'mapped')!;
    expect(outbound['streamSettings']['xhttpSettings']['extra'], {
      'xmux': {'maxConnections': 2},
    });
  });

  test('Xray imports top-level XHTTP options and honors extra precedence', () {
    final source = XrayConfig.outbound(
      LinkParser.parseLink(xhttpLink('stream-up'))!,
      'xhttp',
    )!;
    final settings = source['streamSettings']['xhttpSettings'] as Map;
    settings['headers'] = {'X-Transport': 'outer'};
    settings['scMaxBufferedPosts'] = 32;
    final plain = LinkParser.parseContent(
      jsonEncode({
        'outbounds': [source],
      }),
    ).single;
    expect(plain.outbound['transport']['options']['sc-max-buffered-posts'], 32);
    expect(plain.outbound['transport']['options']['headers'], {
      'X-Transport': 'outer',
    });
    settings['extra'] = {
      'headers': {'X-Transport': 'inner'},
      'xmux': {'maxConnections': 2},
    };
    final withExtra = LinkParser.parseContent(
      jsonEncode({
        'outbounds': [source],
      }),
    ).single;
    final translated = XrayConfig.outbound(withExtra, 'again')!;
    expect(
      translated['streamSettings']['xhttpSettings']['extra'],
      settings['extra'],
    );
    expect(
      withExtra.outbound['transport']['options'],
      isNot(contains('sc-max-buffered-posts')),
    );
  });

  test('Xray keeps transport headers when extra settings exist', () {
    final node = LinkParser.parseLink(xhttpLink('stream-one'))!;
    final map = {
      ...node.outbound,
      'transport': {
        ...node.outbound['transport'] as Map,
        'headers': {'X-Transport': 'keep'},
        'options': {
          'reuse-settings': {'max-connections': '2'},
        },
      },
    };
    final translated = XrayConfig.outboundFromMap(map, 'xhttp')!;
    expect(translated['streamSettings']['xhttpSettings']['extra'], {
      'headers': {'X-Transport': 'keep'},
      'xmux': {'maxConnections': 2},
    });
  });

  for (final mode in ['gun', 'multi']) {
    test('gRPC $mode preserves authority and service name through Xray', () {
      final link =
          'vless://$kUuid@edge.example.com:443?type=grpc&mode=$mode'
          '&security=reality&sni=cdn.example.com&fp=firefox&pbk=$kRealityPbk&sid=a1'
          '&serviceName=tunnel%2Fservice&authority=grpc.example.com';
      final node = LinkParser.parseLink(link)!;
      final translated = XrayConfig.outbound(node, 'grpc')!;
      expect(translated['streamSettings']['grpcSettings'], {
        'serviceName': 'tunnel/service',
        'authority': 'grpc.example.com',
        'multiMode': mode == 'multi',
      });
      final roundTrip = LinkParser.parseContent(
        jsonEncode({
          'outbounds': [translated],
        }),
      ).single;
      expect(roundTrip.outbound, node.outbound);
    });
  }

  test('Xray declines unsupported options instead of dropping them', () {
    final node = LinkParser.parseLink(xhttpLink('stream-up'))!;
    final map = {
      ...node.outbound,
      'transport': {
        ...node.outbound['transport'] as Map,
        'options': {'session-table': 'mihomo-specific'},
      },
    };
    expect(XrayConfig.outboundFromMap(map, 'unsupported'), isNull);
  });

  test('Xray leaves removed HTTP/2 transport on the native core', () {
    final node = LinkParser.parseLink(
      'vless://$kUuid@edge.example.com:443?type=h2&security=tls'
      '&sni=cdn.example.com&host=front.example.com&path=%2Ftunnel',
    )!;
    expect(node.outbound['transport']['type'], 'http');
    expect(XrayConfig.supports(node), isFalse);
    expect(XrayConfig.outbound(node, 'http2'), isNull);
    // An HTTP CONNECT proxy remains supported over ordinary TCP.
    final proxy = LinkParser.parseLink(
      'http://user:password@proxy.example.com:8080',
    )!;
    expect(XrayConfig.supports(proxy), isTrue);
  });

  test('Xray declines removed allowInsecure without changing TLS policy', () {
    for (final network in ['tcp', 'ws', 'xhttp']) {
      final node = LinkParser.parseLink(
        'vless://$kUuid@edge.example.com:443?type=$network&security=tls'
        '&sni=cdn.example.com&allowInsecure=1',
      )!;
      expect(node.outbound['tls']['insecure'], isTrue);
      expect(XrayConfig.supports(node), isFalse);
      expect(XrayConfig.outbound(node, 'insecure'), isNull);
      expect(node.outbound['tls']['insecure'], isTrue);
    }
    final reality = LinkParser.parseLink(xhttpLink('stream-one'))!;
    final pinned = {
      ...reality.outbound,
      'tls': {...reality.outbound['tls'] as Map, 'insecure': true},
    };
    final outbound = XrayConfig.outboundFromMap(pinned, 'pinned')!;
    expect(outbound['streamSettings']['security'], 'reality');
    expect(
      outbound['streamSettings']['realitySettings'],
      isNot(contains('allowInsecure')),
    );
  });

  test(
    'Xray accepts a synthetic XHTTP plan with post buffering',
    () async {
      final node = LinkParser.parseLink(
        xhttpLink(
          'stream-up',
          extra: {
            'scMaxBufferedPosts': 64,
            'scMaxEachPostBytes': 65536,
            'xmux': {'maxConnections': 2},
          },
        ),
      )!;
      final plan = XrayConfig.build([(node: node, tag: 'xhttp')])!;
      final directory = await Directory.systemTemp.createTemp(
        'melsi-xray-config-',
      );
      try {
        final path = '${directory.path}/config.json';
        await File(path).writeAsString(plan.json);
        final result = await Process.run(
          Platform.environment['MELSI_XRAY_BIN']!,
          ['run', '-test', '-config', path],
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['MELSI_XRAY_BIN'] == null
        ? 'MELSI_XRAY_BIN not set'
        : false,
  );
}
