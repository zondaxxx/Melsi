import 'package:flutter/material.dart';

import '../theme/entrance.dart';
import '../theme/theme.dart';

/// IndexedStack that keeps every page alive and brings the *incoming* page in
/// with a fade and a short directional settle: it slides up from +10px when
/// moving to a higher tab index and down from −10px to a lower one — the
/// vertical axis on both layouts, matching the sidebar's order. The outgoing
/// page is not animated (IndexedStack simply stops showing it).
///
/// A spring drives the move from the *current* progress and velocity, so a
/// rapid second tap retargets from wherever the page is instead of snapping
/// back to the start. Reduced motion: a 160ms fade, no offset.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({super.key, required this.index, required this.children});
  final int index;
  final List<Widget> children;

  /// Travel of the incoming page; fixed regardless of layout width.
  static const double travel = 10;

  static final _spring = Springs.of(0.36, 1.0);

  @override
  State<FadeIndexedStack> createState() => FadeIndexedStackState();
}

class FadeIndexedStackState extends State<FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  /// Progress of the incoming page, 0 → 1. Unbounded so the spring owns it.
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 1);

  /// +1 when the incoming page sits below the previous one, −1 above.
  int _direction = 1;

  /// Captured when a transition starts so the offset it renders (none under
  /// reduced motion) stays consistent for its whole run.
  bool _reduce = false;

  /// Current vertical offset of the visible page in logical pixels (for tests).
  double get debugOffset => _offset(_c.value);

  double _offset(double t) => _c.isAnimating && !_reduce
      ? (1 - t) * FadeIndexedStack.travel * _direction
      : 0;

  @override
  void didUpdateWidget(FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    _direction = widget.index > oldWidget.index ? 1 : -1;
    // A settled stack starts a fresh transition; a mid-flight one keeps its
    // progress so the new page continues from the current offset and opacity.
    if (!_c.isAnimating) _c.value = 0;
    _reduce = context.reduceMotion;
    if (_reduce) {
      _c.animateTo(1, duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    } else {
      _c.animateWith(SettlingSpring(FadeIndexedStack._spring,
          start: _c.value, end: 1, velocity: _c.velocity));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, _offset(t)),
            child: child,
          ),
        );
      },
      child: IndexedStack(
        index: widget.index,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            TickerMode(enabled: i == widget.index, child: widget.children[i]),
        ],
      ),
    );
  }
}
