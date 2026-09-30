// P2-connect-motion: route line, status pulse, rolling numerals, feedback
// grammar and the session summary.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/features/motion/feedback.dart';
import 'package:melsi/features/motion/rolling_number.dart';
import 'package:melsi/features/motion/route_line.dart';
import 'package:melsi/features/motion/session_summary.dart';
import 'package:melsi/features/motion/status_pulse.dart';
import 'package:melsi/services/clash_api.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/ui/theme/theme.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

/// A tunnel whose start always fails: the app lands in [VpnStatus.error].
class _ErrorVpn extends FakeVpn {
  @override
  Future<void> start(BuiltConfig cfg, {required String name}) async {
    throw StateError('handshake failed');
  }
}

/// A tunnel that reports "connecting" and then waits for [finish] — for
/// watching what a long connect does.
class _ManualVpn extends FakeVpn {
  final _ctrl = StreamController<VpnState>.broadcast();
  VpnState _state = VpnState.stopped;

  void _set(VpnState s) {
    _state = s;
    _ctrl.add(s);
  }

  @override
  Stream<VpnState> get states => _ctrl.stream;

  @override
  Future<void> start(BuiltConfig cfg, {required String name}) async {
    started = cfg;
    starts++;
    _set(const VpnState(VpnStatus.connecting));
  }

  void finish() => _set(const VpnState(VpnStatus.connected));

  @override
  Future<void> stop() async {
    _set(const VpnState(VpnStatus.stopping));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    _set(VpnState.stopped);
  }

  @override
  Future<VpnState> currentState() async => _state;
}

/// Pumps [total] in [step]s so timers and spring completions interleave the
/// way they do on a device (one long pump delivers a single frame).
Future<void> pumpFor(WidgetTester tester, Duration total,
    {Duration step = const Duration(milliseconds: 50)}) async {
  var left = total;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    await tester.pump(d);
    left -= d;
  }
}

RouteLineState _line(WidgetTester tester) => tester.state<RouteLineState>(find.byType(RouteLine));

Future<AppState> _bootWithServer(WidgetTester tester, {FakeVpn? vpn, Size? size}) async {
  final (state, _) = await bootApp(tester, vpn: vpn, size: size ?? const Size(390, 844));
  await state.importText(kSampleVless);
  await tester.pump();
  return state;
}

/// Hosts a bare widget with the app theme (for the number / feedback tests).
Widget _host(Widget child, {bool reduce = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('RouteLine', () {
    testWidgets('sweeps while connecting, completes into a tick when connected', (tester) async {
      final vpn = FakeVpn(delay: const Duration(milliseconds: 400));
      final state = await _bootWithServer(tester, vpn: vpn);
      final line = _line(tester);
      expect(line.debugPhase, RoutePhase.idle);
      expect(line.debugLineOpacity * line.debugTrackOpacity, 0);

      state.connect();
      // The status lands in this frame; the sweep's first tick is the next.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(line.debugPhase, RoutePhase.connecting);
      expect(line.debugProgress, greaterThan(0));
      expect(line.debugProgress, lessThan(1));
      expect(line.debugSweeping, isTrue);

      await tester.pump(const Duration(milliseconds: 500));
      expect(line.debugPhase, RoutePhase.connected);
      expect(line.debugSweeping, isFalse);

      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('Подключено'), findsOneWidget);
      expect(line.debugTrackOpacity, lessThan(0.2));
      expect(line.debugProgress, closeTo(1, 0.05), reason: 'the line has drawn');

      // Hold, then dissolve into the end tick.
      await pumpFor(tester, const Duration(seconds: 2));
      expect(line.debugTickOpacity, 1);
      expect(line.debugSegmentOpacity, 0);

      state.disconnect();
      await pumpFor(tester, const Duration(seconds: 1));
      expect(line.debugPhase, RoutePhase.idle);
      expect(line.debugTickOpacity, 0);
      await shutdownApp(tester, state);
    });

    testWidgets('snaps to danger and fades on error, nothing leaks', (tester) async {
      final state = await _bootWithServer(tester, vpn: _ErrorVpn());
      final line = _line(tester);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.vpnState.status, VpnStatus.error);
      expect(line.debugPhase, RoutePhase.error);
      expect(line.debugShakeCount, 1);
      expect(line.debugLineOpacity, greaterThan(0));

      await pumpFor(tester, const Duration(milliseconds: 500));
      expect(line.debugLineOpacity, 0, reason: 'line gone after 500ms');
      expect(find.text('Ошибка'), findsOneWidget);

      // Let the error toast go before the leak check.
      await pumpFor(tester, const Duration(seconds: 5), step: const Duration(milliseconds: 500));
      await shutdownApp(tester, state);
    });

    testWidgets('sweep is capped at three cycles; cancel springs it back', (tester) async {
      final vpn = _ManualVpn();
      final state = await _bootWithServer(tester, vpn: vpn);
      final line = _line(tester);
      state.connect();
      await pumpFor(tester, const Duration(seconds: 4));
      expect(line.debugPhase, RoutePhase.connecting);
      expect(line.debugSweeping, isTrue, reason: 'mid-way through the third cycle');
      // 3 × 2.2 s plus a frame per leg.
      await pumpFor(tester, const Duration(seconds: 4));
      expect(line.debugPhase, RoutePhase.connecting);
      expect(line.debugSweeping, isFalse, reason: 'capped: never loops forever');
      expect(line.debugSegmentOpacity, closeTo(0.6, 0.01), reason: 'rests at 60%');
      expect(line.debugProgress, 0, reason: 'a cycle ends where it began');

      state.disconnect();
      await tester.pump(const Duration(milliseconds: 50));
      expect(line.debugPhase, RoutePhase.idle);
      await pumpFor(tester, const Duration(seconds: 1));
      expect(line.debugTrackOpacity, 0);
      expect(line.debugSegmentOpacity, 0);
      await shutdownApp(tester, state);
    });

    testWidgets('a connect that completes late still draws from the sweep', (tester) async {
      final vpn = _ManualVpn();
      final state = await _bootWithServer(tester, vpn: vpn);
      final line = _line(tester);
      state.connect();
      await pumpFor(tester, const Duration(milliseconds: 700));
      final at = line.debugProgress;
      expect(at, greaterThan(0.3));
      vpn.finish();
      await tester.pump(const Duration(milliseconds: 20));
      expect(line.debugPhase, RoutePhase.connected);
      await tester.pump(const Duration(milliseconds: 20));
      expect(line.debugProgress, greaterThan(0.2), reason: 'starts from the sweep position');
      await pumpFor(tester, const Duration(seconds: 2));
      expect(line.debugTickOpacity, 1);
      await shutdownApp(tester, state);
    });

    testWidgets('reduced motion: cross-fades, no travelling segment', (tester) async {
      reducedMotion(tester);
      final vpn = FakeVpn(delay: const Duration(milliseconds: 400));
      final state = await _bootWithServer(tester, vpn: vpn);
      final line = _line(tester);
      state.connect();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(line.debugPhase, RoutePhase.connecting);
      expect(line.debugSweeping, isFalse);
      expect(line.debugProgress, 0);
      expect(line.debugSegmentOpacity, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(line.debugTrackOpacity, greaterThan(0.5));

      await pumpFor(tester, const Duration(milliseconds: 600));
      expect(line.debugPhase, RoutePhase.connected);
      expect(line.debugTickOpacity, 1);
      expect(line.debugTrackOpacity, 0);
      await shutdownApp(tester, state);
    });
  });

  group('StatusPulse', () {
    testWidgets('breathes only while connected', (tester) async {
      final state = await _bootWithServer(tester);
      Iterable<StatusPulseState> pulses() =>
          tester.stateList<StatusPulseState>(find.byType(StatusPulse));
      expect(pulses().any((p) => p.debugPulseActive), isFalse);

      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);
      expect(state.connected, isTrue);
      expect(pulses().where((p) => p.debugPulseActive), hasLength(1));

      state.disconnect();
      await settle(tester);
      expect(pulses().any((p) => p.debugPulseActive), isFalse);
      await shutdownApp(tester, state);
    });

    testWidgets('reduced motion: solid dot, no controller', (tester) async {
      reducedMotion(tester);
      final state = await _bootWithServer(tester);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);
      expect(state.connected, isTrue);
      final pulses = tester.stateList<StatusPulseState>(find.byType(StatusPulse));
      expect(pulses.any((p) => p.debugPulseActive), isFalse);
      await shutdownApp(tester, state);
    });
  });

  group('MonoNumber', () {
    List<RollingDigitState> cells(WidgetTester tester) =>
        tester.stateList<RollingDigitState>(find.byType(RollingDigit)).toList();

    Widget number(String text, {bool reduce = false}) =>
        _host(MonoNumber(text, style: const TextStyle(fontSize: 22)), reduce: reduce);

    testWidgets("'12' → '13' rolls the last cell up one", (tester) async {
      await tester.pumpWidget(number('12'));
      expect(cells(tester).map((c) => c.debugValue), [1, 2]);

      await tester.pumpWidget(number('13'));
      await tester.pump(const Duration(milliseconds: 50));
      final mid = cells(tester)[1].debugValue;
      expect(mid, greaterThan(2));
      expect(mid, lessThan(3));
      expect(cells(tester)[0].debugValue, 1, reason: 'untouched cell stays put');

      await pumpFor(tester, const Duration(milliseconds: 600));
      expect(cells(tester)[1].debugValue, 3);
      expect(cells(tester).any((c) => c.debugAnimating), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets("'9' → '0' goes the short way (+1)", (tester) async {
      await tester.pumpWidget(number('9'));
      await tester.pumpWidget(number('0'));
      await tester.pump(const Duration(milliseconds: 50));
      final v = cells(tester).single.debugValue;
      expect(v, greaterThan(9));
      expect(v, lessThan(10));
      await pumpFor(tester, const Duration(milliseconds: 600));
      expect(cells(tester).single.debugValue, 0, reason: 'rests back inside 0…9');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('mixed text keeps words findable and the shape stable', (tester) async {
      await tester.pumpWidget(number('Сессия 00:12:34'));
      expect(find.textContaining('Сессия'), findsOneWidget);
      expect(cells(tester), hasLength(6));
      // The first real value after a dash enters from below.
      await tester.pumpWidget(number('—'));
      expect(cells(tester), isEmpty);
      await tester.pumpWidget(number('42'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(cells(tester)[0].debugValue, lessThan(4));
      expect(cells(tester)[0].debugValue, greaterThan(3));
      await pumpFor(tester, const Duration(milliseconds: 700));
      expect(cells(tester).map((c) => c.debugValue), [4, 2]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reduced motion: fixed cells, nothing animates', (tester) async {
      await tester.pumpWidget(number('12', reduce: true));
      await tester.pumpWidget(number('13', reduce: true));
      await tester.pump();
      expect(cells(tester).map((c) => c.debugValue), [1, 3]);
      expect(cells(tester).any((c) => c.debugAnimating), isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('Feedback', () {
    testWidgets('Shake is one-shot and dies', (tester) async {
      Widget shaker(int trigger) => _host(Shake(trigger: trigger, child: const Text('x')));
      await tester.pumpWidget(shaker(0));
      final s = tester.state<ShakeState>(find.byType(Shake));
      expect(s.debugAnimating, isFalse);
      await tester.pumpWidget(shaker(1));
      await tester.pump(const Duration(milliseconds: 40));
      expect(s.debugOffset.abs(), greaterThan(1));
      expect(s.debugOffset.abs(), lessThanOrEqualTo(4.0001));
      await pumpFor(tester, const Duration(milliseconds: 1500));
      expect(s.debugAnimating, isFalse);
      expect(s.debugOffset, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('Shake under reduced motion does not move', (tester) async {
      Widget shaker(int trigger) =>
          _host(Shake(trigger: trigger, child: const Text('x')), reduce: true);
      await tester.pumpWidget(shaker(0));
      await tester.pumpWidget(shaker(1));
      await tester.pump(const Duration(milliseconds: 40));
      final s = tester.state<ShakeState>(find.byType(Shake));
      expect(s.debugAnimating, isFalse);
      expect(s.debugOffset, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('CheckDraw draws after a beat; static when reduced', (tester) async {
      await tester.pumpWidget(_host(const CheckDraw()));
      final c = tester.state<CheckDrawState>(find.byType(CheckDraw));
      await tester.pump(const Duration(milliseconds: 30));
      expect(c.debugProgress, 0, reason: 'still in the 60ms beat');
      await tester.pump(const Duration(milliseconds: 150));
      expect(c.debugProgress, greaterThan(0));
      expect(c.debugProgress, lessThan(1));
      await pumpFor(tester, const Duration(milliseconds: 300));
      expect(c.debugProgress, 1);
      expect(c.debugAnimating, isFalse);

      await tester.pumpWidget(_host(const CheckDraw(), reduce: true));
      final r = tester.state<CheckDrawState>(find.byType(CheckDraw));
      expect(r.debugProgress, 1);
      expect(r.debugAnimating, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    test('Haptics are no-ops off phones', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // No binding, no channel: a real call would throw. These must not.
      Haptics.tap();
      Haptics.select();
      Haptics.success();
      Haptics.error();
    });
  });

  group('SessionSummaryNote', () {
    Future<void> session(WidgetTester tester, AppState state, Duration length) async {
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.connected, isTrue);
      state.traffic.push(120000, 3500000);
      state.traffic.setTotals(
          ConnectionsSnapshot(uploadTotal: 38 << 20, downloadTotal: 1932735283, count: 4));
      state.connectedAt = DateTime.now().subtract(length);
      state.disconnect();
      await settle(tester);
    }

    testWidgets('a session of 31s leaves a summary for six seconds', (tester) async {
      // The test font is an em square per glyph — twice as wide as a real
      // one — so the full form only fits a phone at half scale here.
      tester.platformDispatcher.textScaleFactorTestValue = 0.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final state = await _bootWithServer(tester);
      await session(tester, state, const Duration(seconds: 31));
      expect(find.text('Не подключено'), findsOneWidget);
      expect(find.textContaining('Сессия'), findsOneWidget);
      final note = tester.state<SessionSummaryNoteState>(find.byType(SessionSummaryNote));
      expect(note.debugSummary?.down, 1932735283);
      expect(note.debugSummary?.up, 38 << 20);
      expect(note.debugSummary?.length.inSeconds, inInclusiveRange(31, 32));
      // "Сессия 00:00:31 · ↓ 1.8 ГБ · ↑ 38 МБ": digits are cells, the rest text.
      expect(find.textContaining('ГБ'), findsOneWidget);
      expect(find.textContaining('МБ'), findsOneWidget);
      expect(find.byType(RollingDigit), findsWidgets);

      await pumpFor(tester, const Duration(seconds: 7), step: const Duration(milliseconds: 250));
      expect(find.textContaining('Сессия'), findsNothing);
      await shutdownApp(tester, state);
    });

    testWidgets('a 10s session says nothing', (tester) async {
      final state = await _bootWithServer(tester);
      await session(tester, state, const Duration(seconds: 10));
      expect(find.textContaining('Сессия'), findsNothing);
      await shutdownApp(tester, state);
    });

    testWidgets('a new connect hides it at once', (tester) async {
      final state = await _bootWithServer(tester);
      await session(tester, state, const Duration(minutes: 2));
      expect(find.textContaining('Сессия'), findsOneWidget);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);
      expect(find.textContaining('Сессия'), findsNothing);
      await shutdownApp(tester, state);
    });

    testWidgets('narrow phones (and large text) get the short form', (tester) async {
      final state = await _bootWithServer(tester, size: const Size(320, 640));
      expect(find.byType(SessionSummaryNote), findsOneWidget);
      await session(tester, state, const Duration(seconds: 45));
      expect(find.textContaining('Сессия'), findsOneWidget);
      expect(find.textContaining('ГБ'), findsNothing);
      expect(tester.takeException(), isNull, reason: 'no overflow at 320px');
      await shutdownApp(tester, state);
    });
  });
}
