import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/store.dart';

import 'fakes.dart';
import 'harness.dart';

Future<void> connect(WidgetTester tester, AppState state) async {
  await state.importText(kSampleVless);
  state.connect();
  await tester.pump(const Duration(milliseconds: 100));
  await settle(tester);
  expect(state.connected, isTrue);
}

void main() {
  testWidgets('timer and screen privacy are accessible from command search', (
    tester,
  ) async {
    final (state, features) = await bootApp(tester);
    final privacy = features.commands.byId('tools.hideAddresses')!;
    expect(privacy.isOn!(), isFalse);
    await privacy.run(
      tester.element(find.byKey(const ValueKey('dashboard-timer'))),
    );
    expect(state.hideAddresses, isTrue);
    final timer = features.commands.byId('tools.disconnectTimer')!;
    unawaited(
      timer.run(tester.element(find.byKey(const ValueKey('dashboard-timer')))),
    );
    await settle(tester);
    expect(find.text('Отключить через'), findsOneWidget);
    expect(find.text('Сначала подключитесь к серверу'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('timer-15'))));
    await settle(tester);
    expect(state.disconnectAt, isNull);
    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await settle(tester);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('timer disconnects at expiry and manual stop clears it', (
    tester,
  ) async {
    final (state, features) = await bootApp(tester);
    await connect(tester, state);
    state.scheduleDisconnect(const Duration(seconds: 3));
    expect(state.disconnectAt, isNotNull);
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(state.vpnState.status, VpnStatus.stopped);
    expect(state.disconnectAt, isNull);
    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    state.scheduleDisconnect(const Duration(minutes: 30));
    state.disconnect();
    await settle(tester);
    expect(state.disconnectAt, isNull);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('resuming after the deadline disconnects immediately', (tester) async {
    final (state, features) = await bootApp(tester);
    await connect(tester, state);
    state.scheduleDisconnect(const Duration(minutes: 30));
    state.disconnectAt = DateTime.now().subtract(const Duration(seconds: 1));
    state.onResume();
    await settle(tester);
    expect(state.vpnState.status, VpnStatus.stopped);
    expect(state.disconnectAt, isNull);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets(
    'timer can be replaced and cancelled without dropping the tunnel',
    (tester) async {
      final (state, features) = await bootApp(tester);
      await connect(tester, state);
      state.scheduleDisconnect(const Duration(seconds: 2));
      state.scheduleDisconnect(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 3));
      expect(state.connected, isTrue);
      state.scheduleDisconnect(null);
      await tester.pump(const Duration(seconds: 5));
      expect(state.connected, isTrue);
      state.disconnect();
      await settle(tester);
      state.scheduleDisconnect(const Duration(minutes: 15));
      expect(state.disconnectAt, isNull);
      await shutdownApp(tester, state, features: features);
    },
  );

  testWidgets('configuration reapply preserves the deadline', (tester) async {
    final (state, features) = await bootApp(tester);
    await connect(tester, state);
    state.scheduleDisconnect(const Duration(minutes: 30));
    final deadline = state.disconnectAt;
    state.updateRouting((routing) => routing.blockAds = !routing.blockAds);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(state.connected, isTrue);
    expect(state.disconnectAt, deadline);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('expiry during configuration restart prevents a new connection', (
    tester,
  ) async {
    final vpn = FakeVpn();
    final (state, features) = await bootApp(tester, vpn: vpn);
    await connect(tester, state);
    vpn.delay = const Duration(seconds: 2);
    state.scheduleDisconnect(const Duration(seconds: 2));
    state.updateRouting((routing) => routing.blockAds = !routing.blockAds);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(state.applying, isTrue);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(state.vpnState.status, VpnStatus.stopped);
    expect(vpn.starts, 1);
    expect(state.disconnectAt, isNull);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('home opens timer presets and schedules the selected duration', (
    tester,
  ) async {
    final (state, features) = await bootApp(tester);
    await connect(tester, state);
    final timer = find.byKey(const ValueKey('dashboard-timer'));
    await tester.ensureVisible(timer);
    await settle(tester);
    await tester.tap(timer);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('timer-30')));
    await settle(tester);
    expect(state.disconnectAt, isNotNull);
    expect(
      state.disconnectAt!.difference(DateTime.now()).inMinutes,
      inInclusiveRange(29, 30),
    );
    expect(find.byKey(const ValueKey('timer-30')), findsNothing);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('favorite shortcut selects a server without starting VPN', (
    tester,
  ) async {
    final vpn = FakeVpn();
    final (state, features) = await bootApp(tester, vpn: vpn);
    await state.importText(kSampleVless);
    await state.importText(
      kSampleVless.replaceAll('nl1.example.com', 'de1.example.com'),
    );
    final second = state.nodes.last.id;
    state.toggleFavourite(second);
    await settle(tester);
    final favorite = find.byKey(ValueKey('home-favorite-$second'));
    await tester.ensureVisible(favorite);
    await settle(tester);
    await tester.tap(favorite);
    await settle(tester);
    expect(state.selectedNodeId, second);
    expect(vpn.starts, 0);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('address privacy is saved and does not change VPN config', (
    tester,
  ) async {
    final (state, features) = await bootApp(
      tester,
      data: {
        'sections': {
          'netcheck': {
            'realIp': {
              'ip': '203.0.113.7',
              'countryCode': 'NL',
              'org': 'Demo ISP',
              'at': DateTime.now().toIso8601String(),
            },
          },
        },
      },
    );
    await connect(tester, state);
    final privacy = find.byKey(const ValueKey('geo-privacy'));
    await tester.ensureVisible(privacy);
    await settle(tester);
    expect(
      find.textContaining('203.0.113.7', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(privacy);
    await settle(tester);
    expect(state.hideAddresses, isTrue);
    expect(
      find.textContaining('IP скрыт', findRichText: true),
      findsNWidgets(2),
    );
    expect(
      find.textContaining('203.0.113.7', findRichText: true),
      findsNothing,
    );
    expect(find.textContaining('Demo ISP', findRichText: true), findsNothing);
    expect(state.needsReconnect, isFalse);
    final restored = AppState(
      store: MemoryStateStore(state.toJson()),
      vpn: FakeVpn(),
      enableNetwork: false,
    );
    await restored.load();
    await tester.pump();
    expect(restored.hideAddresses, isTrue);
    restored.dispose();
    await shutdownApp(tester, state, features: features);
  });

  for (final size in [const Size(360, 740), const Size(1280, 820)]) {
    testWidgets('home fits $size at large text scale with reduced motion', (
      tester,
    ) async {
      reducedMotion(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (state, features) = await bootApp(tester, size: size);
      await connect(tester, state);
      final details = find.byKey(const ValueKey('dashboard-details'));
      await tester.ensureVisible(details);
      await settle(tester);
      await tester.tap(details);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await shutdownApp(tester, state, features: features);
    });
  }
}
