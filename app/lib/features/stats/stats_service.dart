import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;

import '../../services/vpn_controller.dart';
import '../../state/commands.dart';
import '../../state/feature_service.dart';
import 'stats_models.dart';
import 'stats_screen.dart' show openStatsScreen;

/// Session history and daily traffic totals.
///
/// A record opens when the tunnel reports `connected` and closes when it
/// reports `stopped` / `error` — unless the app is in the middle of a
/// seamless re-apply (`app.applying`), where the tunnel restarts under the
/// hood but the user sees one session: then the record stays open and the
/// byte counters simply start again from zero.
///
/// While a record is open a 5-second sampler reads the traffic monitor's
/// totals. Bytes are counted as *deltas* against the last seen totals, so a
/// counter that dropped (the tunnel restarted) starts a new baseline and
/// never produces a negative delta. Every sample folds the new bytes and
/// seconds into the day they belong to, splitting at local midnight, so a
/// session that runs overnight lands on both days and the Home card is live.
///
/// Storage is `sections.stats` of the app state file: the 200 newest
/// sessions and the last 90 days. A running session is checkpointed every
/// 30 seconds as if it had ended then, so a crash loses at most half a
/// minute.
class StatsService extends FeatureService {
  StatsService(super.app, super.features);

  static const String sectionName = 'stats';
  static const String commandId = 'stats.open';
  static const int maxSessions = 200;
  static const int maxDays = 90;
  static const Duration sampleEvery = Duration(seconds: 5);
  static const Duration checkpointEvery = Duration(seconds: 30);

  /// Closed sessions, newest first.
  final List<SessionRecord> _closed = [];
  final Map<String, DayTotal> _days = {};
  SessionRecord? _current;

  // Traffic-monitor totals at the last sample: the baseline deltas are
  // measured against.
  int _baseUp = 0;
  int _baseDown = 0;

  // How much of the open record is already folded into day totals, and up
  // to which instant its seconds are.
  int _foldedUp = 0;
  int _foldedDown = 0;
  DateTime? _foldedAt;

  DateTime? _lastSwitchAt;

  /// The monitor's `lastUpTotal/lastDownTotal` were already counted for this
  /// stop (it resets its counters once per stop; we must count them once).
  bool _finalCounted = false;

  Timer? _sampler;
  int _ticks = 0;
  bool _listening = false;

  /// Range (days) the Stats screen showed last; persisted with the section.
  int preferredRange = 30;

  // ------------------------------------------------------------ lifecycle

  @override
  Future<void> load() async {
    _closed.clear();
    _days.clear();
    final j = app.sectionOf(sectionName);
    if (j != null) _read(j);
    if (!_listening) {
      // The app notifies before it runs its status hooks, and it is the only
      // place `applying` changes: listening to it catches a re-apply that
      // ended without a tunnel (the record must close then).
      app.addListener(_sync);
      _listening = true;
    }
    features.commands.register(AppCommand(
      id: commandId,
      titleKey: 'stats.openCmd',
      group: 'palette.g.tools',
      icon: Icons.bar_chart_rounded,
      run: (context) async => openStatsScreen(context),
    ));
    _sync();
    notifyListeners();
  }

  @override
  void onVpn(VpnStatus prev, VpnStatus next) => _sync();

  @override
  void onResume() => _sync();

  @override
  void dispose() {
    _stopSampler();
    if (_listening) {
      app.removeListener(_sync);
      _listening = false;
    }
    super.dispose();
  }

  // ------------------------------------------------------------ queries

  /// The running session (if any) followed by the closed ones, newest first.
  List<SessionRecord> get sessions =>
      List.unmodifiable([?_current, ..._closed]);

  /// The session that is running right now.
  SessionRecord? get current => _current;

  bool get hasData =>
      _current != null || _closed.isNotEmpty || _days.values.any((d) => !d.isEmpty);

  /// Today's total including the running session up to this instant.
  DayTotal get todayTotal => _dayWithTail(DayTotal.keyOf(now()));

  /// The last [n] days ending today, oldest first, zero days filled in.
  List<DayTotal> lastDays(int n) {
    final today = now();
    return [
      for (var i = n - 1; i >= 0; i--)
        _dayWithTail(DayTotal.keyOf(DateTime(today.year, today.month, today.day - i))),
    ];
  }

  /// Sum of the last [days] days ([DayTotal.day] is the first day of the
  /// range).
  DayTotal totals(int days) {
    final list = lastDays(days);
    var up = 0, down = 0, seconds = 0;
    for (final d in list) {
      up += d.up;
      down += d.down;
      seconds += d.seconds;
    }
    return DayTotal(day: list.first.day, up: up, down: down, seconds: seconds);
  }

  /// Whether the 5-second sampler is running (only while a session is open).
  @visibleForTesting
  bool get sampling => _sampler != null;

  // ------------------------------------------------------------ commands

  /// Drops every closed session and all day totals. A running session keeps
  /// its own bytes and is re-folded into today so the card stays consistent.
  void clear() {
    _closed.clear();
    _days.clear();
    final rec = _current;
    if (rec != null) {
      _foldInterval(rec.start, now(), rec.up, rec.down);
      _foldedUp = rec.up;
      _foldedDown = rec.down;
      _foldedAt = now();
    }
    _save();
    notifyListeners();
  }

  /// Removes one closed session and takes its traffic out of the day totals
  /// (a deleted session "did not happen").
  void deleteSession(String id) {
    final i = _closed.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final rec = _closed.removeAt(i);
    _foldInterval(rec.start, rec.end ?? rec.start, -rec.up, -rec.down, sign: -1);
    _save();
    notifyListeners();
  }

  /// Writes the section now (the sampler does it every 30 s on its own).
  void checkpoint() => _save();

  /// Remembers the range the Stats screen shows (7 / 30 / 90 days).
  void setRange(int days) {
    if (days == preferredRange || !const [7, 30, 90].contains(days)) return;
    preferredRange = days;
    _save();
  }

  // ------------------------------------------------------------ recording

  /// Reconciles the record with the tunnel status. Idempotent: it runs from
  /// the app listener, the status hook and resume alike.
  void _sync() {
    final status = app.vpnState.status;
    final rec = _current;
    if (rec == null) {
      if (status == VpnStatus.connected) _open();
      return;
    }
    switch (status) {
      case VpnStatus.connected:
        // Back after a seamless restart: the counters run again from zero
        // (the baseline was reset when the final totals were counted).
        _finalCounted = false;
      case VpnStatus.stopped || VpnStatus.error:
        if (!_finalCounted) {
          // The monitor reset itself before telling anyone; its "last"
          // totals are the session's final reading.
          _account(app.traffic.lastUpTotal, app.traffic.lastDownTotal);
          _baseUp = 0;
          _baseDown = 0;
          _finalCounted = true;
        }
        if (!app.applying) _close(now());
      case VpnStatus.connecting || VpnStatus.stopping:
        break;
    }
  }

  void _open() {
    final t = now();
    final node = app.activeNode;
    _current = SessionRecord(
      id: _newId(t),
      start: t,
      nodeId: node?.id,
      nodeName: node?.name ?? '',
      countryCode: node?.countryCode,
    );
    _baseUp = app.traffic.upTotal;
    _baseDown = app.traffic.downTotal;
    _foldedUp = 0;
    _foldedDown = 0;
    _foldedAt = t;
    _lastSwitchAt = app.proxyGroup?.lastSwitch?.at;
    _finalCounted = false;
    _ticks = 0;
    _sampler?.cancel();
    _sampler = Timer.periodic(sampleEvery, (_) => _tick());
    notifyListeners();
  }

  void _tick() {
    final rec = _current;
    if (rec == null) {
      _stopSampler();
      return;
    }
    _account(app.traffic.upTotal, app.traffic.downTotal);
    _countSwitch(rec);
    _refreshNode(rec);
    _fold(rec, now());
    _ticks++;
    if (_ticks % (checkpointEvery.inSeconds ~/ sampleEvery.inSeconds) == 0) _save();
    notifyListeners();
  }

  void _close(DateTime at) {
    final rec = _current!;
    rec.end = at;
    _fold(rec, at);
    _closed.insert(0, rec);
    _current = null;
    _stopSampler();
    _trim();
    _save();
    notifyListeners();
  }

  void _stopSampler() {
    _sampler?.cancel();
    _sampler = null;
  }

  /// Adds the growth of the monitor's totals since the last sample. A total
  /// below the baseline means the counters restarted: everything since then
  /// counts, and nothing is ever negative.
  void _account(int up, int down) {
    final rec = _current;
    if (rec == null) return;
    rec.up += up >= _baseUp ? up - _baseUp : up;
    rec.down += down >= _baseDown ? down - _baseDown : down;
    _baseUp = up;
    _baseDown = down;
  }

  /// A `last_switch` newer than the one already seen (and inside this
  /// session) is one more server switch.
  void _countSwitch(SessionRecord rec) {
    final at = app.proxyGroup?.lastSwitch?.at;
    if (at == null || at == _lastSwitchAt) return;
    if (at.isAfter(rec.start)) rec.switches++;
    _lastSwitchAt = at;
  }

  /// The engine's real pick becomes known after its first poll; until the
  /// session has switched, the snapshot follows it.
  void _refreshNode(SessionRecord rec) {
    if (rec.switches > 0) return;
    final n = app.activeNode;
    if (n == null || n.id == rec.nodeId) return;
    rec.nodeId = n.id;
    rec.nodeName = n.name;
    rec.countryCode = n.countryCode;
  }

  /// Folds what the record gained since the last fold into the day totals.
  void _fold(SessionRecord rec, DateTime to) {
    _foldInterval(_foldedAt ?? rec.start, to, rec.up - _foldedUp, rec.down - _foldedDown);
    _foldedAt = to;
    _foldedUp = rec.up;
    _foldedDown = rec.down;
  }

  /// Distributes [up]/[down] bytes and the seconds of [from]..[to] over the
  /// local calendar days the interval touches, proportionally to the time
  /// spent in each. [sign] is −1 when taking a session out again.
  void _foldInterval(DateTime from, DateTime to, int up, int down, {int sign = 1}) {
    if (!to.isAfter(from)) {
      _addDay(DayTotal.keyOf(to), up, down, 0);
      return;
    }
    final totalMs = to.difference(from).inMilliseconds;
    var cursor = from;
    var upLeft = up, downLeft = down;
    while (cursor.isBefore(to)) {
      final midnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final segEnd = midnight.isBefore(to) ? midnight : to;
      final ms = segEnd.difference(cursor).inMilliseconds;
      final last = !segEnd.isBefore(to);
      final segUp = last ? upLeft : (up * ms / totalMs).round();
      final segDown = last ? downLeft : (down * ms / totalMs).round();
      upLeft -= segUp;
      downLeft -= segDown;
      _addDay(DayTotal.keyOf(cursor), segUp, segDown, sign * (ms / 1000).round());
      cursor = segEnd;
    }
  }

  void _addDay(String key, int up, int down, int seconds) {
    if (up == 0 && down == 0 && seconds == 0) return;
    _days[key] = (_days[key] ?? DayTotal(day: key)).plus(up: up, down: down, seconds: seconds);
  }

  /// The stored day plus, for today, what the running session gained since
  /// its last sample: the live traffic delta and the seconds elapsed.
  DayTotal _dayWithTail(String key) {
    final stored = _days[key] ?? DayTotal(day: key);
    final rec = _current;
    if (rec == null || key != DayTotal.keyOf(now())) return stored;
    final tr = app.traffic;
    final liveUp = tr.upTotal >= _baseUp ? tr.upTotal - _baseUp : tr.upTotal;
    final liveDown = tr.downTotal >= _baseDown ? tr.downTotal - _baseDown : tr.downTotal;
    final secs = now().difference(_foldedAt ?? rec.start).inSeconds;
    return stored.plus(
      up: rec.up - _foldedUp + liveUp,
      down: rec.down - _foldedDown + liveDown,
      seconds: math.max(0, secs),
    );
  }

  // ------------------------------------------------------------ storage

  void _trim() {
    _closed.sort((a, b) => b.start.compareTo(a.start));
    if (_closed.length > maxSessions) _closed.removeRange(maxSessions, _closed.length);
    final today = now();
    final cutoff = DayTotal.keyOf(DateTime(today.year, today.month, today.day - (maxDays - 1)));
    _days.removeWhere((k, _) => k.compareTo(cutoff) < 0);
    if (_days.length > maxDays) {
      final keys = _days.keys.toList()..sort();
      for (final k in keys.take(_days.length - maxDays)) {
        _days.remove(k);
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'range': preferredRange,
        'sessions': [
          if (_current != null) _current!.closedAt(now()).toJson(),
          for (final s in _closed) s.toJson(),
        ],
        'days': [for (final k in _days.keys.toList()..sort()) _days[k]!.toJson()],
      };

  void _read(Map<String, dynamic> j) {
    for (final e in j['sessions'] as List? ?? const []) {
      if (e is! Map) continue;
      final s = SessionRecord.fromJson(e.cast<String, dynamic>());
      if (s == null) continue;
      // A session that was running when the app died stays as its last
      // checkpoint left it: closed there.
      s.end ??= s.start;
      _closed.add(s);
    }
    for (final e in j['days'] as List? ?? const []) {
      if (e is! Map) continue;
      final d = DayTotal.fromJson(e.cast<String, dynamic>());
      if (d != null && !d.isEmpty) _days[d.day] = d;
    }
    final range = j['range'];
    if (range is num && const [7, 30, 90].contains(range.toInt())) preferredRange = range.toInt();
    _trim();
  }

  void _save() => app.setSection(sectionName, toJson());

  static final _rng = math.Random();

  static String _newId(DateTime t) =>
      '${t.millisecondsSinceEpoch.toRadixString(36)}-${_rng.nextInt(0xFFFFFF).toRadixString(36)}';
}
