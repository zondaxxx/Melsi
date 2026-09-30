import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/features/favorites/favorites_widgets.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/store.dart';
import 'package:melsi/ui/screens/servers_screen.dart' show NodeRow;
import 'package:melsi/ui/widgets/page.dart' show SheetClose;

import '../ui/fakes.dart';
import '../ui/harness.dart';

/// [kSampleVless] pointed at another host with another name (the flag in
/// the name decides the country code).
String _link(String host, String name) {
  final base = kSampleVless.substring(0, kSampleVless.indexOf('#'));
  return '${base.replaceAll('nl1.example.com', host)}#${Uri.encodeComponent(name)}';
}

void main() {
  testWidgets('pin from the actions sheet: Избранное group, persisted; unpin removes it',
      (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester);
    await state.importText(kSampleVless);
    final id = state.nodes.single.id;
    await tester.tap(find.text('Серверы'));
    await settle(tester);
    expect(find.byType(NodeRow), findsOneWidget);
    expect(find.text('Избранное'), findsNothing);

    await tester.longPress(find.byType(NodeRow));
    await settle(tester);
    await tester.tap(find.text('В избранное'));
    await settle(tester);

    expect(state.favouriteIds, [id]);
    expect(find.text('Избранное'), findsOneWidget, reason: 'the favourites header');
    expect(find.byType(NodeRow), findsNWidgets(2), reason: 'favourites copy + group row');
    expect(find.byIcon(Icons.star_rounded), findsWidgets);
    final store = state.store as MemoryStateStore;
    expect(store.data!['favourites'], [id]);

    await tester.longPress(find.byType(NodeRow).last);
    await settle(tester);
    await tester.tap(find.text('Убрать из избранного'));
    await settle(tester);

    expect(state.favouriteIds, isEmpty);
    expect(find.text('Избранное'), findsNothing);
    expect(find.byType(NodeRow), findsOneWidget);
    expect(store.data!['favourites'], isEmpty);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('recents are newest first and capped at 6; removing a node prunes both lists',
      (tester) async {
    final state = testState();
    await state.load();
    for (var i = 0; i < 7; i++) {
      expect(await state.importText(_link('h$i.example.com', 'Node $i')), 1);
    }
    expect(state.nodes, hasLength(7));
    for (final n in state.nodes) {
      await state.selectNode(n.id);
    }
    expect(state.recentIds, state.nodes.reversed.take(6).map((n) => n.id).toList());
    expect(state.recentNodes.first.name, 'Node 6');

    // Re-selecting moves a node to the front without duplicating it.
    await state.selectNode(state.nodes[3].id);
    expect(state.recentIds.first, state.nodes[3].id);
    expect(state.recentIds.toSet(), hasLength(6));

    final last = state.nodes.last;
    state.toggleFavourite(last.id);
    expect(state.favouriteIds, [last.id]);
    expect(state.isFavourite(last.id), isTrue);
    state.removeNode(last.id);
    expect(state.favouriteIds, isEmpty);
    expect(state.recentIds, isNot(contains(last.id)));
    expect(state.recentIds, hasLength(5));
    state.dispose();
  });

  testWidgets('switcher shows recents, favourites and best-per-country chips', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester);
    await state.importText(kSampleVless);
    await state.importText(_link('de1.example.com', '🇩🇪 Germany Reality'));
    await state.importText(_link('fi1.example.com', '🇫🇮 Finland Reality'));
    final nl = state.nodes[0], de = state.nodes[1], fi = state.nodes[2];
    expect([nl.countryCode, de.countryCode, fi.countryCode], ['NL', 'DE', 'FI']);
    final at = DateTime(2026, 10, 1);
    state.latencies[nl.id] = Latency(120, viaUrl: false, at: at);
    state.latencies[de.id] = Latency(40, viaUrl: false, at: at);
    state.latencies[fi.id] = Latency(80, viaUrl: false, at: at);
    await state.selectNode(nl.id); // recent
    state.toggleFavourite(de.id); // favourite
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('home-node-panel')));
    await settle(tester);
    expect(find.text('Выбор сервера'), findsOneWidget);
    expect(find.text('НЕДАВНИЕ'), findsOneWidget);
    expect(find.text('ИЗБРАННОЕ'), findsOneWidget);
    expect(find.text('ЛУЧШИЙ ПО СТРАНЕ'), findsOneWidget);
    expect(find.byType(SwitcherNodeRow), findsNWidgets(2), reason: 'one recent, one favourite');
    final chips = tester.widgetList<CountryChip>(find.byType(CountryChip)).toList();
    expect(chips.map((c) => c.countryCode), ['DE', 'FI', 'NL'], reason: 'fastest first');

    // A chip selects the node and closes the switcher.
    await tester.tap(find.byType(CountryChip).at(1));
    await settle(tester);
    expect(state.selectedNode?.id, fi.id);
    expect(state.recentIds.first, fi.id);
    expect(find.text('Выбор сервера'), findsNothing);

    // Pinning the recent moves it: "Недавние" empties, "Избранное" grows.
    state.toggleFavourite(nl.id);
    state.toggleFavourite(fi.id);
    await tester.tap(find.byKey(const ValueKey('home-node-panel')));
    await settle(tester);
    expect(find.text('НЕДАВНИЕ'), findsNothing);
    expect(find.byType(SwitcherNodeRow), findsNWidgets(3));
    await tester.tap(find.byType(SwitcherNodeRow).first);
    await settle(tester);
    expect(find.text('Выбор сервера'), findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('strip stays hidden with fewer than two measured countries', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await bootApp(tester);
    await state.importText(kSampleVless);
    await state.importText(_link('de1.example.com', '🇩🇪 Germany Reality'));
    state.latencies[state.nodes.first.id] =
        Latency(50, viaUrl: false, at: DateTime(2026, 10, 1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('home-node-panel')));
    await settle(tester);
    expect(find.text('ЛУЧШИЙ ПО СТРАНЕ'), findsNothing);
    expect(find.byType(CountryChip), findsNothing);
    await tester.tap(find.byType(SheetClose));
    await settle(tester);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('palette commands: toggle current and one pick per favourite', (tester) async {
    final (state, f) = await bootApp(tester);
    await state.importText(kSampleVless);
    final id = state.nodes.single.id;
    final toggle = f.commands.byId('fav.toggleCurrent');
    expect(toggle, isNotNull);
    expect(toggle!.isOn!(), isFalse);
    expect(f.commands.byId('fav.pick.$id'), isNull);
    final el = tester.element(find.byType(Scaffold).first);
    await toggle.run(el);
    expect(state.isFavourite(id), isTrue);
    expect(toggle.isOn!(), isTrue);
    final pick = f.commands.byId('fav.pick.$id');
    expect(pick, isNotNull);
    expect(pick!.titleKey, contains('Netherlands'));
    expect(pick.keywords, contains('nl1.example.com'));

    state.toggleFavourite(id);
    expect(f.commands.byId('fav.pick.$id'), isNull);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('desktop: the outline star shows on hover and pins in one click (reduced motion)',
      (tester) async {
    stubPlatformChannels(tester);
    reducedMotion(tester);
    final (state, f) = await bootApp(tester, size: const Size(1280, 800));
    await state.importText(kSampleVless);
    final id = state.nodes.single.id;
    await tester.tap(find.text('Серверы'));
    await settle(tester);

    final star = find.byType(FavoriteStar);
    expect(star, findsOneWidget);
    AnimatedOpacity opacity() => tester.widget<AnimatedOpacity>(
        find.descendant(of: star.first, matching: find.byType(AnimatedOpacity)));
    expect(opacity().opacity, 0, reason: 'unpinned and not hovered: invisible');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(star));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity().opacity, 1, reason: 'hover reveals the outline star');
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);

    await tester.tap(star);
    await settle(tester);
    expect(state.isFavourite(id), isTrue);
    expect(find.text('Избранное'), findsOneWidget);
    expect(find.byType(FavoriteStar), findsNWidgets(2));
    await shutdownApp(tester, state, features: f);
  });
}
