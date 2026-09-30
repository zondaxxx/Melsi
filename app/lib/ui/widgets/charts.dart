import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Dash pattern shared by the upload trace and its legend swatch.
const List<double> kUploadDash = [4, 3];

/// Returns [path] cut into dashes of [pattern] (on, off, on, off …).
Path dashPath(Path path, List<double> pattern) {
  final out = Path();
  for (final metric in path.computeMetrics()) {
    var d = 0.0;
    var i = 0;
    while (d < metric.length) {
      final len = pattern[i % pattern.length];
      if (i.isEven) out.addPath(metric.extractPath(d, d + len), Offset.zero);
      d += len;
      i++;
    }
  }
  return out;
}

/// A 12px line sample: solid or dashed in the series' colour. Sits before a
/// chart caption so the header doubles as the legend.
class SeriesSwatch extends StatelessWidget {
  const SeriesSwatch({super.key, required this.color, this.dashed = false, this.width = 12});
  final Color color;
  final bool dashed;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(width, 4),
        painter: _SwatchPainter(color: color, dashed: dashed),
      );
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter({required this.color, required this.dashed});
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    var path = Path()
      ..moveTo(0, y)
      ..lineTo(size.width, y);
    if (dashed) path = dashPath(path, kUploadDash);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = dashed ? 1.25 : 1.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.color != color || old.dashed != dashed;
}

/// Two-series speed sparkline: thin lines, no grid — the panel prints the
/// peak value instead. Download is the solid label-colour line, upload a
/// dashed secondary one, so the series read apart without colour. Scales to
/// the max of both series.
class SpeedChartPainter extends CustomPainter {
  SpeedChartPainter({
    required this.down,
    required this.up,
    required this.downColor,
    required this.upColor,
    super.repaint,
  });

  final List<double> down;
  final List<double> up;
  final Color downColor;
  final Color upColor;

  /// The value the chart is scaled to (max of both series, at least 8 KB/s).
  static double peak(List<double> down, List<double> up) => math.max(
      1024.0 * 8, math.max(down.fold<double>(0, math.max), up.fold<double>(0, math.max)));

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = peak(down, up);

    void series(List<double> data, Color color, double width, {bool dashed = false}) {
      if (data.length < 2 || data.every((v) => v <= 0)) return;
      var path = smoothPath(data, size, maxV * 1.15);
      if (dashed) path = dashPath(path, kUploadDash);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    series(up, upColor, 1.25, dashed: true);
    series(down, downColor, 1.5);
  }

  @override
  bool shouldRepaint(SpeedChartPainter old) => true;
}

/// Latency line, no grid; null samples break the line and show a small red
/// tick at the bottom. The latest sample gets a dot.
class LatencyChartPainter extends CustomPainter {
  LatencyChartPainter({
    required this.samples,
    required this.color,
    required this.failColor,
    this.capacity = 60,
  });

  final List<int?> samples;
  final Color color;
  final Color failColor;
  final int capacity;

  /// Highest sample (what the chart is scaled from).
  static int? peak(List<int?> samples) {
    final v = samples.whereType<int>();
    return v.isEmpty ? null : v.fold<int>(0, math.max);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final maxV = math.max(60, peak(samples) ?? 0).toDouble() * 1.25;
    final dx = size.width / (capacity - 1);
    final start = capacity - samples.length;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Path? path;
    Offset? last;
    for (var i = 0; i < samples.length; i++) {
      final x = (start + i) * dx;
      final v = samples[i];
      if (v == null) {
        canvas.drawLine(Offset(x, size.height - 5), Offset(x, size.height),
            Paint()
              ..color = failColor
              ..strokeWidth = 1.5);
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final p = Offset(x, size.height - (v / maxV) * size.height);
      if (path == null) {
        path = Path()..moveTo(p.dx, p.dy);
      } else {
        final mid = (last!.dx + p.dx) / 2;
        path.cubicTo(mid, last.dy, mid, p.dy, p.dx, p.dy);
      }
      last = p;
    }
    if (path != null) canvas.drawPath(path, line);
    if (last != null && samples.last != null) {
      canvas.drawCircle(last, 2.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(LatencyChartPainter old) => true;
}

/// The plot floats this far above the bottom of its box, so a series at
/// zero never merges with the hairline under the chart.
const double kChartBaselinePad = 4;

/// Smooth path through evenly spaced samples.
Path smoothPath(List<double> data, Size size, double maxV) {
  final n = data.length;
  final dx = size.width / (n - 1);
  final h = size.height - kChartBaselinePad;
  Offset pt(int i) =>
      Offset(i * dx, h - (data[i] / maxV).clamp(0, 1) * (h - 2) - 1);
  final path = Path()..moveTo(0, pt(0).dy);
  for (var i = 1; i < n; i++) {
    final a = pt(i - 1), b = pt(i);
    final mid = (a.dx + b.dx) / 2;
    path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
  }
  return path;
}
