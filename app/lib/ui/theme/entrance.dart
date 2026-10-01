// One-time staggered entrance for lists, plus the spring simulation shared by
// the navigation motion (tab stack, sheets, entrances).
//
// Integration note (P3-navigation-motion): this file ships the primitive only.
// The wrap targets — `NodeRow` on the servers screen, the switcher `_Row`, the
// game chips — live outside this package's ownership; the orchestrator's
// integration pass wraps each of them in a one-line
// `StaggeredEntrance(group: 'servers', index: i, child: row)` after merge, and
// calls `StaggeredEntrance.reset('servers')` when that list becomes empty so
// the next population enters again.

import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'motion.dart';
import 'tokens.dart';

/// A spring simulation that lands *exactly* on its target once it is within
/// tolerance, optionally after a [delay] during which it holds [start].
///
/// [SpringSimulation] alone stops a hair short of the target (whatever value
/// the last tick produced), which leaves a sub-pixel offset or a 0.997 opacity
/// on the settled frame. Snapping the final sample keeps the settled page
/// pixel-exact and lets tests assert on `== 0` / `== 1`. The delay lives inside
/// the simulation (rather than a [Timer]) so it obeys [TickerMode]: an entrance
/// built offstage in an [IndexedStack] starts counting only when it becomes
/// visible, and a paused ticker never leaks a frame request.
class SettlingSpring extends Simulation {
  SettlingSpring(
    SpringDescription spring, {
    required this.start,
    required this.end,
    double velocity = 0,
    this.delay = Duration.zero,
    super.tolerance = const Tolerance(distance: 0.003, velocity: 0.05),
  }) : _spring = SpringSimulation(spring, start, end, velocity, tolerance: tolerance);

  final double start;
  final double end;
  final Duration delay;
  final SpringSimulation _spring;

  double get _delaySeconds => delay.inMicroseconds / Duration.microsecondsPerSecond;

  @override
  double x(double time) {
    final t = time - _delaySeconds;
    if (t < 0) return start;
    if (_spring.isDone(t)) return end;
    return _spring.x(t);
  }

  @override
  double dx(double time) {
    final t = time - _delaySeconds;
    if (t < 0) return 0;
    if (_spring.isDone(t)) return 0;
    return _spring.dx(t);
  }

  @override
  bool isDone(double time) {
    final t = time - _delaySeconds;
    return t >= 0 && _spring.isDone(t);
  }
}

/// Fades a list row in and lifts it 8px the *first* time its [group] appears
/// after app start, staggered by [index] (28ms per row, capped at 300ms).
///
/// The group is remembered process-wide, so scrolling, rebuilding or switching
/// tabs never replays the entrance; only [reset] (call it when the list
/// becomes empty) arms it again. Rows past [maxAnimated] and every row under
/// reduced motion appear instantly. Items built during the same frame as the
/// first sighting all take part — the group is marked "shown" at the end of
/// that frame, not on the first row's init — so a lazily built list animates
/// its first viewport and nothing more.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.group,
    required this.index,
    required this.child,
  });

  final String group;
  final int index;
  final Widget child;

  /// Rows at or beyond this index appear without animation.
  static const int maxAnimated = 12;

  /// Stagger per row and its cap.
  static const Duration step = Duration(milliseconds: 28);
  static const Duration maxDelay = Duration(milliseconds: 300);

  /// Lift distance; fixed regardless of layout width.
  static const double rise = 8;

  static final _spring = Springs.of(0.42, 1.0);

  /// Groups that have already had their entrance.
  static final Set<String> _shown = {};

  /// Groups first seen during the current frame; promoted to [_shown] once
  /// the frame ends so every sibling built in that frame still animates.
  static final Set<String> _pending = {};

  /// Arms [group] again (e.g. after its list emptied) so the next rows enter.
  static void reset(String group) {
    _shown.remove(group);
    _pending.remove(group);
  }

  /// Forgets every group. Tests call it in `setUp`.
  static void debugReset() {
    _shown.clear();
    _pending.clear();
  }

  /// Whether [group] has had (or is having) its entrance.
  static bool debugShown(String group) => _shown.contains(group) || _pending.contains(group);

  /// Reports a row of [group] being built; true if the row should animate.
  static bool _claim(String group) {
    if (_shown.contains(group)) return false;
    if (_pending.add(group)) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_pending.remove(group)) _shown.add(group);
      });
    }
    return true;
  }

  static Duration delayFor(int index) {
    final d = step * index;
    return d > maxDelay ? maxDelay : d;
  }

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  /// Null when this row was decided to appear instantly; the decision is made
  /// once, at first build, and never revisited for this element.
  AnimationController? _c;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (context.reduceMotion || widget.index >= StaggeredEntrance.maxAnimated) return;
    if (!StaggeredEntrance._claim(widget.group)) return;
    _c = AnimationController.unbounded(vsync: this, value: 0)
      ..animateWith(SettlingSpring(
        StaggeredEntrance._spring,
        start: 0,
        end: 1,
        delay: StaggeredEntrance.delayFor(widget.index),
      ));
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    // The wrappers stay after the spring settles (opacity 1 / zero offset are
    // free) so the child's element — and any state it holds — is never
    // re-parented mid-life.
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) {
        final t = c.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * StaggeredEntrance.rise),
            child: child,
          ),
        );
      },
    );
  }
}
