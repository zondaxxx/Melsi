// P1-onboarding: first-run flow, upgrade bypass, reduced motion, replay.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/l10n/l10n.dart';
import 'package:melsi/state/store.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

const _fresh = {
  'settings': {'onboardingDone': false},
};

Map<String, dynamic> _upgrade() => {
      'settings': {'onboardingDone': false},
      'nodes': [
        {
          'id': 'n1',
          'name': '🇩🇪 Frankfurt · Reality',
          'outbound': {'type': 'vless', 'server': 'de1.example.net', 'server_port': 443, 'uuid': 'x'},
          'countryCode': 'DE',
          'rawLink': 'vless://x@de1.example.net:443#Frankfurt',
        },
      ],
    };

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  testWidgets('external import can dismiss onboarding after it mounted', (tester) async {
    final (state, features) = await bootApp(tester, data: _fresh);
    state.finishOnboarding();
    await settle(tester);
    expect(find.text('Не подключено'), findsOneWidget);
    expect(_key('onboarding-skip'), findsNothing);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('fresh install: brand moment, features, add a server, open', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester, data: _fresh);

    // 500ms in: still the brand moment, tap-anywhere target present.
    expect(_key('onboarding-skip'), findsOneWidget);
    expect(find.text('Не подключено'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(_key('onboarding-skip'), findsNothing, reason: 'auto-advanced at 900ms');
    expect(find.text('Далее'), findsOneWidget);
    expect(find.text('Умный выбор сервера'), findsOneWidget);
    expect(find.text('Российские сайты напрямую, остальное через VPN'), findsOneWidget);

    await tester.tap(find.text('Далее'));
    await settle(tester);
    expect(find.text('Добавьте сервер'), findsOneWidget);
    expect(find.text('Позже'), findsOneWidget);

    await tester.enterText(_key('onboarding-link-field'), kSampleVless);
    // The field grows with the long link; the panel's AnimatedSize follows.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(_key('onboarding-submit'));
    await settle(tester);
    expect(state.nodes, hasLength(1));
    expect(find.textContaining('Добавлено'), findsOneWidget);
    expect(find.text('Добавлено: 1 сервер'), findsOneWidget);
    expect(find.text('Позже'), findsNothing);
    expect(_key('onboarding-link-field'), findsNothing, reason: 'panel collapsed');

    await tester.tap(find.text('Далее'));
    await settle(tester);
    await settle(tester);
    expect(find.text('Почти готово'), findsOneWidget);
    expect(find.text('Подключаться при запуске'), findsOneWidget);
    expect(state.settings.connectOnLaunch, isFalse);
    await tester.tap(find.text('Подключаться при запуске'));
    await tester.pump();
    expect(state.settings.connectOnLaunch, isTrue);

    await tester.tap(_key('onboarding-open'));
    await settle(tester);
    expect(state.settings.onboardingDone, isTrue);
    expect(find.text('Не подключено'), findsOneWidget);
    expect(find.text('Почти готово'), findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('tap anywhere skips the brand moment', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) =
        await bootApp(tester, data: _fresh, firstPump: const Duration(milliseconds: 100));
    expect(_key('onboarding-skip'), findsOneWidget);
    await tester.tap(_key('onboarding-skip'));
    await tester.pump();
    expect(_key('onboarding-skip'), findsNothing);
    await settle(tester);
    expect(find.text('Далее'), findsOneWidget);

    // "Пропустить" is the way out of the whole flow.
    await tester.tap(find.text('Пропустить'));
    await settle(tester);
    expect(state.settings.onboardingDone, isTrue);
    expect(find.text('Не подключено'), findsOneWidget);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('reduced motion: step 1 after one 200ms pump; "Позже" path', (tester) async {
    stubPlatformChannels(tester);
    reducedMotion(tester);
    final (state, f) = await bootApp(tester, data: _fresh, firstPump: Duration.zero);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_key('onboarding-skip'), findsNothing);
    expect(find.text('Далее'), findsOneWidget);

    await tester.tap(find.text('Далее'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Добавьте сервер'), findsOneWidget);
    await tester.tap(find.text('Позже'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Почти готово'), findsOneWidget);
    await tester.tap(_key('onboarding-open'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Не подключено'), findsOneWidget);
    expect(state.nodes, isEmpty);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('upgrade with servers skips onboarding and persists the flag', (tester) async {
    final (state, f) = await bootApp(tester, data: _upgrade());
    expect(_key('onboarding-skip'), findsNothing);
    expect(find.text('Добавьте сервер'), findsNothing);
    expect(find.text('Не подключено'), findsOneWidget);
    expect(state.settings.onboardingDone, isTrue);
    final saved = (state.store as MemoryStateStore).data!;
    expect((saved['settings'] as Map)['onboardingDone'], isTrue);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('settings row replays the welcome even with servers', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester, size: const Size(1280, 800), data: _upgrade());
    await tester.tap(find.text('Настройки'));
    await settle(tester);
    await tester.dragUntilVisible(
      _key('onboarding-replay'),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await settle(tester);
    await tester.tap(_key('onboarding-replay'));
    await settle(tester);
    expect(_key('onboarding-skip'), findsOneWidget);
    expect(find.text('Настройки'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Пропустить'));
    await settle(tester);
    expect(find.text('Не подключено'), findsWidgets); // sidebar + home on desktop
    expect(state.settings.onboardingDone, isTrue);
    expect(state.nodes, hasLength(1), reason: 'replay never touches the servers');
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('fits a 360px phone and keeps phone widths on desktop', (tester) async {
    stubPlatformChannels(tester);
    var (state, f) = await bootApp(tester, size: const Size(360, 640), data: _fresh);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Далее'));
    await settle(tester);
    expect(find.text('Добавьте сервер'), findsOneWidget);
    expect(tester.getSize(_key('onboarding-later')).width, lessThan(360));
    await shutdownApp(tester, state, features: f);

    (state, f) = await bootApp(tester, size: const Size(1280, 800), data: _fresh);
    await tester.pump(const Duration(seconds: 1));
    final next = tester.getRect(_key('onboarding-next'));
    expect(next.width, lessThanOrEqualTo(520));
    expect(next.center.dx, closeTo(640, 1));
    await shutdownApp(tester, state, features: f);
  });

  test('added count uses the Russian plural forms', () {
    const l = L10n('ru');
    expect(l('onboard.added', {'n': l.plural(1, 'onboard.added')}), 'Добавлено: 1 сервер');
    expect(l('onboard.added', {'n': l.plural(3, 'onboard.added')}), 'Добавлено: 3 сервера');
    expect(l('onboard.added', {'n': l.plural(12, 'onboard.added')}), 'Добавлено: 12 серверов');
    const en = L10n('en');
    expect(en('onboard.added', {'n': en.plural(2, 'onboard.added')}), 'Added: 2 servers');
  });
}
