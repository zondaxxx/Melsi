import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../services/vpn_controller.dart';
import '../../ui/theme/theme.dart';
import 'feedback.dart';

/// What the line is doing right now (tests read it through
/// [RouteLineState.debugPhase]).
enum RoutePhase { idle, connecting, connected, error }

/// The route line under the connect button: a 1px track in the 20px gap the
/// layout always had, so nothing jumps.
///
/// * stopped: invisible.
/// * connecting: the track fades in (separator) and a 24%-wide label-coloured
///   segment ping-pongs along it — the route being searched. Capped at
///   [kSweepCycles] cycles, then it rests at 60% opacity.
/// * connected: the segment springs from wherever it is to the full width in
///   `c.success`, holds, then dissolves into a 2px tick at the far end while
///   the track fades away — the route is drawn; the tick remembers it.
/// * error: the segment snaps to full width in `c.danger` and the whole line
///   fades over 400 ms, shaking once on the way out.
/// * cancel while connecting: the segment springs back to zero width.
///
/// Reduced motion: the states cross-fade in 160 ms, no travelling segment.
/// No accent here: meaning colours only on the completed line and the tick.
class RouteLine extends StatefulWidget {
  const RouteLine({super.key, required this.status});
  final VpnStatus status;

  /// Total height, so Home's layout never jumps.
  static const double height = Space.xl;

  /// Key of the painted box.
  static const Key lineKey = ValueKey('home-route-line');

  /// The sweep loops at most this many times (left→right→left = one cycle).
  /// It MUST be finite: `pumpAndSettle`-based tests would otherwise hang on
  /// a Home that is still "connecting", and a stuck tunnel should not keep a
  /// phone awake with a moving line either.
  static const int kSweepCycles = 3;

  /// Width of the searching segment as a fraction of the track.
  static const double segmentFraction = 0.24;

  @override
  State<RouteLine> createState() => RouteLineState();
}

class RouteLineState extends State<RouteLine> with TickerProviderStateMixin {
  static const _sweepPeriod = Duration(milliseconds: 1100);
  static const _hold = Duration(milliseconds: 320);

  /// Track (separator hairline) opacity.
  late final AnimationController _track =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 120));

  /// Sweep position 0…1 while connecting (ping-pong, capped).
  late final AnimationController _sweep = AnimationController(vsync: this, duration: _sweepPeriod);

  /// Segment start / end as fractions of the width, once the sweep hands
  /// over (connected, error, cancel).
  late final AnimationController _start = AnimationController.unbounded(vsync: this);
  late final AnimationController _end = AnimationController.unbounded(vsync: this);

  /// Segment opacity (1 while sweeping, 0.6 at rest, 0 once dissolved).
  late final AnimationController _segment =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 300));

  /// The 2px tick at the far end.
  late final AnimationController _tick =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  /// Whole-line opacity: the error fade.
  late final AnimationController _all =
      AnimationController(vsync: this, value: 1, duration: const Duration(milliseconds: 400));

  late final Listenable _repaint =
      Listenable.merge([_track, _sweep, _start, _end, _segment, _tick, _all]);

  RoutePhase _phase = RoutePhase.idle;
  int _cycles = 0;
  int _shake = 0;
  Timer? _holdTimer;

  /// Bumps on every phase change so a stale continuation (a spring that
  /// finished after the status moved on) does nothing.
  int _gen = 0;

  RoutePhase get debugPhase => _phase;

  /// connecting: sweep position; connected: how far the line has drawn.
  double get debugProgress => switch (_phase) {
        RoutePhase.connecting => _sweep.value,
        RoutePhase.connected => _end.value.clamp(0.0, 1.0),
        _ => 0,
      };

  /// Effective opacity of the separator track.
  double get debugTrackOpacity => _track.value * _all.value;

  /// Effective opacity of the whole line (0 = nothing painted).
  double get debugLineOpacity => _all.value;

  /// Effective opacity of the end tick.
  double get debugTickOpacity => _tick.value * _all.value;

  /// Effective opacity of the travelling / completed segment.
  double get debugSegmentOpacity => _segment.value * _all.value;

  bool get debugSweeping => _sweep.isAnimating;
  int get debugShakeCount => _shake;

  bool get _reduce => context.reduceMotion;

  @override
  void initState() {
    super.initState();
    _sweep.addStatusListener(_onSweepStatus);
  }

  bool _first = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_first) return;
    _first = false;
    _apply(widget.status, initial: true);
  }

  @override
  void didUpdateWidget(RouteLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _apply(widget.status);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _sweep.removeStatusListener(_onSweepStatus);
    for (final c in [_track, _sweep, _start, _end, _segment, _tick, _all]) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------ sweep

  /// Ping-pong by hand (rather than `repeat(reverse: true)`) so the cap is
  /// explicit: after [RouteLine.kSweepCycles] round trips the segment stops
  /// where it is and rests at 60%.
  void _onSweepStatus(AnimationStatus s) {
    if (_phase != RoutePhase.connecting) return;
    switch (s) {
      case AnimationStatus.completed:
        _sweep.reverse();
      case AnimationStatus.dismissed:
        _cycles++;
        if (_cycles < RouteLine.kSweepCycles) {
          _sweep.forward();
        } else {
          _segment.animateTo(0.6);
        }
      case AnimationStatus.forward || AnimationStatus.reverse:
        break;
    }
  }

  /// Segment edges right now, whichever source drives them.
  (double, double) get _edges {
    if (_phase == RoutePhase.connecting) {
      final p = Curves.easeInOut.transform(_sweep.value);
      final start = p * (1 - RouteLine.segmentFraction);
      return (start, start + RouteLine.segmentFraction);
    }
    return (_start.value, _end.value);
  }

  /// Freezes the current edges (captured before the phase changed) into the
  /// spring-driven pair, so the next motion starts exactly where the sweep
  /// left the segment.
  void _handOver((double, double) edges) {
    final (s, e) = edges;
    _sweep.stop();
    _start.value = s;
    _end.value = e;
  }

  // ------------------------------------------------------------ phases

  void _apply(VpnStatus status, {bool initial = false}) {
    _holdTimer?.cancel();
    _gen++;
    final reduce = _reduce;
    // Where the segment is *now*, read while the old phase still says which
    // controllers drive it.
    final edges = _edges;
    switch (status) {
      case VpnStatus.connecting:
        _toConnecting(reduce);
      case VpnStatus.connected:
        _toConnected(reduce, edges, initial: initial);
      case VpnStatus.error:
        _toError(reduce, edges);
      case VpnStatus.stopped || VpnStatus.stopping:
        _toIdle(reduce, edges, initial: initial);
    }
  }

  void _toConnecting(bool reduce) {
    // Rewind before the phase flips: the status listener must not count the
    // rewind's `dismissed` as a finished cycle.
    _sweep.stop();
    _sweep.value = 0;
    _phase = RoutePhase.connecting;
    _cycles = 0;
    _all.value = 1;
    _tick.value = 0;
    _tick.stop();
    if (reduce) {
      // Cross-fade to a plain track; nothing travels.
      _segment.value = 0;
      _track.animateTo(1, duration: const Duration(milliseconds: 160));
      return;
    }
    _track.forward();
    _segment.animateTo(1, duration: const Duration(milliseconds: 120));
    _sweep.forward();
  }

  void _toConnected(bool reduce, (double, double) edges, {required bool initial}) {
    final from = _phase;
    _phase = RoutePhase.connected;
    _all.value = 1;
    if (initial || reduce) {
      // Already connected at mount (Home is kept alive, this is launch) or
      // reduced motion: the resting picture, cross-faded.
      _sweep.stop();
      _segment.value = 0;
      final d = Duration(milliseconds: initial ? 0 : 160);
      _track.animateTo(0, duration: d);
      _tick.animateTo(1, duration: d);
      return;
    }
    if (from == RoutePhase.connecting) {
      _handOver(edges);
    } else {
      // Came from nowhere (e.g. resumed into a live tunnel): draw from the
      // left edge.
      _sweep.stop();
      _start.value = 0;
      _end.value = 0;
    }
    final gen = _gen;
    final spring = Springs.of(0.55, 0.9);
    _segment.animateTo(1, duration: const Duration(milliseconds: 120));
    // The success line takes the track's place while it draws.
    _track.animateTo(0, duration: const Duration(milliseconds: 300));
    _start.springTo(0, spring: spring);
    _end.springTo(1, spring: spring).then((_) {
      if (!mounted || gen != _gen) return;
      _holdTimer = Timer(_hold, () {
        if (!mounted || gen != _gen) return;
        // Dissolve: the line thins into the tick.
        _segment.animateTo(0, duration: const Duration(milliseconds: 260));
        _tick.forward(from: 0);
      });
    });
  }

  void _toError(bool reduce, (double, double) edges) {
    _phase = RoutePhase.error;
    _tick.stop();
    if (reduce) {
      _sweep.stop();
      _all.animateTo(0, duration: const Duration(milliseconds: 160));
      return;
    }
    _handOver(edges);
    _start.value = 0;
    _end.value = 1;
    _segment.value = 1;
    _all.value = 1;
    _all.animateTo(0, duration: const Duration(milliseconds: 400));
    _shake++;
  }

  void _toIdle(bool reduce, (double, double) edges, {required bool initial}) {
    final from = _phase;
    _phase = RoutePhase.idle;
    if (initial) {
      _track.value = 0;
      _segment.value = 0;
      _tick.value = 0;
      return;
    }
    if (reduce) {
      _sweep.stop();
      const d = Duration(milliseconds: 160);
      _track.animateTo(0, duration: d);
      _tick.animateTo(0, duration: d);
      _segment.animateTo(0, duration: d);
      return;
    }
    switch (from) {
      case RoutePhase.connecting:
        // Cancel: the searching segment springs back to nothing.
        _handOver(edges);
        _end.springTo(_start.value, spring: Springs.of(0.4, 1.0));
        _segment.animateTo(0, duration: const Duration(milliseconds: 300));
        _track.animateTo(0, duration: const Duration(milliseconds: 300));
      case RoutePhase.connected:
        _segment.animateTo(0, duration: const Duration(milliseconds: 200));
        _tick.reverse();
        _track.animateTo(0, duration: const Duration(milliseconds: 200));
      case RoutePhase.error || RoutePhase.idle:
        // Already fading or faded (stopping → stopped arrives while the
        // fade-out above is still running: let it finish, do not snap).
        _sweep.stop();
    }
  }

  // ------------------------------------------------------------ paint

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Shake(
      trigger: _shake,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: SizedBox(
            key: RouteLine.lineKey,
            height: RouteLine.height,
            width: double.infinity,
            // Own layer: the sweep repaints for seconds; the page need not.
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _RoutePainter(
                  repaint: _repaint,
                  state: this,
                  track: c.separator,
                  searching: c.label,
                  success: c.success,
                  danger: c.danger,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required Listenable repaint,
    required this.state,
    required this.track,
    required this.searching,
    required this.success,
    required this.danger,
  }) : super(repaint: repaint);

  final RouteLineState state;
  final Color track;
  final Color searching;
  final Color success;
  final Color danger;

  @override
  void paint(Canvas canvas, Size size) {
    final all = state._all.value;
    if (all <= 0 || size.width <= 0) return;
    // The line sits on the box's middle pixel row (crisp at 2× and 3×).
    final y = (size.height / 2).floorToDouble() - 0.5;
    final w = size.width;

    final trackA = state._track.value * all;
    if (trackA > 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, y, w, 1),
        Paint()..color = track.withValues(alpha: track.a * trackA),
      );
    }

    final segA = state._segment.value * all;
    if (segA > 0) {
      final (s, e) = state._edges;
      final x0 = (s.clamp(0.0, 1.0) * w).floorToDouble();
      final x1 = (e.clamp(0.0, 1.0) * w).ceilToDouble();
      if (x1 > x0) {
        final color = switch (state._phase) {
          RoutePhase.connected => success,
          RoutePhase.error => danger,
          _ => searching,
        };
        canvas.drawRect(
          Rect.fromLTWH(x0, y, x1 - x0, 1),
          Paint()..color = color.withValues(alpha: segA),
        );
      }
    }

    final tickA = state._tick.value * all;
    if (tickA > 0) {
      // 2px wide, 6px tall, on the line's far end: the destination.
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(w - 2, y - 2.5, 2, 6), const Radius.circular(1)),
        Paint()..color = success.withValues(alpha: tickA),
      );
    }
  }

  @override
  bool shouldRepaint(_RoutePainter oldDelegate) =>
      oldDelegate.state != state ||
      oldDelegate.track != track ||
      oldDelegate.searching != searching ||
      oldDelegate.success != success ||
      oldDelegate.danger != danger;
}
