import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/models.dart';

import 'samples.dart';

Map<String, dynamic> ob(String key) {
  final n = LinkParser.parseLink(kSampleLinks[key]!);
  expect(n, isNotNull, reason: key);
  return n!.outbound;
}

void main() {
  group('parseLink', () {
    test('every sample parses', () {
      for (final e in kSampleLinks.entries) {
        final n = LinkParser.parseLink(e.value, subscriptionId: 's1');
        expect(n, isNotNull, reason: e.key);
        expect(n!.id, ProxyNode.computeId(
            n.chain == null ? n.outbound : {'outbound': n.outbound, 'chain': n.chain}));
        expect(n.subscriptionId, 's1');
        expect(n.outbound.containsKey('tag'), isFalse);
      }
    });

    test('vmess ws tls (v2rayN json)', () {
      final n = LinkParser.parseLink(kSampleLinks['vmess_ws_tls']!)!;
      expect(n.name, '🇩🇪 Germany VMess WS');
      expect(n.countryCode, 'DE');
      final o = n.outbound;
      expect(o['type'], 'vmess');
      expect(o['server'], 'de1.example.com');
      expect(o['server_port'], 443);
      expect(o['uuid'], kUuid);
      expect(o['security'], 'auto');
      expect(o['transport'], {
        'type': 'ws',
        'path': '/vmws',
        'headers': {'Host': 'cdn.example.com'},
        'max_early_data': 2048,
        'early_data_header_name': 'Sec-WebSocket-Protocol',
      });
      expect(o['tls']['server_name'], 'cdn.example.com');
      expect(o['tls']['alpn'], ['h2', 'http/1.1']);
      expect(o['tls']['utls'], {'enabled': true, 'fingerprint': 'chrome'});
    });

    test('vmess grpc / h2 / httpupgrade / quic / tcp-http', () {
      expect(ob('vmess_grpc')['transport'],
          {'type': 'grpc', 'service_name': 'vmgrpc'});
      expect(ob('vmess_grpc')['security'], 'aes-128-gcm');
      expect(ob('vmess_h2')['transport'],
          {'type': 'http', 'host': ['us2.example.com'], 'path': '/h2'});
      expect(ob('vmess_httpupgrade')['transport'],
          {'type': 'httpupgrade', 'host': 'fr.example.com', 'path': '/hu'});
      expect(ob('vmess_httpupgrade')['tls'], isNull);
      expect(ob('vmess_quic')['transport'], {'type': 'quic'});
      expect(ob('vmess_tcp_http')['transport']['type'], 'http');
      expect(ob('vmess_tcp_http')['transport']['method'], 'GET');
    });

    test('vless reality vision', () {
      final n = LinkParser.parseLink(kSampleLinks['vless_reality_vision']!)!;
      expect(n.name, '🇳🇱 Netherlands Reality');
      expect(n.countryCode, 'NL');
      final o = n.outbound;
      expect(o['flow'], 'xtls-rprx-vision');
      expect(o['tls'], {
        'enabled': true,
        'server_name': 'www.microsoft.com',
        'reality': {
          'enabled': true,
          'public_key': kRealityPbk,
          'short_id': '6ba85179e30d4fc2',
        },
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
      });
      expect(o['transport'], isNull);
    });

    test('vless ws with ed in path, grpc reality, h2 xudp', () {
      final ws = ob('vless_ws_tls');
      expect(ws['transport']['path'], '/vlws');
      expect(ws['transport']['max_early_data'], 2560);
      expect(ws['tls']['utls']['fingerprint'], 'firefox');
      final wsNode = LinkParser.parseLink(kSampleLinks['vless_ws_tls']!)!;
      expect(wsNode.name, 'Франкфурт WS');
      expect(wsNode.countryCode, 'DE');
      final g = ob('vless_grpc_reality');
      expect(g['transport'], {'type': 'grpc', 'service_name': 'grpcsvc', 'multi_mode': false});
      expect(g['tls']['reality']['short_id'], 'a1');
      expect(g['tls']['utls']['fingerprint'], 'safari');
      final h2 = ob('vless_h2');
      expect(h2['transport']['type'], 'http');
      expect(h2['packet_encoding'], 'xudp');
      expect(LinkParser.parseLink(kSampleLinks['vless_httpupgrade']!)!.countryCode,
          'AT');
    });

    test('vless xhttp is retained, KCP and legacy XTLS are skipped', () {
      expect(
          LinkParser.parseLink(
              'vless://$kUuid@x.example.com:443?security=tls&type=xhttp&path=%2Fx#xhttp'),
          isNotNull);
      expect(
          LinkParser.parseLink(
              'vless://$kUuid@x.example.com:443?security=tls&type=kcp#kcp'),
          isNull);
      expect(
          LinkParser.parseLink(
              'vless://$kUuid@x.example.com:443?security=xtls&flow=xtls-rprx-direct#old'),
          isNull);
    });

    test('trojan', () {
      final o = ob('trojan_ws');
      expect(o['password'], 'p@ssw0rd');
      expect(o['tls']['server_name'], 'fi1.example.com');
      expect(o['transport']['type'], 'ws');
      final g = ob('trojan_grpc');
      expect(g['tls']['insecure'], true);
      expect(g['transport']['service_name'], 'trgrpc');
    });

    test('shadowsocks variants', () {
      final a = LinkParser.parseLink(kSampleLinks['ss_sip002_b64']!)!;
      expect(a.name, 'SS Москва');
      expect(a.countryCode, 'RU');
      expect(a.outbound, {
        'type': 'shadowsocks',
        'server': '1.2.3.4',
        'server_port': 8388,
        'method': 'chacha20-ietf-poly1305',
        'password': 'secretpass',
      });
      expect(ob('ss_2022')['method'], '2022-blake3-aes-128-gcm');
      expect(ob('ss_2022')['password'], kSs2022Key);
      expect(ob('ss_obfs')['plugin'], 'obfs-local');
      expect(ob('ss_obfs')['plugin_opts'], 'obfs=http;obfs-host=www.bing.com');
      expect(ob('ss_v2ray_plugin')['plugin'], 'v2ray-plugin');
      expect(ob('ss_v2ray_plugin')['plugin_opts'],
          'mode=websocket;tls;host=v2p.example.com;path=/ss');
      expect(ob('ss_legacy')['server'], '7.7.7.7');
      expect(ob('ss_legacy')['password'], 'legacypw');
      final st = LinkParser.parseLink(kSampleLinks['ss_shadowtls']!)!;
      expect(st.chain, hasLength(1));
      expect(st.chain!.first['type'], 'shadowtls');
      expect(st.chain!.first['server'], 'stls.example.com');
      expect(st.chain!.first['version'], 3);
      expect(st.outbound['detour'], st.chain!.first['tag']);
      expect(LinkParser.parseLink('ss://YWVzLTI1Ni1nY206b2Jmc3Bhc3M@h.com:1?plugin=kcptun'),
          isNull);
    });

    test('ssr', () {
      final n = LinkParser.parseLink(kSampleLinks['ssr']!)!;
      expect(n.name, 'SSR Hong Kong');
      expect(n.countryCode, 'HK');
      expect(n.outbound['type'], 'shadowsocksr');
      expect(n.outbound['server'], 'ssr.example.com');
      expect(n.outbound['password'], 'ssrpass');
      expect(n.outbound['obfs_param'], 'bing.com');
      expect(n.protocol, ProxyProtocol.shadowsocksr);
    });

    test('snell', () {
      expect(ob('snell'), {
        'type': 'snell',
        'server': 'snell.example.com',
        'server_port': 6333,
        'version': 4,
        'psk': 'snellpsk',
        'obfs_mode': 'http',
        'obfs_host': 'www.bing.com',
      });
    });

    test('hysteria v1', () {
      final o = ob('hysteria');
      expect(o['auth_str'], 'hyauth');
      expect(o['obfs'], 'obfspw');
      expect(o['up_mbps'], 50);
      expect(o['down_mbps'], 200);
      expect(o['tls']['alpn'], ['hysteria']);
      expect(o['tls']['server_name'], 'hy.example.com');
    });

    test('hysteria2 with port hopping and obfs', () {
      final n = LinkParser.parseLink(kSampleLinks['hysteria2_hopping']!)!;
      expect(n.countryCode, 'SG');
      final o = n.outbound;
      expect(o['server_port'], 443);
      expect(o['server_ports'], ['443:443', '20000:30000']);
      expect(o['password'], 'hy2pass');
      expect(o['obfs'], {'type': 'salamander', 'password': 'obfspw'});
      expect(o['tls']['insecure'], true);
      final s = ob('hy2_simple');
      expect(s['server_ports'], isNull);
      expect(s['tls']['server_name'], 'a.example.com');
      final mport = LinkParser.parseLink(
          'hysteria2://p@h.example.com:443/?mport=1000-2000&sni=h.example.com');
      expect(mport!.outbound['server_ports'], ['1000:2000']);
    });

    test('tuic', () {
      final o = ob('tuic');
      expect(o['uuid'], kUuid);
      expect(o['password'], 'tuicpass');
      expect(o['congestion_control'], 'bbr');
      expect(o['udp_relay_mode'], 'native');
      expect(o['tls']['alpn'], ['h3']);
    });

    test('anytls, naive', () {
      expect(ob('anytls')['password'], 'anypw');
      expect(ob('anytls')['tls']['utls']['fingerprint'], 'chrome');
      expect(ob('naive_https')['username'], 'user');
      expect(ob('naive_https')['quic'], isNull);
      expect(ob('naive_quic')['quic'], true);
    });

    test('wireguard -> endpoint', () {
      final n = LinkParser.parseLink(kSampleLinks['wireguard']!)!;
      expect(n.protocol.isEndpoint, isTrue);
      expect(n.server, 'wg.example.com');
      expect(n.port, 51820);
      expect(n.outbound, {
        'type': 'wireguard',
        'address': ['10.7.0.2/32', 'fd00::2/128'],
        'private_key': kWgPriv,
        'mtu': 1280,
        'peers': [
          {
            'address': 'wg.example.com',
            'port': 51820,
            'public_key': kWgPub,
            'allowed_ips': ['0.0.0.0/0', '::/0'],
            'reserved': [1, 2, 3],
          }
        ],
      });
    });

    test('ssh, socks, http', () {
      expect(ob('ssh')['user'], 'root');
      expect(ob('ssh')['password'], 'sshpass');
      expect(ob('socks_v2rayn')['username'], 'user');
      expect(ob('socks_v2rayn')['password'], 'pass');
      expect(ob('socks5')['version'], '5');
      expect(ob('http')['tls'], isNull);
      expect(ob('https')['tls']['server_name'], 'proxy.example.com');
      // A web URL is not a proxy.
      expect(LinkParser.parseLink('https://example.com/sub/abc?token=1'), isNull);
    });

    test('garbage returns null', () {
      for (final s in [
        '',
        'hello',
        'vmess://!!!',
        'vless://nohost',
        'ss://@:0',
        'trojan://pw@host:99999',
        'shadowtls://whatever',
        'unknown://x@y:1',
      ]) {
        expect(LinkParser.parseLink(s), isNull, reason: s);
      }
    });

    test('ipv6 hosts and odd encodings', () {
      final n = LinkParser.parseLink(
          'vless://$kUuid@[2001:db8::1]:443?security=tls&sni=v6.example.com&type=tcp#v6%20node%20100%');
      expect(n!.outbound['server'], '2001:db8::1');
      expect(n.outbound['server_port'], 443);
      expect(n.name, 'v6 node 100%');
      final t = LinkParser.parseLink('trojan://pw@1.2.3.4:443#🇩🇪 raw emoji name');
      expect(t!.name, '🇩🇪 raw emoji name');
      expect(t.outbound['tls'], {'enabled': true});
    });

    test('ids are stable and distinct', () {
      final a = LinkParser.parseLink(kSampleLinks['tuic']!)!;
      final b = LinkParser.parseLink(kSampleLinks['tuic']!)!;
      final c = LinkParser.parseLink(kSampleLinks['anytls']!)!;
      expect(a.id, b.id);
      expect(a.id, isNot(c.id));
    });
  });

  group('parseContent', () {
    test('plain list', () {
      final text = kSampleLinks.values.join('\n');
      final nodes = LinkParser.parseContent('# comment\n$text\n\n');
      expect(nodes.length, kSampleLinks.length);
    });

    test('base64 list (std, url-safe, no padding)', () {
      final text = kSampleLinks.values.take(10).join('\r\n');
      final std = base64.encode(utf8.encode(text));
      expect(LinkParser.parseContent(std).length, 10);
      final url = base64Url.encode(utf8.encode(text)).replaceAll('=', '');
      expect(LinkParser.parseContent(url).length, 10);
      // wrapped in lines of 76 chars
      final wrapped = RegExp('.{1,76}')
          .allMatches(std)
          .map((m) => m.group(0))
          .join('\n');
      expect(LinkParser.parseContent(wrapped).length, 10);
    });

    test('clash yaml', () {
      final nodes = LinkParser.parseContent(kClashYaml, subscriptionId: 'c');
      final byName = {for (final n in nodes) n.name: n};
      expect(byName.keys, containsAll([
        '🇩🇪 DE SS', 'SS obfs', 'SS shadow-tls', 'SSR HK', 'VMess WS',
        'VMess gRPC', 'Нидерланды Reality', 'VLESS h2', 'Trojan', 'Hysteria',
        '🇸🇬 Hy2', 'TUIC', 'WG', 'Socks', 'HTTP TLS', 'Snell v4', 'AnyTLS',
        'SSH',
      ]));
      expect(byName.containsKey('Snell v2 (unsupported)'), isFalse);
      expect(byName['🇩🇪 DE SS']!.countryCode, 'DE');
      expect(byName['Нидерланды Reality']!.countryCode, 'NL');
      final reality = byName['Нидерланды Reality']!.outbound;
      expect(reality['tls']['reality']['public_key'], kRealityPbk);
      expect(reality['flow'], 'xtls-rprx-vision');
      final ws = byName['VMess WS']!.outbound;
      expect(ws['transport']['headers'], {'Host': 'vm.example.com'});
      expect(ws['transport']['max_early_data'], 2048);
      expect(byName['SS obfs']!.outbound['plugin_opts'],
          'obfs=tls;obfs-host=bing.com');
      expect(byName['SS shadow-tls']!.chain, isNotNull);
      final hy2 = byName['🇸🇬 Hy2']!.outbound;
      expect(hy2['server_ports'], ['20000:30000']);
      expect(hy2['up_mbps'], 50);
      expect(hy2['obfs']['type'], 'salamander');
      expect(byName['Hysteria']!.outbound['up_mbps'], 30);
      final wg = byName['WG']!.outbound;
      expect(wg['address'], ['172.16.0.2/32', 'fd01::2/128']);
      expect(wg['peers'][0]['reserved'], [209, 98, 59]);
      expect(wg['peers'][0]['pre_shared_key'], kWgPsk);
      expect(byName['TUIC']!.outbound['zero_rtt_handshake'], true);
      expect(byName['AnyTLS']!.outbound['idle_session_timeout'], '30s');
      expect(byName['HTTP TLS']!.outbound['tls']['enabled'], true);
      expect(nodes.every((n) => n.subscriptionId == 'c'), isTrue);
    });

    test('sing-box json', () {
      final nodes = LinkParser.parseContent(kSingBoxJson);
      final names = nodes.map((n) => n.name).toList();
      expect(names, containsAll(
          ['🇫🇮 Helsinki VLESS', 'hy2-sg', 'ss-stls', 'legacy-wg', 'WG Warsaw']));
      expect(names, isNot(contains('select')));
      expect(names, isNot(contains('stls-out')));
      expect(names, isNot(contains('direct')));
      final fi = nodes.firstWhere((n) => n.name.contains('Helsinki'));
      expect(fi.countryCode, 'FI');
      final legacy = nodes.firstWhere((n) => n.name == 'legacy-wg');
      expect(legacy.outbound['type'], 'wireguard');
      expect(legacy.outbound['peers'][0]['public_key'], kWgPub);
      expect(legacy.outbound['address'], ['10.0.0.2/32']);
      final ss = nodes.firstWhere((n) => n.name == 'ss-stls');
      expect(ss.chain!.single['type'], 'shadowtls');
      expect(ss.outbound['detour'], ss.chain!.single['tag']);
    });

    test('wireguard conf', () {
      final nodes = LinkParser.parseContent(kWireGuardConf);
      expect(nodes, hasLength(1));
      final n = nodes.single;
      expect(n.name, 'Amsterdam WG');
      expect(n.countryCode, 'NL');
      expect(n.outbound['mtu'], 1420);
      expect(n.outbound['peers'][0]['address'], '203.0.113.10');
      expect(n.outbound['peers'][0]['persistent_keepalive_interval'], 25);
      expect(
          LinkParser.parseContent(kWireGuardConf.replaceFirst(
              'MTU = 1420', 'MTU = 1420\nJc = 4\nH1 = 1234')),
          hasLength(1));
    });

    test('xray json', () {
      final nodes = LinkParser.parseContent(kXrayJson);
      expect(nodes, hasLength(1));
      expect(nodes.single.name, '🇩🇪 Xray DE');
      expect(nodes.single.outbound['type'], 'vless');
      expect(nodes.single.outbound['tls']['reality']['short_id'], 'ab');
    });

    test('never throws, drops junk', () {
      for (final s in [
        '',
        '   ',
        '{',
        '[1,2,3]',
        'proxies: [',
        'proxies:\n  - {type: ss}\n',
        '<html>404</html>',
        'aGVsbG8gd29ybGQ=',
        '\u0000\u0001',
      ]) {
        expect(LinkParser.parseContent(s), isEmpty, reason: s);
      }
    });

    test('dedupes identical nodes', () {
      final l = kSampleLinks['tuic']!;
      expect(LinkParser.parseContent('$l\n$l'), hasLength(1));
    });
  });
}
