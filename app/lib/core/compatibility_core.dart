import 'models.dart';

abstract final class CompatibilityCore {
  static const xhttpOptionNames = {
    'headers', 'no-grpc-header', 'x-padding-bytes', 'x-padding-obfs-mode',
    'x-padding-key', 'x-padding-header', 'x-padding-placement', 'x-padding-method',
    'uplink-http-method', 'session-placement', 'session-key', 'session-table',
    'session-length', 'seq-placement', 'seq-key', 'uplink-data-placement',
    'uplink-data-key', 'uplink-chunk-size', 'sc-max-each-post-bytes',
    'sc-min-posts-interval-ms', 'reuse-settings',
  };

  static void validateXhttpOptions(Map options) {
    for (final key in options.keys) {
      if (!xhttpOptionNames.contains(key)) throw FormatException('Unsupported XHTTP option: $key');
    }
  }

  static bool needsMihomo(Map<String, dynamic> outbound) =>
      outbound['type'] == 'shadowsocksr' ||
      outbound['type'] == 'amneziawg' ||
      (outbound['transport'] as Map?)?['type'] == 'xhttp';

  static String nameFor(ProxyNode node) => needsMihomo(node.outbound) ? 'Mihomo' : 'sing-box';

  static Map<String, dynamic> wrap(Map<String, dynamic> outbound) {
    if (!needsMihomo(outbound)) return outbound;
    final proxy = switch (outbound['type']) {
      'shadowsocksr' => {
          'type': 'ssr',
          'server': outbound['server'],
          'port': outbound['server_port'],
          'cipher': outbound['method'],
          'password': outbound['password'],
          'protocol': outbound['protocol'] ?? 'origin',
          'obfs': outbound['obfs'] ?? 'plain',
          'protocol-param': outbound['protocol_param'] ?? '',
          'obfs-param': outbound['obfs_param'] ?? outbound['server'],
        },
      'amneziawg' => _amnezia(outbound),
      'vless' => _xhttp(outbound),
      _ => throw const FormatException('XHTTP requires VLESS with the bundled Mihomo core'),
    };
    return {
      'type': 'mihomo',
      'tag': outbound['tag'],
      'domain_resolver': {'server': 'dns-direct'},
      if (outbound['detour'] != null) 'detour': outbound['detour'],
      if (outbound['tcp_fast_open'] != null) 'tcp_fast_open': outbound['tcp_fast_open'],
      'proxy': {...proxy, 'name': outbound['tag'], 'udp': true},
    };
  }

  static Map<String, dynamic> _xhttp(Map<String, dynamic> outbound) {
    final tls = (outbound['tls'] as Map?) ?? const {};
    final transport = (outbound['transport'] as Map?) ?? const {};
    validateXhttpOptions((transport['options'] as Map?) ?? const {});
    final reality = tls['reality'] as Map?;
    final utls = tls['utls'] as Map?;
    return {
      'type': 'vless',
      'server': outbound['server'],
      'port': outbound['server_port'],
      'uuid': outbound['uuid'],
      if (outbound['flow'] != null) 'flow': outbound['flow'],
      'network': 'xhttp',
      'xudp': true,
      'tls': tls['enabled'] == true,
      'servername': tls['server_name'] ?? outbound['server'],
      'skip-cert-verify': tls['insecure'] == true,
      if (tls['alpn'] != null) 'alpn': tls['alpn'],
      if (utls?['enabled'] == true) 'client-fingerprint': utls?['fingerprint'] ?? 'chrome',
      if (reality?['enabled'] == true)
        'reality-opts': {
          'public-key': reality?['public_key'],
          'short-id': reality?['short_id'] ?? '',
        },
      'xhttp-opts': {
        'path': transport['path'] ?? '/',
        'host': transport['host'] ?? tls['server_name'] ?? outbound['server'],
        'mode': transport['mode'] ?? 'auto',
        if (transport['headers'] != null) 'headers': transport['headers'],
        ...?(transport['options'] as Map?)?.cast<String, dynamic>(),
      },
    };
  }

  static Map<String, dynamic> _amnezia(Map<String, dynamic> outbound) {
    final addresses = (outbound['address'] as List).cast<String>();
    final peers = (outbound['peers'] as List).cast<Map>();
    return {
      'type': 'wireguard',
      'private-key': outbound['private_key'],
      if (outbound['mtu'] != null) 'mtu': outbound['mtu'],
      for (final address in addresses)
        if (address.contains(':')) 'ipv6': address.split('/').first
        else 'ip': address.split('/').first,
      'amnezia-wg-option': outbound['amnezia'],
      'persistent-keepalive': peers.first['persistent_keepalive_interval'] ?? 0,
      'peers': [
        for (final peer in peers)
          {
            'server': peer['address'],
            'port': peer['port'],
            'public-key': peer['public_key'],
            'allowed-ips': peer['allowed_ips'],
            if (peer['pre_shared_key'] != null) 'pre-shared-key': peer['pre_shared_key'],
            if (peer['reserved'] != null) 'reserved': peer['reserved'],
          },
      ],
    };
  }
}
