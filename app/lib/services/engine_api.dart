import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client for the Melsi engine control API (CONTRACT §3).
class EngineApi {
  EngineApi({required this.endpoint, required this.secret, http.Client? client})
      : _client = client ?? http.Client();

  /// `host:port`
  final String endpoint;
  final String secret;
  final http.Client _client;

  Uri _u(String path) => Uri.parse('http://$endpoint$path');
  Map<String, String> get _h => {
        'Authorization': 'Bearer $secret',
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>> _get(String path,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final r = await _client.get(_u(path), headers: _h).timeout(timeout);
    _check(r);
    return (jsonDecode(r.body) as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> _post(String path, [Object? body,
      Duration timeout = const Duration(seconds: 5)]) async {
    final r = await _client
        .post(_u(path), headers: _h, body: body == null ? null : jsonEncode(body))
        .timeout(timeout);
    _check(r);
    return r.body.isEmpty ? {} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
  }

  void _check(http.Response r) {
    if (r.statusCode >= 300) {
      throw EngineApiException(r.statusCode, r.body);
    }
  }

  String _sel(String selector) => Uri.encodeComponent(selector);

  Future<EngineHealth> health({Duration timeout = const Duration(seconds: 2)}) async =>
      EngineHealth.fromJson(await _get('/health', timeout: timeout));

  Future<List<GroupStatus>> status() async {
    final j = await _get('/status');
    return (j['groups'] as List? ?? const [])
        .map((e) => GroupStatus.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<GroupStatus> setAuto(String selector, bool auto) async =>
      GroupStatus.fromJson(await _post('/groups/${_sel(selector)}/auto', {'auto': auto}));

  Future<GroupStatus> setMode(String selector, String mode) async =>
      GroupStatus.fromJson(await _post('/groups/${_sel(selector)}/mode', {'mode': mode}));

  Future<GroupStatus> probe(String selector) async => GroupStatus.fromJson(
      await _post('/groups/${_sel(selector)}/probe', null, const Duration(seconds: 30)));

  Future<GroupStatus> select(String selector, String tag) async =>
      GroupStatus.fromJson(await _post('/groups/${_sel(selector)}/select', {'tag': tag}));

  Future<void> stop() async {
    await _post('/stop');
  }

  void close() => _client.close();
}

class EngineApiException implements Exception {
  EngineApiException(this.status, this.body);
  final int status;
  final String body;
  @override
  String toString() => 'Engine API $status: $body';
}

class EngineHealth {
  EngineHealth({required this.ok, this.version, this.singBox, this.uptimeSec});
  final bool ok;
  final String? version;
  final String? singBox;
  final int? uptimeSec;

  factory EngineHealth.fromJson(Map<String, dynamic> j) => EngineHealth(
        ok: j['ok'] == true,
        version: j['version'] as String?,
        singBox: j['sing_box'] as String?,
        uptimeSec: (j['uptime_sec'] as num?)?.toInt(),
      );
}

class LastSwitch {
  LastSwitch({this.from, this.to, this.reason, this.at});
  final String? from;
  final String? to;
  final String? reason;
  final DateTime? at;

  factory LastSwitch.fromJson(Map<String, dynamic> j) => LastSwitch(
        from: j['from'] as String?,
        to: j['to'] as String?,
        reason: j['reason'] as String?,
        at: j['at'] is String ? DateTime.tryParse(j['at'] as String) : null,
      );
}

class NodeStat {
  NodeStat({
    required this.tag,
    this.latencyMs,
    this.jitterMs,
    this.loss,
    this.score,
    this.alive = false,
    this.samples = 0,
    this.lastError,
  });

  final String tag;
  final int? latencyMs;
  final int? jitterMs;

  /// 0..1
  final double? loss;
  final double? score;
  final bool alive;
  final int samples;
  final String? lastError;

  factory NodeStat.fromJson(Map<String, dynamic> j) => NodeStat(
        tag: j['tag'] as String? ?? '',
        latencyMs: (j['latency_ms'] as num?)?.round(),
        jitterMs: (j['jitter_ms'] as num?)?.round(),
        loss: (j['loss'] as num?)?.toDouble(),
        score: (j['score'] as num?)?.toDouble(),
        alive: j['alive'] == true,
        samples: (j['samples'] as num?)?.toInt() ?? 0,
        lastError: (j['last_error'] as String?)?.isEmpty ?? true
            ? null
            : j['last_error'] as String,
      );
}

class GroupStatus {
  GroupStatus({
    required this.selector,
    this.auto = false,
    this.mode,
    this.current,
    this.lastSwitch,
    this.nodes = const [],
  });

  final String selector;
  final bool auto;
  final String? mode;
  final String? current;
  final LastSwitch? lastSwitch;
  final List<NodeStat> nodes;

  NodeStat? stat(String? tag) {
    if (tag == null) return null;
    for (final n in nodes) {
      if (n.tag == tag) return n;
    }
    return null;
  }

  NodeStat? get currentStat => stat(current);

  factory GroupStatus.fromJson(Map<String, dynamic> j) => GroupStatus(
        selector: j['selector'] as String? ?? '',
        auto: j['auto'] == true,
        mode: j['mode'] as String?,
        current: j['current'] as String?,
        lastSwitch: j['last_switch'] is Map
            ? LastSwitch.fromJson((j['last_switch'] as Map).cast<String, dynamic>())
            : null,
        nodes: (j['nodes'] as List? ?? const [])
            .map((e) => NodeStat.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}
