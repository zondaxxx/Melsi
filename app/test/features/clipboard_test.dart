import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/main.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';
import 'package:melsi/state/store.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

const _offerKey = ValueKey('clipboard-offer');
const _addKey = ValueKey('clipboard-offer-add');
const _linkText = 'В буфере ссылка на сервер';

/// [bootApp] with a fake clipboard: the harness builds its own state, so
/// the features (which need the same state) are wired here by hand.
Future<(AppState, Features)> _boot(
  WidgetTester tester, {
  required Future<String?> Function() read,
  bool? watch = true,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final state = testState(data: {
    'settings': {'clipboardWatch': ?watch},
  });
  await state.load();
  state.settings.locale ??= 'ru';
  final f = testFeatures(state, readClipboard: read);
  await f.init();
  await tester.pumpWidget(MelsiApp(state: state, features: f, launchMoment: false));
  await tester.pump(const Duration(milliseconds: 500));
  return (state, f);
}

/// Lets the toast spring all the way out.
Future<void> _settleOut(WidgetTester tester) async {
  await settle(tester);
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('offers a link found on the clipboard; Add imports it; then stays quiet',
      (tester) async {
    stubPlatformChannels(tester);
    var reads = 0;
    final (state, f) = await _boot(tester, read: () async {
      reads++;
      return kSampleVless;
    });
    expect(reads, 1, reason: 'checked once at load');
    expect(find.text(_linkText), findsOneWidget);

    f.onResume();
    await settle(tester);
    expect(reads, 2);
    expect(find.text(_linkText), findsOneWidget, reason: 'the same offer stays');

    await tester.tap(find.byKey(_addKey));
    await _settleOut(tester);
    expect(state.nodes, hasLength(1));
    expect(state.nodes.single.name, contains('Netherlands'));
    expect(state.settings.lastClipboardHash, ClipboardWatcher.fingerprint(kSampleVless));
    expect(f.clipboard.offer, isNull);
    expect(find.text(_linkText), findsNothing);

    f.onResume();
    await settle(tester);
    expect(f.clipboard.offer, isNull);
    expect(find.text(_linkText), findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('disabled: the clipboard is never read', (tester) async {
    var reads = 0;
    final (state, f) = await _boot(tester, watch: false, read: () async {
      reads++;
      return kSampleVless;
    });
    f.onResume();
    await settle(tester);
    expect(reads, 0);
    expect(f.clipboard.enabled, isFalse);
    expect(f.clipboard.offer, isNull);
    expect(find.byKey(_offerKey), findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('auto-dismiss after 8s keeps the fingerprint only, never the text',
      (tester) async {
    final (state, f) = await _boot(tester, read: () async => kSampleVless);
    expect(f.clipboard.offer, isNotNull);
    await tester.pump(const Duration(seconds: 9));
    await _settleOut(tester);
    expect(f.clipboard.offer, isNull);
    expect(find.byKey(_offerKey), findsNothing);
    expect(state.settings.lastClipboardHash, ClipboardWatcher.fingerprint(kSampleVless));
    expect(state.nodes, isEmpty);
    final persisted = jsonEncode((state.store as MemoryStateStore).data);
    expect(persisted, isNot(contains('nl1.example.com')));
    expect(persisted, isNot(contains('bf000d23')));
    expect(persisted, contains(state.settings.lastClipboardHash!));

    f.onResume();
    await settle(tester);
    expect(f.clipboard.offer, isNull, reason: 'a dismissed clipboard is not offered again');
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('the close glyph dismisses; a new clipboard is offered again (reduced motion)',
      (tester) async {
    stubPlatformChannels(tester);
    reducedMotion(tester);
    var text = kSampleVless;
    final (state, f) = await _boot(tester, read: () async => text);
    expect(find.byKey(_offerKey), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(_offerKey), matching: find.byIcon(Icons.close_rounded)));
    await _settleOut(tester);
    expect(f.clipboard.offer, isNull);
    expect(find.byKey(_offerKey), findsNothing);

    text = 'https://sub.example.com/api/v1/abc?token=1';
    f.onResume();
    await settle(tester);
    expect(find.text('В буфере подписка (sub.example.com)'), findsOneWidget);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('classifies subscriptions and lists; skips junk and what is already added',
      (tester) async {
    final state = testState(data: {
      'settings': {'clipboardWatch': true}
    });
    await state.load();
    String? text = 'https://sub.example.com/api/v1/abc';
    var boom = false;
    final f = testFeatures(state, readClipboard: () async {
      if (boom) throw StateError('no clipboard');
      return text;
    });
    await f.init();
    final w = f.clipboard;
    // load() fires the first check without awaiting it; settle it here.
    await w.check();
    expect(w.offer?.kind, ClipboardOfferKind.subscription);
    expect(w.offer?.host, 'sub.example.com');
    w.dismiss();

    final second = kSampleVless.replaceAll('nl1.example.com', 'de1.example.com');
    text = '$kSampleVless\n$second';
    await w.check();
    expect(w.offer?.kind, ClipboardOfferKind.many);
    expect(w.offer?.count, 2);
    w.dismiss();

    text = 'hello world';
    await w.check();
    expect(w.offer, isNull);

    text = '   ';
    await w.check();
    expect(w.offer, isNull);

    boom = true;
    text = kSampleVless;
    await w.check();
    expect(w.offer, isNull, reason: 'a throwing reader is swallowed');
    boom = false;

    await state.importText(kSampleVless);
    await w.check();
    expect(w.offer, isNull, reason: 'the link is already a node');

    // Only the last fingerprint is kept: the list dismissed above is
    // remembered, the subscription dismissed before it is fair game again.
    text = '$kSampleVless\n$second';
    await w.check();
    expect(w.offer, isNull, reason: 'the last dismissed clipboard is remembered');
    text = 'https://sub.example.com/api/v1/abc';
    await w.check();
    expect(w.offer?.kind, ClipboardOfferKind.subscription);
    w.dismiss();

    // A single link inside a multi-line blob is still one link.
    text = '\n$second\n';
    await w.check();
    expect(w.offer?.kind, ClipboardOfferKind.link);
    expect(await w.accept(), 1);
    expect(state.nodes, hasLength(2));
    f.dispose();
    state.dispose();
  });

  testWidgets('empty state hint: "Нашли ссылку в буфере — Добавить" imports', (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await _boot(tester, read: () async => kSampleVless);
    await tester.tap(find.text('Серверы'));
    await settle(tester);
    final hint = find.textContaining('Нашли ссылку в буфере', findRichText: true);
    expect(hint, findsOneWidget);

    // Fire the "Добавить" span's recognizer (tapping the centre of a
    // Text.rich lands on whichever span happens to be there).
    final rich = tester.widget<RichText>(find.descendant(
        of: find.byKey(const ValueKey('clipboard-hint')), matching: find.byType(RichText)));
    TapGestureRecognizer? tap;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
        tap = span.recognizer as TapGestureRecognizer;
      }
      return tap == null;
    });
    expect(tap, isNotNull);
    tap!.onTap!();
    await _settleOut(tester);
    expect(state.nodes, hasLength(1));
    expect(find.textContaining('Нашли ссылку в буфере', findRichText: true), findsNothing);
    expect(find.text('Пока нет серверов'), findsNothing);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('wide layout: the toast sits top-right and never covers the sidebar',
      (tester) async {
    final (state, f) = await _boot(tester, size: const Size(1280, 800), read: () async => kSampleVless);
    final box = tester.getRect(find.byKey(_offerKey));
    expect(box.top, lessThan(60));
    expect(box.right, closeTo(1280 - 16, 1));
    expect(box.width, lessThanOrEqualTo(400));
    expect(box.left, greaterThan(236), reason: 'clear of the sidebar');
    // The page underneath still takes taps.
    await tester.tap(find.text('Серверы'));
    await settle(tester);
    expect(find.text('Пока нет серверов'), findsOneWidget);
    await shutdownApp(tester, state, features: f);
  });

  testWidgets('settings: the switch flips clipboardWatch without touching the config',
      (tester) async {
    stubPlatformChannels(tester);
    final (state, f) = await _boot(tester, watch: null, read: () async => null);
    expect(state.settings.clipboardWatch, isNull);
    expect(f.clipboard.enabled, !state.isIOS, reason: 'platform default');
    await tester.tap(find.text('Настройки'));
    await settle(tester);
    final row = find.text('Предлагать импорт из буфера');
    await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    await settle(tester);
    expect(row, findsOneWidget);
    expect(find.textContaining('только его отпечаток'), findsOneWidget);
    await tester.tap(row);
    await settle(tester);
    expect(state.settings.clipboardWatch, state.isIOS, reason: 'flipped from the platform default');
    expect(f.clipboard.enabled, state.isIOS);
    expect(state.needsReconnect, isFalse);
    await tester.tap(row);
    await settle(tester);
    expect(state.settings.clipboardWatch, !state.isIOS);
    await shutdownApp(tester, state, features: f);
  });
}
