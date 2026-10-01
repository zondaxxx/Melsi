import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One sample from `GET /traffic` — bytes per second.
class TrafficSample {
  const TrafficSample(this.up, this.down);
  final int up;
  final int down;
}

class ConnectionsSnapshot {
  ConnectionsSnapshot({
    required this.uploadTotal,
    required this.downloadTotal,
    required this.count,
    this.memory,
  });
  final int uploadTotal;
  final int downloadTotal;
  final int count;
  final int? memory;
}

class ClashLogLine {
  ClashLogLine(this.level, this.payload, this.time);
  final String level;
  final String payload;
  final DateTime time;
}

/// Minimal client for sing-box's Clash-compatible API.
class ClashApi {
  ClashApi({required this.endpoint, required this.secret, http.Client? client})
      : _client = client ?? http.Client();

  /// `host:port`
  final String endpoint;
  final String secret;
  final http.Client _client;

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('http://$endpoint$path').replace(queryParameters: q);
  Map<String, String> get _h => {'Authorization': 'Bearer $secret'};

  /// Streams `{"up":N,"down":N}` lines once per second until cancelled.
  Stream<TrafficSample> traffic() => _jsonLines('/traffic').map((j) =>
      TrafficSample((j['up'] as num?)?.toInt() ?? 0, (j['down'] as num?)?.toInt() ?? 0));

  /// Live log stream (`GET /logs?level=`).
  Stream<ClashLogLine> logs({String level = 'info'}) =>
      _jsonLines('/logs', {'level': level}).map((j) => ClashLogLine(
          j['type'] as String? ?? 'info', j['payload'] as String? ?? '', DateTime.now()));

  Stream<Map<String, dynamic>> _jsonLines(String path, [Map<String, String>? q]) {
    late StreamController<Map<String, dynamic>> ctrl;
    http.Client? client;
    StreamSubscription<String>? sub;
    ctrl = StreamController<Map<String, dynamic>>(
      onListen: () async {
        client = http.Client();
        try {
          final req = http.Request('GET', _u(path, q))..headers.addAll(_h);
          final res = await client!.send(req);
          if (res.statusCode != 200) {
            ctrl.addError(Exception('HTTP ${res.statusCode}'));
            await ctrl.close();
            return;
          }
          sub = res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
            if (line.trim().isEmpty) return;
            try {
              ctrl.add((jsonDecode(line) as Map).cast<String, dynamic>());
            } catch (_) {}
          }, onError: ctrl.addError, onDone: ctrl.close);
        } catch (e) {
          if (!ctrl.isClosed) {
            ctrl.addError(e);
            await ctrl.close();
          }
        }
      },
      onCancel: () async {
        await sub?.cancel();
        client?.close();
      },
    );
    return ctrl.stream;
  }

  Future<ConnectionsSnapshot> connections() async {
    final r = await _client.get(_u('/connections'), headers: _h)
        .timeout(const Duration(seconds: 3));
    final j = (jsonDecode(r.body) as Map).cast<String, dynamic>();
    return ConnectionsSnapshot(
      uploadTotal: (j['uploadTotal'] as num?)?.toInt() ?? 0,
      downloadTotal: (j['downloadTotal'] as num?)?.toInt() ?? 0,
      count: (j['connections'] as List?)?.length ?? 0,
      memory: (j['memory'] as num?)?.toInt(),
    );
  }

  /// Closes all connections (so they reconnect through a new node).
  Future<void> closeAllConnections() async {
    await _client.delete(_u('/connections'), headers: _h)
        .timeout(const Duration(seconds: 3));
  }

  Future<Map<String, dynamic>> proxies() async {
    final r = await _client.get(_u('/proxies'), headers: _h)
        .timeout(const Duration(seconds: 3));
    return ((jsonDecode(r.body) as Map)['proxies'] as Map? ?? {})
        .cast<String, dynamic>();
  }

  /// Real URL test through [name]. Returns ms or null on failure/timeout.
  Future<int?> delay(String name,
      {required String url, int timeoutMs = 5000}) async {
    try {
      final r = await _client
          .get(
              _u('/proxies/${Uri.encodeComponent(name)}/delay',
                  {'url': url, 'timeout': '$timeoutMs'}),
              headers: _h)
          .timeout(Duration(milliseconds: timeoutMs + 1500));
      if (r.statusCode != 200) return null;
      final d = (jsonDecode(r.body) as Map)['delay'];
      return d is num && d > 0 ? d.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  /// Switches selector [selector] to outbound [name].
  Future<bool> select(String selector, String name) async {
    final r = await _client
        .put(_u('/proxies/${Uri.encodeComponent(selector)}'),
            headers: {..._h, 'Content-Type': 'application/json'},
            body: jsonEncode({'name': name}))
        .timeout(const Duration(seconds: 3));
    return r.statusCode < 300;
  }

  void close() => _client.close();
}
