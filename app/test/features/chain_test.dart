import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/features/chain/chain_commands.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/ui/screens/settings_screen.dart';

import '../core/samples.dart';
import '../ui/fakes.dart';
import '../ui/harness.dart';

const _kGermany = 'vless://bf000d23-0752-40b4-affe-68f7707a9661@de1.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179e30d4fc2&type=tcp#%F0%9F%87%A9%F0%9F%87%AA%20Germany%20Reality';

/// Two vless nodes: Netherlands (first, selected) and Germany.
Future<void> _twoNodes(AppState state) async {
  await state.importText(kSampleVless);
  await state.importText(_kGermany);
  expect(state.nodes, hasLength(2));
}

Finder _settingsScroll() => find.descendant(
    of: find.byType(SettingsScreen), matching: find.byType(Scrollable).first);

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.text('Настройки'));
  await settle(tester);
  await tester.scrollUntilVisible(find.text('Через входной сервер'), 200,
      scrollable: _settingsScroll());
  await tester.pump();
}

void main() {
  testWidgets('chain: exits detour through the entry; toggling re-applies while connected',
      (tester) async {
    final vpn = FakeVpn();
    final (state, features) = await bootApp(tester, vpn: vpn);
    await _twoNodes(state);
    final entry = state.nodes.first;
    state.updateChain((c) {
      c.enabled = true;
      c.entryNodeId = entry.id;
    });
    await tester.pump(const Duration(milliseconds: 300));

    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.connected, isTrue);
    expect(vpn.starts, 1);
    final built = vpn.started!;
    expect(built.chainActive, isTrue);
    expect(built.entryTag, built.nodeTags[entry.id]);
    expect(built.singBox, contains('"detour"'));
    expect(built.singBox, contains('"detour": "${built.entryTag}"'));

    // Home shows the "via <entry>" footnote with the entry's country box.
    await settle(tester);
    expect(find.text('через'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-chain-line')), findsOneWidget);
    expect(find.textContaining('Netherlands'), findsWidgets);

    // Switching the chain off while connected re-applies after the debounce.
    state.updateChain((c) => c.enabled = false);
    await tester.pump(const Duration(milliseconds: 800));
    expect(vpn.starts, 1, reason: 'still debouncing');
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(vpn.starts, 2);
    expect(vpn.started!.chainActive, isFalse);
    // (dns-remote always detours via `proxy`; the entry's detour is what
    // must be gone.)
    expect(vpn.started!.singBox, isNot(contains('"detour": "${built.entryTag}"')));
    expect(state.connected, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('home-chain-line')), findsNothing);

    // …and back on.
    state.updateChain((c) => c.enabled = true);
    await tester.pump(const Duration(milliseconds: 1300));
    await settle(tester);
    expect(vpn.starts, 3);
    expect(vpn.started!.singBox, contains('"detour": "${built.entryTag}"'));
    expect(find.text('через'), findsOneWidget);

    await shutdownApp(tester, state, features: features);
  });

  testWidgets('settings section, picker and entry row', (tester) async {
    stubPlatformChannels(tester);
    final (state, features) = await bootApp(tester, size: const Size(360, 780));
    await _twoNodes(state);
    await _openSettings(tester);

    expect(find.text('ДВОЙНОЙ VPN'), findsOneWidget);
    expect(find.text('Через входной сервер'), findsOneWidget);
    expect(find.text('Входной сервер'), findsOneWidget);
    expect(find.text('не выбран'), findsOneWidget);

    // Switching on with no entry opens the picker straight away.
    await tester.tap(find.text('Через входной сервер'));
    await settle(tester);
    expect(state.chain.enabled, isTrue);
    expect(find.text('Входной сервер'), findsWidgets);
    // The selected (exit) node is shown but can't be picked.
    expect(find.text('это выходной сервер'), findsOneWidget);
    await tester.tap(find.text('это выходной сервер'));
    await settle(tester);
    expect(state.chain.entryNodeId, isNull, reason: 'the exit is inert');

    // Pick Germany.
    await tester.tap(find.textContaining('Germany').last);
    await settle(tester);
    expect(state.chain.entryNodeId, state.nodes.last.id);
    expect(find.text('это выходной сервер'), findsNothing, reason: 'sheet closed');
    expect(find.textContaining('Germany'), findsOneWidget, reason: 'entry row value');
    expect(find.text('не выбран'), findsNothing);
    expect(tester.takeException(), isNull);

    // The entry row reopens the picker with the check on the entry.
    await tester.tap(find.text('Входной сервер'));
    await settle(tester);
    expect(find.textContaining('Germany'), findsWidgets);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);

    // Off again: the entry is kept for next time.
    await tester.tap(find.text('Через входной сервер'));
    await settle(tester);
    expect(state.chain.enabled, isFalse);
    expect(state.chain.entryNodeId, state.nodes.last.id);
    expect(tester.takeException(), isNull);

    await shutdownApp(tester, state, features: features);
  });

  testWidgets('picker: WireGuard is inert, fewer than two servers shows the empty state',
      (tester) async {
    final (state, features) = await bootApp(tester);
    await state.importText(kSampleVless);
    await _openSettings(tester);
    await tester.tap(find.text('Входной сервер'));
    await settle(tester);
    expect(find.text('Нужны хотя бы два сервера'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);

    await state.importText(kWireGuardConf);
    expect(state.nodes.any((n) => n.protocol.isEndpoint), isTrue);
    await tester.pump();
    await tester.tap(find.text('Входной сервер'));
    await settle(tester);
    expect(find.text('WireGuard не может быть входом'), findsOneWidget);
    await tester.tap(find.text('WireGuard не может быть входом'));
    await settle(tester);
    expect(state.chain.entryNodeId, isNull);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);

    await shutdownApp(tester, state, features: features);
  });

  testWidgets('"Use as entry" node action enables the chain; wide layout works',
      (tester) async {
    stubPlatformChannels(tester);
    final (state, features) = await bootApp(tester, size: const Size(1280, 800));
    await _twoNodes(state);
    await tester.tap(find.text('Серверы'));
    await settle(tester);
    await tester.longPress(find.textContaining('Germany').first);
    await settle(tester);
    expect(find.text('Сделать входным'), findsOneWidget);
    await tester.tap(find.text('Сделать входным'));
    await settle(tester);
    expect(state.chain.enabled, isTrue);
    expect(state.chain.entryNodeId, state.nodes.last.id);

    // Settings on the wide layout: the picker is a dialog there.
    await _openSettings(tester);
    expect(find.text('ДВОЙНОЙ VPN'), findsOneWidget);
    await tester.tap(find.text('Входной сервер'));
    await settle(tester);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.textContaining('Germany'), findsWidgets);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);
    expect(find.byType(Dialog), findsNothing);

    // Home's footnote names the entry even before connecting.
    await tester.tap(find.text('Главная'));
    await settle(tester);
    expect(find.text('через'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('reduced motion: the chain line is static', (tester) async {
    reducedMotion(tester);
    final (state, features) = await bootApp(tester);
    await _twoNodes(state);
    state.updateChain((c) {
      c.enabled = true;
      c.entryNodeId = state.nodes.last.id;
    });
    await tester.pump();
    expect(find.text('через'), findsOneWidget);
    state.updateChain((c) => c.enabled = false);
    await tester.pump();
    expect(find.text('через'), findsNothing);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('chain.toggle command is registered once and toggles the chain', (tester) async {
    final (state, features) = await bootApp(tester);
    await tester.pump();
    final cmd = features.commands.byId(kChainToggleCommand);
    expect(cmd, isNotNull);
    expect(cmd!.isOn!(), isFalse);
    registerChainCommands(features); // idempotent
    expect(features.commands.all.where((c) => c.id == kChainToggleCommand), hasLength(1));
    await cmd.run(tester.element(find.byType(MaterialApp)));
    expect(state.chain.enabled, isTrue);
    expect(cmd.isOn!(), isTrue);
    await shutdownApp(tester, state, features: features);
  });
}
