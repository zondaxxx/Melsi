import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/ui/theme/theme.dart';
import 'package:melsi/ui/widgets/brand_wordmark.dart';

import 'harness.dart' show reducedMotion;

Widget subject({bool glow = true, bool enabled = true}) => MaterialApp(
  theme: buildTheme(Brightness.dark),
  home: TickerMode(
    enabled: enabled,
    child: Center(child: Wordmark(size: 80, glow: glow)),
  ),
);

void main() {
  testWidgets('hero uses bundled Inter and a finite glow', (tester) async {
    await tester.pumpWidget(subject());
    final initial = tester.widget<Text>(find.text('Melsi')).style!;
    expect(initial.fontFamily, 'Inter');
    expect(initial.fontSize, 80);
    await tester.pump(const Duration(milliseconds: 1200));
    final peak = tester.widget<Text>(find.text('Melsi')).style!;
    expect(peak.shadows!.first.blurRadius, greaterThan(initial.shadows!.first.blurRadius));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.binding.hasScheduledFrame, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion does not schedule the glow', (tester) async {
    reducedMotion(tester);
    await tester.pumpWidget(subject());
    final before = tester.widget<Text>(find.text('Melsi')).style!;
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(find.text('Melsi')).style, before);
    expect(tester.binding.hasScheduledFrame, false);
  });

  testWidgets('muted subtree and regular wordmark stay still', (tester) async {
    await tester.pumpWidget(subject(enabled: false));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.hasScheduledFrame, false);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(subject(glow: false));
    await tester.pump();
    expect(tester.widget<Text>(find.text('Melsi')).style!.shadows, isNull);
    expect(tester.binding.hasScheduledFrame, false);
  });

  test('brand button color provides readable white text in both themes', () {
    for (final colors in [MelsiColors.light, MelsiColors.dark]) {
      expect(colors.accent, const Color(0xff7053e8));
      final contrast = (colors.onAccent.computeLuminance() + 0.05) /
          (colors.accent.computeLuminance() + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    }
  });
}
