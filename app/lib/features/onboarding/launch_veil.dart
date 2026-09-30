import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../ui/shell.dart' show Wordmark;
import '../../ui/theme/theme.dart';

/// Cold-start brand moment layered over the app: an opaque sheet in the page
/// colour with the wordmark, a hairline that draws itself underneath, then a
/// fade while the wordmark drifts up and settles. 480ms end to end, one
/// controller, one shot — a resume never replays it because the controller
/// is created once in [initState]. A tap in the first 300ms hurries it; past
/// that the veil no longer catches pointers, so it can never block the app.
/// With reduced motion it is a plain 160ms fade.
///
/// [enabled] false builds [child] directly (tests, screenshots).
class LaunchVeil extends StatefulWidget {
  const LaunchVeil({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  /// The overlay itself carries this key; it leaves the tree when done.
  static const Key veilKey = ValueKey('launch-veil');

  @override
  State<LaunchVeil> createState() => LaunchVeilState();
}

/// Timeline (milliseconds of the 480ms run).
const _kTotalMs = 480.0;
const _kLineStartMs = 60.0;
const _kLineEndMs = 300.0;
const _kFadeStartMs = 240.0;
const _kTapUntilMs = 300.0;
const _kReducedMs = 160;
const _kHurryMs = 120;

class LaunchVeilState extends State<LaunchVeil> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  bool _done = false;
  bool _reduce = false;
  bool _started = false;

  /// 0…1 progress of the run; 1 once the veil has left the tree. Exposed
  /// for tests only.
  double get debugProgress => _done ? 1 : (_c?.value ?? 0);

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _done = true;
      return;
    }
    // Reduced motion is handled here (a real 160ms fade), so the framework's
    // own 5% time-scaling for disabled animations is opted out of.
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion is only known once MediaQuery is reachable, so the
    // run starts here — exactly once; later dependency changes are ignored.
    if (_started || _done) return;
    _started = true;
    _reduce = context.reduceMotion;
    final c = _c!;
    if (_reduce) c.duration = const Duration(milliseconds: _kReducedMs);
    c.forward();
  }

  void _onStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || _done) return;
    setState(() => _done = true);
    // The AnimatedBuilder below still listens during this frame; release
    // the controller once the tree without the veil has been built.
    SchedulerBinding.instance.addPostFrameCallback((_) => _disposeController());
  }

  void _disposeController() {
    _c?.dispose();
    _c = null;
  }

  void _hurry() {
    final c = _c;
    if (c == null || _done || c.isCompleted) return;
    if (c.value * _kTotalMs >= _kTapUntilMs) return;
    c.animateTo(1, duration: const Duration(milliseconds: _kHurryMs), curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final showing = !_done && c != null;
    // The Stack stays whether or not the veil is showing, so removing the
    // overlay never re-parents (and so re-creates) the app underneath.
    return LaunchVeilScope(
      active: showing,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (showing)
            Positioned.fill(
              key: LaunchVeil.veilKey,
              // Above the Scaffold, so it brings its own Material: without
              // one the wordmark would draw in the fallback text style.
              child: Material(
                type: MaterialType.transparency,
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) =>
                      _reduce ? _reducedFrame(context, c.value) : _frame(context, c.value),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Reduced motion: the sheet with the wordmark simply fades away.
  Widget _reducedFrame(BuildContext context, double v) {
    final colors = context.c;
    return IgnorePointer(
      child: Opacity(
        opacity: 1 - Curves.easeIn.transform(v),
        child: ColoredBox(
          color: colors.background,
          child: const Center(child: Wordmark(size: 26)),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, double v) {
    final colors = context.c;
    final ms = v * _kTotalMs;
    final line = Curves.easeOutCubic.transform(_unit(ms, _kLineStartMs, _kLineEndMs));
    final out = Curves.easeInCubic.transform(_unit(ms, _kFadeStartMs, _kTotalMs));
    final ignoring = ms >= _kTapUntilMs;
    return IgnorePointer(
      ignoring: ignoring,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: ignoring ? null : _hurry,
        child: Opacity(
          opacity: 1 - out,
          child: ColoredBox(
            color: colors.background,
            child: Center(
              child: Transform.translate(
                offset: Offset(0, -10 * out),
                child: Transform.scale(
                  scale: 1 - 0.02 * out,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Wordmark(size: 26),
                      const SizedBox(height: Space.m),
                      DrawnHairline(
                        progress: line,
                        width: 56,
                        color: colors.label.withValues(alpha: 0.3),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tells descendants whether the veil is still covering them, so a brand
/// moment underneath (the onboarding's) can wait for it to lift instead of
/// playing twice at once. Absent (no veil in the tree) reads as inactive.
class LaunchVeilScope extends InheritedWidget {
  const LaunchVeilScope({super.key, required this.active, required super.child});
  final bool active;

  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LaunchVeilScope>()?.active ?? false;

  @override
  bool updateShouldNotify(LaunchVeilScope old) => old.active != active;
}

/// Maps [ms] onto 0…1 between [from] and [to] (clamped).
double _unit(double ms, double from, double to) => ((ms - from) / (to - from)).clamp(0.0, 1.0);

/// A 1px hairline that draws itself left→right: [progress] 0…1 is the drawn
/// fraction of [width]. Shared by the launch veil and the onboarding brand
/// moment so the two read as one gesture.
class DrawnHairline extends StatelessWidget {
  const DrawnHairline({
    super.key,
    required this.progress,
    required this.color,
    this.width = 56,
  });

  final double progress;
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(width, kHairline),
        painter: _HairlinePainter(progress: progress, color: color),
      );
}

class _HairlinePainter extends CustomPainter {
  const _HairlinePainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.height
      ..strokeCap = StrokeCap.butt;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width * progress.clamp(0.0, 1.0), y), paint);
  }

  @override
  bool shouldRepaint(_HairlinePainter old) => old.progress != progress || old.color != color;
}
