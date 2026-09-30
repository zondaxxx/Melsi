import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Two-series speed sparkline (download filled, upload line), smoothed with
/// monotone cubic segments. Scales to the max of both series.
class SpeedChartPainter extends CustomPainter {
  SpeedChartPainter({
    required this.down,
    required this.up,
    required this.downColor,
    required this.upColor,
    required this.gridColor,
    super.repaint,
  });

  final List<double> down;
  final List<double> up;
  final Color downColor;
  final Color upColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = math.max(
        1024.0 * 8, math.max(down.fold<double>(0, math.max), up.fold<double>(0, math.max)));
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    void series(List<double> data, Color color, {required bool fill}) {
      if (data.length < 2 || data.every((v) => v <= 0)) return;
      final path = smoothPath(data, size, maxV * 1.15);
      if (fill) {
        final area = Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0.0)],
            ).createShader(Offset.zero & size),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = fill ? 2.2 : 1.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    series(down, downColor, fill: true);
    series(up, upColor, fill: false);
  }

  @override
  bool shouldRepaint(SpeedChartPainter old) => true;
}

/// Latency line with a soft band; null samples break the line and show a
/// small red tick at the bottom.
class LatencyChartPainter extends CustomPainter {
  LatencyChartPainter({
    required this.samples,
    required this.color,
    required this.failColor,
    required this.gridColor,
    this.capacity = 60,
  });

  final List<int?> samples;
  final Color color;
  final Color failColor;
  final Color gridColor;
  final int capacity;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (samples.isEmpty) return;
    final maxV = math.max(
        60, samples.whereType<int>().fold<int>(0, math.max)).toDouble() * 1.25;
    final dx = size.width / (capacity - 1);
    final start = capacity - samples.length;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Path? path;
    Offset? last;
    for (var i = 0; i < samples.length; i++) {
      final x = (start + i) * dx;
      final v = samples[i];
      if (v == null) {
        canvas.drawLine(Offset(x, size.height - 4), Offset(x, size.height),
            Paint()
              ..color = failColor
              ..strokeWidth = 2);
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
      canvas.drawCircle(last, 6, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawCircle(last, 3, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(LatencyChartPainter old) => true;
}

/// Smooth path through evenly spaced samples.
Path smoothPath(List<double> data, Size size, double maxV) {
  final n = data.length;
  final dx = size.width / (n - 1);
  Offset pt(int i) =>
      Offset(i * dx, size.height - (data[i] / maxV).clamp(0, 1) * (size.height - 2) - 1);
  final path = Path()..moveTo(0, pt(0).dy);
  for (var i = 1; i < n; i++) {
    final a = pt(i - 1), b = pt(i);
    final mid = (a.dx + b.dx) / 2;
    path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
  }
  return path;
}
