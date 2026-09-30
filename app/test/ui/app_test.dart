import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/l10n/strings.dart';
import 'package:melsi/main.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/import_input.dart';

import 'fakes.dart';

Future<AppState> _boot(WidgetTester tester, {Size size = const Size(390, 844), FakeVpn? vpn}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final state = testState(vpn: vpn)..settings.locale = 'ru';
  await state.load();
  await tester.pumpWidget(MelsiApp(state: state));
  await tester.pump(const Duration(milliseconds: 500));
  return state;
}

/// Advances enough frames for route/sheet transitions to finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Unmount and let pending timers settle.
Future<void> _shutdown(WidgetTester tester, AppState state) async {
  if (state.vpnState.status != VpnStatus.stopped) {
    state.disconnect();
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  testWidgets('app boots on phone layout with a tab bar', (tester) async {
    final state = await _boot(tester);
    expect(find.text('Melsi'), findsWidgets);
    expect(find.text('Не подключено'), findsOneWidget);
    expect(find.text('Главная'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget);
    await _shutdown(tester, state);
  });

  testWidgets('app boots on desktop layout with a sidebar', (tester) async {
    final state = await _boot(tester, size: const Size(1280, 800));
    expect(find.text('Главная'), findsOneWidget);
    expect(find.text('Маршруты'), findsOneWidget);
    await _shutdown(tester, state);
  });

  testWidgets('tabs switch', (tester) async {
    final state = await _boot(tester);
    await tester.tap(find.text('Серверы'));
    await _settle(tester);
    expect(find.text('Пока нет серверов'), findsOneWidget);
    expect(find.text('Добавить подписку'), findsOneWidget);

    await tester.tap(find.text('Игры'));
    await _settle(tester);
    expect(find.text('Игровой режим'), findsWidgets);
    expect(find.text('Counter-Strike 2'), findsOneWidget);

    await tester.tap(find.text('Маршруты'));
    await _settle(tester);
    expect(find.text('Умный РФ'), findsWidgets);

    await tester.tap(find.text('Настройки'));
    await _settle(tester);
    expect(find.text('УМНЫЙ ВЫБОР СЕРВЕРА'), findsOneWidget);
    await _shutdown(tester, state);
  });

  testWidgets('add a vless link, then connect and disconnect', (tester) async {
    final vpn = FakeVpn();
    final state = await _boot(tester, vpn: vpn);
    await tester.tap(find.text('Серверы'));
    await _settle(tester);

    await tester.tap(find.text('Добавить подписку'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('add-link-field')), kSampleVless);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-submit')));
    await _settle(tester);

    expect(state.nodes, hasLength(1));
    expect(state.nodes.single.name, contains('Netherlands'));
    expect(find.textContaining('Netherlands Reality'), findsWidgets);

    await tester.tap(find.text('Главная'));
    await _settle(tester);
    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    expect(vpn.started, isNotNull);
    expect(vpn.started!.singBox, contains('"vless"'));
    expect(state.connected, isTrue);
    await _settle(tester);
    expect(find.text('Подключено'), findsOneWidget);

    state.disconnect();
    await _settle(tester);
    expect(find.text('Не подключено'), findsOneWidget);
    await _shutdown(tester, state);
  });

  testWidgets('config changes while connected apply themselves after a debounce', (tester) async {
    final vpn = FakeVpn();
    final state = await _boot(tester, vpn: vpn);
    await state.importText(kSampleVless);
    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.vpnState.status, VpnStatus.connected, reason: '${state.vpnState}');
    expect(vpn.starts, 1);
    final since = state.connectedAt;

    state.updateRouting((r) => r.blockAds = !r.blockAds);
    await tester.pump(const Duration(milliseconds: 800));
    expect(state.needsReconnect, isTrue);
    expect(state.applyPhase, ApplyPhase.pending);

    // A further edit inside the window pushes the apply back.
    state.updateRouting((r) => r.bypassLan = !r.bypassLan);
    await tester.pump(const Duration(milliseconds: 800));
    expect(vpn.starts, 1, reason: 'still debouncing');

    await tester.pump(const Duration(milliseconds: 500));
    await _settle(tester);
    expect(vpn.starts, 2, reason: 'one restart for both edits');
    expect(state.connected, isTrue);
    expect(state.needsReconnect, isFalse);
    expect(state.connectedAt, since, reason: 'session timer survives the re-apply');
    expect(state.applyPhase, ApplyPhase.done);
    expect(find.text('Готово'), findsOneWidget);
    expect(find.text('Переподключитесь, чтобы применить изменения'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(state.applyPhase, ApplyPhase.idle);
    await _shutdown(tester, state);
  });

  testWidgets('disconnecting cancels a pending apply', (tester) async {
    final vpn = FakeVpn();
    final state = await _boot(tester, vpn: vpn);
    await state.importText(kSampleVless);
    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    state.updateSettings((s) => s.ipv6 = !s.ipv6);
    await tester.pump(const Duration(milliseconds: 300));
    state.disconnect();
    await tester.pump(const Duration(seconds: 2));
    expect(vpn.starts, 1);
    expect(state.vpnState.status, VpnStatus.stopped);
    expect(state.applyPhase, ApplyPhase.idle);
    await _shutdown(tester, state);
  });

  testWidgets('home server card opens the quick switcher', (tester) async {
    final state = await _boot(tester);
    await state.importText(kSampleVless);
    await state.importText(kSampleVless.replaceAll('nl1.example.com', 'de1.example.com').replaceAll('Netherlands', 'Germany'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.nodes, hasLength(2));
    await tester.tap(find.byKey(const ValueKey('home-node-panel')));
    await _settle(tester);
    expect(find.text('Выбор сервера'), findsOneWidget);
    await tester.tap(find.textContaining('Germany').last);
    await _settle(tester);
    expect(state.selectedNode!.name, contains('Germany'));
    expect(state.settings.autoSelect, isFalse);
    expect(find.text('Выбор сервера'), findsNothing);
    await _shutdown(tester, state);
  });

  test('ru and en have the same keys', () {
    final ru = kStrings['ru']!.keys.toSet();
    final en = kStrings['en']!.keys.toSet();
    expect(ru.difference(en), isEmpty, reason: 'missing in en');
    expect(en.difference(ru), isEmpty, reason: 'missing in ru');
  });

  group('ImportInput', () {
    test('classifies subscription URLs vs proxy links', () {
      expect(ImportInput.classify('https://sub.example.com/api/v1/abc'), isA<SubscriptionUrlInput>());
      expect(ImportInput.classify('https://example.com/?token=1'), isA<SubscriptionUrlInput>());
      expect(ImportInput.classify('http://1.2.3.4:8080'), isA<SingleLinkInput>());
      expect(ImportInput.classify(kSampleVless), isA<SingleLinkInput>());
      expect(ImportInput.classify('$kSampleVless\n$kSampleVless'), isA<ContentInput>());
      expect(ImportInput.classify('  '), isA<ImportEmpty>());
    });

    test('parses deep links', () {
      final a = DeepLinkImport.parse(
          'melsi://import?url=${Uri.encodeComponent('https://s.example/sub?x=1')}&name=My');
      expect(a?.url, 'https://s.example/sub?x=1');
      expect(a?.name, 'My');
      final b = DeepLinkImport.parse(
          'sing-box://import-remote-profile?url=${Uri.encodeComponent('https://s.example/a')}#Prof');
      expect(b?.url, 'https://s.example/a');
      expect(b?.name, 'Prof');
      final c = DeepLinkImport.parse('clash://install-config?url=https%3A%2F%2Fs.example%2Fc');
      expect(c?.url, 'https://s.example/c');
      final d = DeepLinkImport.parse('hiddify://import/https://s.example/h#Name');
      expect(d?.url, 'https://s.example/h');
      expect(d?.name, 'Name');
      expect(DeepLinkImport.parse('https://example.com'), isNull);
    });
  });
}
