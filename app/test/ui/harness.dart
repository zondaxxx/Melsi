// Shared widget-test harness: every test boots the app the same way.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/main.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';

import 'fakes.dart';

/// Boots [MelsiApp] on a phone (default) or the given [size] with Russian
/// strings, a fake VPN and offline features. Returns the state and the
/// features so tests can drive them directly.
Future<(AppState, Features)> bootApp(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  FakeVpn? vpn,
  PlatformKind? platform,
  Map<String, dynamic>? data,
  Features? features,
  bool launchMoment = false,
  Duration firstPump = const Duration(milliseconds: 500),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final state = testState(data: data, vpn: vpn, platform: platform);
  await state.load();
  // Russian unless the seed data chose a language (load() replaces settings).
  state.settings.locale ??= 'ru';
  final f = features ?? testFeatures(state);
  await f.init();
  await tester.pumpWidget(MelsiApp(state: state, features: f, launchMoment: launchMoment));
  await tester.pump(firstPump);
  return (state, f);
}

/// Advances enough frames for route/sheet transitions to finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Unmount and let pending timers settle; fails if anything still wants a
/// frame (a leaked animation).
Future<void> shutdownApp(WidgetTester tester, AppState state, {Features? features}) async {
  if (state.vpnState.status != VpnStatus.stopped) {
    state.disconnect();
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
  features?.dispose();
  expect(tester.binding.hasScheduledFrame, isFalse, reason: 'an animation is still running');
}

/// Turns on the platform's reduced-motion flag for this test.
void reducedMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Silences haptics / clipboard platform calls that would otherwise log
/// "MissingPluginException" noise (they are no-ops in tests anyway).
void stubPlatformChannels(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
}
