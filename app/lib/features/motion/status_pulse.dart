import 'package:flutter/widgets.dart';

import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import 'feedback.dart';

/// Status dot that breathes softly while [active]: every 4 s one ring leaves
/// the dot (size → 2.2×size) and fades over the first 900 ms — a slow pulse,
/// not a blink. The ring paints outside the dot's box, so the layout around
/// it never changes.
///
/// The repeating controller exists only while [active] (it is cancelled on
/// `!active` and on dispose — the pulse is the one loop in the app, and it
/// runs only while connected). Reduced motion: a solid dot.
///
/// Turning to the danger colour also shakes the dot once — the headline's
/// half of the error grammar (the route line does the other half), since the
/// screens that place this dot cannot be edited by the motion feature.
class StatusPulse extends StatefulWidget {
  const StatusPulse({
    super.key,
    required this.color,
    this.size = 8,
    this.hollow = false,
    this.active = false,
  });
  final Color color;
  final double size;
  final bool hollow;
  final bool active;

  /// Full breath cycle.
  static const Duration period = Duration(seconds: 4);

  /// The ring's life within a cycle.
  static const Duration ring = Duration(milliseconds: 900);

  @override
  State<StatusPulse> createState() => StatusPulseState();
}

class StatusPulseState extends State<StatusPulse> with SingleTickerProviderStateMixin {
  AnimationController? _pulse;
  int _shake = 0;

  /// Whether the dot was born in the danger colour (the headline swaps
  /// dots per status, so an error dot usually arrives rather than turns).
  bool? _bornDanger;

  /// Whether the breathing controller exists and runs (tests).
  bool get debugPulseActive => _pulse?.isAnimating ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bornDanger ??= _isDanger;
    _sync();
  }

  @override
  void didUpdateWidget(StatusPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
    if (oldWidget.color != widget.color && _isDanger) _shake++;
  }

  bool get _isDanger => widget.color.toARGB32() == context.c.danger.toARGB32();

  /// Creates or cancels the controller so it matches [StatusPulse.active]
  /// and the reduced-motion setting.
  void _sync() {
    final want = widget.active && !context.reduceMotion;
    if (want && _pulse == null) {
      _pulse = AnimationController(vsync: this, duration: StatusPulse.period)..repeat();
    } else if (!want && _pulse != null) {
      _pulse!.dispose();
      _pulse = null;
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    _pulse = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = StatusDot(widget.color, size: widget.size, hollow: widget.hollow);
    final p = _pulse;
    // Its own layer: the ring repaints every frame for the whole session
    // and must not drag the page along. Layers do not clip, so the ring may
    // still spill past the dot's box.
    final child = p == null
        ? dot
        : RepaintBoundary(
            child: CustomPaint(
              painter: _RingPainter(progress: p, color: widget.color, size: widget.size),
              child: dot,
            ),
          );
    return Shake(trigger: _shake, shakeOnMount: _bornDanger ?? false, child: child);
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.size})
      : super(repaint: progress);
  final Animation<double> progress;
  final Color color;
  final double size;

  @override
  void paint(Canvas canvas, Size box) {
    final t = progress.value * StatusPulse.period.inMilliseconds / StatusPulse.ring.inMilliseconds;
    if (t >= 1) return;
    final e = Curves.easeOut.transform(t.clamp(0.0, 1.0));
    final r = size / 2 + (size * 1.1 - size / 2) * e;
    canvas.drawCircle(
      box.center(Offset.zero),
      r,
      Paint()
        ..color = color.withValues(alpha: 0.35 * (1 - e))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.size != size || oldDelegate.progress != progress;
}
