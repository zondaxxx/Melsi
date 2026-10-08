// «Где я»: the real public IP (measured while stopped) versus the tunnel
// exit (measured while connected), a leak verdict from the two, and the
// in-tunnel speed test. Results are cached in the `netcheck` section of
// the state file so the panel has numbers before the first lookup lands.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/io_client.dart';
import 'package:http/http.dart' as http;

import '../../core/models.dart';
import '../../services/tcp_ping.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_state.dart';
import '../../state/commands.dart';
import '../../state/feature_service.dart';
import 'ip_geo.dart';
import 'speed_test.dart';
import 'speed_test_sheet.dart';

/// What the two IPs say about the tunnel.
enum LeakVerdict {
  /// Not connected, or one side unknown.
  unknown,

  /// Exit differs from the real IP and sits in the server's country.
  ok,

  /// Exit country equals the real country while the server is elsewhere:
  /// the probe may have gone around the tunnel.
  warning,

  /// Exit IP equals the real IP: traffic is going direct.
  danger,
}

enum SpeedPhase { idle, ping, down, up, done }

/// One finished speed test. Speeds are bytes per second.
class SpeedResult {
  const SpeedResult({required this.down, required this.up, this.ping, required this.at});
  final double down;
  final double up;
  final int? ping;
  final DateTime at;

  Map<String, dynamic> toJson() =>
      {'down': down, 'up': up, 'ping': ping, 'at': at.toIso8601String()};

  static SpeedResult? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['at'];
    return SpeedResult(
      down: (j['down'] as num?)?.toDouble() ?? 0,
      up: (j['up'] as num?)?.toDouble() ?? 0,
      ping: (j['ping'] as num?)?.toInt(),
      at: (at is String ? DateTime.tryParse(at) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class NetCheckService extends FeatureService {
  NetCheckService(super.app, super.features);

  static const sectionName = 'netcheck';

  /// Key under which results of a disconnected run are kept.
  static const directKey = 'direct';

  /// Automatic lookups wait this long after connect: the tunnel is up but
  /// the engine may still be picking a node.
  static const connectDelay = Duration(milliseconds: 1500);
  static const switchMinGap = Duration(seconds: 10);
  static const resumeStale = Duration(minutes: 10);

  /// Kept per node, newest first.
  static const maxResultsPerNode = 5;
  static const maxSamples = 60;

  // ---------------------------------------------------------------- ip

  IpInfo? realIp;
  IpInfo? exitIp;
  bool checking = false;

  /// The last lookup failed (the cached values, if any, are kept).
  bool error = false;

  /// Which side the running lookup measures (true = exit).
  bool checkingExit = false;

  DateTime? _lastRefresh;
  DateTime? _connectedAt;
  DateTime? _switchSeen;
  String? _nodeSeen;
  Timer? _connectTimer;
  bool _queued = false;
  bool _listening = false;
  bool _disposed = false;
  int _lookupGeneration = 0;

  // ---------------------------------------------------------------- speed

  SpeedPhase phase = SpeedPhase.idle;
  double currentBps = 0;
  final List<double> samples = [];
  SpeedResult? result;
  int? livePing;
  double? liveDown;
  bool speedFailed = false;
  SpeedTestException? speedFailure;
  SpeedPhase? failedPhase;

  String get speedErrorKey => speedFailure == null
      ? 'speed.failed'
      : 'speed.error.${speedFailure!.failure.name}';
  Map<String, String> get speedErrorArgs => {
    if (speedFailure?.statusCode != null) 'status': '${speedFailure!.statusCode}',
  };
  final Map<String, List<SpeedResult>> _speedResults = {};
  SpeedTest? _speed;

  bool get speedRunning =>
      phase == SpeedPhase.ping || phase == SpeedPhase.down || phase == SpeedPhase.up;

  /// Key of the node a speed test is attributed to right now.
  String get speedKey => (app.connected ? app.activeNode?.id : null) ?? directKey;

  /// Past results for [nodeId] (or the direct runs), newest first.
  List<SpeedResult> resultsFor(String? nodeId) =>
      List.unmodifiable(_speedResults[nodeId ?? directKey] ?? const []);

  // ---------------------------------------------------------------- verdict

  LeakVerdict get verdict {
    final r = realIp, e = exitIp;
    if (!app.connected || r == null || e == null) return LeakVerdict.unknown;
    if (e.ip == r.ip) return LeakVerdict.danger;
    final node = app.activeNode?.countryCode?.toUpperCase();
    if (e.countryCode != null &&
        e.countryCode == r.countryCode &&
        node != null &&
        node != e.countryCode) {
      return LeakVerdict.warning;
    }
    return LeakVerdict.ok;
  }

  /// iOS shows a system indicator for background network use, so idle
  /// lookups run only when the user asks. A connect is the user's action:
  /// the map needs the exit country, and that request goes through the
  /// tunnel. `defaultTargetPlatform` (not dart:io) so tests can override it.
  bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// Whether a lookup may start on its own while disconnected (load, resume).
  bool get autoAllowed => app.settings.ipCheck && !isIOS;

  /// Exit lookup after connect or a server change. Allowed on iOS.
  bool get exitProbeAllowed => app.settings.ipCheck;

  // ---------------------------------------------------------------- lifecycle

  @override
  Future<void> load() async {
    _lookupGeneration++;
    _nodeSeen = app.activeNode?.id;
    _restore(app.sectionOf(sectionName));
    if (!_listening) {
      _listening = true;
      app.addListener(_onApp);
    }
    _registerCommands();
    if (autoAllowed) unawaited(refresh());
  }

  void _restore(Map<String, dynamic>? j) {
    realIp = null;
    exitIp = null;
    result = null;
    _speedResults.clear();
    if (j == null) return;
    final r = j['realIp'], e = j['exitIp'];
    realIp = r is Map ? IpInfo.fromJson(r.cast<String, dynamic>()) : null;
    exitIp = e is Map ? IpInfo.fromJson(e.cast<String, dynamic>()) : null;
    result = SpeedResult.fromJson(j['lastSpeed']);
    _speedResults.clear();
    final all = j['speedResults'];
    if (all is Map) {
      all.forEach((k, v) {
        if (v is! List) return;
        final list = v.map(SpeedResult.fromJson).whereType<SpeedResult>().toList();
        if (list.isNotEmpty) _speedResults[k.toString()] = list.take(maxResultsPerNode).toList();
      });
    }
  }

  void _persist() {
    if (_disposed) return;
    app.setSection(sectionName, {
      'realIp': realIp?.toJson(),
      'exitIp': exitIp?.toJson(),
      'lastSpeed': result?.toJson(),
      'speedResults': {
        for (final e in _speedResults.entries) e.key: e.value.map((r) => r.toJson()).toList(),
      },
    });
  }

  void _registerCommands() {
    features.commands.registerAll([
      AppCommand(
        id: 'geo.refresh',
        titleKey: 'geo.refreshCmd',
        group: 'palette.g.tools',
        icon: Icons.public_rounded,
        run: (_) => refresh(manual: true),
      ),
      AppCommand(
        id: 'geo.copy',
        titleKey: 'geo.copyCmd',
        group: 'palette.g.tools',
        icon: Icons.copy_rounded,
        subtitle: (app.connected ? exitIp : realIp)?.ip,
        run: (_) => copyIp(),
      ),
      AppCommand(
        id: 'speed.run',
        titleKey: 'speed.cmd',
        group: 'palette.g.tools',
        icon: Icons.speed_rounded,
        run: (context) async {
          unawaited(runSpeedTest());
          await showSpeedTestSheet(context);
        },
      ),
    ]);
  }

  @override
  void onVpn(VpnStatus prev, VpnStatus next) {
    _lookupGeneration++;
    if (next != VpnStatus.connected && speedRunning) cancelSpeedTest();
    _connectTimer?.cancel();
    _connectTimer = null;
    if (next == VpnStatus.connected) {
      // A new session has a new exit; the stale one would read as a verdict.
      exitIp = null;
      error = false;
      _connectedAt = now();
      _switchSeen = null;
      _nodeSeen = app.activeNode?.id;
      _notify();
      if (exitProbeAllowed) _connectTimer = Timer(connectDelay, () => refresh());
      return;
    }
    // A session ended (a failed connect never had an exit to re-read).
    final hadSession = prev == VpnStatus.connected || prev == VpnStatus.stopping;
    final stoppedNow = next == VpnStatus.stopped || next == VpnStatus.error;
    if (hadSession && stoppedNow) {
      _connectedAt = null;
      if (speedRunning) cancelSpeedTest();
      // The tunnel is briefly down while a config change re-applies; the
      // real IP does not change in that window.
      if (autoAllowed && !app.applying) unawaited(refresh());
    }
  }

  @override
  void onResume() {
    if (!autoAllowed || app.connected || checking) return;
    final at = realIp?.at;
    if (at == null || now().difference(at) >= resumeStale) unawaited(refresh());
  }

  /// The engine switched nodes: the exit moved with it.
  void _onApp() {
    if (_disposed || !app.connected) return;
    final nodeId = app.activeNode?.id;
    final nodeChanged = nodeId != _nodeSeen;
    final at = app.proxyGroup?.lastSwitch?.at;
    if (!nodeChanged && (at == null || at == _switchSeen)) return;
    // Importing a server while disconnected leaves [_nodeSeen] stale, so the
    // first connected notification looks like a switch. [onVpn] owns that
    // lookup and waits until the tunnel can answer.
    if (_connectedAt == null) {
      _nodeSeen = nodeId;
      if (at != null) _switchSeen = at;
      return;
    }
    final first = _switchSeen == null;
    _switchSeen = at;
    _nodeSeen = nodeId;
    if (nodeChanged) {
      _lookupGeneration++;
      exitIp = null;
      error = false;
      cancelSpeedTest();
      _notify();
    }
    // The first status poll after connect reports a switch that the
    // connect lookup already covers.
    final since = _connectedAt == null ? null : now().difference(_connectedAt!);
    if (!nodeChanged && first && since != null && since < connectDelay * 2) return;
    final last = _lastRefresh;
    if (!exitProbeAllowed) return;
    _connectTimer?.cancel();
    final remaining = last == null ? Duration.zero : switchMinGap - now().difference(last);
    if (remaining > Duration.zero) {
      _connectTimer = Timer(remaining, () => refresh());
    } else {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connectTimer?.cancel();
    if (_listening) app.removeListener(_onApp);
    _speed?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------- lookup

  /// Client for the probe. Desktop in system-proxy mode has no TUN, so the
  /// request is pointed at the local mixed port to traverse the tunnel;
  /// everywhere else the injected factory is enough.
  http.Client _lookupClient() {
    final s = app.settings;
    if (networkAllowed && app.connected && isDesktop && s.captureMode == CaptureMode.systemProxy) {
      return IOClient(HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${s.mixedPort}');
    }
    return features.httpClient();
  }

  /// Looks the public IP up and files it as the real IP or the exit,
  /// depending on the tunnel state when the lookup started. Automatic
  /// callers respect the setting. Idle lookups also skip iOS; a connected
  /// lookup does not, because the map needs the exit country. A user tap
  /// ([manual]) only needs the panel to exist.
  Future<void> refresh({bool manual = false}) async {
    if (_disposed) return;
    final exit = app.connected;
    // Idle lookups stay off on iOS. A connected lookup is the exit probe the
    // map waits on, so it runs there too.
    if (!manual && !(exit ? exitProbeAllowed : autoAllowed)) return;
    if (checking) {
      _queued = true;
      return;
    }
    final generation = _lookupGeneration;
    final nodeId = app.activeNode?.id;
    checking = true;
    checkingExit = exit;
    _notify();
    IpInfo? info;
    try {
      info = await IpGeoClient(client: _lookupClient).lookup(at: now());
    } catch (_) {
      info = null;
    }
    if (_disposed) return;
    if (generation != _lookupGeneration || exit != app.connected ||
        (exit && nodeId != app.activeNode?.id)) {
      checking = false;
      final retry = _queued;
      _queued = false;
      _notify();
      if (retry) unawaited(refresh(manual: manual));
      return;
    }
    _lastRefresh = now();
    if (info != null) {
      if (exit) {
        exitIp = info;
      } else {
        realIp = info;
      }
      error = false;
    } else {
      error = true;
    }
    checking = false;
    _registerCommands();
    _persist();
    _notify();
    if (_queued) {
      _queued = false;
      unawaited(refresh(manual: manual));
    }
  }

  /// Copies the IP the user sees (exit while connected, else the real one).
  Future<void> copyIp() async {
    final ip = (app.connected ? exitIp : realIp)?.ip ?? (exitIp ?? realIp)?.ip;
    if (ip == null) return;
    await Clipboard.setData(ClipboardData(text: ip));
    app.notice('notice.copied', kind: NoticeKind.success);
  }

  // ---------------------------------------------------------------- speed

  /// Ping → download → upload, then the result is filed under the active
  /// node (or [directKey]). Progress is published through [phase],
  /// [currentBps] and [samples].
  Future<void> runSpeedTest() async {
    if (speedRunning || _disposed) return;
    final key = speedKey;
    final test = _speed = SpeedTest(client: _lookupClient);
    samples.clear();
    currentBps = 0;
    result = null;
    livePing = null;
    liveDown = null;
    speedFailed = false;
    speedFailure = null;
    failedPhase = null;
    phase = SpeedPhase.ping;
    _notify();

    final ping = await _ping();
    if (_ended(test)) return;
    livePing = ping;
    phase = SpeedPhase.down;
    samples.clear();
    currentBps = 0;
    _notify();

    final down = await _measure(test, test.download());
    if (_ended(test)) return;
    if (down == null) {
      _fail(test);
      return;
    }
    liveDown = down;
    phase = SpeedPhase.up;
    samples.clear();
    currentBps = 0;
    _notify();

    final up = await _measure(test, test.upload());
    if (_ended(test)) return;
    if (up == null) {
      _fail(test);
      return;
    }

    result = SpeedResult(down: down, up: up, ping: ping, at: now());
    final list = _speedResults.putIfAbsent(key, () => []);
    list.insert(0, result!);
    if (list.length > maxResultsPerNode) list.removeRange(maxResultsPerNode, list.length);
    phase = SpeedPhase.done;
    currentBps = down;
    _speed = null;
    _persist();
    _notify();
  }

  void cancelSpeedTest() {
    final t = _speed;
    if (t == null) return;
    t.cancel();
    speedFailure = null;
    failedPhase = null;
    _speed = null;
    phase = SpeedPhase.idle;
    currentBps = 0;
    samples.clear();
    result = null;
    livePing = null;
    liveDown = null;
    _notify();
  }

  /// True when [test] is no longer the run in progress (cancelled or the
  /// service went away).
  bool _ended(SpeedTest test) => _disposed || test.cancelled || !identical(_speed, test);

  void _fail(SpeedTest test) {
    if (!identical(_speed, test)) return;
    _speed = null;
    failedPhase = phase;
    phase = SpeedPhase.idle;
    speedFailed = true;
    currentBps = 0;
    _notify();
  }

  /// Consumes a progress stream into [samples]; returns the average
  /// throughput, or null when the stream failed.
  Future<double?> _measure(SpeedTest test, Stream<SpeedSample> stream) async {
    SpeedSample? last;
    try {
      await for (final s in stream) {
        // A reading that lands after cancel must not repopulate the chart.
        if (_ended(test)) return null;
        last = s;
        currentBps = s.bps;
        samples.add(s.bps);
        if (samples.length > maxSamples) samples.removeAt(0);
        _notify();
      }
    } catch (error) {
      if (!_ended(test)) speedFailure = SpeedTestException.from(error);
      return null;
    }
    if (last == null || last.bytes == 0) {
      if (!_ended(test)) speedFailure = const SpeedTestException(SpeedFailure.empty);
      return null;
    }
    return last.averageBps;
  }

  /// Clash delay of the active tag while connected, TCP connect time
  /// otherwise. Both open real sockets, so tests (network off) skip it.
  Future<int?> _ping() async {
    if (!networkAllowed) return null;
    final node = app.activeNode;
    if (app.connected) {
      final clash = app.clash;
      final tag = node == null ? null : app.tagOf(node.id);
      if (clash == null || tag == null) return null;
      return clash.delay(tag, url: app.settings.probeUrl, timeoutMs: 5000);
    }
    if (node == null) return null;
    return tcpPing(node.server, node.port);
  }
}
