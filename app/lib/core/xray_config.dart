// Original Xray-core JSON for the nodes a build hands to Xray.
//
// sing-box keeps TUN, DNS and the selector. Each translated node becomes a
// local SOCKS inbound inside one Xray process, and sing-box dials that port.
// Protocols Xray does not carry (SSR, Hysteria, WireGuard, …) are left out
// so the caller can keep them on sing-box.

import 'dart:convert';

import 'models.dart';

class XrayMember {
  const XrayMember({
    required this.nodeId,
    required this.tag,
    required this.port,
  });

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
  static Map<String, dynamic>? outbound(ProxyNode node, String tag) =>
      outboundFromMap(node.outbound, tag);

  /// Also accepts an outbound after the caller applies per-node settings.
  static Map<String, dynamic>? outboundFromMap(
    Map<String, dynamic> ob,
    String tag,
  ) {
    // Xray 26.3 rejects allowInsecure instead of merely warning. Keep these
    // nodes on a core that supports their explicitly requested TLS policy.
    final tls = ob['tls'];
    final reality = tls is Map ? tls['reality'] : null;
    if (tls is Map &&
        tls['insecure'] == true &&
        !(reality is Map && reality['enabled'] == true)) {
      return null;
    }
    final protocol = switch (ob['type']) {
      'vless' ||
      'vmess' ||
      'trojan' ||
      'shadowsocks' ||
      'socks' ||
      'http' => ob['type'] as String,
      _ => null,
    };
    if (protocol == null) return null;
    final transport = ob['transport'] as Map?;
    final network = transport?['type'] as String? ?? 'tcp';
    if (network == 'quic' || network == 'httpupgrade') return null;
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
      'routing': {'domainStrategy': 'AsIs', 'rules': rules},
    };
    return XrayPlan(
      json: const JsonEncoder.withIndent('  ').convert(config),
      members: members,
    );
  }

  static String _level(LogLevel level) => switch (level) {
    LogLevel.trace || LogLevel.debug => 'debug',
    LogLevel.info => 'info',
    LogLevel.warn => 'warning',
    LogLevel.error => 'error',
  };

  static Map<String, dynamic>? _settings(
    Map<String, dynamic> ob,
    String protocol,
  ) {
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
            {
              'address': server,
              'port': port,
              'method': method,
              'password': password,
            },
          ],
        };
      case 'socks':
        return {
          'servers': [
            {
              'address': server,
              'port': port,
              if (ob['username'] != null)
                'users': [
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
              if (ob['username'] != null)
                'users': [
                  {'user': ob['username'], 'pass': ob['password'] ?? ''},
                ],
            },
          ],
        };
      default:
        return null;
    }
  }

  static Map<String, dynamic>? _stream(
    Map<String, dynamic> ob,
    String network,
  ) {
    final xrayNet = switch (network) {
      'tcp' || 'raw' => 'tcp',
      'ws' => 'ws',
      'grpc' => 'grpc',
      'xhttp' => 'xhttp',
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
          if (transport?['service_name'] != null)
            'serviceName': transport?['service_name'],
          if (transport?['authority'] != null)
            'authority': transport?['authority'],
          if (transport?['multi_mode'] != null)
            'multiMode': transport?['multi_mode'],
        };
      case 'xhttp':
        final settings = _xhttpSettings(transport!);
        if (settings == null) return null;
        stream['xhttpSettings'] = settings;
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

  /// The parser stores XHTTP options with the shared kebab-case names. Xray
  /// uses the original camelCase names and calls connection reuse `xmux`.
  static Map<String, dynamic>? _xhttpSettings(Map transport) {
    const names = {
      'headers': 'headers',
      'no-grpc-header': 'noGRPCHeader',
      'x-padding-bytes': 'xPaddingBytes',
      'x-padding-obfs-mode': 'xPaddingObfsMode',
      'x-padding-key': 'xPaddingKey',
      'x-padding-header': 'xPaddingHeader',
      'x-padding-placement': 'xPaddingPlacement',
      'x-padding-method': 'xPaddingMethod',
      'uplink-http-method': 'uplinkHTTPMethod',
      'session-placement': 'sessionPlacement',
      'session-key': 'sessionKey',
      'seq-placement': 'seqPlacement',
      'seq-key': 'seqKey',
      'uplink-data-placement': 'uplinkDataPlacement',
      'uplink-data-key': 'uplinkDataKey',
      'uplink-chunk-size': 'uplinkChunkSize',
      'sc-max-each-post-bytes': 'scMaxEachPostBytes',
      'sc-min-posts-interval-ms': 'scMinPostsIntervalMs',
      'sc-max-buffered-posts': 'scMaxBufferedPosts',
    };
    const reuseNames = {
      'max-concurrency': 'maxConcurrency',
      'max-connections': 'maxConnections',
      'c-max-reuse-times': 'cMaxReuseTimes',
      'h-max-request-times': 'hMaxRequestTimes',
      'h-max-reusable-secs': 'hMaxReusableSecs',
      'h-keep-alive-period': 'hKeepAlivePeriod',
    };
    final extra = <String, dynamic>{
      if (transport['headers'] != null) 'headers': transport['headers'],
    };
    for (final entry in ((transport['options'] as Map?) ?? const {}).entries) {
      if (entry.key == 'reuse-settings') {
        if (entry.value is! Map) return null;
        final xmux = <String, dynamic>{};
        for (final setting in (entry.value as Map).entries) {
          final name = reuseNames[setting.key];
          if (name == null) return null;
          final value = setting.value;
          xmux[name] = value is String ? int.tryParse(value) ?? value : value;
        }
        extra['xmux'] = xmux;
      } else {
        final name = names[entry.key];
        // In particular, do not silently discard Mihomo-only options.
        if (name == null) return null;
        extra[name] = entry.value;
      }
    }
    return {
      'path': transport['path'] ?? '/',
      if (transport['host'] != null) 'host': transport['host'],
      'mode': transport['mode'] ?? 'auto',
      // Xray replaces the outer settings with `extra` (except host/path/mode),
      // so headers must also live inside it when other options are present.
      if (extra.isNotEmpty) 'extra': extra,
    };
  }
}
