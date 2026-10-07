import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/ui/theme/theme.dart';
import 'package:melsi/ui/widgets/route_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<RouteFieldState> show(
    WidgetTester tester, {
    required VpnStatus status,
    bool exitReady = false,
    bool exitFailed = false,
    bool exitSkipped = false,
    String exitCode = 'JP',
    double exitLat = 35.7,
    double exitLon = 139.7,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: RouteField(
        status: status,
        originCode: 'DE',
        originLat: 52.5,
        originLon: 13.4,
        exitCode: exitReady ? exitCode : null,
        exitLat: exitReady ? exitLat : null,
        exitLon: exitReady ? exitLon : null,
        exitReady: exitReady,
        exitFailed: exitFailed,
        exitSkipped: exitSkipped,
      ),
    ));
    await tester.pump();
    return tester.state<RouteFieldState>(find.byType(RouteField));
  }

  Future<void> gone(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  }

  testWidgets('holds at the origin until the exit IP is known, then flies', (tester) async {
    var state = await show(tester, status: VpnStatus.stopped);
    expect(state.debugCue, MapCue.idle);

    state = await show(tester, status: VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.debugCue, MapCue.approach);
    await tester.pump(const Duration(milliseconds: 800));
    expect(state.debugCue, MapCue.waiting);

    state = await show(tester, status: VpnStatus.connected);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(state.debugCue, MapCue.waiting);

    state = await show(tester, status: VpnStatus.connected, exitReady: true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.debugCue, MapCue.travel);
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(state.debugCue, MapCue.settled);

    await gone(tester);
  });

  testWidgets('a failed exit lookup returns home and spreads red', (tester) async {
    final state = await show(tester, status: VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(state.debugCue, MapCue.waiting);

    await show(tester, status: VpnStatus.connected, exitFailed: true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.debugCue, MapCue.retreat);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(state.debugCue, MapCue.failed);

    await gone(tester);
  });

  testWidgets('giving up on the exit IP returns home in red', (tester) async {
    final state = await show(tester, status: VpnStatus.connected);
    expect(state.debugCue, MapCue.waiting);
    await tester.pump(const Duration(seconds: 20));
    expect(state.debugCue, MapCue.retreat);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(state.debugCue, MapCue.failed);
    await gone(tester);
  });

  testWidgets('resume with a known exit does not replay the approach', (tester) async {
    final state = await show(tester, status: VpnStatus.connected, exitReady: true);
    expect(state.debugCue, MapCue.settled);
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugCue, MapCue.settled);
    await gone(tester);
  });

  testWidgets('a late exit lookup recovers after the map timed out', (tester) async {
    final state = await show(tester, status: VpnStatus.connected);
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(milliseconds: 1600));
    expect(state.debugCue, MapCue.failed);

    await show(tester, status: VpnStatus.connected, exitReady: true);
    expect(state.debugCue, MapCue.travel);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 800));
    expect(state.debugCue, MapCue.settled);
    await gone(tester);
  });

  testWidgets('retry during the error animation starts a fresh approach', (tester) async {
    final state = await show(tester, status: VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 200));
    await show(tester, status: VpnStatus.error);
    expect(state.debugCue, MapCue.retreat);

    await show(tester, status: VpnStatus.connecting);
    expect(state.debugCue, MapCue.approach);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(state.debugCue, MapCue.waiting);
    await gone(tester);
  });

  testWidgets('reduced motion settles when connection skips the connecting frame', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = await show(tester, status: VpnStatus.stopped);
    await show(tester, status: VpnStatus.connected, exitReady: true);
    expect(state.debugCue, MapCue.settled);
    await gone(tester);
  });

  testWidgets('a server change waits, then flies, without restarting the approach', (tester) async {
    var state = await show(tester, status: VpnStatus.connected, exitReady: true);
    expect(state.debugCue, MapCue.settled);

    state = await show(tester, status: VpnStatus.connected);
    expect(state.debugCue, MapCue.waiting);
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.debugCue, MapCue.waiting);

    state = await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
      exitCode: 'NL',
      exitLat: 52.3,
      exitLon: 4.9,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.debugCue, MapCue.travel);
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(state.debugCue, MapCue.settled);
    await gone(tester);
  });

  testWidgets('disconnect during the approach can connect again from the start', (tester) async {
    var state = await show(tester, status: VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.debugCue, MapCue.approach);

    state = await show(tester, status: VpnStatus.stopped);
    expect(state.debugCue, MapCue.idle);

    state = await show(tester, status: VpnStatus.connecting);
    expect(state.debugCue, MapCue.approach);
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.debugCue, MapCue.approach);
    await gone(tester);
  });

  testWidgets('reduced motion still waits for the exit', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    var state = await show(tester, status: VpnStatus.connecting);
    expect(state.debugCue, MapCue.waiting);

    state = await show(tester, status: VpnStatus.connected, exitReady: true);
    expect(state.debugCue, MapCue.settled);

    state = await show(tester, status: VpnStatus.error);
    expect(state.debugCue, MapCue.failed);
    await gone(tester);
  });
}
