// Share-link / subscription parser producing sing-box 1.14 outbound maps.
//
// Every public entry point is total: `parseLink` returns null and
// `parseContent` returns what it could parse instead of throwing.

import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'country.dart';
import 'compatibility_core.dart';
import 'models.dart';

class LinkParser {
  LinkParser._();

  /// One share link -> node, null if unsupported/invalid.
  static ProxyNode? parseLink(String link, {String? subscriptionId}) {
    try {
      final r = _parseLinkRaw(link.trim());
      if (r == null) return null;
      return _node(r, subscriptionId: subscriptionId, rawLink: link.trim());
    } catch (_) {
      return null;
    }
  }

  /// Whole subscription body: base64 list, plain list, Clash/Mihomo YAML,
  /// sing-box JSON (outbounds/endpoints), Xray JSON (best-effort),
  /// WireGuard .conf. Never throws; drops what it can't parse.
  static List<ProxyNode> parseContent(String content,
      {String? subscriptionId}) {
    try {
      final results = _parseContentRaw(content, 0);
      final out = <ProxyNode>[];
      final seen = <String>{};
      for (final r in results) {
        try {
          final n = _node(r, subscriptionId: subscriptionId, rawLink: r.raw);
          if (seen.add(n.id)) out.add(n);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}

// =================================================================== internals

class _Parsed {
  _Parsed(this.name, this.outbound, {this.raw, this.chain});
  String name;
  final Map<String, dynamic> outbound;
  final String? raw;
  final List<Map<String, dynamic>>? chain;
}

ProxyNode _node(_Parsed r, {String? subscriptionId, String? rawLink}) {
  final ob = r.outbound;
  ob.remove('tag');
  var name = r.name.trim();
  if (name.isEmpty) {
    final server = ob['server'] ??
        ((ob['peers'] as List?)?.firstOrNull as Map?)?['address'] ??
        '';
    final port = ob['server_port'] ??
        ((ob['peers'] as List?)?.firstOrNull as Map?)?['port'] ??
        '';
    name = '${ob['type']} $server:$port';
  }
  final id = ProxyNode.computeId(
      r.chain == null ? ob : {'outbound': ob, 'chain': r.chain});
  return ProxyNode(
    id: id,
    name: name,
    outbound: ob,
    subscriptionId: subscriptionId,
    rawLink: rawLink,
    countryCode: guessCountryCode(name),
    chain: r.chain,
  );
}

// ------------------------------------------------------------------ content

List<_Parsed> _parseContentRaw(String content, int depth) {
  var text = content.replaceAll('﻿', '').trim();
  if (text.isEmpty || depth > 3) return const [];

  // JSON (sing-box / Xray)
  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      final j = jsonDecode(text);
      if (j is Map && j['proxies'] is List) return _parseClash(text);
      final r = _parseJsonConfig(j);
      if (r.isNotEmpty) return r;
    } catch (_) {}
  }

  // WireGuard .conf
  if (RegExp(r'^\s*\[Interface\]', multiLine: true, caseSensitive: false)
      .hasMatch(text)) {
    final r = _parseWireGuardConf(text);
    if (r.isNotEmpty) return r;
  }

  // Clash / Mihomo YAML
  if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(text)) {
    final r = _parseClash(text);
    if (r.isNotEmpty) return r;
  }

  // Plain link list
  if (text.contains('://')) {
    final out = <_Parsed>[];
    for (final line in const LineSplitter().convert(text)) {
      final l = line.trim();
      if (l.isEmpty || !l.contains('://')) continue;
      try {
        final r = _parseLinkRaw(l);
        if (r != null) out.add(r);
      } catch (_) {}
    }
    if (out.isNotEmpty) return out;
  }

  // Base64 wrapped
  final compact = text.replaceAll(RegExp(r'\s'), '');
  if (RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) {
    final decoded = _b64(compact);
    if (decoded != null && decoded.trim().isNotEmpty && decoded != text) {
      return _parseContentRaw(decoded, depth + 1);
    }
  }
  return const [];
}

// ------------------------------------------------------------------ helpers

/// Lenient base64 (std / url-safe / missing padding) -> UTF-8 string.
String? _b64(String input) {
  try {
    var s = input.trim().replaceAll(RegExp(r'\s'), '');
    s = s.replaceAll('-', '+').replaceAll('_', '/');
    s = s.replaceAll('=', '');
    final rem = s.length % 4;
    if (rem == 1) return null;
    if (rem > 0) s = s + '=' * (4 - rem);
    return utf8.decode(base64.decode(s), allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// Lenient percent-decoding: tolerates raw non-ASCII characters and stray
/// `%` signs (Uri.decodeComponent throws on both).
String _dec(String s) {
  if (!s.contains('%')) return s;
  final bytes = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final v = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
      if (v != null) {
        bytes.add(v);
        i += 2;
        continue;
      }
    }
    if (c < 0x80) {
      bytes.add(c);
    } else {
      // Copy the (possibly surrogate-paired) character as UTF-8.
      var end = i + 1;
      if (c >= 0xD800 && c <= 0xDBFF && end < s.length) end++;
      bytes.addAll(utf8.encode(s.substring(i, end)));
      i = end - 1;
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v.toString().trim().toLowerCase();
  return s == '1' || s == 'true' || s == 'yes' || s == 'on';
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim());
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

List<String> _csv(Object? v) {
  if (v == null) return const [];
  if (v is List) {
    return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }
  return v
      .toString()
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

bool _validPort(int? p) => p != null && p > 0 && p < 65536;

/// Parses "100", "100 Mbps", "1 Gbps", "50Mbps" -> Mbps.
int? _mbps(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  final m = RegExp(r'^\s*([\d.]+)\s*([KMGT]?)(bps|Bps|b|B)?\s*$',
          caseSensitive: true)
      .firstMatch(v.toString());
  if (m == null) return int.tryParse(v.toString().trim());
  var n = double.tryParse(m.group(1)!) ?? 0;
  switch (m.group(2)) {
    case 'K':
      n = n / 1000;
    case 'G':
      n = n * 1000;
    case 'T':
      n = n * 1000000;
  }
  if (m.group(3) == 'Bps' || m.group(3) == 'B') n *= 8;
  final r = n.round();
  return r <= 0 ? null : r;
}

/// "443", "443,20000-30000", "20000:30000" -> sing-box `server_ports`.
List<String> _portRanges(String spec) {
  final out = <String>[];
  for (final part in spec.split(RegExp(r'[,/]'))) {
    final p = part.trim();
    if (p.isEmpty) continue;
    final m = RegExp(r'^(\d+)\s*[-:]\s*(\d+)$').firstMatch(p);
    if (m != null) {
      out.add('${m.group(1)}:${m.group(2)}');
    } else if (RegExp(r'^\d+$').hasMatch(p)) {
      out.add('$p:$p');
    }
  }
  return out;
}

int? _firstPort(String spec) {
  final m = RegExp(r'\d+').firstMatch(spec);
  return m == null ? null : int.tryParse(m.group(0)!);
}

const _utlsFingerprints = {
  'chrome_psk', 'chrome_psk_shuffle', 'chrome_padding_psk_shuffle',
  'chrome_pq', 'chrome_pq_psk', 'chrome', 'firefox', 'edge', 'safari',
  '360', 'qq', 'ios', 'android', 'random', 'randomized',
};

String? _fingerprint(String? fp) {
  if (fp == null) return null;
  final f = fp.trim().toLowerCase();
  if (f.isEmpty || f == 'none' || f == 'unsafe') return null;
  if (_utlsFingerprints.contains(f)) return f;
  if (f.startsWith('randomized')) return 'randomized';
  if (f.startsWith('chrome')) return 'chrome';
  if (f.startsWith('firefox')) return 'firefox';
  if (f.startsWith('safari')) return 'safari';
  if (f.startsWith('ios')) return 'ios';
  if (f.startsWith('edge')) return 'edge';
  return 'chrome';
}

Map<String, dynamic> _tls({
  String? sni,
  bool insecure = false,
  List<String> alpn = const [],
  String? fp,
  String? realityPbk,
  String? realitySid,
  bool disableSni = false,
}) {
  final tls = <String, dynamic>{'enabled': true};
  if (sni != null && sni.isNotEmpty) tls['server_name'] = sni;
  if (disableSni) tls['disable_sni'] = true;
  if (insecure) tls['insecure'] = true;
  if (alpn.isNotEmpty) tls['alpn'] = alpn;
  var fingerprint = _fingerprint(fp);
  if (realityPbk != null && realityPbk.isNotEmpty) {
    // REALITY requires uTLS in sing-box.
    fingerprint ??= 'chrome';
    tls['reality'] = {
      'enabled': true,
      'public_key': realityPbk,
      if (realitySid != null && realitySid.isNotEmpty) 'short_id': realitySid,
    };
    tls.remove('insecure');
  }
  if (fingerprint != null) {
    tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
  }
  return tls;
}

/// Common V2Ray-family description filled from links / Clash / Xray JSON.
class _V2 {
  String type = 'vless'; // vmess | vless | trojan
  String name = '';
  String server = '';
  int? port;
  String secret = ''; // uuid or password
  int alterId = 0;
  String? cipher; // vmess security
  String network = 'tcp';
  String? headerType;
  String? host;
  String? path;
  String? serviceName;
  String? grpcAuthority;
  bool? grpcMultiMode;
  String? method;
  int? maxEarlyData;
  String? earlyDataHeader;
  Map<String, String> headers = {};
  Map<String, dynamic> xhttpOptions = {};
  String? xhttpMode;
  String security = 'none'; // none | tls | reality
  String? sni;
  bool insecure = false;
  List<String> alpn = [];
  String? fp;
  String? pbk;
  String? sid;
  String? flow;
  String? packetEncoding;

  Map<String, dynamic>? build() {
    if (server.isEmpty || !_validPort(port) || secret.isEmpty) return null;
    final ob = <String, dynamic>{
      'type': type,
      'server': server,
      'server_port': port,
    };
    switch (type) {
      case 'vmess':
        ob['uuid'] = secret;
        const sec = {
          'auto', 'none', 'zero', 'aes-128-cfb', 'aes-128-gcm',
          'chacha20-poly1305',
        };
        final c = (cipher ?? 'auto').toLowerCase();
        ob['security'] = sec.contains(c) ? c : 'auto';
        if (alterId > 0) ob['alter_id'] = alterId;
        if (packetEncoding == 'xudp' || packetEncoding == 'packetaddr') {
          ob['packet_encoding'] = packetEncoding;
        }
      case 'vless':
        ob['uuid'] = secret;
        final f = flow?.trim() ?? '';
        if (f.startsWith('xtls-rprx-vision')) {
          ob['flow'] = 'xtls-rprx-vision';
        } else if (f.isNotEmpty && f != 'none') {
          return null; // legacy XTLS flows are not supported by sing-box
        }
        if (packetEncoding == 'xudp' || packetEncoding == 'packetaddr') {
          ob['packet_encoding'] = packetEncoding;
        } else if (packetEncoding == 'none') {
          ob['packet_encoding'] = '';
        }
      case 'trojan':
        ob['password'] = secret;
      default:
        return null;
    }

    // transport
    final net = network.toLowerCase();
    Map<String, dynamic>? transport;
    switch (net) {
      case '':
      case 'tcp':
      case 'raw':
        if (headerType == 'http') {
          transport = {
            'type': 'http',
            if (host != null && host!.isNotEmpty) 'host': _csv(host),
            if (path != null && path!.isNotEmpty) 'path': path!.split(',').first,
            'method': method ?? 'GET',
          };
        }
      case 'ws':
      case 'websocket':
        var p = path ?? '/';
        var ed = maxEarlyData;
        // Xray style early data: /path?ed=2048
        final edm = RegExp(r'[?&]ed=(\d+)').firstMatch(p);
        if (edm != null) {
          ed ??= int.tryParse(edm.group(1)!);
          p = p.replaceFirst(RegExp(r'[?&]ed=\d+'), '');
          if (p.contains('&') && !p.contains('?')) {
            p = p.replaceFirst('&', '?');
          }
        }
        final h = <String, dynamic>{...headers};
        if (host != null && host!.isNotEmpty) h['Host'] = host;
        transport = {
          'type': 'ws',
          'path': p.isEmpty ? '/' : p,
          if (h.isNotEmpty) 'headers': h,
          if (ed != null && ed > 0) 'max_early_data': ed,
          if (ed != null && ed > 0)
            'early_data_header_name':
                earlyDataHeader ?? 'Sec-WebSocket-Protocol',
        };
      case 'grpc':
      case 'gun':
        transport = {
          'type': 'grpc',
          if ((serviceName ?? path ?? '').isNotEmpty)
            'service_name': serviceName ?? path,
          if (grpcAuthority != null && grpcAuthority!.isNotEmpty) 'authority': grpcAuthority,
          if (grpcMultiMode != null) 'multi_mode': grpcMultiMode,
        };
      case 'h2':
      case 'http':
        transport = {
          'type': 'http',
          if (host != null && host!.isNotEmpty) 'host': _csv(host),
          if (path != null && path!.isNotEmpty) 'path': path,
          if (method != null) 'method': method,
        };
      case 'httpupgrade':
        transport = {
          'type': 'httpupgrade',
          if (host != null && host!.isNotEmpty) 'host': host,
          if (path != null && path!.isNotEmpty) 'path': path,
          if (headers.isNotEmpty) 'headers': headers,
        };
      case 'quic':
        transport = {'type': 'quic'};
      case 'xhttp':
      case 'splithttp':
        CompatibilityCore.validateXhttpOptions(xhttpOptions);
        if (type != 'vless') return null;
        if (!const {'auto', 'packet-up', 'stream-up', 'stream-one'}
            .contains(xhttpMode ?? 'auto')) {
          return null;
        }
        transport = {
          'type': 'xhttp',
          'path': path ?? '/',
          if (host != null) 'host': host,
          'mode': xhttpMode ?? 'auto',
          if (headers.isNotEmpty) 'headers': headers,
          if (xhttpOptions.isNotEmpty) 'options': xhttpOptions,
        };
      default:
        return null;
    }
    if (transport != null) ob['transport'] = transport;

    final sec = security.toLowerCase();
    if (sec == 'tls' || sec == 'xtls' || sec == 'reality') {
      if (sec == 'reality' && (pbk == null || pbk!.isEmpty)) return null;
      ob['tls'] = _tls(
        sni: sni ?? (host != null && !_isIp(host!) ? host : null),
        insecure: insecure,
        alpn: alpn,
        fp: fp,
        realityPbk: sec == 'reality' ? pbk : null,
        realitySid: sid,
      );
    } else if (type == 'trojan') {
      // Trojan without TLS is technically possible but almost always a
      // mistake in the link; keep plain only if explicitly security=none.
    }
    if (ob['flow'] != null && ob['tls'] == null) return null;
    return ob;
  }
}

bool _isIp(String s) =>
    RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(s) || s.contains(':');

// ------------------------------------------------------------------ URL

class _Url {
  String scheme = '';
  String? user;
  String? pass;
  String? rawUserInfo;
  String host = '';
  String portSpec = '';
  String path = '';
  Map<String, String> query = {};
  String fragment = '';

  int? get port => _int(portSpec);

  String? q(String key, [List<String> alt = const []]) {
    for (final k in [key, ...alt]) {
      final v = query[k] ?? query[k.toLowerCase()];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  static _Url? parse(String link) {
    final si = link.indexOf('://');
    if (si <= 0) return null;
    final u = _Url()..scheme = link.substring(0, si).toLowerCase();
    var rest = link.substring(si + 3);
    final hi = rest.indexOf('#');
    if (hi >= 0) {
      u.fragment = _dec(rest.substring(hi + 1)).trim();
      rest = rest.substring(0, hi);
    }
    final qi = rest.indexOf('?');
    if (qi >= 0) {
      for (final kv in rest.substring(qi + 1).split('&')) {
        if (kv.isEmpty) continue;
        final ei = kv.indexOf('=');
        final k = ei < 0 ? kv : kv.substring(0, ei);
        final v = ei < 0 ? '' : kv.substring(ei + 1);
        u.query[_dec(k)] = _dec(v);
      }
      rest = rest.substring(0, qi);
    }
    final pi = rest.indexOf('/');
    var authority = rest;
    if (pi >= 0) {
      u.path = _dec(rest.substring(pi));
      authority = rest.substring(0, pi);
    }
    final at = authority.lastIndexOf('@');
    if (at >= 0) {
      final ui = authority.substring(0, at);
      u.rawUserInfo = ui;
      final ci = ui.indexOf(':');
      if (ci >= 0) {
        u.user = _dec(ui.substring(0, ci));
        u.pass = _dec(ui.substring(ci + 1));
      } else {
        u.user = _dec(ui);
      }
      authority = authority.substring(at + 1);
    }
    if (authority.startsWith('[')) {
      final end = authority.indexOf(']');
      if (end < 0) return null;
      u.host = authority.substring(1, end);
      final after = authority.substring(end + 1);
      if (after.startsWith(':')) u.portSpec = after.substring(1);
    } else {
      final ci = authority.indexOf(':');
      if (ci >= 0) {
        u.host = authority.substring(0, ci);
        u.portSpec = authority.substring(ci + 1);
      } else {
        u.host = authority;
      }
    }
    u.host = _dec(u.host);
    return u;
  }
}

// ------------------------------------------------------------------ links

_Parsed? _parseLinkRaw(String link) {
  final si = link.indexOf('://');
  if (si <= 0) return null;
  final scheme = link.substring(0, si).toLowerCase();
  switch (scheme) {
    case 'vmess':
      return _vmess(link);
    case 'vless':
      return _v2Url(link, 'vless');
    case 'trojan':
      return _v2Url(link, 'trojan');
    case 'ss':
      return _ss(link);
    case 'ssr':
      return _ssr(link);
    case 'snell':
      return _snell(link);
    case 'hysteria':
      return _hysteria(link);
    case 'hysteria2':
    case 'hy2':
      return _hysteria2(link);
    case 'tuic':
      return _tuic(link);
    case 'anytls':
      return _anytls(link);
    case 'naive+https':
    case 'naive+quic':
    case 'naive':
      return _naive(link);
    case 'wireguard':
    case 'wg':
    case 'awg':
    case 'amneziawg':
      return _wireguardUrl(link);
    case 'ssh':
      return _ssh(link);
    case 'socks':
    case 'socks5':
    case 'socks5h':
    case 'socks4':
    case 'socks4a':
      return _socks(link);
    case 'http':
    case 'https':
      return _http(link);
    case 'shadowtls':
      // No standard share-link format for a stand-alone ShadowTLS node
      // (it is only a wrapper); Shadowsocks+ShadowTLS is accepted via
      // `ss://...?plugin=shadow-tls;...` and Clash `plugin: shadow-tls`.
      return null;
    default:
      return null;
  }
}

_Parsed? _vmess(String link) {
  final body = link.substring('vmess://'.length);
  final hashIdx = body.indexOf('#');
  final payload = hashIdx >= 0 ? body.substring(0, hashIdx) : body;
  final decoded = _b64(payload.split('?').first);
  if (decoded != null && decoded.trim().startsWith('{')) {
    final j = jsonDecode(decoded) as Map;
    final v = _V2()
      ..type = 'vmess'
      ..name = _str(j['ps']) ?? ''
      ..server = (_str(j['add']) ?? '').trim()
      ..port = _int(j['port'])
      ..secret = (_str(j['id']) ?? '').trim()
      ..alterId = _int(j['aid']) ?? 0
      ..cipher = _str(j['scy'])
      ..network = _str(j['net']) ?? 'tcp'
      ..headerType = _str(j['type'])
      ..host = _str(j['host'])
      ..path = _str(j['path'])
      ..security = _str(j['tls']) ?? 'none'
      ..sni = _str(j['sni'])
      ..alpn = _csv(j['alpn'])
      ..fp = _str(j['fp'])
      ..insecure = _truthy(j['allowInsecure']) || _truthy(j['insecure'])
      ..pbk = _str(j['pbk'])
      ..sid = _str(j['sid']);
    if (v.network == 'grpc') {
      v.serviceName = v.path;
    }
    if (v.network == 'quic') {
      // v2rayN puts QUIC security in host/path; sing-box only supports none.
      v.host = null;
      v.path = null;
    }
    if (hashIdx >= 0 && v.name.isEmpty) v.name = _dec(body.substring(hashIdx + 1));
    final ob = v.build();
    return ob == null ? null : _Parsed(v.name, ob);
  }
  // Xray "VMessAEAD" URL form: vmess://uuid@host:port?...
  return _v2Url(link, 'vmess');
}

_Parsed? _v2Url(String link, String type) {
  final u = _Url.parse(link);
  if (u == null) return null;
  final v = _V2()
    ..type = type
    ..name = u.fragment
    ..server = u.host
    ..port = u.port
    ..secret = type == 'trojan'
        ? (u.pass == null ? (u.user ?? '') : '${u.user}:${u.pass}')
        : (u.user ?? '')
    ..network = u.q('type', ['network', 'net']) ?? 'tcp'
    ..xhttpMode = u.q('mode')
    ..headerType = u.q('headerType')
    ..host = u.q('host')
    ..path = u.q('path')
    ..serviceName = u.q('serviceName', ['servicename'])
    ..grpcAuthority = u.q('authority')
    ..security =
        u.q('security') ?? (type == 'trojan' ? 'tls' : 'none')
    ..sni = u.q('sni', ['peer', 'servername'])
    ..alpn = _csv(u.q('alpn'))
    ..fp = u.q('fp', ['fingerprint'])
    ..insecure = _truthy(u.q('allowInsecure', ['insecure', 'allowinsecure']))
    ..pbk = u.q('pbk', ['publicKey', 'public-key'])
    ..sid = u.q('sid', ['shortId', 'short-id'])
    ..flow = u.q('flow')
    ..packetEncoding = u.q('packetEncoding', ['packet-encoding'])
    ..cipher = u.q('encryption');
  if (type == 'vless') {
    final enc = u.q('encryption');
    // VLESS "encryption" (ML-KEM, Xray 25.x) is unsupported by sing-box.
    if (enc != null && enc != 'none' && enc.isNotEmpty) return null;
    v.cipher = null;
  }
  if (type == 'vmess') {
    v.cipher = u.q('encryption', ['security_cipher']) ?? 'auto';
  }
  final ed = u.q('ed');
  if (u.q('extra') case final String extra) {
    v.xhttpOptions = _xhttpExtra(Map<String, dynamic>.from(jsonDecode(extra) as Map));
  }
  if (ed != null) v.maxEarlyData = _int(ed);
  if (v.network == 'grpc' && v.serviceName == null) v.serviceName = v.path;
  if (v.network == 'grpc' || v.network == 'gun') {
    final mode = u.q('mode');
    if (mode == 'multi') v.grpcMultiMode = true;
    if (mode == 'gun') v.grpcMultiMode = false;
  }
  final ob = v.build();
  return ob == null ? null : _Parsed(v.name, ob);
}

const _ssMethods = {
  'none', 'aes-128-gcm', 'aes-192-gcm', 'aes-256-gcm',
  'chacha20-ietf-poly1305', 'xchacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305', 'aes-128-ctr', 'aes-192-ctr',
  'aes-256-ctr', 'aes-128-cfb', 'aes-192-cfb', 'aes-256-cfb', 'rc4-md5',
  'chacha20-ietf', 'xchacha20',
};

String? _ssMethod(String m) {
  var s = m.trim().toLowerCase();
  if (s == 'chacha20-poly1305') s = 'chacha20-ietf-poly1305';
  if (s == 'xchacha20-poly1305') s = 'xchacha20-ietf-poly1305';
  if (s == 'plain' || s == 'dummy') s = 'none';
  return _ssMethods.contains(s) ? s : null;
}

_Parsed? _ss(String link) {
  var body = link.substring('ss://'.length);
  var name = '';
  final hi = body.indexOf('#');
  if (hi >= 0) {
    name = _dec(body.substring(hi + 1));
    body = body.substring(0, hi);
  }
  // Legacy: ss://BASE64(method:password@host:port)
  if (!body.contains('@')) {
    final main = body.split('?').first.split('/').first;
    final dec = _b64(main);
    if (dec == null || !dec.contains('@')) return null;
    final q = body.contains('?') ? body.substring(body.indexOf('?')) : '';
    final at = dec.lastIndexOf('@');
    final ui = dec.substring(0, at);
    body = '${Uri.encodeComponent(ui)}@${dec.substring(at + 1)}$q';
  }
  final u = _Url.parse('ss://$body');
  if (u == null) return null;
  String method, password;
  if (u.pass != null) {
    method = u.user ?? '';
    password = u.pass!;
  } else {
    final dec = _b64(u.rawUserInfo ?? '') ?? _dec(u.rawUserInfo ?? '');
    final ci = dec.indexOf(':');
    if (ci < 0) return null;
    method = dec.substring(0, ci);
    password = dec.substring(ci + 1);
  }
  final m = _ssMethod(method);
  if (m == null || !_validPort(u.port) || u.host.isEmpty) return null;
  final ob = <String, dynamic>{
    'type': 'shadowsocks',
    'server': u.host,
    'server_port': u.port,
    'method': m,
    'password': password,
  };
  if (_truthy(u.q('uot', ['udp-over-tcp']))) ob['udp_over_tcp'] = true;
  List<Map<String, dynamic>>? chain;
  final plugin = u.q('plugin');
  if (plugin != null) {
    final parts = plugin.split(';');
    final opts = <String, String>{};
    for (final p in parts.skip(1)) {
      final ei = p.indexOf('=');
      if (ei < 0) {
        opts[p] = '';
      } else {
        opts[p.substring(0, ei)] = p.substring(ei + 1);
      }
    }
    final res = _ssPlugin(parts.first, opts, ob);
    if (res == false) return null;
    if (res is List<Map<String, dynamic>>) chain = res;
  }
  return _Parsed(name, ob, chain: chain);
}

/// Applies a SIP003 plugin to [ob]. Returns false if unsupported, a chain
/// list for shadow-tls, or true.
Object _ssPlugin(
    String plugin, Map<String, String> opts, Map<String, dynamic> ob) {
  final name = plugin.trim().toLowerCase();
  switch (name) {
    case '':
    case 'none':
      return true;
    case 'obfs-local':
    case 'simple-obfs':
    case 'obfs':
      final mode = opts['obfs'] ?? opts['mode'] ?? 'http';
      final host = opts['obfs-host'] ?? opts['host'];
      ob['plugin'] = 'obfs-local';
      ob['plugin_opts'] = [
        'obfs=$mode',
        if (host != null && host.isNotEmpty) 'obfs-host=$host',
      ].join(';');
      return true;
    case 'v2ray-plugin':
      final o = <String>[];
      final mode = opts['mode'] ?? 'websocket';
      if (mode != 'websocket') return false; // quic mode unsupported
      o.add('mode=websocket');
      if (opts.containsKey('tls') && opts['tls'] != 'false') o.add('tls');
      if ((opts['host'] ?? '').isNotEmpty) o.add('host=${opts['host']}');
      if ((opts['path'] ?? '').isNotEmpty) o.add('path=${opts['path']}');
      if (opts.containsKey('mux')) {
        o.add('mux=${_truthy(opts['mux']) || opts['mux'] == '' ? 1 : 0}');
      }
      ob['plugin'] = 'v2ray-plugin';
      ob['plugin_opts'] = o.join(';');
      return true;
    case 'shadow-tls':
    case 'shadowtls':
      final host = opts['host'] ?? opts['sni'];
      final pw = opts['password'] ?? opts['passwd'];
      final ver = _int(opts['version']) ?? 3;
      if (host == null || (ver >= 2 && (pw == null || pw.isEmpty))) {
        return false;
      }
      return _shadowTlsChain(ob, host, pw, ver, fp: opts['fp']);
    default:
      return false;
  }
}

/// Turns [ob] (shadowsocks) into "dial through shadowtls" and returns the
/// chain. The shadowtls outbound takes over server/server_port.
List<Map<String, dynamic>> _shadowTlsChain(
    Map<String, dynamic> ob, String sni, String? password, int version,
    {String? fp}) {
  const placeholder = 'shadowtls';
  final stls = <String, dynamic>{
    'type': 'shadowtls',
    'tag': placeholder,
    'server': ob['server'],
    'server_port': ob['server_port'],
    'version': version.clamp(1, 3),
    if (version >= 2 && password != null) 'password': password,
    'tls': _tls(sni: sni, fp: fp ?? 'chrome'),
  };
  // The shadowtls outbound ignores the destination; server/server_port stay
  // on the real host so UI latency probes (TCP ping) keep working.
  ob['detour'] = placeholder;
  ob.remove('udp_over_tcp');
  ob['udp_over_tcp'] = {'enabled': true, 'version': 2};
  return [stls];
}

_Parsed? _ssr(String link) {
  final dec = _b64(link.substring('ssr://'.length));
  if (dec == null) return null;
  final si = dec.indexOf('/?');
  final main = si >= 0 ? dec.substring(0, si) : dec.split('?').first;
  final params = <String, String>{};
  if (si >= 0) {
    for (final kv in dec.substring(si + 2).split('&')) {
      final ei = kv.indexOf('=');
      if (ei > 0) params[kv.substring(0, ei)] = kv.substring(ei + 1);
    }
  }
  final parts = main.split(':');
  if (parts.length < 6) return null;
  final pw = _b64(parts.last) ?? '';
  final obfs = parts[parts.length - 2];
  final method = parts[parts.length - 3];
  final protocol = parts[parts.length - 4];
  final port = _int(parts[parts.length - 5]);
  final host = parts.sublist(0, parts.length - 5).join(':');
  if (!_validPort(port)) return null;
  String? p(String k) {
    final v = params[k];
    if (v == null || v.isEmpty) return null;
    return _b64(v);
  }

  final ob = <String, dynamic>{
    'type': 'shadowsocksr',
    'server': host,
    'server_port': port,
    'method': method,
    'password': pw,
    'obfs': obfs,
    if (p('obfsparam') != null) 'obfs_param': p('obfsparam'),
    'protocol': protocol,
    if (p('protoparam') != null) 'protocol_param': p('protoparam'),
  };
  return _Parsed(p('remarks') ?? '', ob);
}

Map<String, dynamic>? _snellOutbound(String server, int? port, String? psk,
    int? version, String? obfs, String? obfsHost) {
  if (server.isEmpty || !_validPort(port) || psk == null || psk.isEmpty) {
    return null;
  }
  final v = version ?? 4;
  // sing-box client speaks Snell v4 (v5 servers accept it) and v6.
  final sbVersion = (v == 4 || v == 5) ? 4 : (v == 6 ? 6 : null);
  if (sbVersion == null) return null;
  final ob = <String, dynamic>{
    'type': 'snell',
    'server': server,
    'server_port': port,
    'version': sbVersion,
    'psk': psk,
  };
  if (sbVersion == 4 && obfs != null && obfs != 'none' && obfs.isNotEmpty) {
    if (obfs != 'http' && obfs != 'tls') return null;
    ob['obfs_mode'] = obfs;
    if (obfsHost != null && obfsHost.isNotEmpty) ob['obfs_host'] = obfsHost;
  }
  return ob;
}

_Parsed? _snell(String link) {
  final u = _Url.parse(link);
  if (u == null) return null;
  final psk = u.q('psk') ?? (u.pass != null ? '${u.user}:${u.pass}' : u.user);
  final ob = _snellOutbound(u.host, u.port, psk, _int(u.q('version')),
      u.q('obfs'), u.q('obfs-host', ['obfsHost', 'host']));
  return ob == null ? null : _Parsed(u.fragment, ob);
}

_Parsed? _hysteria(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty) return null;
  final proto = u.q('protocol') ?? 'udp';
  if (proto != 'udp') return null; // faketcp / wechat-video unsupported
  final ports = u.q('mport');
  final port = u.port ?? (ports != null ? _firstPort(ports) : null);
  if (!_validPort(port)) return null;
  final ob = <String, dynamic>{
    'type': 'hysteria',
    'server': u.host,
    'server_port': port,
    'up_mbps': _mbps(u.q('upmbps', ['up'])) ?? 20,
    'down_mbps': _mbps(u.q('downmbps', ['down'])) ?? 100,
  };
  if (ports != null && _portRanges(ports).isNotEmpty) {
    ob['server_ports'] = _portRanges(ports);
  }
  final auth = u.q('auth', ['auth_str', 'auth-str']) ?? u.user;
  if (auth != null && auth.isNotEmpty) ob['auth_str'] = auth;
  final obfs = u.q('obfsParam', ['obfs-password', 'obfsparam']) ??
      (u.q('obfs') != 'xplus' ? u.q('obfs') : null);
  if (obfs != null && obfs.isNotEmpty) ob['obfs'] = obfs;
  ob['tls'] = _tls(
    sni: u.q('peer', ['sni']) ?? (_isIp(u.host) ? null : u.host),
    insecure: _truthy(u.q('insecure', ['allowInsecure'])),
    alpn: _csv(u.q('alpn') ?? 'hysteria'),
  );
  return _Parsed(u.fragment, ob);
}

_Parsed? _hysteria2(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty) return null;
  String spec = u.portSpec.isEmpty ? '443' : u.portSpec;
  final mport = u.q('mport', ['ports']);
  final ob = <String, dynamic>{
    'type': 'hysteria2',
    'server': u.host,
  };
  final multi = spec.contains(',') || spec.contains('-') || mport != null;
  final port = _firstPort(spec);
  if (!_validPort(port)) return null;
  ob['server_port'] = port;
  if (multi) {
    final ranges = _portRanges(mport ?? spec);
    if (ranges.isNotEmpty) ob['server_ports'] = ranges;
  }
  final password = u.pass != null ? '${u.user}:${u.pass}' : (u.user ?? u.q('auth'));
  if (password != null && password.isNotEmpty) ob['password'] = password;
  final up = _mbps(u.q('upmbps', ['up']));
  final down = _mbps(u.q('downmbps', ['down']));
  if (up != null) ob['up_mbps'] = up;
  if (down != null) ob['down_mbps'] = down;
  final obfs = u.q('obfs');
  if (obfs != null && obfs != 'none') {
    if (obfs != 'salamander') return null;
    ob['obfs'] = {
      'type': 'salamander',
      'password': u.q('obfs-password', ['obfsPassword', 'obfs_password']) ?? '',
    };
  }
  ob['tls'] = _tls(
    sni: u.q('sni', ['peer']) ?? (_isIp(u.host) ? null : u.host),
    insecure: _truthy(u.q('insecure', ['allowInsecure'])),
    alpn: _csv(u.q('alpn')),
  );
  // Note: `pinSHA256` (certificate hash) has no sing-box equivalent
  // (sing-box pins the public key), so it is ignored.
  return _Parsed(u.fragment, ob);
}

_Parsed? _tuic(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty || !_validPort(u.port)) return null;
  final uuid = u.user;
  if (uuid == null || uuid.isEmpty) return null;
  final ob = <String, dynamic>{
    'type': 'tuic',
    'server': u.host,
    'server_port': u.port,
    'uuid': uuid,
    if (u.pass != null) 'password': u.pass,
  };
  final cc = u.q('congestion_control', ['congestion-control', 'cc']);
  if (cc != null) {
    final c = cc.toLowerCase().replaceAll('-', '_');
    if (const {'cubic', 'new_reno', 'bbr'}.contains(c)) {
      ob['congestion_control'] = c;
    } else if (c == 'newreno') {
      ob['congestion_control'] = 'new_reno';
    }
  }
  final relay = u.q('udp_relay_mode', ['udp-relay-mode']);
  if (relay == 'native' || relay == 'quic') ob['udp_relay_mode'] = relay;
  if (_truthy(u.q('reduce_rtt', ['zero_rtt_handshake', 'reduce-rtt']))) {
    ob['zero_rtt_handshake'] = true;
  }
  final alpn = _csv(u.q('alpn'));
  ob['tls'] = _tls(
    sni: u.q('sni', ['peer']) ?? (_isIp(u.host) ? null : u.host),
    insecure: _truthy(u.q('allow_insecure', ['insecure', 'allowInsecure'])),
    alpn: alpn.isEmpty ? const ['h3'] : alpn,
    disableSni: _truthy(u.q('disable_sni', ['disable-sni'])),
  );
  return _Parsed(u.fragment, ob);
}

_Parsed? _anytls(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty || !_validPort(u.port)) return null;
  final pw = u.pass != null ? '${u.user}:${u.pass}' : u.user;
  if (pw == null || pw.isEmpty) return null;
  final ob = <String, dynamic>{
    'type': 'anytls',
    'server': u.host,
    'server_port': u.port,
    'password': pw,
    'tls': _tls(
      sni: u.q('sni', ['peer']) ?? (_isIp(u.host) ? null : u.host),
      insecure: _truthy(u.q('insecure', ['allowInsecure'])),
      alpn: _csv(u.q('alpn')),
      fp: u.q('fp'),
    ),
  };
  return _Parsed(u.fragment, ob);
}

_Parsed? _naive(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty) return null;
  final quic = u.scheme == 'naive+quic';
  final port = u.port ?? 443;
  final ob = <String, dynamic>{
    'type': 'naive',
    'server': u.host,
    'server_port': port,
    if (u.user != null && u.user!.isNotEmpty) 'username': u.user,
    if (u.pass != null && u.pass!.isNotEmpty) 'password': u.pass,
    if (quic) 'quic': true,
    'tls': _tls(sni: u.q('sni') ?? (_isIp(u.host) ? null : u.host)),
  };
  final extra = u.q('extra-headers');
  if (extra != null) {
    final headers = <String, String>{};
    for (final line in extra.split(RegExp(r'\r?\n|\\r\\n'))) {
      final ci = line.indexOf(':');
      if (ci > 0) {
        headers[line.substring(0, ci).trim()] = line.substring(ci + 1).trim();
      }
    }
    if (headers.isNotEmpty) ob['extra_headers'] = headers;
  }
  return _Parsed(u.fragment, ob);
}

List<String> _wgAddresses(Iterable<String> raw) {
  final out = <String>[];
  for (final a in raw) {
    final s = a.trim();
    if (s.isEmpty) continue;
    if (s.contains('/')) {
      out.add(s);
    } else {
      out.add(s.contains(':') ? '$s/128' : '$s/32');
    }
  }
  return out;
}

List<int>? _reserved(Object? v) {
  if (v == null) return null;
  if (v is List) {
    final l = v.map(_int).whereType<int>().toList();
    return l.length == 3 ? l : null;
  }
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  if (s.contains(',')) {
    final l = s.split(',').map((e) => int.tryParse(e.trim())).whereType<int>().toList();
    return l.length == 3 ? l : null;
  }
  try {
    var b = s.replaceAll('-', '+').replaceAll('_', '/');
    while (b.length % 4 != 0) {
      b += '=';
    }
    final bytes = base64.decode(b);
    return bytes.length == 3 ? bytes.toList() : null;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _wgEndpoint({
  required String privateKey,
  required List<String> address,
  required List<Map<String, dynamic>> peers,
  int? mtu,
}) {
  if (privateKey.isEmpty || address.isEmpty || peers.isEmpty) return null;
  return {
    'type': 'wireguard',
    'address': address,
    'private_key': privateKey,
    if (mtu != null && mtu > 0) 'mtu': mtu,
    'peers': peers,
  };
}

Map<String, dynamic>? _wgPeer({
  required String server,
  required int? port,
  required String? publicKey,
  String? psk,
  List<String> allowedIps = const [],
  List<int>? reserved,
  int? keepalive,
}) {
  if (server.isEmpty || !_validPort(port) || publicKey == null ||
      publicKey.isEmpty) {
    return null;
  }
  return {
    'address': server,
    'port': port,
    'public_key': publicKey,
    if (psk != null && psk.isNotEmpty) 'pre_shared_key': psk,
    'allowed_ips':
        allowedIps.isEmpty ? const ['0.0.0.0/0', '::/0'] : allowedIps,
    'reserved': ?reserved,
    if (keepalive != null && keepalive > 0)
      'persistent_keepalive_interval': keepalive,
  };
}

_Parsed? _wireguardUrl(String link) {
  final u = _Url.parse(link);
  if (u == null) return null;
  final pk = u.user ?? u.q('privatekey', ['private_key', 'secretKey']);
  final peer = _wgPeer(
    server: u.host,
    port: u.port ?? 51820,
    publicKey: u.q('publickey', ['public_key', 'publicKey', 'peer_public_key']),
    psk: u.q('presharedkey', ['pre_shared_key', 'preSharedKey', 'psk']),
    allowedIps: _csv(u.q('allowedips', ['allowed_ips'])),
    reserved: _reserved(u.q('reserved')),
    keepalive: _int(u.q('keepalive', ['persistent_keepalive'])),
  );
  if (peer == null || pk == null) return null;
  final ep = _wgEndpoint(
    privateKey: pk,
    address: _wgAddresses(_csv(u.q('address', ['ip', 'local_address']))),
    peers: [peer],
    mtu: _int(u.q('mtu')),
  );
  if (ep != null) _applyAmnezia(ep, u.query, force: u.scheme == 'awg' || u.scheme == 'amneziawg');
  return ep == null ? null : _Parsed(u.fragment, ep);
}

_Parsed? _ssh(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty) return null;
  final ob = <String, dynamic>{
    'type': 'ssh',
    'server': u.host,
    'server_port': u.port ?? 22,
    'user': u.user ?? 'root',
    if (u.pass != null && u.pass!.isNotEmpty) 'password': u.pass,
  };
  final pk = u.q('private_key', ['privateKey', 'pk']);
  if (pk != null) {
    final decoded = pk.contains('BEGIN') ? pk : (_b64(pk) ?? pk);
    ob['private_key'] = decoded;
  }
  final hk = _csv(u.q('host_key', ['hostKey']));
  if (hk.isNotEmpty) ob['host_key'] = hk;
  return _Parsed(u.fragment, ob);
}

_Parsed? _socks(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty || !_validPort(u.port)) return null;
  var user = u.user;
  var pass = u.pass;
  if (user != null && pass == null) {
    // v2rayN: socks://BASE64(user:pass)@host:port
    final dec = _b64(u.rawUserInfo ?? '');
    if (dec != null && dec.contains(':')) {
      final ci = dec.indexOf(':');
      user = dec.substring(0, ci);
      pass = dec.substring(ci + 1);
    }
  }
  final version = switch (u.scheme) {
    'socks4' => '4',
    'socks4a' => '4a',
    _ => '5',
  };
  final ob = <String, dynamic>{
    'type': 'socks',
    'server': u.host,
    'server_port': u.port,
    'version': version,
    if (user != null && user.isNotEmpty) 'username': user,
    if (pass != null && pass.isNotEmpty) 'password': pass,
  };
  return _Parsed(u.fragment, ob);
}

_Parsed? _http(String link) {
  final u = _Url.parse(link);
  if (u == null || u.host.isEmpty) return null;
  // A bare http(s) URL with a path is a web page / subscription URL, not a
  // proxy.
  if (u.path.length > 1 || u.query.isNotEmpty && u.user == null) return null;
  final tls = u.scheme == 'https';
  final port = u.port ?? (tls ? 443 : 80);
  final ob = <String, dynamic>{
    'type': 'http',
    'server': u.host,
    'server_port': port,
    if (u.user != null && u.user!.isNotEmpty) 'username': u.user,
    if (u.pass != null && u.pass!.isNotEmpty) 'password': u.pass,
    if (tls)
      'tls': _tls(
          sni: u.q('sni') ?? (_isIp(u.host) ? null : u.host),
          insecure: _truthy(u.q('insecure', ['allowInsecure']))),
  };
  return _Parsed(u.fragment, ob);
}

// ------------------------------------------------------------------ WG conf

const _amneziaNumbers = {'version', 'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'itime'};
const _amneziaStrings = {
  'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5', 'j1', 'j2', 'j3',
  'header-protection-key', 'content-padding-addition', 'rekey-after-time',
  'rekey-timeout', 'reject-after-time', 'keepalive-timeout', 'max-handshake-attempts',
};

void _applyAmnezia(Map<String, dynamic> endpoint, Map<String, dynamic> input, {bool force = false}) {
  final options = <String, dynamic>{};
  final aliases = {
    for (final name in {..._amneziaNumbers, ..._amneziaStrings, 'random-trailers', 'disable-cookies'})
      name.replaceAll('-', ''): name,
  };
  for (final entry in input.entries) {
    final rawKey = entry.key.toLowerCase().replaceAll('_', '-');
    final key = aliases[rawKey.replaceAll('-', '')] ?? rawKey;
    if (_amneziaNumbers.contains(key)) {
      final value = _int(entry.value);
      if (value == null || value < 0) throw const FormatException('Invalid AmneziaWG number');
      options[key] = value;
    } else if (_amneziaStrings.contains(key)) {
      options[key] = entry.value.toString();
    } else if (key == 'random-trailers' || key == 'disable-cookies') {
      options[key] = _truthy(entry.value);
    }
  }
  if (options.isNotEmpty || force) {
    if (options.isEmpty) throw const FormatException('AmneziaWG parameters missing');
    endpoint['type'] = 'amneziawg';
    endpoint['amnezia'] = options;
  }
}

Map<String, dynamic> _xhttpExtra(Map<String, dynamic> extra) {
  const names = {
    'noGRPCHeader': 'no-grpc-header',
    'xPaddingBytes': 'x-padding-bytes',
    'xPaddingObfsMode': 'x-padding-obfs-mode',
    'xPaddingKey': 'x-padding-key',
    'xPaddingHeader': 'x-padding-header',
    'xPaddingPlacement': 'x-padding-placement',
    'xPaddingMethod': 'x-padding-method',
    'uplinkHTTPMethod': 'uplink-http-method',
    'sessionPlacement': 'session-placement',
    'sessionKey': 'session-key',
    'sessionTable': 'session-table',
    'sessionLength': 'session-length',
    'seqPlacement': 'seq-placement',
    'seqKey': 'seq-key',
    'uplinkDataPlacement': 'uplink-data-placement',
    'uplinkDataKey': 'uplink-data-key',
    'uplinkChunkSize': 'uplink-chunk-size',
    'scMaxEachPostBytes': 'sc-max-each-post-bytes',
    'scMinPostsIntervalMs': 'sc-min-posts-interval-ms',
    'scMaxBufferedPosts': 'sc-max-buffered-posts',
    'headers': 'headers',
  };
  final result = <String, dynamic>{};
  for (final entry in extra.entries) {
    if (entry.key == 'xmux') {
      const reuseNames = {
        'maxConcurrency': 'max-concurrency', 'maxConnections': 'max-connections',
        'cMaxReuseTimes': 'c-max-reuse-times', 'hMaxRequestTimes': 'h-max-request-times',
        'hMaxReusableSecs': 'h-max-reusable-secs', 'hKeepAlivePeriod': 'h-keep-alive-period',
      };
      final reuse = <String, dynamic>{};
      for (final setting in (entry.value as Map).entries) {
        final key = reuseNames[setting.key];
        if (key == null) throw FormatException('Unsupported XMUX option: ${setting.key}');
        reuse[key] = key == 'h-keep-alive-period' ? _int(setting.value) : setting.value.toString();
      }
      result['reuse-settings'] = reuse;
      continue;
    }
    final key = names[entry.key];
    if (key == null) throw FormatException('Unsupported XHTTP extra: ${entry.key}');
    result[key] = entry.value;
  }
  return result;
}

List<_Parsed> _parseWireGuardConf(String text) {
  final sections = <(String, Map<String, String>)>[];
  String? current;
  Map<String, String> kv = {};
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.split(RegExp(r'\s[#;]')).first.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    final sm = RegExp(r'^\[(\w+)\]$').firstMatch(line);
    if (sm != null) {
      if (current != null) sections.add((current, kv));
      current = sm.group(1)!.toLowerCase();
      kv = {};
      continue;
    }
    final ei = line.indexOf('=');
    if (ei > 0 && current != null) {
      final k = line.substring(0, ei).trim().toLowerCase();
      final v = line.substring(ei + 1).trim();
      kv[k] = kv.containsKey(k) ? '${kv[k]},$v' : v;
    }
  }
  if (current != null) sections.add((current, kv));
  final iface = sections.where((s) => s.$1 == 'interface').firstOrNull?.$2;
  if (iface == null) return const [];
  final peers = <Map<String, dynamic>>[];
  for (final s in sections.where((s) => s.$1 == 'peer')) {
    final p = s.$2;
    final endpoint = p['endpoint'] ?? '';
    String host;
    int? port;
    if (endpoint.startsWith('[')) {
      final end = endpoint.indexOf(']');
      host = endpoint.substring(1, end);
      port = _int(endpoint.substring(end + 2));
    } else {
      final ci = endpoint.lastIndexOf(':');
      host = ci > 0 ? endpoint.substring(0, ci) : endpoint;
      port = ci > 0 ? _int(endpoint.substring(ci + 1)) : null;
    }
    final peer = _wgPeer(
      server: host,
      port: port,
      publicKey: p['publickey'],
      psk: p['presharedkey'],
      allowedIps: _csv(p['allowedips']),
      reserved: _reserved(p['reserved'] ?? iface['reserved']),
      keepalive: _int(p['persistentkeepalive']),
    );
    if (peer != null) peers.add(peer);
  }
  final ep = _wgEndpoint(
    privateKey: iface['privatekey'] ?? '',
    address: _wgAddresses(_csv(iface['address'])),
    peers: peers,
    mtu: _int(iface['mtu']),
  );
  if (ep == null) return const [];
  _applyAmnezia(ep, iface);
  final nameLine = RegExp(r'^\s*#\s*Name\s*=\s*(.+)$', multiLine: true)
      .firstMatch(text)
      ?.group(1);
  final first = peers.first;
  return [
    _Parsed(nameLine ?? '${ep['type'] == 'amneziawg' ? 'AmneziaWG' : 'WireGuard'} ${first['address']}', ep, raw: null)
  ];
}

// ------------------------------------------------------------------ Clash

Object? _plain(Object? v) {
  if (v is YamlMap) {
    return {for (final e in v.entries) e.key.toString(): _plain(e.value)};
  }
  if (v is YamlList) return v.map(_plain).toList();
  return v;
}

List<_Parsed> _parseClash(String text) {
  Object? doc;
  try {
    doc = _plain(loadYaml(text));
  } catch (_) {
    return const [];
  }
  if (doc is! Map) return const [];
  final proxies = doc['proxies'];
  if (proxies is! List) return const [];
  final out = <_Parsed>[];
  for (final p in proxies) {
    if (p is! Map) continue;
    try {
      final r = _clashProxy(Map<String, dynamic>.from(p));
      if (r != null) out.add(r);
    } catch (_) {}
  }
  return out;
}

_Parsed? _clashProxy(Map<String, dynamic> p) {
  final type = (p['type'] ?? '').toString().toLowerCase();
  final name = (p['name'] ?? '').toString();
  final server = (p['server'] ?? '').toString().trim();
  final port = _int(p['port']);
  final sni = _str(p['sni']) ?? _str(p['servername']);
  final insecure = _truthy(p['skip-cert-verify']);
  final alpn = _csv(p['alpn']);
  final fp = _str(p['client-fingerprint']);
  Map<String, dynamic>? ob;
  List<Map<String, dynamic>>? chain;

  switch (type) {
    case 'ss':
      final m = _ssMethod((p['cipher'] ?? '').toString());
      if (m == null || !_validPort(port) || server.isEmpty) return null;
      ob = {
        'type': 'shadowsocks',
        'server': server,
        'server_port': port,
        'method': m,
        'password': (p['password'] ?? '').toString(),
      };
      if (_truthy(p['udp-over-tcp'])) {
        final v = _int(p['udp-over-tcp-version']);
        ob['udp_over_tcp'] =
            v == null ? true : {'enabled': true, 'version': v};
      }
      final plugin = _str(p['plugin']);
      if (plugin != null) {
        final po = Map<String, dynamic>.from((p['plugin-opts'] as Map?) ?? {});
        final opts = <String, String>{};
        switch (plugin) {
          case 'obfs':
            opts['obfs'] = (po['mode'] ?? 'http').toString();
            if (po['host'] != null) opts['obfs-host'] = po['host'].toString();
            if (_ssPlugin('obfs-local', opts, ob) == false) return null;
          case 'v2ray-plugin':
            opts['mode'] = (po['mode'] ?? 'websocket').toString();
            if (_truthy(po['tls'])) opts['tls'] = '';
            if (po['host'] != null) opts['host'] = po['host'].toString();
            if (po['path'] != null) opts['path'] = po['path'].toString();
            if (po.containsKey('mux')) opts['mux'] = _truthy(po['mux']) ? '1' : '0';
            if (_ssPlugin('v2ray-plugin', opts, ob) == false) return null;
          case 'shadow-tls':
            final host = _str(po['host']);
            if (host == null) return null;
            chain = _shadowTlsChain(ob, host, _str(po['password']),
                _int(po['version']) ?? 2,
                fp: fp);
          default:
            return null;
        }
      }
    case 'ssr':
      if (!_validPort(port) || server.isEmpty) return null;
      ob = {
        'type': 'shadowsocksr',
        'server': server,
        'server_port': port,
        'method': (p['cipher'] ?? '').toString(),
        'password': (p['password'] ?? '').toString(),
        'obfs': (p['obfs'] ?? 'plain').toString(),
        if (_str(p['obfs-param']) != null) 'obfs_param': _str(p['obfs-param']),
        'protocol': (p['protocol'] ?? 'origin').toString(),
        if (_str(p['protocol-param']) != null)
          'protocol_param': _str(p['protocol-param']),
      };
    case 'vmess':
    case 'vless':
    case 'trojan':
      final v = _V2()
        ..type = type
        ..name = name
        ..server = server
        ..port = port
        ..secret = type == 'trojan'
            ? (p['password'] ?? '').toString()
            : (p['uuid'] ?? '').toString()
        ..alterId = _int(p['alterId']) ?? 0
        ..cipher = _str(p['cipher'])
        ..network = _str(p['network']) ?? 'tcp'
        ..sni = sni
        ..insecure = insecure
        ..alpn = alpn
        ..fp = fp
        ..flow = _str(p['flow'])
        ..packetEncoding = _truthy(p['xudp'])
            ? 'xudp'
            : (_truthy(p['packet-addr']) ? 'packetaddr' : _str(p['packet-encoding']));
      final reality = p['reality-opts'];
      if (reality is Map) {
        v.security = 'reality';
        v.pbk = _str(reality['public-key']);
        v.sid = _str(reality['short-id']);
      } else if (type == 'trojan' || _truthy(p['tls'])) {
        v.security = 'tls';
      }
      switch (v.network) {
        case 'xhttp':
        case 'splithttp':
          final options = Map<String, dynamic>.from((p['xhttp-opts'] as Map?) ?? {});
          v.path = _str(options.remove('path'));
          v.host = _str(options.remove('host'));
          v.xhttpMode = _str(options.remove('mode'));
          v.xhttpOptions = options;
        case 'ws':
          final o = Map<String, dynamic>.from((p['ws-opts'] as Map?) ?? {});
          v.path = _str(o['path']) ?? _str(p['ws-path']) ?? '/';
          final h = Map<String, dynamic>.from((o['headers'] as Map?) ??
              (p['ws-headers'] as Map?) ??
              {});
          for (final e in h.entries) {
            if (e.key.toLowerCase() == 'host') {
              v.host = e.value.toString();
            } else {
              v.headers[e.key] = e.value.toString();
            }
          }
          v.maxEarlyData = _int(o['max-early-data']);
          v.earlyDataHeader = _str(o['early-data-header-name']);
          if (_truthy(o['v2ray-http-upgrade'])) v.network = 'httpupgrade';
        case 'h2':
          final o = Map<String, dynamic>.from((p['h2-opts'] as Map?) ?? {});
          v.host = _csv(o['host']).join(',');
          v.path = _str(o['path']);
        case 'http':
          final o = Map<String, dynamic>.from((p['http-opts'] as Map?) ?? {});
          v.network = 'tcp';
          v.headerType = 'http';
          v.method = _str(o['method']);
          final paths = _csv(o['path']);
          v.path = paths.isEmpty ? null : paths.first;
          final h = (o['headers'] as Map?) ?? {};
          final hosts = _csv(h['Host'] ?? h['host']);
          if (hosts.isNotEmpty) v.host = hosts.join(',');
        case 'grpc':
          final o = Map<String, dynamic>.from((p['grpc-opts'] as Map?) ?? {});
          v.serviceName = _str(o['grpc-service-name']);
      }
      ob = v.build();
    case 'hysteria':
      if (server.isEmpty) return null;
      final ports = _str(p['ports']);
      final prt = port ?? (ports != null ? _firstPort(ports) : null);
      if (!_validPort(prt)) return null;
      final proto = _str(p['protocol']) ?? 'udp';
      if (proto != 'udp') return null;
      ob = {
        'type': 'hysteria',
        'server': server,
        'server_port': prt,
        if (ports != null) 'server_ports': _portRanges(ports),
        'up_mbps': _mbps(p['up']) ?? 20,
        'down_mbps': _mbps(p['down']) ?? 100,
        if (_str(p['auth-str'] ?? p['auth_str']) != null)
          'auth_str': _str(p['auth-str'] ?? p['auth_str']),
        if (_str(p['auth']) != null) 'auth': _str(p['auth']),
        if (_str(p['obfs']) != null) 'obfs': _str(p['obfs']),
        'tls': _tls(
            sni: sni ?? (_isIp(server) ? null : server),
            insecure: insecure,
            alpn: alpn.isEmpty ? const ['hysteria'] : alpn,
            fp: fp),
      };
    case 'hysteria2':
    case 'hy2':
      if (server.isEmpty) return null;
      final ports = _str(p['ports']);
      final prt = port ?? (ports != null ? _firstPort(ports) : null);
      if (!_validPort(prt)) return null;
      ob = {
        'type': 'hysteria2',
        'server': server,
        'server_port': prt,
        if (ports != null && _portRanges(ports).isNotEmpty)
          'server_ports': _portRanges(ports),
        if (_str(p['password'] ?? p['auth']) != null)
          'password': _str(p['password'] ?? p['auth']),
        if (_mbps(p['up']) != null) 'up_mbps': _mbps(p['up']),
        if (_mbps(p['down']) != null) 'down_mbps': _mbps(p['down']),
        'tls': _tls(
            sni: sni ?? (_isIp(server) ? null : server),
            insecure: insecure,
            alpn: alpn,
            fp: null),
      };
      final obfs = _str(p['obfs']);
      if (obfs != null && obfs != 'none') {
        if (obfs != 'salamander') return null;
        ob['obfs'] = {
          'type': 'salamander',
          'password': (p['obfs-password'] ?? '').toString(),
        };
      }
      if (p['hop-interval'] != null) {
        final hi = _int(p['hop-interval']);
        if (hi != null && hi > 0) ob['hop_interval'] = '${hi}s';
      }
    case 'tuic':
      if (server.isEmpty || !_validPort(port)) return null;
      final uuid = _str(p['uuid']);
      if (uuid == null) return null; // TUIC v4 token auth is unsupported
      ob = {
        'type': 'tuic',
        'server': server,
        'server_port': port,
        'uuid': uuid,
        if (_str(p['password']) != null) 'password': _str(p['password']),
        'tls': _tls(
            sni: sni ?? (_isIp(server) ? null : server),
            insecure: insecure,
            alpn: alpn.isEmpty ? const ['h3'] : alpn,
            disableSni: _truthy(p['disable-sni'])),
      };
      final cc = _str(p['congestion-controller'])?.toLowerCase();
      if (cc == 'bbr' || cc == 'cubic' || cc == 'new_reno') {
        ob['congestion_control'] = cc;
      } else if (cc == 'newreno') {
        ob['congestion_control'] = 'new_reno';
      }
      final relay = _str(p['udp-relay-mode']);
      if (relay == 'native' || relay == 'quic') ob['udp_relay_mode'] = relay;
      if (_truthy(p['reduce-rtt'])) ob['zero_rtt_handshake'] = true;
    case 'wireguard':
      final peers = <Map<String, dynamic>>[];
      final rawPeers = p['peers'];
      if (rawPeers is List && rawPeers.isNotEmpty) {
        for (final rp in rawPeers.whereType<Map>()) {
          final peer = _wgPeer(
            server: (rp['server'] ?? '').toString(),
            port: _int(rp['port']),
            publicKey: _str(rp['public-key']),
            psk: _str(rp['pre-shared-key']),
            allowedIps: _csv(rp['allowed-ips']),
            reserved: _reserved(rp['reserved']),
          );
          if (peer != null) peers.add(peer);
        }
      } else {
        final peer = _wgPeer(
          server: server,
          port: port,
          publicKey: _str(p['public-key']),
          psk: _str(p['pre-shared-key']),
          allowedIps: _csv(p['allowed-ips']),
          reserved: _reserved(p['reserved']),
          keepalive: _int(p['persistent-keepalive']),
        );
        if (peer != null) peers.add(peer);
      }
      ob = _wgEndpoint(
        privateKey: (p['private-key'] ?? '').toString(),
        address: _wgAddresses([
          if (_str(p['ip']) != null) _str(p['ip'])!,
          if (_str(p['ipv6']) != null) _str(p['ipv6'])!,
        ]),
        peers: peers,
        mtu: _int(p['mtu']),
      );
      if (ob != null && p['amnezia-wg-option'] is Map) {
        _applyAmnezia(ob, Map<String, dynamic>.from(p['amnezia-wg-option'] as Map), force: true);
      }
    case 'socks5':
      if (server.isEmpty || !_validPort(port) || _truthy(p['tls'])) return null;
      ob = {
        'type': 'socks',
        'server': server,
        'server_port': port,
        'version': '5',
        if (_str(p['username']) != null) 'username': _str(p['username']),
        if (_str(p['password']) != null) 'password': _str(p['password']),
      };
    case 'http':
      if (server.isEmpty || !_validPort(port)) return null;
      ob = {
        'type': 'http',
        'server': server,
        'server_port': port,
        if (_str(p['username']) != null) 'username': _str(p['username']),
        if (_str(p['password']) != null) 'password': _str(p['password']),
        if (_truthy(p['tls']))
          'tls': _tls(
              sni: sni ?? (_isIp(server) ? null : server),
              insecure: insecure,
              fp: fp),
      };
    case 'snell':
      final o = Map<String, dynamic>.from((p['obfs-opts'] as Map?) ?? {});
      final ver = _int(p['version']);
      if (ver == null) return null; // Clash default v1: not supported
      ob = _snellOutbound(server, port, _str(p['psk']), ver, _str(o['mode']),
          _str(o['host']));
    case 'anytls':
      if (server.isEmpty || !_validPort(port)) return null;
      ob = {
        'type': 'anytls',
        'server': server,
        'server_port': port,
        'password': (p['password'] ?? '').toString(),
        'tls': _tls(
            sni: sni ?? (_isIp(server) ? null : server),
            insecure: insecure,
            alpn: alpn,
            fp: fp),
      };
      final ic = _int(p['idle-session-check-interval']);
      final it = _int(p['idle-session-timeout']);
      final mi = _int(p['min-idle-session']);
      if (ic != null) ob['idle_session_check_interval'] = '${ic}s';
      if (it != null) ob['idle_session_timeout'] = '${it}s';
      if (mi != null) ob['min_idle_session'] = mi;
    case 'ssh':
      if (server.isEmpty) return null;
      ob = {
        'type': 'ssh',
        'server': server,
        'server_port': port ?? 22,
        'user': (p['username'] ?? 'root').toString(),
        if (_str(p['password']) != null) 'password': _str(p['password']),
        if (_str(p['private-key']) != null)
          'private_key': _str(p['private-key']),
        if (_str(p['private-key-passphrase']) != null)
          'private_key_passphrase': _str(p['private-key-passphrase']),
        if (_csv(p['host-key']).isNotEmpty) 'host_key': _csv(p['host-key']),
        if (_csv(p['host-key-algorithms']).isNotEmpty)
          'host_key_algorithms': _csv(p['host-key-algorithms']),
      };
    default:
      return null;
  }
  if (ob == null) return null;
  // Clash `udp: false` → TCP-only.
  if (p['udp'] == false &&
      const {'shadowsocks', 'vmess', 'vless', 'trojan', 'socks'}
          .contains(ob['type'])) {
    ob['network'] = 'tcp';
  }
  if (_truthy(p['tfo'])) ob['tcp_fast_open'] = true;
  final smux = p['smux'];
  if (smux is Map && _truthy(smux['enabled']) &&
      const {'shadowsocks', 'vmess', 'vless', 'trojan'}.contains(ob['type']) &&
      ob['flow'] == null) {
    final proto = (smux['protocol'] ?? 'h2mux').toString();
    ob['multiplex'] = {
      'enabled': true,
      if (const {'h2mux', 'smux', 'yamux'}.contains(proto)) 'protocol': proto,
      if (_int(smux['max-connections']) != null)
        'max_connections': _int(smux['max-connections']),
      if (_truthy(smux['padding'])) 'padding': true,
    };
  }
  return _Parsed(name, ob, chain: chain);
}

// ------------------------------------------------------------------ JSON

List<_Parsed> _parseJsonConfig(Object? j) {
  if (j is List) {
    // Array of full configs (v2rayN / Xray style) or array of outbounds.
    final out = <_Parsed>[];
    for (final e in j) {
      if (e is Map) {
        if (e.containsKey('outbounds') || e.containsKey('endpoints')) {
          out.addAll(_parseJsonConfig(e));
        } else if (e.containsKey('protocol')) {
          final r = _xrayOutbound(Map<String, dynamic>.from(e), null);
          if (r != null) out.add(r);
        } else if (e.containsKey('type')) {
          out.addAll(_singBox({'outbounds': [e]}));
        }
      }
    }
    return out;
  }
  if (j is! Map) return const [];
  final m = Map<String, dynamic>.from(j);
  final outbounds = m['outbounds'];
  final isXray = outbounds is List &&
      outbounds.any((o) => o is Map && o.containsKey('protocol'));
  if (isXray) {
    final remarks = _str(m['remarks']);
    final out = <_Parsed>[];
    for (final o in outbounds.whereType<Map>()) {
      final r = _xrayOutbound(Map<String, dynamic>.from(o), remarks);
      if (r != null) out.add(r);
    }
    // A single-server Xray config uses the config's remarks as name.
    return out;
  }
  return _singBox(m);
}

Map<String, dynamic> _deepCopy(Map m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

const _skipSingBoxTypes = {
  'selector', 'urltest', 'direct', 'block', 'dns', 'bridge',
};

List<_Parsed> _singBox(Map<String, dynamic> m) {
  final out = <_Parsed>[];
  final all = <String, Map<String, dynamic>>{};
  final obs = (m['outbounds'] as List?)?.whereType<Map>().toList() ?? [];
  for (final o in obs) {
    final t = o['tag'];
    if (t is String) all[t] = _deepCopy(o);
  }
  // shadowtls outbounds used as detours are folded into their users.
  final usedAsDetour = <String>{};
  for (final o in obs) {
    final d = o['detour'];
    if (d is String && all[d]?['type'] == 'shadowtls') usedAsDetour.add(d);
  }
  for (final o in obs) {
    final type = o['type'];
    if (type is! String || _skipSingBoxTypes.contains(type)) continue;
    final tag = (o['tag'] ?? '').toString();
    if (usedAsDetour.contains(tag)) continue;
    if (type == 'shadowtls') continue; // stand-alone shadowtls is useless
    final ob = _deepCopy(o);
    ob.remove('tag');
    List<Map<String, dynamic>>? chain;
    final d = ob['detour'];
    if (d is String) {
      final dep = all[d];
      if (dep != null && dep['type'] == 'shadowtls' && dep['detour'] == null) {
        final c = _deepCopy(dep)..['tag'] = 'shadowtls';
        ob['detour'] = 'shadowtls';
        chain = [c];
      } else {
        ob.remove('detour'); // chains to other nodes are not preserved
      }
    }
    if (type == 'wireguard') {
      final ep = _legacyWireGuard(ob);
      if (ep != null) out.add(_Parsed(tag, ep));
      continue;
    }
    out.add(_Parsed(tag, ob, chain: chain));
  }
  final eps = (m['endpoints'] as List?)?.whereType<Map>() ?? const [];
  for (final e in eps) {
    final type = e['type'];
    if (type is! String) continue;
    final tag = (e['tag'] ?? '').toString();
    final ep = _deepCopy(e)
      ..remove('tag')
      ..remove('detour')
      ..remove('listen_port');
    out.add(_Parsed(tag, ep));
  }
  return out;
}

/// Pre-1.11 WireGuard *outbound* → 1.14 endpoint.
Map<String, dynamic>? _legacyWireGuard(Map<String, dynamic> o) {
  if (o['peers'] is List && o['server'] == null) {
    final peers = (o['peers'] as List).whereType<Map>().map((p) {
      return <String, dynamic>{
        'address': p['server'],
        'port': p['server_port'],
        'public_key': p['public_key'],
        if (p['pre_shared_key'] != null) 'pre_shared_key': p['pre_shared_key'],
        'allowed_ips': p['allowed_ips'] ?? const ['0.0.0.0/0', '::/0'],
        if (p['reserved'] != null) 'reserved': _reserved(p['reserved']),
      };
    }).toList();
    return _wgEndpoint(
      privateKey: (o['private_key'] ?? '').toString(),
      address: _wgAddresses(_csv(o['local_address'])),
      peers: peers,
      mtu: _int(o['mtu']),
    );
  }
  final peer = _wgPeer(
    server: (o['server'] ?? '').toString(),
    port: _int(o['server_port']),
    publicKey: _str(o['peer_public_key']),
    psk: _str(o['pre_shared_key']),
    reserved: _reserved(o['reserved']),
  );
  if (peer == null) return null;
  return _wgEndpoint(
    privateKey: (o['private_key'] ?? '').toString(),
    address: _wgAddresses(_csv(o['local_address'])),
    peers: [peer],
    mtu: _int(o['mtu']),
  );
}

_Parsed? _xrayOutbound(Map<String, dynamic> o, String? remarks) {
  final protocol = (o['protocol'] ?? '').toString();
  final settings = Map<String, dynamic>.from((o['settings'] as Map?) ?? {});
  final stream = Map<String, dynamic>.from((o['streamSettings'] as Map?) ?? {});
  final tag = _str(o['tag']);
  final name = remarks ?? tag ?? '';
  if (const {'freedom', 'blackhole', 'dns', 'loopback'}.contains(protocol)) {
    return null;
  }
  Map<String, dynamic> first(String key) {
    final l = settings[key];
    if (l is List && l.isNotEmpty && l.first is Map) {
      return Map<String, dynamic>.from(l.first as Map);
    }
    return {};
  }

  switch (protocol) {
    case 'vless':
    case 'vmess':
    case 'trojan':
      final v = _V2()
        ..type = protocol
        ..name = name;
      if (protocol == 'trojan') {
        final s = first('servers');
        v.server = (s['address'] ?? '').toString();
        v.port = _int(s['port']);
        v.secret = (s['password'] ?? '').toString();
        v.flow = _str(s['flow']);
      } else {
        var vn = first('vnext');
        if (vn.isEmpty) vn = settings; // Xray 25 flat form
        v.server = (vn['address'] ?? '').toString();
        v.port = _int(vn['port']);
        final users = vn['users'];
        final u = users is List && users.isNotEmpty && users.first is Map
            ? Map<String, dynamic>.from(users.first as Map)
            : vn;
        v.secret = (u['id'] ?? '').toString();
        v.flow = _str(u['flow']);
        v.alterId = _int(u['alterId']) ?? 0;
        v.cipher = protocol == 'vmess' ? _str(u['security']) : null;
        final enc = _str(u['encryption']);
        if (protocol == 'vless' && enc != null && enc != 'none') return null;
      }
      v.network = _str(stream['network']) ?? 'tcp';
      v.security = _str(stream['security']) ?? 'none';
      final tls = Map<String, dynamic>.from(
          (stream['tlsSettings'] as Map?) ?? (stream['realitySettings'] as Map?) ?? {});
      v.sni = _str(tls['serverName']);
      v.insecure = _truthy(tls['allowInsecure']);
      v.alpn = _csv(tls['alpn']);
      v.fp = _str(tls['fingerprint']);
      v.pbk = _str(tls['publicKey']) ?? _str(tls['password']);
      v.sid = _str(tls['shortId']);
      Map<String, dynamic> s(String k) =>
          Map<String, dynamic>.from((stream[k] as Map?) ?? {});
      switch (v.network) {
        case 'xhttp':
        case 'splithttp':
          final options = s('xhttpSettings').isNotEmpty ? s('xhttpSettings') : s('splithttpSettings');
          v.path = _str(options['path']);
          v.host = _str(options['host']);
          v.xhttpMode = _str(options['mode']);
          // Xray's `extra` replaces outer options, except host/path/mode.
          final extra = options['extra'] as Map?;
          v.xhttpOptions = _xhttpExtra(extra != null
              ? Map<String, dynamic>.from(extra)
              : {
                  for (final entry in options.entries)
                    if (!const {'path', 'host', 'mode'}.contains(entry.key)) entry.key: entry.value,
                });
        case 'ws':
          final w = s('wsSettings');
          v.path = _str(w['path']);
          final h = Map<String, dynamic>.from((w['headers'] as Map?) ?? {});
          v.host = _str(w['host']) ?? _str(h['Host']) ?? _str(h['host']);
        case 'grpc':
          final grpc = s('grpcSettings');
          v.serviceName = _str(grpc['serviceName']);
          v.grpcAuthority = _str(grpc['authority']);
          if (grpc['multiMode'] != null) v.grpcMultiMode = _truthy(grpc['multiMode']);
        case 'httpupgrade':
          final w = s('httpupgradeSettings');
          v.path = _str(w['path']);
          v.host = _str(w['host']);
        case 'http':
        case 'h2':
          final w = s('httpSettings');
          v.path = _str(w['path']);
          v.host = _csv(w['host']).join(',');
        case 'tcp':
        case 'raw':
          final w = s(stream.containsKey('rawSettings') ? 'rawSettings' : 'tcpSettings');
          final header = Map<String, dynamic>.from((w['header'] as Map?) ?? {});
          if (header['type'] == 'http') {
            v.headerType = 'http';
            final req = Map<String, dynamic>.from((header['request'] as Map?) ?? {});
            v.path = _csv(req['path']).firstOrNull;
            final hh = Map<String, dynamic>.from((req['headers'] as Map?) ?? {});
            v.host = _csv(hh['Host']).join(',');
          }
      }
      final ob = v.build();
      return ob == null ? null : _Parsed(name, ob);
    case 'shadowsocks':
      final s = first('servers').isEmpty ? settings : first('servers');
      final m = _ssMethod((s['method'] ?? '').toString());
      final port = _int(s['port']);
      final server = (s['address'] ?? '').toString();
      if (m == null || !_validPort(port) || server.isEmpty) return null;
      return _Parsed(name, {
        'type': 'shadowsocks',
        'server': server,
        'server_port': port,
        'method': m,
        'password': (s['password'] ?? '').toString(),
        if (_truthy(s['uot'])) 'udp_over_tcp': true,
      });
    case 'socks':
    case 'http':
      final s = first('servers').isEmpty ? settings : first('servers');
      final port = _int(s['port']);
      final server = (s['address'] ?? '').toString();
      if (!_validPort(port) || server.isEmpty) return null;
      final users = s['users'];
      final u = users is List && users.isNotEmpty && users.first is Map
          ? users.first as Map
          : s;
      return _Parsed(name, {
        'type': protocol,
        'server': server,
        'server_port': port,
        if (protocol == 'socks') 'version': '5',
        if (_str(u['user']) != null) 'username': _str(u['user']),
        if (_str(u['pass']) != null) 'password': _str(u['pass']),
      });
    case 'wireguard':
      final peers = <Map<String, dynamic>>[];
      for (final p in (settings['peers'] as List? ?? const []).whereType<Map>()) {
        final endpoint = (p['endpoint'] ?? '').toString();
        final ci = endpoint.lastIndexOf(':');
        var host = ci > 0 ? endpoint.substring(0, ci) : endpoint;
        if (host.startsWith('[') && host.endsWith(']')) {
          host = host.substring(1, host.length - 1);
        }
        final peer = _wgPeer(
          server: host,
          port: ci > 0 ? _int(endpoint.substring(ci + 1)) : null,
          publicKey: _str(p['publicKey']),
          psk: _str(p['preSharedKey']),
          allowedIps: _csv(p['allowedIPs']),
          reserved: _reserved(settings['reserved']),
          keepalive: _int(p['keepAlive']),
        );
        if (peer != null) peers.add(peer);
      }
      final ep = _wgEndpoint(
        privateKey: (settings['secretKey'] ?? '').toString(),
        address: _wgAddresses(_csv(settings['address'])),
        peers: peers,
        mtu: _int(settings['mtu']),
      );
      return ep == null ? null : _Parsed(name, ep);
    case 'hysteria':
    case 'hysteria2':
      // Xray 25+ "hysteria" outbound (v2 protocol).
      final port = _int(settings['port']);
      final server = (settings['address'] ?? '').toString();
      if (!_validPort(port) || server.isEmpty) return null;
      final tls = Map<String, dynamic>.from((stream['tlsSettings'] as Map?) ?? {});
      return _Parsed(name, {
        'type': 'hysteria2',
        'server': server,
        'server_port': port,
        if (_str(settings['password'] ?? settings['auth']) != null)
          'password': _str(settings['password'] ?? settings['auth']),
        'tls': _tls(
            sni: _str(tls['serverName']) ?? (_isIp(server) ? null : server),
            insecure: _truthy(tls['allowInsecure']),
            alpn: _csv(tls['alpn'])),
      });
    default:
      return null;
  }
}
