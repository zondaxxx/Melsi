import 'models.dart';
import 'xray_config.dart';

abstract final class CompatibilityCore {
  static const xhttpOptionNames = {
    'headers',
    'no-grpc-header',
    'x-padding-bytes',
    'x-padding-obfs-mode',
    'x-padding-key',
    'x-padding-header',
    'x-padding-placement',
    'x-padding-method',
    'uplink-http-method',
    'session-placement',
    'session-key',
    'session-table',
    'session-length',
    'seq-placement',
    'seq-key',
    'uplink-data-placement',
    'uplink-data-key',
    'uplink-chunk-size',
    'sc-max-each-post-bytes',
    'sc-min-posts-interval-ms',
    'sc-max-buffered-posts',
    'reuse-settings',
  };

  static void validateXhttpOptions(Map options) {
    for (final key in options.keys) {
      if (!xhttpOptionNames.contains(key)) {
        throw FormatException('Unsupported XHTTP option: $key');
      }
    }
  }

  static bool needsMihomo(Map<String, dynamic> outbound) =>
      outbound['type'] == 'shadowsocksr' ||
      outbound['type'] == 'amneziawg' ||
      _legacyXhttp(outbound);

  // Xray removed allowInsecure. Keep explicitly unverified, non-REALITY
  // XHTTP on its existing adapter instead of rejecting the whole VPN config.
  static bool _legacyXhttp(Map<String, dynamic> outbound) {
    final tls = outbound['tls'] as Map?;
    return (outbound['transport'] as Map?)?['type'] == 'xhttp' &&
        tls?['insecure'] == true && !realityOrVision(outbound);
  }

  static bool needsXray(Map<String, dynamic> outbound) {
    if (_legacyXhttp(outbound)) return false;
    final transport = outbound['transport'] as Map?;
    return realityOrVision(outbound) ||
        transport?['type'] == 'xhttp' ||
        (transport?['type'] == 'grpc' &&
            (transport?['authority'] != null ||
                transport?['multi_mode'] == true));
  }

  /// REALITY must use the current Xray handshake. Older sing-box/Mihomo
  /// client versions are rejected by current Xray server version gates.
  static bool realityOrVision(Map<String, dynamic> outbound) {
    final flow = outbound['flow'];
    if (flow is String && flow.isNotEmpty) return true;
    final tls = outbound['tls'];
    if (tls is! Map) return false;
    final reality = tls['reality'];
    return reality is Map && reality['enabled'] == true;
  }

  /// Clash/Mihomo proxy object for a sing-box outbound the embedded adapter
  /// can dial, or null when the node should stay a native sing-box outbound
  /// (unknown transport, REALITY/Vision, or a protocol [wrap] already owns).
  static Map<String, dynamic>? clashProxy(Map<String, dynamic> outbound) {
    if (needsMihomo(outbound) || needsXray(outbound)) return null;
    final type = outbound['type'];
    final server = outbound['server'];
    final port = outbound['server_port'];
    if (server is! String || server.isEmpty || port is! num) return null;
    final network = _clashNetwork(outbound['transport'] as Map?);
    // Empty string marks a transport Mihomo mode will not claim.
    if (network == '') return null;
    final base = <String, dynamic>{
      'server': server,
      'port': port,
      'udp': true,
      'network': ?network,
    };
    _clashTransport(base, outbound['transport'] as Map?);
    _clashTls(base, outbound);
    switch (type) {
      case 'vmess':
        final id = outbound['uuid'];
        if (id is! String || id.isEmpty) return null;
        return {
          ...base,
          'type': 'vmess',
          'uuid': id,
          'alterId': outbound['alter_id'] ?? 0,
          'cipher': outbound['security'] ?? 'auto',
        };
      case 'vless':
        final id = outbound['uuid'];
        if (id is! String || id.isEmpty) return null;
        return {
          ...base,
          'type': 'vless',
          'uuid': id,
          if (outbound['flow'] != null) 'flow': outbound['flow'],
          'packet-encoding': outbound['packet_encoding'] ?? 'xudp',
        };
      case 'trojan':
        final password = outbound['password'];
        if (password is! String || password.isEmpty) return null;
        return {...base, 'type': 'trojan', 'password': password};
      case 'shadowsocks':
        final method = outbound['method'];
        final password = outbound['password'];
        if (method is! String || password is! String) return null;
        return {...base, 'type': 'ss', 'cipher': method, 'password': password};
      case 'hysteria2':
        final password = outbound['password'];
        if (password is! String || password.isEmpty) return null;
        return {
          'type': 'hysteria2',
          'server': server,
          'port': port,
          'password': password,
          'udp': true,
          if (outbound['up_mbps'] != null) 'up': outbound['up_mbps'],
          if (outbound['down_mbps'] != null) 'down': outbound['down_mbps'],
          'skip-cert-verify': (outbound['tls'] as Map?)?['insecure'] == true,
          if ((outbound['tls'] as Map?)?['server_name'] != null)
            'sni': (outbound['tls'] as Map)['server_name'],
        };
      case 'socks':
        return {
          'type': 'socks5',
          'server': server,
          'port': port,
          'udp': true,
          if (outbound['username'] != null) 'username': outbound['username'],
          if (outbound['password'] != null) 'password': outbound['password'],
        };
      case 'http':
        return {
          'type': 'http',
          'server': server,
          'port': port,
          if (outbound['username'] != null) 'username': outbound['username'],
          if (outbound['password'] != null) 'password': outbound['password'],
          'tls': (outbound['tls'] as Map?)?['enabled'] == true,
          if ((outbound['tls'] as Map?)?['server_name'] != null)
            'sni': (outbound['tls'] as Map)['server_name'],
          'skip-cert-verify': (outbound['tls'] as Map?)?['insecure'] == true,
        };
      default:
        return null;
    }
  }

  /// `ws` / `grpc` / `http` / `h2`, or null for plain TCP. Returns null from
  /// [_clashNetwork] via a sentinel when the transport cannot move.
  static String? _clashNetwork(Map? transport) {
    final type = transport?['type'];
    if (type == null) return null;
    return switch (type) {
      'ws' => 'ws',
      'grpc' => 'grpc',
      'http' => 'h2',
      _ => '',
    };
  }

  static void _clashTransport(Map<String, dynamic> proxy, Map? transport) {
    if (transport == null) return;
    switch (transport['type']) {
      case 'ws':
        proxy['ws-opts'] = {
          'path': transport['path'] ?? '/',
          if (transport['headers'] != null) 'headers': transport['headers'],
        };
      case 'grpc':
        proxy['grpc-opts'] = {
          if (transport['service_name'] != null)
            'grpc-service-name': transport['service_name'],
        };
      case 'http':
        final host = transport['host'];
        proxy['h2-opts'] = {
          if (transport['path'] != null) 'path': transport['path'],
          if (host is List) 'host': host,
          if (host is String && host.isNotEmpty) 'host': [host],
        };
    }
  }

  static void _clashTls(
    Map<String, dynamic> proxy,
    Map<String, dynamic> outbound,
  ) {
    final tls = outbound['tls'];
    if (tls is! Map || tls['enabled'] != true) return;
    proxy['tls'] = true;
    proxy['servername'] = tls['server_name'] ?? outbound['server'];
    proxy['skip-cert-verify'] = tls['insecure'] == true;
    if (tls['alpn'] != null) proxy['alpn'] = tls['alpn'];
    final utls = tls['utls'];
    if (utls is Map && utls['enabled'] == true) {
      proxy['client-fingerprint'] = utls['fingerprint'] ?? 'chrome';
    }
    final reality = tls['reality'];
    if (reality is Map && reality['enabled'] == true) {
      proxy['reality-opts'] = {
        'public-key': reality['public_key'],
        'short-id': reality['short_id'] ?? '',
      };
    }
  }

  static String nameFor(ProxyNode node) => needsXray(node.outbound)
      ? 'Xray'
      : needsMihomo(node.outbound)
      ? 'Mihomo'
      : 'sing-box';

  static Map<String, dynamic>? wrapXray(Map<String, dynamic> outbound) {
    final translated = XrayConfig.outboundFromMap(
      outbound,
      outbound['tag'] as String,
    );
    if (translated == null) return null;
    return {
      'type': 'xray',
      'tag': outbound['tag'],
      'domain_resolver': {'server': 'dns-direct'},
      if (outbound['detour'] != null) 'detour': outbound['detour'],
      'outbound': translated,
    };
  }

  static Map<String, dynamic> wrap(Map<String, dynamic> outbound) {
    if (needsXray(outbound)) {
      final wrapped = wrapXray(outbound);
      if (wrapped != null) return wrapped;
      throw const FormatException('Unsupported Xray transport');
    }
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
      _ => throw const FormatException('Unsupported Mihomo protocol'),
    };
    return {
      'type': 'mihomo',
      'tag': outbound['tag'],
      'domain_resolver': {'server': 'dns-direct'},
      if (outbound['detour'] != null) 'detour': outbound['detour'],
      if (outbound['tcp_fast_open'] != null)
        'tcp_fast_open': outbound['tcp_fast_open'],
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
        if (address.contains(':'))
          'ipv6': address.split('/').first
        else
          'ip': address.split('/').first,
      'amnezia-wg-option': outbound['amnezia'],
      'persistent-keepalive': peers.first['persistent_keepalive_interval'] ?? 0,
      'peers': [
        for (final peer in peers)
          {
            'server': peer['address'],
            'port': peer['port'],
            'public-key': peer['public_key'],
            'allowed-ips': peer['allowed_ips'],
            if (peer['pre_shared_key'] != null)
              'pre-shared-key': peer['pre_shared_key'],
            if (peer['reserved'] != null) 'reserved': peer['reserved'],
          },
      ],
    };
  }
}
