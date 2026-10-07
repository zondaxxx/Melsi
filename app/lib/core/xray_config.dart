// Original Xray-core JSON for the nodes a build hands to Xray.
//
// sing-box keeps TUN, DNS and the selector. Each translated node becomes a
// local SOCKS inbound inside one Xray process, and sing-box dials that port.
// Protocols Xray does not carry (SSR, Hysteria, WireGuard, …) are left out
// so the caller can keep them on sing-box.

import 'dart:convert';

import 'models.dart';

class XrayMember {
  const XrayMember({required this.nodeId, required this.tag, required this.port});

  final String nodeId;
  final String tag;
  final int port;
}

class XrayPlan {
  const XrayPlan({required this.json, required this.members});

  final String json;
  final List<XrayMember> members;

  bool contains(String nodeId) => members.any((m) => m.nodeId == nodeId);
  int? portOf(String nodeId) {
    for (final m in members) {
      if (m.nodeId == nodeId) return m.port;
    }
    return null;
  }
}

abstract final class XrayConfig {
  static const firstPort = 28100;

  /// True when [node] can be dialed by Xray without a sing-box helper chain.
  static bool supports(ProxyNode node) {
    if (node.chain != null && node.chain!.isNotEmpty) return false;
    return outbound(node, 'probe') != null;
  }

  /// One Xray outbound object, or null when the protocol/transport is not
  /// something this translator will claim.
  static Map<String, dynamic>? outbound(ProxyNode node, String tag) {
    final ob = node.outbound;
    final protocol = switch (ob['type']) {
      'vless' || 'vmess' || 'trojan' || 'shadowsocks' || 'socks' || 'http' => ob['type'] as String,
      _ => null,
    };
    if (protocol == null) return null;
    final transport = ob['transport'] as Map?;
    final network = transport?['type'] as String? ?? 'tcp';
    if (network == 'xhttp' || network == 'quic' || network == 'httpupgrade') return null;
    final stream = _stream(ob, network);
    if (stream == null) return null;
    final settings = _settings(ob, protocol);
    if (settings == null) return null;
    return {
      'tag': tag,
      'protocol': protocol == 'shadowsocks' ? 'shadowsocks' : protocol,
      'settings': settings,
      'streamSettings': stream,
    };
  }

  /// Builds one Xray config for [nodes] (already tagged). Empty when none
  /// of them can move.
  static XrayPlan? build(
    List<({ProxyNode node, String tag})> nodes, {
    LogLevel logLevel = LogLevel.warn,
  }) {
    final members = <XrayMember>[];
    final inbounds = <Map<String, dynamic>>[];
    final outbounds = <Map<String, dynamic>>[];
    final rules = <Map<String, dynamic>>[];
    var port = firstPort;
    for (final item in nodes) {
      final translated = outbound(item.node, item.tag);
      if (translated == null) continue;
      final inboundTag = 'in-${item.tag}';
      members.add(XrayMember(nodeId: item.node.id, tag: item.tag, port: port));
      inbounds.add({
        'tag': inboundTag,
        'listen': '127.0.0.1',
        'port': port,
        'protocol': 'socks',
        'settings': {'auth': 'noauth', 'udp': true},
        'sniffing': {'enabled': false},
      });
      outbounds.add(translated);
      rules.add({
        'type': 'field',
        'inboundTag': [inboundTag],
        'outboundTag': item.tag,
      });
      port++;
    }
    if (members.isEmpty) return null;
    outbounds.add({'tag': 'block', 'protocol': 'blackhole', 'settings': {}});
    final config = {
      'log': {'loglevel': _level(logLevel)},
      'inbounds': inbounds,
      'outbounds': outbounds,
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': rules,
      },
    };
    return XrayPlan(json: const JsonEncoder.withIndent('  ').convert(config), members: members);
  }

  static String _level(LogLevel level) => switch (level) {
        LogLevel.trace || LogLevel.debug => 'debug',
        LogLevel.info => 'info',
        LogLevel.warn => 'warning',
        LogLevel.error => 'error',
      };

  static Map<String, dynamic>? _settings(Map<String, dynamic> ob, String protocol) {
    final server = ob['server'];
    final port = ob['server_port'];
    if (server is! String || server.isEmpty || port is! num) return null;
    switch (protocol) {
      case 'vless':
        final id = ob['uuid'];
        if (id is! String || id.isEmpty) return null;
        return {
          'vnext': [
            {
              'address': server,
              'port': port,
              'users': [
                {
                  'id': id,
                  'encryption': 'none',
                  if (ob['flow'] != null) 'flow': ob['flow'],
                },
              ],
            },
          ],
        };
      case 'vmess':
        final id = ob['uuid'];
        if (id is! String || id.isEmpty) return null;
        return {
          'vnext': [
            {
              'address': server,
              'port': port,
              'users': [
                {
                  'id': id,
                  'security': ob['security'] ?? 'auto',
                  'alterId': ob['alter_id'] ?? 0,
                },
              ],
            },
          ],
        };
      case 'trojan':
        final password = ob['password'];
        if (password is! String || password.isEmpty) return null;
        return {
          'servers': [
            {'address': server, 'port': port, 'password': password},
          ],
        };
      case 'shadowsocks':
        final method = ob['method'];
        final password = ob['password'];
        if (method is! String || password is! String) return null;
        return {
          'servers': [
            {'address': server, 'port': port, 'method': method, 'password': password},
          ],
        };
      case 'socks':
        return {
          'servers': [
            {
              'address': server,
              'port': port,
              if (ob['username'] != null) 'users': [
                {'user': ob['username'], 'pass': ob['password'] ?? ''},
              ],
            },
          ],
        };
      case 'http':
        return {
          'servers': [
            {
              'address': server,
              'port': port,
              if (ob['username'] != null) 'users': [
                {'user': ob['username'], 'pass': ob['password'] ?? ''},
              ],
            },
          ],
        };
      default:
        return null;
    }
  }

  static Map<String, dynamic>? _stream(Map<String, dynamic> ob, String network) {
    final xrayNet = switch (network) {
      'tcp' || 'raw' => 'tcp',
      'ws' => 'ws',
      'grpc' => 'grpc',
      'http' => 'http',
      _ => null,
    };
    if (xrayNet == null) return null;
    final stream = <String, dynamic>{'network': xrayNet};
    final transport = ob['transport'] as Map?;
    switch (xrayNet) {
      case 'ws':
        stream['wsSettings'] = {
          'path': transport?['path'] ?? '/',
          if (transport?['headers'] != null) 'headers': transport?['headers'],
        };
      case 'grpc':
        stream['grpcSettings'] = {
          if (transport?['service_name'] != null) 'serviceName': transport?['service_name'],
        };
      case 'http':
        final host = transport?['host'];
        stream['httpSettings'] = {
          'path': transport?['path'] ?? '/',
          if (host is List) 'host': host,
          if (host is String && host.isNotEmpty) 'host': [host],
        };
      default:
        break;
    }
    final tls = ob['tls'];
    if (tls is Map && tls['enabled'] == true) {
      final reality = tls['reality'];
      if (reality is Map && reality['enabled'] == true) {
        final key = reality['public_key'];
        if (key is! String || key.isEmpty) return null;
        stream['security'] = 'reality';
        stream['realitySettings'] = {
          'serverName': tls['server_name'] ?? ob['server'],
          'fingerprint': (tls['utls'] as Map?)?['fingerprint'] ?? 'chrome',
          'publicKey': key,
          'shortId': reality['short_id'] ?? '',
        };
      } else {
        stream['security'] = 'tls';
        stream['tlsSettings'] = {
          'serverName': tls['server_name'] ?? ob['server'],
          'allowInsecure': tls['insecure'] == true,
          if (tls['alpn'] != null) 'alpn': tls['alpn'],
          if ((tls['utls'] as Map?)?['fingerprint'] != null)
            'fingerprint': (tls['utls'] as Map)['fingerprint'],
        };
      }
    } else {
      stream['security'] = 'none';
    }
    return stream;
  }
}
