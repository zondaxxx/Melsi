// Public IP lookup over a chain of free geo providers.
//
// Each provider answers a slightly different JSON shape, so an adapter per
// host maps it onto [IpInfo]; the first 2xx answer carrying an `ip` wins.
// The client factory is injected so the service can route the probe
// through the system proxy on desktop, and tests can answer offline.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/models.dart';

/// Thrown when every provider failed (network, timeout, bad JSON).
class IpLookupException implements Exception {
  IpLookupException(this.cause);
  final Object? cause;

  @override
  String toString() => 'IpLookupException($cause)';
}

/// Maps one provider's JSON onto [IpInfo]. Returns null for a body that
/// carries no usable `ip` (e.g. ipwho.is `{"success": false}`).
typedef IpAdapter = IpInfo? Function(Map<String, dynamic> json, DateTime at);

class IpGeoClient {
  IpGeoClient({
    required this.client,
    List<Uri>? providers,
    this.timeout = const Duration(seconds: 5),
  }) : providers = providers ?? defaultProviders;

  /// Fresh client per lookup (closed when it returns).
  final http.Client Function() client;
  final List<Uri> providers;
  final Duration timeout;

  /// Tried in order; all three are in `ConfigBuilder.probeHosts`, so the
  /// request always leaves through the tunnel while connected.
  static final List<Uri> defaultProviders = [
    Uri.parse('https://ipwho.is/'),
    Uri.parse('https://api.ip.sb/geoip'),
    Uri.parse('https://ipinfo.io/json'),
  ];

  /// Per-host adapter table. Unknown hosts fall back to [genericAdapter],
  /// which understands the common field names of all three.
  static final Map<String, IpAdapter> adapters = {
    'ipwho.is': _ipwho,
    'api.ip.sb': _ipsb,
    'ipinfo.io': _ipinfo,
  };

  /// Asks the providers in order and returns the first good answer.
  /// Throws [IpLookupException] when none answered.
  Future<IpInfo> lookup({DateTime? at}) async {
    final c = client();
    Object? last;
    try {
      for (final uri in providers) {
        try {
          final r = await c
              .get(uri, headers: const {'Accept': 'application/json'})
              .timeout(timeout);
          if (r.statusCode < 200 || r.statusCode >= 300) {
            last = http.ClientException('HTTP ${r.statusCode}', uri);
            continue;
          }
          // Decode ourselves: providers don't always declare a charset and
          // http would fall back to latin-1 (garbling city names).
          final body = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
          if (body is! Map) {
            last = const FormatException('not a JSON object');
            continue;
          }
          final json = body.cast<String, dynamic>();
          final ip = json['ip'];
          if (ip is! String || ip.trim().isEmpty) {
            last = const FormatException('no ip field');
            continue;
          }
          final adapter = adapters[uri.host] ?? genericAdapter;
          final info = adapter(json, at ?? DateTime.now());
          if (info != null) return info;
          last = const FormatException('provider refused');
        } catch (e) {
          last = e;
        }
      }
    } finally {
      c.close();
    }
    throw IpLookupException(last);
  }

  // ------------------------------------------------------------ adapters

  /// ipwho.is: `{ip, success, country_code, city, connection: {org}}`.
  static IpInfo? _ipwho(Map<String, dynamic> j, DateTime at) {
    if (j['success'] == false) return null;
    final conn = j['connection'];
    return IpInfo(
      ip: _s(j['ip'])!,
      countryCode: _cc(j['country_code']),
      city: _s(j['city']),
      org: _s(conn is Map ? (conn['org'] ?? conn['isp']) : null),
      at: at,
    );
  }

  /// api.ip.sb/geoip: `{ip, country_code, city, organization, isp}`.
  static IpInfo? _ipsb(Map<String, dynamic> j, DateTime at) => IpInfo(
        ip: _s(j['ip'])!,
        countryCode: _cc(j['country_code']),
        city: _s(j['city']),
        org: _s(j['organization'] ?? j['isp'] ?? j['asn_organization']),
        at: at,
      );

  /// ipinfo.io/json: `{ip, country, city, org}` (org is "AS1234 Name").
  static IpInfo? _ipinfo(Map<String, dynamic> j, DateTime at) => IpInfo(
        ip: _s(j['ip'])!,
        countryCode: _cc(j['country']),
        city: _s(j['city']),
        org: _stripAsn(_s(j['org'])),
        at: at,
      );

  /// Any host: the union of the field names above.
  static IpInfo? genericAdapter(Map<String, dynamic> j, DateTime at) {
    if (j['success'] == false) return null;
    final conn = j['connection'];
    return IpInfo(
      ip: _s(j['ip'])!,
      countryCode: _cc(j['country_code'] ?? j['countryCode'] ?? j['country']),
      city: _s(j['city']),
      org: _stripAsn(_s(j['org'] ??
          j['organization'] ??
          j['isp'] ??
          (conn is Map ? (conn['org'] ?? conn['isp']) : null))),
      at: at,
    );
  }

  static String? _s(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// Two-letter code, upper-cased; anything else is "unknown".
  static String? _cc(Object? v) {
    final s = _s(v);
    if (s == null || s.length != 2) return null;
    return s.toUpperCase();
  }

  /// "AS15169 Google LLC" → "Google LLC".
  static String? _stripAsn(String? org) {
    if (org == null) return null;
    final m = RegExp(r'^AS\d+\s+(.+)$').firstMatch(org);
    return m == null ? org : m.group(1);
  }
}
