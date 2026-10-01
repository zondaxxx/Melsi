// Feedback grammar: the one haptic map, the error shake and the
// self-drawing check. Every other feature says "success" or "error" through
// these, so the app answers the same way everywhere.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../ui/theme/theme.dart';

/// The four haptics the app uses, named by meaning rather than strength so
/// callers do not have to remember which impact is which. Desktops have no
/// taptic engine: every call is a no-op there (decided by
/// [defaultTargetPlatform], so tests — which report Android — still exercise
/// the calls, harmlessly).
abstract final class Haptics {
  static bool get _supported => switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.android => true,
        _ => false,
      };

  /// A control was pressed.
  static void tap() {
    if (_supported) HapticFeedback.lightImpact();
  }

  /// A value was picked (segmented, list row, toggle).
  static void select() {
    if (_supported) HapticFeedback.selectionClick();
  }

  /// Something completed (connected, imported, copied).
  static void success() {
    if (_supported) HapticFeedback.mediumImpact();
  }

  /// Something failed.
  static void error() {
    if (_supported) HapticFeedback.heavyImpact();
  }
}

/// One-shot horizontal shake: a loose spring kicked sideways, ±[amplitude]
/// px, dead in about 450 ms. Bump [trigger] to shake again; the same value
/// never re-shakes, so a rebuild is not a shake. Reduced motion: no
/// displacement at all.
class Shake extends StatefulWidget {
  const Shake({
    super.key,
    required this.trigger,
    required this.child,
    this.amplitude = 4,
    this.shakeOnMount = false,
  });

  /// Monotonic counter; every change fires one shake.
  final int trigger;
  final Widget child;
  final double amplitude;

  /// Also shake once right after the first frame (for a widget that is
  /// created already in its error state).
  final bool shakeOnMount;

  @override
  State<Shake> createState() => ShakeState();
}

class ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  /// Loose (ζ 0.35) so it swings through zero a few times, short response
  /// so those swings are quick — a shake, not a wobble.
  static final SpringDescription _spring = Springs.of(0.28, 0.35);
  static const double _kick = 240;

  /// Peak excursion of the spring kicked from rest at [_kick] px/s. The
  /// rendered offset is normalised by it so the shake is exactly
  /// ±[Shake.amplitude] regardless of spring maths.
  static final double _peak = () {
    final sim = SpringSimulation(_spring, 0, 0, _kick);
    var peak = 0.0;
    for (var t = 0.0; t < 0.6; t += 0.004) {
      final x = sim.x(t).abs();
      if (x > peak) peak = x;
    }
    return peak == 0 ? 1.0 : peak;
  }();

  late final AnimationController _c = AnimationController.unbounded(vsync: this);
  bool _mounted = false;

  /// Current horizontal offset in px (tests).
  double get debugOffset => _c.value / _peak * widget.amplitude;
  bool get debugAnimating => _c.isAnimating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mounted) return;
    _mounted = true;
    if (widget.shakeOnMount) _shake();
  }

  @override
  void didUpdateWidget(Shake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) _shake();
  }

  void _shake() {
    if (context.reduceMotion) return;
    _c.value = 0;
    _c.springTo(0, spring: _spring, velocity: _kick).then((_) {
      // Settle to a whole pixel so the child never rests blurred.
      if (mounted) _c.value = 0;
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: Offset(debugOffset, 0),
          child: child,
        ),
      );
}

/// A check mark that draws itself: after a 60 ms beat the stroke runs along
/// its path over 260 ms (ease-out cubic). One-shot on mount. Reduced motion:
/// the finished glyph, no drawing.
class CheckDraw extends StatefulWidget {
  const CheckDraw({super.key, this.size = 18, this.color, this.strokeWidth = 2});

  final double size;

  /// Defaults to `c.success`.
  final Color? color;
  final double strokeWidth;

  static const Duration beat = Duration(milliseconds: 60);
  static const Duration draw = Duration(milliseconds: 260);

  @override
  State<CheckDraw> createState() => CheckDrawState();
}

class CheckDrawState extends State<CheckDraw> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: CheckDraw.beat + CheckDraw.draw);
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(
      CheckDraw.beat.inMilliseconds / (CheckDraw.beat + CheckDraw.draw).inMilliseconds,
      1,
      curve: Curves.easeOutCubic,
    ),
  );
  bool _started = false;

  /// 0…1 of the path drawn (tests).
  double get debugProgress => _t.value;
  bool get debugAnimating => _c.isAnimating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (context.reduceMotion) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(
            painter: _CheckPainter(
              progress: _t,
              color: widget.color ?? context.c.success,
              strokeWidth: widget.strokeWidth,
            ),
          ),
        ),
      );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.progress, required this.color, required this.strokeWidth})
      : super(repaint: progress);
  final Animation<double> progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0) return;
    final s = size.shortestSide;
    final path = Path()
      ..moveTo(s * 0.2, s * 0.53)
      ..lineTo(s * 0.42, s * 0.75)
      ..lineTo(s * 0.8, s * 0.3);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (t >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    // Draw the first t of the path's length: the stroke runs along it.
    for (final ui.PathMetric m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * t), paint);
    }
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth || oldDelegate.progress != progress;
}
