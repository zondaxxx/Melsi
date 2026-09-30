// Downloads a subscription URL and parses body + provider headers.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'link_parser.dart';
import 'models.dart';

/// App version reported in the default User-Agent.
const String kMelsiVersion = '1.0.0';

/// Default subscription User-Agent. Mentions clash/mihomo so panels
/// (Marzban, Remnawave, 3x-ui, ...) return a full-featured format.
const String kDefaultSubscriptionUserAgent =
    'Melsi/$kMelsiVersion sing-box/1.14 (clash-verge; mihomo)';

class SubscriptionFetchException implements Exception {
  SubscriptionFetchException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'SubscriptionFetchException: $message';
}

class SubscriptionFetcher {
  SubscriptionFetcher(
      {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _client = client; // ignore: prefer_initializing_formals

  final http.Client? _client;
  final Duration timeout;

  /// GET [url] and parse it. Throws [SubscriptionFetchException] on network
  /// errors, timeouts and non-2xx responses. An empty `nodes` list means the
  /// body was downloaded but nothing in it could be parsed.
  Future<SubscriptionFetchResult> fetch(String url,
      {String? userAgent, String? subscriptionId}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw SubscriptionFetchException('Invalid subscription URL');
    }
    final client = _client ?? http.Client();
    try {
      final req = http.Request('GET', uri)
        ..followRedirects = true
        ..maxRedirects = 10
        ..headers['User-Agent'] =
            (userAgent == null || userAgent.trim().isEmpty)
                ? kDefaultSubscriptionUserAgent
                : userAgent
        ..headers['Accept'] = '*/*';
      final streamed = await client.send(req).timeout(timeout);
      final resp = await http.Response.fromStream(streamed).timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw SubscriptionFetchException('HTTP ${resp.statusCode}',
            statusCode: resp.statusCode);
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      return parseResponse(body, resp.headers,
          subscriptionId: subscriptionId);
    } on SubscriptionFetchException {
      rethrow;
    } on TimeoutException {
      throw SubscriptionFetchException('Timed out');
    } catch (e) {
      throw SubscriptionFetchException(e.toString());
    } finally {
      if (_client == null) client.close();
    }
  }

  /// Parses an already downloaded body + headers (header names lower-case).
  static SubscriptionFetchResult parseResponse(
      String body, Map<String, String> headers,
      {String? subscriptionId}) {
    final h = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
    final info = parseUserInfo(h['subscription-userinfo']);
    String? title = decodeHeaderText(h['profile-title']);
    title ??= _filenameFromDisposition(h['content-disposition']);
    final interval = int.tryParse((h['profile-update-interval'] ?? '').trim());
    return SubscriptionFetchResult(
      nodes: LinkParser.parseContent(body, subscriptionId: subscriptionId),
      title: title,
      upload: info.upload,
      download: info.download,
      total: info.total,
      expire: info.expire,
      updateIntervalHours: (interval != null && interval > 0) ? interval : null,
      supportUrl: _nonEmpty(h['support-url']),
      webPageUrl: _nonEmpty(h['profile-web-page-url']),
      announce: decodeHeaderText(h['announce']),
    );
  }

  /// `upload=1; download=2; total=3; expire=1700000000`.
  static ({int? upload, int? download, int? total, DateTime? expire})
      parseUserInfo(String? header) {
    int? up, down, total;
    DateTime? expire;
    if (header != null) {
      for (final part in header.split(RegExp(r'[;,]'))) {
        final kv = part.split('=');
        if (kv.length != 2) continue;
        final k = kv[0].trim().toLowerCase();
        final v = num.tryParse(kv[1].trim())?.toInt();
        if (v == null) continue;
        switch (k) {
          case 'upload':
            up = v;
          case 'download':
            down = v;
          case 'total':
            total = v;
          case 'expire':
            if (v > 0) {
              expire = DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true);
            }
        }
      }
    }
    return (upload: up, download: down, total: total, expire: expire);
  }

  /// Plain text or `base64:<b64>`; also undoes latin-1 mojibake of UTF-8.
  static String? decodeHeaderText(String? value) {
    if (value == null) return null;
    var v = value.trim();
    if (v.isEmpty) return null;
    if (v.toLowerCase().startsWith('base64:')) {
      var b = v.substring(7).trim().replaceAll('-', '+').replaceAll('_', '/');
      b = b.replaceAll('=', '');
      while (b.length % 4 != 0) {
        b += '=';
      }
      try {
        v = utf8.decode(base64.decode(b), allowMalformed: true).trim();
      } catch (_) {
        return null;
      }
    } else if (v.codeUnits.every((c) => c < 256) &&
        v.codeUnits.any((c) => c >= 0x80)) {
      // Header bytes decoded as latin-1 by the HTTP stack.
      try {
        v = utf8.decode(latin1.encode(v));
      } catch (_) {}
    }
    return v.isEmpty ? null : v;
  }

  static String? _filenameFromDisposition(String? cd) {
    if (cd == null) return null;
    final star = RegExp(r"filename\*\s*=\s*[^']*''([^;]+)", caseSensitive: false)
        .firstMatch(cd);
    String strip(String n) =>
        n.replaceFirst(RegExp(r'\.(ya?ml|json|txt|conf)$'), '');
    if (star != null) {
      try {
        return strip(Uri.decodeComponent(star.group(1)!.trim()));
      } catch (_) {}
    }
    final m = RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false)
        .firstMatch(cd);
    final name = m?.group(1)?.trim();
    if (name == null || name.isEmpty) return null;
    return strip(name);
  }

  static String? _nonEmpty(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}
