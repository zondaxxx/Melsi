import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/features/palette/command_palette.dart';
import 'package:melsi/features/palette/palette_search.dart';
import 'package:melsi/state/features.dart';
import 'package:melsi/ui/shell.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

const _wide = Size(1280, 800);
const _hint = 'Сервер, действие или настройка…';
final _germany =
    kSampleVless.replaceAll('nl1.example.com', 'de1.example.com').replaceAll('Netherlands', 'Germany');

Future<void> _ctrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await settle(tester);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(kPaletteFieldKey), text);
  await tester.pump();
}

Future<void> _enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await settle(tester);
}

Finder get _palette => find.byType(CommandPalette);

/// Text inside the palette only (Home shows the same server name and
/// "Подключиться" underneath the dialog).
Finder _inPalette(String text) => find.descendant(of: _palette, matching: find.text(text));
Finder _inPaletteContaining(String text) =>
    find.descendant(of: _palette, matching: find.textContaining(text));

void main() {
  group('paletteScore', () {
    test('exact > prefix > word start > substring > subsequence > none', () {
      const title = 'Kill switch';
      final exact = paletteScore('kill switch', title, const []);
      final prefix = paletteScore('kil', title, const []);
      final wordStart = paletteScore('swi', title, const []);
      final substring = paletteScore('ill', title, const []);
      final subsequence = paletteScore('ksw', title, const []);
      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(wordStart));
      expect(wordStart, greaterThan(substring));
      expect(substring, greaterThan(subsequence));
      expect(subsequence, greaterThan(0));
      expect(paletteScore('zzz', title, const []), 0);
      expect(paletteScore('', title, const []), 0);
    });

    test('keywords match but never beat a matching title', () {
      expect(paletteScore('fav', 'Netherlands', const ['nl', 'fav']), greaterThan(0));
      expect(paletteScore('nl', 'Netherlands', const ['nl']), greaterThan(0));
      expect(paletteScore('net', 'Netherlands', const []),
          greaterThan(paletteScore('net', 'Germany', const ['network'])));
    });

    test('multi-word queries need every word; ё folds to е', () {
      expect(paletteScore('kill zzz', 'Kill switch', const []), 0);
      expect(paletteScore('kill sw', 'Kill switch', const []), greaterThan(0));
      expect(paletteScore('темное', 'Тёмное', const []), greaterThan(0));
    });
  });

  testWidgets('ctrl+K on a wide layout opens the palette; commands run on Enter', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester, size: _wide);
    await state.importText(kSampleVless);
    await state.importText(_germany);
    await tester.pump(const Duration(milliseconds: 300));
    final nl = state.nodes.firstWhere((n) => n.name.contains('Netherlands'));
    final de = state.nodes.firstWhere((n) => n.name.contains('Germany'));
    await state.selectNode(de.id);
    await tester.pump();
    expect(state.selectedNodeId, de.id);
    expect(state.settings.killSwitch, isFalse);

    await _ctrlK(tester);
    expect(_palette, findsOneWidget);
    expect(find.text(_hint), findsOneWidget);
    // Empty query: the state's most relevant actions, e.g. connect.
    expect(_inPalette('Подключиться'), findsOneWidget);

    await _type(tester, 'kill');
    expect(_inPalette('Kill switch'), findsOneWidget);
    await _enter(tester);
    expect(_palette, findsNothing);
    expect(state.settings.killSwitch, isTrue);

    await _ctrlK(tester);
    expect(_palette, findsOneWidget);
    // Recents show what just ran.
    expect(f.palette.recentIds, ['toggle.killSwitch']);
    expect(_inPalette('НЕДАВНИЕ'), findsOneWidget);

    await _type(tester, 'nether');
    expect(_inPaletteContaining('Netherlands'), findsOneWidget);
    expect(_inPaletteContaining('Germany'), findsNothing);
    await _enter(tester);
    expect(_palette, findsNothing);
    expect(state.selectedNodeId, nl.id);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('on a phone ctrl+K opens nothing', (tester) async {
    final (state, f) = await bootApp(tester, size: const Size(390, 844));
    await _ctrlK(tester);
    expect(_palette, findsNothing);
    expect(find.text(_hint), findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('Esc closes and focus returns to the shell', (tester) async {
    final (state, f) = await bootApp(tester, size: _wide);
    await _ctrlK(tester);
    expect(_palette, findsOneWidget);
    // The search field owns focus while the palette is open.
    expect(FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<CommandPalette>(), isNotNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(_palette, findsNothing);
    final focus = FocusManager.instance.primaryFocus;
    expect(focus?.context?.findAncestorWidgetOfExactType<Shell>(), isNotNull,
        reason: 'focus is back inside the shell');

    // …and the shortcut works again right away.
    await _ctrlK(tester);
    expect(_palette, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(_palette, findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('no shortcut while a text field has focus', (tester) async {
    final (state, f) = await bootApp(tester, size: _wide);
    await state.importText(kSampleVless);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Серверы'));
    await settle(tester);
    // The Servers search field lives inside the shell's shortcut scope.
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>(), isNotNull);

    await _ctrlK(tester);
    expect(_palette, findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('keyboard: arrows move the highlight, Tab jumps groups, toggles show state',
      (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester, size: _wide);
    await _ctrlK(tester);
    await _type(tester, 'режим');
    // Smart-select toggle plus the smart modes: current picks read "вкл.".
    expect(_inPalette('вкл.'), findsWidgets);
    expect(_inPalette('выкл.'), findsWidgets);

    // "theme" hits the three theme options by keyword; ties break on title
    // length, so the order is dark, light, system. ↓ lands on light.
    await _type(tester, 'theme');
    expect(state.settings.themeMode, 'system');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await _enter(tester);
    expect(state.settings.themeMode, 'light');

    // "игр": the Games tab (Sections) ranks first, Game Mode (Settings)
    // second. Tab jumps to the next group, so Enter toggles Game Mode
    // instead of switching tabs.
    await _ctrlK(tester);
    await _type(tester, 'игр');
    expect(_inPalette('Игры'), findsOneWidget);
    expect(_inPalette('Игровой режим'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_palette, findsOneWidget, reason: 'Tab never leaves the palette');
    await _enter(tester);
    expect(state.game.enabled, isTrue);
    expect(find.text('Counter-Strike 2'), findsNothing, reason: 'still on Home');

    await _ctrlK(tester);
    await _type(tester, 'обход');
    expect(_inPalette('Обход блокировок'), findsOneWidget);
    await _enter(tester);
    expect(state.routing.preset.name, 'blockedOnly');
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('commands registered by other features appear without palette edits',
      (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester, size: _wide);
    var ran = 0;
    f.commands.register(AppCommand(
      id: 'doctor.run',
      titleKey: 'Run diagnostics',
      group: PaletteGroups.tools,
      icon: Icons.healing_outlined,
      keywords: const ['diag'],
      run: (_) async => ran++,
    ));
    await _ctrlK(tester);
    await _type(tester, 'diag');
    expect(_inPalette('Run diagnostics'), findsOneWidget);
    expect(_inPalette('ИНСТРУМЕНТЫ'), findsOneWidget);
    await _enter(tester);
    expect(ran, 1);
    expect(f.palette.recentIds.first, 'doctor.run');

    await _ctrlK(tester);
    await _type(tester, 'qwertyuiop');
    expect(_inPalette('Ничего не найдено'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('tab commands switch the shell page', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester, size: _wide);
    await _ctrlK(tester);
    await _type(tester, 'настройки');
    await _enter(tester);
    await settle(tester);
    expect(find.text('УМНЫЙ ВЫБОР СЕРВЕРА'), findsOneWidget);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('reduced motion: opens and closes with a plain fade, nothing leaks', (tester) async {
    reducedMotion(tester);
    final (state, f) = await bootApp(tester, size: _wide);
    await _ctrlK(tester);
    expect(_palette, findsOneWidget);
    await tester.tapAt(const Offset(20, 780)); // the barrier
    await settle(tester);
    expect(_palette, findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('service re-registers server rows when latency or status changes', (tester) async {
    final (state, f) = await bootApp(tester, size: _wide);
    expect(f.commands.byId('vpn.toggle')!.titleKey, 'home.connect');
    await state.importText(kSampleVless);
    await tester.pump(const Duration(milliseconds: 300));
    final id = 'node.${state.nodes.single.id}';
    expect(f.commands.byId(id)!.subtitle, contains('—'));
    expect(f.commands.byId(id)!.keywords, contains('NL'));

    state.toggleFavourite(state.nodes.single.id);
    await tester.pump();
    expect(f.commands.byId(id)!.keywords, contains('fav'));

    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);
    expect(f.commands.byId('vpn.toggle')!.titleKey, 'home.disconnect');
    expect(f.commands.byId('vpn.reconnect'), isNotNull);

    state.disconnect();
    await settle(tester);
    expect(f.commands.byId('vpn.reconnect'), isNull);
    await shutdownApp(tester, state, features: f);
  });
}
