import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/ui/theme/theme.dart';
import 'package:melsi/ui/widgets/route_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sceneKey = GlobalKey();
  // Load the shared asset before any fake-async widget zone caches its Future.
  late WorldMapData world;
  setUpAll(() async {
    world = await WorldMapData.load();
  });

  Future<RouteFieldState> show(
    WidgetTester tester, {
    required VpnStatus status,
    bool exitReady = false,
    bool exitFailed = false,
    bool exitSkipped = false,
    String? exitCode = 'JP',
    double? exitLat = 35.7,
    double? exitLon = 139.7,
    bool tickerEnabled = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: TickerMode(
          enabled: tickerEnabled,
          child: RepaintBoundary(
            key: sceneKey,
            child: RouteField(
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
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<RouteFieldState>(find.byType(RouteField));
  }

  Future<void> gone(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  }

  testWidgets('holds at the origin until the exit IP is known, then flies', (
    tester,
  ) async {
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

  testWidgets('a failed exit lookup returns home and spreads red', (
    tester,
  ) async {
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

  testWidgets('resume with a known exit does not replay the approach', (
    tester,
  ) async {
    final state = await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
    );
    expect(state.debugCue, MapCue.settled);
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugCue, MapCue.settled);
    await gone(tester);
  });

  testWidgets('a late exit lookup recovers after the map timed out', (
    tester,
  ) async {
    final state = await show(tester, status: VpnStatus.connected);
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(milliseconds: 1600));
    expect(state.debugCue, MapCue.failed);

    await show(tester, status: VpnStatus.connected, exitReady: true);
    expect(state.debugCue, MapCue.travel);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(state.debugCue, MapCue.settled);
    await gone(tester);
  });

  testWidgets('retry during the error animation starts a fresh approach', (
    tester,
  ) async {
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

  testWidgets(
    'reduced motion settles when connection skips the connecting frame',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final state = await show(tester, status: VpnStatus.stopped);
      await show(tester, status: VpnStatus.connected, exitReady: true);
      expect(state.debugCue, MapCue.settled);
      await gone(tester);
    },
  );

  testWidgets(
    'a server change waits, then flies, without restarting the approach',
    (tester) async {
      var state = await show(
        tester,
        status: VpnStatus.connected,
        exitReady: true,
      );
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
    },
  );

  testWidgets(
    'disconnect during the approach can connect again from the start',
    (tester) async {
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
    },
  );

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

  testWidgets('retry takes over the current camera without a jump', (
    tester,
  ) async {
    final state = await show(tester, status: VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 450));
    await show(tester, status: VpnStatus.error);
    await tester.pump(const Duration(milliseconds: 300));
    final zoom = state.debugZoom!;
    final focus = state.debugFocus!;
    await show(tester, status: VpnStatus.connecting);
    expect(state.debugZoom, closeTo(zoom, .00001));
    expect((state.debugFocus! - focus).distance, lessThan(.00001));
    await gone(tester);
  });

  testWidgets(
    'reduced motion keeps the world still while waiting and on error',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final state = await show(tester, status: VpnStatus.connecting);
      final focus = state.debugFocus;
      expect(state.debugZoom, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(state.debugFocus, focus);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await show(tester, status: VpnStatus.error);
      expect(state.debugZoom, 1);
      expect(state.debugFocus, focus);
      await gone(tester);
    },
  );

  testWidgets('enabling reduced motion stops an in-flight camera', (
    tester,
  ) async {
    final state = await show(tester, status: VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 450));
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    expect(state.debugZoom, 1);
    expect(state.debugCue, MapCue.waiting);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await gone(tester);
  });

  testWidgets('arrival settles on the actual exit and keeps its camera fixed', (
    tester,
  ) async {
    final state = await show(tester, status: VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 1000));
    await show(tester, status: VpnStatus.connected, exitReady: true);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(state.debugCue, MapCue.settled);
    final expected = Offset(WorldMapData.xOf(139.7), WorldMapData.yOf(35.7));
    expect((state.debugFocus! - expected).distance, lessThan(.00001));
    expect(state.debugZoom, inInclusiveRange(2.4, 5.6));
    final zoom = state.debugZoom;
    final focus = state.debugFocus;
    await tester.pump(const Duration(milliseconds: 900));
    expect(state.debugZoom, zoom);
    expect(state.debugFocus, focus);
    expect(state.debugPulseAnimating, isTrue);
    await gone(tester);
  });

  testWidgets(
    'an existing connection repeats the soft wave after a complete cycle',
    (tester) async {
      final state = await show(
        tester,
        status: VpnStatus.connected,
        exitReady: true,
      );
      expect(state.debugCue, MapCue.settled);
      expect(state.debugPulseAnimating, isTrue);
      await tester.pump(const Duration(milliseconds: 3700));
      final beforeWrap = state.debugPulse;
      expect(beforeWrap, greaterThan(.7));
      await tester.pump(const Duration(milliseconds: 900));
      final afterWrap = state.debugPulse;
      expect(afterWrap, lessThan(beforeWrap));
      await tester.pump(const Duration(milliseconds: 700));
      expect(state.debugPulse, greaterThan(afterWrap));
      expect(state.debugCue, MapCue.settled);
      await gone(tester);
    },
  );

  testWidgets('a renewed exit lookup preserves the last country framing', (
    tester,
  ) async {
    final state = await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
    );
    final zoom = state.debugZoom;
    final focus = state.debugFocus;
    await show(tester, status: VpnStatus.connected);
    expect(state.debugCue, MapCue.waiting);
    expect(state.debugZoom, zoom);
    expect(state.debugFocus, focus);
    await tester.pump(const Duration(milliseconds: 800));
    expect(state.debugZoom, zoom);
    expect(state.debugFocus, focus);
    await gone(tester);
  });

  testWidgets('coordinate-only exits still get a focused connected wave', (
    tester,
  ) async {
    final state = await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
      exitCode: null,
    );
    final expected = Offset(WorldMapData.xOf(139.7), WorldMapData.yOf(35.7));
    expect(state.debugCue, MapCue.settled);
    expect((state.debugFocus! - expected).distance, lessThan(.00001));
    expect(state.debugZoom, greaterThan(1));
    expect(state.debugPulseAnimating, isTrue);
    await gone(tester);
  });

  testWidgets(
    'skipping exit lookup keeps the world still without a connected wave',
    (tester) async {
      final state = await show(
        tester,
        status: VpnStatus.connected,
        exitSkipped: true,
      );
      expect(state.debugCue, MapCue.settled);
      expect(state.debugZoom, 1);
      expect(state.debugPulseAnimating, isFalse);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await gone(tester);
    },
  );

  testWidgets(
    'reduced motion shows the connected country without a repeating ticker',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final state = await show(
        tester,
        status: VpnStatus.connected,
        exitReady: true,
      );
      expect(state.debugCue, MapCue.settled);
      expect(state.debugZoom, 1);
      expect(state.debugPulseAnimating, isFalse);
      final focus = state.debugFocus;
      final pulse = state.debugPulse;
      await tester.pump(const Duration(seconds: 5));
      expect(state.debugFocus, focus);
      expect(state.debugPulse, pulse);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await gone(tester);
    },
  );

  testWidgets('changing reduced motion stops and restores the settled wave', (
    tester,
  ) async {
    final state = await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
    );
    expect(state.debugPulseAnimating, isTrue);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    expect(state.debugPulseAnimating, isFalse);
    expect(state.debugZoom, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pump();
    expect(state.debugPulseAnimating, isTrue);
    expect(state.debugZoom, greaterThan(1));
    await gone(tester);
  });

  testWidgets('hidden tabs pause the settled wave without losing the country', (
    tester,
  ) async {
    final state = await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
      tickerEnabled: false,
    );
    final focus = state.debugFocus;
    final pulse = state.debugPulse;
    expect(state.debugPulseAnimating, isFalse);
    await tester.pump(const Duration(seconds: 7));
    expect(state.debugFocus, focus);
    expect(state.debugPulse, pulse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await show(tester, status: VpnStatus.connected, exitReady: true);
    expect(state.debugCue, MapCue.settled);
    expect(state.debugFocus, focus);
    expect(state.debugPulseAnimating, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugPulse, isNot(pulse));
    await gone(tester);
  });

  testWidgets(
    'background pauses a connected wave and resumes the same country',
    (tester) async {
      final state = await show(
        tester,
        status: VpnStatus.connected,
        exitReady: true,
      );
      await tester.pump(const Duration(milliseconds: 500));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pump();
      final focus = state.debugFocus;
      final pulse = state.debugPulse;
      expect(state.debugPulseAnimating, isFalse);
      await tester.pump(const Duration(seconds: 8));
      expect(state.debugFocus, focus);
      expect(state.debugPulse, pulse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.debugCue, MapCue.settled);
      expect(state.debugPulseAnimating, isTrue);
      expect(state.debugFocus, focus);
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.debugPulse, isNot(pulse));
      await gone(tester);
    },
  );

  testWidgets(
    'background pauses an in-flight camera instead of finishing it offscreen',
    (tester) async {
      final state = await show(tester, status: VpnStatus.connecting);
      await tester.pump(const Duration(milliseconds: 350));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pump();
      final zoom = state.debugZoom;
      final focus = state.debugFocus;
      await tester.pump(const Duration(seconds: 5));
      expect(state.debugCue, MapCue.approach);
      expect(state.debugZoom, zoom);
      expect(state.debugFocus, focus);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(state.debugCue, MapCue.waiting);
      await gone(tester);
    },
  );

  testWidgets(
    'settled wave changes rendered pixels while the camera stays fixed',
    (tester) async {
      final state = await show(
        tester,
        status: VpnStatus.connected,
        exitReady: true,
      );
      // FutureBuilder's completed asset Future still delivers its snapshot
      // asynchronously; finish that first paint before comparing wave frames.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      Future<List<int>> pixels() async => (await tester.runAsync(() async {
        final boundary =
            sceneKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final values = bytes!.buffer.asUint8List().toList();
        image.dispose();
        return values;
      }))!;
      await tester.pump(const Duration(milliseconds: 350));
      final first = await pixels();
      final focus = state.debugFocus;
      final zoom = state.debugZoom;
      await tester.pump(const Duration(milliseconds: 1100));
      final second = await pixels();
      expect(second.length, first.length);
      var differences = 0;
      for (var i = 0; i < first.length; i++) {
        if (first[i] != second[i]) differences++;
      }
      expect(
        differences,
        greaterThan(50),
        reason:
            'the wave must be visible, not merely tick an animation controller',
      );
      expect(state.debugFocus, focus);
      expect(state.debugZoom, zoom);
      await gone(tester);
    },
  );

  testWidgets('country-only exit location uses its map anchor', (tester) async {
    final state = await show(
      tester,
      status: VpnStatus.connected,
      exitReady: true,
      exitLat: null,
      exitLon: null,
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final country = world.byCode['JP']!;
    final expected = Offset(
      WorldMapData.xOf(country.lon),
      WorldMapData.yOf(country.lat),
    );
    expect((state.debugFocus! - expected).distance, lessThan(.00001));
    expect(state.debugZoom, inInclusiveRange(2.4, 5.6));
    expect(state.debugPulseAnimating, isTrue);
    await gone(tester);
  });

  testWidgets(
    'resuming while the map tab stays hidden does not restart the wave',
    (tester) async {
      final state = await show(
        tester,
        status: VpnStatus.connected,
        exitReady: true,
        tickerEnabled: false,
      );
      expect(state.debugPulseAnimating, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.debugPulseAnimating, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      await show(tester, status: VpnStatus.connected, exitReady: true);
      expect(state.debugPulseAnimating, isTrue);
      await gone(tester);
    },
  );

  testWidgets(
    'reconnecting a settled route stops its connected wave until ready',
    (tester) async {
      final state = await show(
        tester,
        status: VpnStatus.connected,
        exitReady: true,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.debugPulseAnimating, isTrue);
      await show(tester, status: VpnStatus.connecting);
      expect(state.debugPulseAnimating, isFalse);
      final pulse = state.debugPulse;
      await tester.pump(const Duration(seconds: 1));
      expect(state.debugPulse, pulse);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await show(tester, status: VpnStatus.connected, exitReady: true);
      expect(state.debugPulseAnimating, isTrue);
      await gone(tester);
    },
  );
}
