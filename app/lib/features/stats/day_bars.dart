import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ui/theme/theme.dart';
import 'stats_models.dart';

/// Per-day traffic bars: download in the label colour with upload stacked
/// on top in the secondary one — the same two tones the speed chart uses,
/// so the series read apart without colour. A hairline baseline, optional
/// mono letters under chosen bars, the last bar (today, still counting)
/// outlined instead of filled. [progress] scales every bar from the
/// baseline (the grow-in on first paint); [highlight] tints one column.
class DayBarsPainter extends CustomPainter {
  DayBarsPainter({
    required this.days,
    required this.downColor,
    required this.upColor,
    required this.baselineColor,
    required this.labelStyle,
    this.labels = const {},
    this.progress = 1,
    this.highlight,
    this.highlightColor,
    this.outlineLast = true,
    this.labelHeight = 14,
  });

  final List<DayTotal> days;
  final Color downColor;
  final Color upColor;
  final Color baselineColor;
  final TextStyle labelStyle;

  /// Bar index → text painted under it.
  final Map<int, String> labels;
  final double progress;
  final int? highlight;
  final Color? highlightColor;
  final bool outlineLast;

  /// Space reserved under the baseline for [labels] (0 when there are none).
  final double labelHeight;

  /// Largest day total (what the bars are scaled to), at least 1 byte.
  static int peak(List<DayTotal> days) =>
      math.max(1, days.fold<int>(0, (m, d) => math.max(m, d.total)));

  /// Index of the bar under [dx] for [n] bars across [width].
  static int hitIndex(double dx, double width, int n) =>
      n == 0 ? 0 : (dx / (width / n)).floor().clamp(0, n - 1);

  @override
  void paint(Canvas canvas, Size size) {
    final n = days.length;
    if (n == 0 || size.width <= 0) return;
    final band = labels.isEmpty ? 0.0 : labelHeight;
    final plotH = size.height - band;
    final baseY = plotH - 0.5;
    final slot = size.width / n;
    // Bars keep a gap that reads as a gap at every density: ~30% of the slot
    // on wide charts, at least a pixel when 90 bars share a phone width.
    final gap = (slot * 0.3).clamp(1.0, 6.0);
    final barW = math.max(1.0, slot - gap);
    final usable = math.max(0.0, plotH - 3);
    final maxV = peak(days);
    final p = progress.clamp(0.0, 1.0);

    if (highlight != null && highlight! >= 0 && highlight! < n && highlightColor != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(highlight! * slot, 0, slot, plotH), const Radius.circular(2)),
        Paint()..color = highlightColor!,
      );
    }

    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < n; i++) {
      final d = days[i];
      if (d.total <= 0) continue;
      final x = i * slot + gap / 2;
      var downH = d.down / maxV * usable * p;
      var upH = d.up / maxV * usable * p;
      // A day with traffic is never invisible.
      if (d.down > 0 && downH < 1) downH = 1;
      if (d.up > 0 && upH < 1) upH = 1;
      final outlined = outlineLast && i == n - 1;
      void bar(double top, double h, Color color) {
        if (h <= 0) return;
        final r = RRect.fromRectAndRadius(
            Rect.fromLTWH(x, top, barW, h), const Radius.circular(1));
        if (outlined && h >= 3 && barW >= 3) {
          canvas.drawRRect(r.deflate(0.5), stroke..color = color);
        } else {
          canvas.drawRRect(r, fill..color = color);
        }
      }

      bar(baseY - downH, downH, downColor);
      bar(baseY - downH - upH, upH, upColor);
    }

    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY),
        Paint()
          ..color = baselineColor
          ..strokeWidth = 1);

    labels.forEach((i, text) {
      if (i < 0 || i >= n) return;
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final x = ((i + 0.5) * slot - tp.width / 2).clamp(0.0, math.max(0.0, size.width - tp.width)).toDouble();
      tp.paint(canvas, Offset(x, plotH + 2));
    });
  }

  @override
  bool shouldRepaint(DayBarsPainter old) =>
      old.progress != progress ||
      old.highlight != highlight ||
      old.days.length != days.length ||
      !_sameDays(old.days, days) ||
      old.labels != labels ||
      old.downColor != downColor ||
      old.upColor != upColor ||
      old.baselineColor != baselineColor ||
      old.highlightColor != highlightColor ||
      old.outlineLast != outlineLast ||
      old.labelStyle != labelStyle;

  static bool _sameDays(List<DayTotal> a, List<DayTotal> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// [DayBarsPainter] in the app's colours: download in the label colour,
/// upload secondary, the baseline a separator hairline, labels in small
/// tertiary mono.
class DayBars extends StatelessWidget {
  const DayBars({
    super.key,
    required this.days,
    this.labels = const {},
    this.progress = 1,
    this.highlight,
  });

  final List<DayTotal> days;
  final Map<int, String> labels;
  final double progress;
  final int? highlight;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return CustomPaint(
      size: Size.infinite,
      painter: DayBarsPainter(
        days: days,
        labels: labels,
        progress: progress,
        highlight: highlight,
        highlightColor: c.fill,
        downColor: c.label,
        upColor: c.secondaryLabel,
        baselineColor: c.separator,
        labelStyle: context.t.monoSmall.copyWith(fontSize: 10, color: c.tertiaryLabel),
      ),
    );
  }
}
