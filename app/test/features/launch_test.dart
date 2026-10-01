// P1-onboarding: the cold-start veil — timing, hurry tap, reduced motion,
// and that it never blocks the app once it is lifting.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/features/onboarding/launch_veil.dart';

import '../ui/harness.dart';

Finder get _veil => find.byKey(const ValueKey('launch-veil'));

double _progress(WidgetTester tester) =>
    tester.state<LaunchVeilState>(find.byType(LaunchVeil)).debugProgress;

void main() {
  testWidgets('plays 480ms and removes itself', (tester) async {
    final (state, f) = await bootApp(tester,
        launchMoment: true, firstPump: const Duration(milliseconds: 150));
    expect(_veil, findsOneWidget);
    expect(_progress(tester), closeTo(150 / 480, 0.02));

    await tester.pump(const Duration(milliseconds: 300));
    expect(_veil, findsOneWidget);
    expect(_progress(tester), greaterThanOrEqualTo(0.9));

    await tester.pump(const Duration(milliseconds: 250));
    expect(_veil, findsNothing);
    expect(_progress(tester), 1);
    expect(find.text('Не подключено'), findsOneWidget);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('a tap in the first 300ms hurries it', (tester) async {
    final (state, f) = await bootApp(tester,
        launchMoment: true, firstPump: const Duration(milliseconds: 100));
    expect(_veil, findsOneWidget);
    await tester.tap(_veil);
    await tester.pump(); // the hurry starts on the next frame
    await tester.pump(const Duration(milliseconds: 150));
    expect(_veil, findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('never blocks a tap after 300ms', (tester) async {
    final (state, f) = await bootApp(tester,
        launchMoment: true, firstPump: const Duration(milliseconds: 350));
    expect(_veil, findsOneWidget, reason: 'still fading');
    await tester.tap(find.text('Серверы'), warnIfMissed: false);
    await settle(tester);
    expect(_veil, findsNothing);
    expect(find.text('Пока нет серверов'), findsOneWidget);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('reduced motion: a 160ms fade', (tester) async {
    reducedMotion(tester);
    final (state, f) = await bootApp(tester,
        launchMoment: true, firstPump: const Duration(milliseconds: 50));
    expect(_veil, findsOneWidget);
    expect(_progress(tester), closeTo(50 / 160, 0.02), reason: 'a real 160ms fade');
    await tester.pump(const Duration(milliseconds: 200));
    expect(_veil, findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('disabled: no veil at all', (tester) async {
    final (state, f) = await bootApp(tester, firstPump: Duration.zero);
    expect(_veil, findsNothing);
    expect(_progress(tester), 1);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('the onboarding brand moment waits for the veil', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester, launchMoment: true, data: const {
      'settings': {'onboardingDone': false},
    });
    // 500ms: veil gone, onboarding step 0 just started.
    expect(_veil, findsNothing);
    expect(find.byKey(const ValueKey('onboarding-skip')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.text('Далее'), findsOneWidget);
    await shutdownApp(tester, state, features: f);
  });
}
