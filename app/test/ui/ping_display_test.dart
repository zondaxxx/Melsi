import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/state/app_scope.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/store.dart';
import 'package:melsi/ui/theme/theme.dart';
import 'package:melsi/ui/widgets/common.dart';

import 'fakes.dart';
import 'harness.dart';

Future<void> showChip(
  WidgetTester tester,
  AppState state, {
  int? ms = 48,
  bool failed = false,
  bool testing = false,
  VoidCallback? onTest,
}) => tester.pumpWidget(
  AppScope(
    state: state,
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: LatencyChip(
            ms: ms,
            failed: failed,
            testing: testing,
            onTest: onTest,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test(
    'old settings retain numeric ping and future formats fall back safely',
    () {
      for (final json in [
        <String, dynamic>{},
        {'pingDisplay': 'future'},
      ]) {
        final settings = AppSettings.fromJson(json);
        expect(settings.showPing, isTrue);
        expect(settings.pingDisplay, PingDisplay.number);
      }
    },
  );

  test('visibility and every ping format survive persistence', () {
    for (final format in PingDisplay.values) {
      for (final visible in [false, true]) {
        final before = AppSettings(showPing: visible, pingDisplay: format);
        final after = AppSettings.fromJson(before.toJson());
        expect(after.showPing, visible);
        expect(after.pingDisplay, format);
      }
    }
  });

  testWidgets('numeric, indicator and combined formats share one live policy', (
    tester,
  ) async {
    final state = testState();
    addTearDown(state.dispose);
    await showChip(tester, state);
    expect(find.text('48\u00a0мс'), findsOneWidget);
    expect(find.byKey(const ValueKey('ping-indicator-3')), findsNothing);

    state.updateSettings(
      (s) => s.pingDisplay = PingDisplay.indicator,
      affectsConfig: false,
    );
    await settle(tester);
    expect(find.text('48\u00a0мс'), findsNothing);
    expect(find.byKey(const ValueKey('ping-indicator-3')), findsOneWidget);
    expect(find.bySemanticsLabel('Пинг: 48\u00a0мс'), findsOneWidget);

    state.updateSettings(
      (s) => s.pingDisplay = PingDisplay.both,
      affectsConfig: false,
    );
    await settle(tester);
    expect(find.text('48\u00a0мс'), findsOneWidget);
    expect(find.byKey(const ValueKey('ping-indicator-3')), findsOneWidget);

    state.updateSettings((s) => s.showPing = false, affectsConfig: false);
    await settle(tester);
    expect(find.text('48\u00a0мс'), findsNothing);
    expect(find.byKey(const ValueKey('ping-indicator-3')), findsNothing);
    expect(find.bySemanticsLabel('Пинг: 48\u00a0мс'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('indicator distinguishes quality, unknown, failure and testing', (
    tester,
  ) async {
    final state = testState();
    state.settings.pingDisplay = PingDisplay.indicator;
    addTearDown(state.dispose);
    var taps = 0;
    for (final (ms, bars) in [(48, 3), (100, 2), (250, 1), (null, 0)]) {
      await showChip(tester, state, ms: ms, onTest: () => taps++);
      await settle(tester);
      final indicator = find.byKey(ValueKey('ping-indicator-$bars'));
      expect(indicator, findsOneWidget);
      await tester.tap(indicator);
      await tester.pump();
    }
    expect(taps, 4);
    expect(find.bySemanticsLabel('Пинг: Не проверен'), findsOneWidget);

    await showChip(tester, state, ms: null, failed: true, onTest: () => taps++);
    await settle(tester);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('Пинг: Нет ответа'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(taps, 5);

    await showChip(tester, state, testing: true, onTest: () => taps++);
    await settle(tester);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('Пинг: Проверка…'), findsOneWidget);
    await tester.tap(find.byType(CupertinoActivityIndicator));
    expect(taps, 5);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'settings persist immediately without restarting the active VPN',
    (tester) async {
      final vpn = FakeVpn();
      final (state, features) = await bootApp(tester, vpn: vpn);
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);
      expect(state.connected, isTrue);
      final connectedAt = state.connectedAt;
      await tester.tap(find.text('Настройки'));
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Индикатор'), 240);
      await settle(tester);
      await tester.ensureVisible(find.text('Индикатор'));
      await settle(tester);
      await tester.tap(find.text('Индикатор'));
      await settle(tester);
      expect(state.settings.pingDisplay, PingDisplay.indicator);
      await tester.ensureVisible(find.text('Показывать пинг'));
      await settle(tester);
      await tester.tap(find.text('Показывать пинг'));
      await settle(tester);
      expect(state.settings.showPing, isFalse);
      expect(find.text('Индикатор'), findsNothing);
      final saved = (state.store as MemoryStateStore).data!['settings'];
      expect(saved['showPing'], isFalse);
      expect(saved['pingDisplay'], 'indicator');
      expect(state.connectedAt, connectedAt);
      expect(state.needsReconnect, isFalse);
      expect(vpn.starts, 1);
      await tester.ensureVisible(find.text('Показывать пинг'));
      await settle(tester);
      await tester.tap(find.text('Показывать пинг'));
      await settle(tester);
      expect(state.settings.pingDisplay, PingDisplay.indicator);
      await shutdownApp(tester, state, features: features);
    },
  );

  testWidgets('Home follows ping visibility and format on a small phone', (
    tester,
  ) async {
    reducedMotion(tester);
    final (state, features) = await bootApp(tester, size: const Size(320, 568));
    await state.importText(kSampleVless);
    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);
    final node = state.activeNode!;
    state.latencies[node.id] = Latency(1234, viaUrl: true, at: DateTime.now());
    state.updateSettings(
      (s) => s.pingDisplay = PingDisplay.both,
      affectsConfig: false,
    );
    await settle(tester);
    final ping = find.text('ПИНГ');
    await tester.ensureVisible(ping);
    await settle(tester);
    expect(ping, findsOneWidget);
    expect(find.text('1234\u00a0мс'), findsOneWidget);
    expect(find.byKey(const ValueKey('ping-indicator-1')), findsOneWidget);
    expect(tester.takeException(), isNull);

    state.updateSettings((s) => s.showPing = false, affectsConfig: false);
    await settle(tester);
    expect(find.text('ПИНГ'), findsNothing);
    expect(find.text('ДЖИТТЕР'), findsOneWidget);
    expect(find.text('ПОТЕРИ'), findsOneWidget);
    expect(state.latencyOf(node), 1234);
    expect(state.connected, isTrue);
    await shutdownApp(tester, state, features: features);
  });
}
