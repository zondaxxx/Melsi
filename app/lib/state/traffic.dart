import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/clash_api.dart';

/// Live speed + session totals, fed by the Clash API `/traffic` stream.
/// Kept separate from AppState so the per-second ticks only rebuild the
/// widgets that show them.
class TrafficMonitor extends ChangeNotifier {
  static const historyLength = 60;

  final List<double> upHistory = List.filled(historyLength, 0, growable: true);
  final List<double> downHistory = List.filled(historyLength, 0, growable: true);

  int up = 0;
  int down = 0;
  int upTotal = 0;
  int downTotal = 0;
  int connections = 0;

  /// Totals of the session that just ended (captured by [stop] with
  /// `reset: true`, before the counters are zeroed).
  int lastUpTotal = 0;
  int lastDownTotal = 0;
  DateTime? lastStoppedAt;

  StreamSubscription<TrafficSample>? _sub;
  ClashApi? _api;
  Timer? _retry;
  bool _running = false;

  void start(ClashApi api) {
    stop(reset: true);
    _api = api;
    _running = true;
    _listen();
  }

  void _listen() {
    if (!_running || _api == null) return;
    _sub = _api!.traffic().listen(
      (s) => push(s.up, s.down),
      onError: (Object _) => _scheduleRetry(),
      onDone: _scheduleRetry,
      cancelOnError: true,
    );
  }

  void _scheduleRetry() {
    _sub = null;
    if (!_running) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), _listen);
  }

  /// Adds one per-second sample (also used by tests / demo).
  void push(int upBps, int downBps) {
    up = upBps;
    down = downBps;
    upHistory
      ..removeAt(0)
      ..add(upBps.toDouble());
    downHistory
      ..removeAt(0)
      ..add(downBps.toDouble());
    notifyListeners();
  }

  void setTotals(ConnectionsSnapshot s) {
    upTotal = s.uploadTotal;
    downTotal = s.downloadTotal;
    connections = s.count;
    notifyListeners();
  }

  void stop({bool reset = false}) {
    _running = false;
    _retry?.cancel();
    _sub?.cancel();
    _sub = null;
    up = 0;
    down = 0;
    if (reset) {
      lastUpTotal = upTotal;
      lastDownTotal = downTotal;
      lastStoppedAt = DateTime.now();
      upTotal = 0;
      downTotal = 0;
      connections = 0;
      for (var i = 0; i < historyLength; i++) {
        upHistory[i] = 0;
        downHistory[i] = 0;
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
