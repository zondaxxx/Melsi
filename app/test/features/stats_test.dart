import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/features/stats/day_bars.dart';
import 'package:melsi/features/stats/stats_models.dart';
import 'package:melsi/features/stats/stats_screen.dart';
import 'package:melsi/features/stats/stats_widgets.dart';
import 'package:melsi/l10n/l10n.dart';
import 'package:melsi/services/clash_api.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';
import 'package:melsi/state/store.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

const _mb = 1024 * 1024;

/// A state + features pair without the widget tree, for service tests.
/// (`testWidgets` still provides the fake clock the sampler runs on.)
Future<(AppState, Features, FakeClock)> _service(WidgetTester tester,
    {DateTime? at, Map<String, dynamic>? data}) async {
  final clock = FakeClock(at);
  final state = testState(data: data);
  await state.load();
  final f = testFeatures(state, clock: clock.call);
  await f.init();
  await tester.pumpWidget(const SizedBox());
  return (state, f, clock);
}

Future<void> _connect(WidgetTester tester, AppState state) async {
  if (state.nodes.isEmpty) await state.importText(kSampleVless);
  state.connect();
  await tester.pump(const Duration(milliseconds: 100));
  expect(state.connected, isTrue, reason: '${state.vpnState}');
}

Future<void> _disconnect(WidgetTester tester, AppState state) async {
  state.disconnect();
  await tester.pump(const Duration(milliseconds: 100));
  expect(state.connected, isFalse);
}

void _totals(AppState state, int up, int down) =>
    state.traffic.setTotals(ConnectionsSnapshot(uploadTotal: up, downloadTotal: down, count: 2));

Map<String, dynamic> _savedSection(AppState state) =>
    ((state.store as MemoryStateStore).data!['sections'] as Map)['stats'] as Map<String, dynamic>;

void main() {
  testWidgets('a session records its bytes and folds into today', (tester) async {
    final (state, f, clock) = await _service(tester, at: DateTime(2026, 10, 1, 12));
    final stats = f.stats;
    expect(f.commands.byId(StatsService.commandId), isNotNull);
    expect(stats.sessions, isEmpty);
    expect(stats.hasData, isFalse);

    await _connect(tester, state);
    expect(stats.current, isNotNull);
    expect(stats.sampling, isTrue);
    expect(stats.current!.nodeId, state.nodes.single.id);
    expect(stats.current!.countryCode, 'NL');

    _totals(state, 1 * _mb, 5 * _mb);
    clock.advance(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    // Live: the card's number climbs before the session ends.
    expect(stats.todayTotal.down, 5 * _mb);

    await _disconnect(tester, state);
    expect(stats.current, isNull);
    expect(stats.sampling, isFalse, reason: 'sampler stops with the session');

    final s = stats.sessions.single;
    expect(s.isOpen, isFalse);
    expect(s.up, 1 * _mb);
    expect(s.down, 5 * _mb);
    expect(s.switches, 0);
    expect(s.duration, const Duration(seconds: 6));
    expect(s.nodeName, contains('Netherlands'));

    final today = stats.todayTotal;
    expect(today.day, '2026-10-01');
    expect(today.up, 1 * _mb);
    expect(today.down, 5 * _mb);
    expect(today.seconds, 6);
    expect(stats.lastDays(7).last, today);
    expect(stats.totals(30).down, 5 * _mb);

    final saved = _savedSection(state);
    expect(saved['v'], 1);
    expect(saved['sessions'], hasLength(1));
    expect((saved['days'] as List).single['day'], '2026-10-01');
    f.dispose();
  });

  testWidgets('a session across midnight is split into two days', (tester) async {
    final (state, f, clock) = await _service(tester, at: DateTime(2026, 10, 1, 23, 59));
    final stats = f.stats;
    await _connect(tester, state);

    _totals(state, 1 * _mb, 5 * _mb);
    clock.advance(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 5)); // 23:59:30 — all in day 1

    _totals(state, 2 * _mb, 10 * _mb);
    clock.advance(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 5)); // 00:00:30 — 30 s either side

    await _disconnect(tester, state);
    expect(stats.sessions.single.up, 2 * _mb);
    expect(stats.sessions.single.down, 10 * _mb);

    final days = stats.lastDays(2);
    expect(days.map((d) => d.day), ['2026-10-01', '2026-10-02']);
    expect(days[0].seconds, 60);
    expect(days[1].seconds, 30);
    // The second sample's bytes are shared by time spent on each side.
    expect(days[0].up, (1.5 * _mb).round());
    expect(days[0].down, (7.5 * _mb).round());
    expect(days[1].up, (0.5 * _mb).round());
    expect(days[1].down, (2.5 * _mb).round());
    expect(days[0].up + days[1].up, 2 * _mb);
    expect(days[0].down + days[1].down, 10 * _mb);
    f.dispose();
  });

  testWidgets('a seamless re-apply keeps one record and never counts backwards', (tester) async {
    final vpn = FakeVpn();
    final clock = FakeClock(DateTime(2026, 10, 1, 12));
    final state = testState(vpn: vpn);
    await state.load();
    final f = testFeatures(state, clock: clock.call);
    await f.init();
    await tester.pumpWidget(const SizedBox());
    final stats = f.stats;

    await _connect(tester, state);
    _totals(state, 3 * _mb, 4 * _mb);
    await tester.pump(const Duration(seconds: 5));
    expect(stats.current!.up, 3 * _mb);

    // A counter that dropped is a restarted tunnel: the new reading counts
    // from zero, nothing is subtracted.
    _totals(state, 1 * _mb, 1 * _mb);
    await tester.pump(const Duration(seconds: 5));
    expect(stats.current!.up, 4 * _mb);
    expect(stats.current!.down, 5 * _mb);

    // A config edit restarts the tunnel under a "connected" display.
    state.updateRouting((r) => r.blockAds = !r.blockAds);
    await tester.pump(const Duration(milliseconds: 1300));
    await settle(tester);
    expect(vpn.starts, 2, reason: 'one restart');
    expect(state.connected, isTrue);
    expect(stats.sessions, hasLength(1), reason: 'still the same session');
    expect(stats.current, isNotNull);
    expect(stats.current!.up, 4 * _mb, reason: 'the final reading before the restart counted once');

    _totals(state, 2 * _mb, 2 * _mb); // fresh counters after the restart
    await tester.pump(const Duration(seconds: 5));
    expect(stats.current!.up, 6 * _mb);
    expect(stats.current!.down, 7 * _mb);

    await tester.pump(const Duration(seconds: 2)); // apply phase settles
    await _disconnect(tester, state);
    expect(stats.sessions, hasLength(1));
    expect(stats.sessions.single.up, 6 * _mb);
    expect(stats.sessions.single.down, 7 * _mb);
    expect(stats.todayTotal.up, 6 * _mb);
    f.dispose();
  });

  testWidgets('keeps the 200 newest sessions, 90 days, and round-trips through JSON', (tester) async {
    final base = DateTime(2026, 9, 1);
    final sessions = [
      for (var i = 0; i < 250; i++)
        SessionRecord(
          id: 's$i',
          start: base.add(Duration(hours: i)),
          end: base.add(Duration(hours: i, minutes: 30)),
          nodeName: 'node $i',
          countryCode: 'DE',
          up: i,
          down: i * 2,
          switches: i % 3,
        ).toJson(),
    ];
    final days = [
      for (var i = 0; i < 120; i++)
        DayTotal(day: DayTotal.keyOf(DateTime(2026, 10, 1 - i)), up: 1, down: 2, seconds: 3).toJson(),
    ];
    final data = {
      'sections': {
        'stats': {'v': 1, 'range': 90, 'sessions': sessions, 'days': days},
      },
    };
    final (state, f, _) = await _service(tester, data: data);
    final stats = f.stats;
    expect(stats.sessions, hasLength(StatsService.maxSessions));
    expect(stats.sessions.first.id, 's249', reason: 'newest first');
    expect(stats.sessions.last.id, 's50');
    expect(stats.preferredRange, 90);
    final kept = stats.lastDays(120);
    expect(kept.where((d) => !d.isEmpty), hasLength(StatsService.maxDays));
    expect(kept.take(30).every((d) => d.isEmpty), isTrue, reason: 'days older than 90 are gone');

    stats.checkpoint();
    final json = jsonDecode(jsonEncode((state.store as MemoryStateStore).data)) as Map<String, dynamic>;
    expect((json['sections']['stats']['sessions'] as List), hasLength(200));

    final state2 = testState(data: json);
    await state2.load();
    final f2 = testFeatures(state2);
    await f2.init();
    expect(f2.stats.sessions.map((s) => s.toJson()).toList(),
        stats.sessions.map((s) => s.toJson()).toList());
    expect(f2.stats.lastDays(120), kept);
    expect(f2.stats.preferredRange, 90);
    f.dispose();
    f2.dispose();
  });

  testWidgets('deleting a session takes it out of the day totals; clear wipes everything',
      (tester) async {
    final (state, f, clock) = await _service(tester, at: DateTime(2026, 10, 1, 12));
    final stats = f.stats;
    for (var i = 0; i < 2; i++) {
      await _connect(tester, state);
      _totals(state, 1 * _mb, 2 * _mb);
      clock.advance(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 5));
      await _disconnect(tester, state);
    }
    expect(stats.sessions, hasLength(2));
    expect(stats.todayTotal.down, 4 * _mb);
    expect(stats.todayTotal.seconds, 20);

    stats.deleteSession(stats.sessions.last.id);
    expect(stats.sessions, hasLength(1));
    expect(stats.todayTotal.down, 2 * _mb);
    expect(stats.todayTotal.up, 1 * _mb);
    expect(stats.todayTotal.seconds, 10);

    stats.clear();
    expect(stats.sessions, isEmpty);
    expect(stats.hasData, isFalse);
    expect(stats.todayTotal.isEmpty, isTrue);
    expect(_savedSection(state)['sessions'], isEmpty);
    f.dispose();
  });

  testWidgets('Home card appears with the session; Stats opens from Settings and lists it',
      (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester);
    expect(find.text('СЕГОДНЯ'), findsNothing, reason: 'nothing to show yet');

    await _connect(tester, state);
    _totals(state, 1 * _mb, 5 * _mb);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    expect(find.text('СЕГОДНЯ'), findsOneWidget);
    expect(find.text('5.0 МБ'), findsWidgets);
    expect(find.byKey(const ValueKey('stats-today-open')), findsOneWidget);

    await _disconnect(tester, state);
    await settle(tester);
    expect(find.text('СЕГОДНЯ'), findsNothing, reason: 'telemetry hides with the session');

    await tester.tap(find.text('Настройки'));
    await settle(tester);
    final row = find.byKey(const ValueKey('stats-row'));
    await tester.scrollUntilVisible(row, 250, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    await tester.tap(row);
    await settle(tester);

    expect(find.text('СЕССИИ'), findsOneWidget);
    expect(find.text('7 дней'), findsOneWidget);
    expect(find.text('30 дней'), findsOneWidget);
    expect(find.textContaining('Netherlands Reality'), findsOneWidget);
    // The harness clock stands still, so the session is zero-length.
    expect(find.text('00:00:00'), findsOneWidget, reason: 'session length in mono');
    expect(find.byKey(const ValueKey('stats-clear')), findsOneWidget);

    await tester.tap(find.text('90 дней'));
    await settle(tester);
    expect(f.stats.preferredRange, 90);

    // Scrub the chart: a caption with the date appears.
    final chart = find.byType(DayBars);
    final rect = tester.getRect(chart);
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pump();
    expect(find.text('1 окт'), findsOneWidget);

    Navigator.of(tester.element(find.byType(StatsScreen))).pop();
    await settle(tester);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('on wide layouts Stats is a sheet; empty state and reduced motion', (tester) async {
    reducedMotion(tester);
    final (state, f) = await bootApp(tester, size: const Size(1280, 800));
    await tester.tap(find.text('Настройки'));
    await settle(tester);
    final row = find.byKey(const ValueKey('stats-row'));
    await tester.scrollUntilVisible(row, 250, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    await tester.tap(row);
    await settle(tester);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Пока нет сессий'), findsOneWidget);
    expect(find.text('нет данных'), findsOneWidget);
    expect(find.byKey(const ValueKey('stats-clear')), findsNothing);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);
    expect(find.byType(Dialog), findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  test('metric time stays short at every magnitude', () {
    const ru = L10n('ru');
    const en = L10n('en');
    expect(formatStatsTime(0, ru), '0 мин');
    expect(formatStatsTime(59 * 60 + 59, ru), '59 мин');
    expect(formatStatsTime(5 * 3600 + 20 * 60, ru), '5:20 ч');
    expect(formatStatsTime(5 * 3600 + 5 * 60, en), '5:05 h');
    expect(formatStatsTime(312 * 3600 + 40 * 60, ru), '312 ч');
    expect(formatStatsDate(DateTime(2026, 10, 1), ru), '1 окт');
    expect(formatStatsDate(DateTime(2026, 10, 1), en), 'Oct 1');
  });

  test('models round-trip and tolerate junk', () {
    final s = SessionRecord(
      id: 'a',
      start: DateTime(2026, 10, 1, 12),
      end: DateTime(2026, 10, 1, 13),
      nodeId: 'n',
      nodeName: 'Node',
      countryCode: 'DE',
      up: 1,
      down: 2,
      switches: 3,
    );
    expect(SessionRecord.fromJson(s.toJson())!.toJson(), s.toJson());
    expect(SessionRecord.fromJson({'id': '', 'start': 1}), isNull);
    expect(SessionRecord.fromJson({'id': 'x', 'start': 'later'}), isNull);
    expect(SessionRecord.fromJson({'id': 'x', 'start': 5, 'up': 'many'})!.up, 0);
    const d = DayTotal(day: '2026-10-01', up: 1, down: 2, seconds: 3);
    expect(DayTotal.fromJson(d.toJson()), d);
    expect(DayTotal.fromJson({'day': 'yesterday'}), isNull);
    expect(d.plus(up: -5).up, 0, reason: 'never negative');
    expect(DayTotal.keyOf(DateTime(2026, 1, 9, 23, 59)), '2026-01-09');
    expect(DayTotal.dateOf('2026-01-09'), DateTime(2026, 1, 9));
  });
}
