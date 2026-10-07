// P3-navigation-motion: directional tab springs, spring sheets, staggered
// first entrance.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/ui/screens/home_screen.dart';
import 'package:melsi/ui/theme/entrance.dart';
import 'package:melsi/ui/widgets/fade_stack.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

FadeIndexedStackState _stack(WidgetTester tester) =>
    tester.state<FadeIndexedStackState>(find.byType(FadeIndexedStack));

/// Opacity the nearest [Opacity] ancestor gives [finder]; 1 when there is none.
double _opacityOf(WidgetTester tester, Finder finder) {
  final o = find.ancestor(of: finder, matching: find.byType(Opacity));
  if (o.evaluate().isEmpty) return 1;
  return tester.widget<Opacity>(o.first).opacity;
}

Future<void> _closeTopRoute(WidgetTester tester) async {
  await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
  await settle(tester);
}

Widget _entranceApp(List<String> labels, {String group = 'g', bool reduce = false}) =>
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            for (final (i, l) in labels.indexed)
              StaggeredEntrance(group: group, index: i, child: Text(l)),
          ],
        ),
      ),
    );

void main() {
  setUp(StaggeredEntrance.debugReset);

  group('FadeIndexedStack', () {
    testWidgets('incoming page slides from +10px upward, then from -10px back', (tester) async {
      final (state, f) = await bootApp(tester);
      expect(_stack(tester).debugOffset, 0);

      await tester.tap(find.text('Серверы'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget,
          reason: 'IndexedStack keeps Home alive');
      expect(_stack(tester).debugOffset, greaterThan(0));
      expect(_stack(tester).debugOffset, lessThanOrEqualTo(FadeIndexedStack.travel));

      await tester.pump(const Duration(milliseconds: 500));
      expect(_stack(tester).debugOffset, 0);
      expect(find.text('Пока нет серверов'), findsOneWidget);

      await tester.tap(find.text('Главная'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_stack(tester).debugOffset, lessThan(0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_stack(tester).debugOffset, 0);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('a rapid second tap continues from the current offset', (tester) async {
      final (state, f) = await bootApp(tester);
      await tester.tap(find.text('Настройки'));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 60));
      final midway = _stack(tester).debugOffset;
      expect(midway, greaterThan(0));
      expect(midway, lessThan(FadeIndexedStack.travel));

      await tester.tap(find.text('Серверы'));
      await tester.pump(const Duration(milliseconds: 16));
      final retargeted = _stack(tester).debugOffset;
      expect(retargeted, greaterThan(0),
          reason: 'reversing tabs must not teleport the visible page across zero');
      expect(retargeted, lessThanOrEqualTo(midway),
          reason: 'the page continues toward its resting position');

      await tester.pump(const Duration(milliseconds: 600));
      expect(_stack(tester).debugOffset, 0);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('reduced motion: fade only, no offset', (tester) async {
      reducedMotion(tester);
      final (state, f) = await bootApp(tester);
      await tester.tap(find.text('Серверы'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_stack(tester).debugOffset, 0);
      expect(_opacityOf(tester, find.byType(IndexedStack)), lessThan(1));
      await tester.pump(const Duration(milliseconds: 80));
      expect(_stack(tester).debugOffset, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_opacityOf(tester, find.byType(IndexedStack)), 1);
      await shutdownApp(tester, state, features: f);
    });
  });

  group('showMelsiSheet', () {
    testWidgets('phone: switcher opens with a spring and leaves no ticker behind', (tester) async {
      final (state, f) = await bootApp(tester);
      await state.importText(kSampleVless);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-node-panel')));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Выбор сервера'), findsOneWidget);
      await settle(tester);
      await _closeTopRoute(tester);
      expect(find.text('Выбор сервера'), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('phone: throwing the sheet down dismisses it', (tester) async {
      final (state, f) = await bootApp(tester);
      await state.importText(kSampleVless);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-node-panel')));
      await settle(tester);
      expect(find.text('Выбор сервера'), findsOneWidget);
      await tester.fling(find.text('Выбор сервера'), const Offset(0, 300), 2500);
      await settle(tester);
      expect(find.text('Выбор сервера'), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('phone, reduced motion: cross-fade, still closes cleanly', (tester) async {
      reducedMotion(tester);
      final (state, f) = await bootApp(tester);
      await state.importText(kSampleVless);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-node-panel')));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('Выбор сервера'), findsOneWidget);
      expect(find.byType(FadeTransition), findsWidgets);
      await settle(tester);
      await _closeTopRoute(tester);
      expect(find.text('Выбор сервера'), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('desktop: switcher is a scaled dialog that closes cleanly', (tester) async {
      final (state, f) = await bootApp(tester, size: const Size(1280, 800));
      await state.importText(kSampleVless);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-node-panel')));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Выбор сервера'), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.ancestor(of: find.byType(Dialog), matching: find.byType(ScaleTransition)),
          findsOneWidget);
      await settle(tester);
      await _closeTopRoute(tester);
      expect(find.text('Выбор сервера'), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('desktop, reduced motion: fade only', (tester) async {
      reducedMotion(tester);
      final (state, f) = await bootApp(tester, size: const Size(1280, 800));
      await state.importText(kSampleVless);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('home-node-panel')));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Выбор сервера'), findsOneWidget);
      expect(find.ancestor(of: find.byType(Dialog), matching: find.byType(ScaleTransition)),
          findsNothing);
      expect(find.ancestor(of: find.byType(Dialog), matching: find.byType(FadeTransition)),
          findsWidgets);
      await settle(tester);
      await _closeTopRoute(tester);
      await shutdownApp(tester, state, features: f);
    });
  });

  group('StaggeredEntrance', () {
    testWidgets('rows enter staggered and settle within 600ms', (tester) async {
      await tester.pumpWidget(_entranceApp(['a', 'b', 'c']));
      expect(_opacityOf(tester, find.text('a')), 0);
      expect(_opacityOf(tester, find.text('c')), lessThan(1));
      await tester.pump(const Duration(milliseconds: 100));
      // The stagger: the first row is ahead of the third.
      expect(_opacityOf(tester, find.text('a')), greaterThan(_opacityOf(tester, find.text('c'))));
      await tester.pump(const Duration(milliseconds: 500));
      for (final l in ['a', 'b', 'c']) {
        expect(_opacityOf(tester, find.text(l)), 1, reason: 'row $l settled');
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a group shown once never replays', (tester) async {
      await tester.pumpWidget(_entranceApp(['a', 'b', 'c']));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_entranceApp(['a', 'b', 'c']));
      for (final l in ['a', 'b', 'c']) {
        expect(_opacityOf(tester, find.text(l)), 1, reason: 'row $l is instant');
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reset arms the group again; other groups are independent', (tester) async {
      await tester.pumpWidget(_entranceApp(['a']));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      StaggeredEntrance.reset('g');
      await tester.pumpWidget(_entranceApp(['a']));
      expect(_opacityOf(tester, find.text('a')), 0);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_entranceApp(['x'], group: 'other'));
      expect(_opacityOf(tester, find.text('x')), 0);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('rows past the cap and reduced motion appear instantly', (tester) async {
      final many = [for (var i = 0; i < 14; i++) 'r$i'];
      await tester.pumpWidget(_entranceApp(many));
      expect(_opacityOf(tester, find.text('r11')), 0);
      expect(_opacityOf(tester, find.text('r12')), 1);
      expect(_opacityOf(tester, find.text('r13')), 1);
      await tester.pump(const Duration(milliseconds: 900));
      expect(_opacityOf(tester, find.text('r11')), 1);
      await tester.pumpWidget(const SizedBox());

      StaggeredEntrance.debugReset();
      await tester.pumpWidget(_entranceApp(['a', 'b', 'c'], reduce: true));
      for (final l in ['a', 'b', 'c']) {
        expect(_opacityOf(tester, find.text(l)), 1, reason: 'row $l under reduced motion');
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    test('delay is 28ms per row, capped at 300ms', () {
      expect(StaggeredEntrance.delayFor(0), Duration.zero);
      expect(StaggeredEntrance.delayFor(3), const Duration(milliseconds: 84));
      expect(StaggeredEntrance.delayFor(11), const Duration(milliseconds: 300));
    });
  });
}
