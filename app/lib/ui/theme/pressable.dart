import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'tokens.dart';

/// Instant press feedback: scales down on pointer-*down* (not on release) and
/// springs back, interruptibly, from wherever it is. Tap commits on release;
/// dragging away cancels. With reduced motion it dims instead of scaling.
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.haptic = false,
    this.enabled = true,
    this.behavior = HitTestBehavior.opaque,
    this.semanticLabel,
    this.cursor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;
  final bool enabled;
  final HitTestBehavior behavior;
  final String? semanticLabel;
  final MouseCursor? cursor;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController.unbounded(vsync: this, value: 0);

  bool get _active =>
      widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  void _down(PointerDownEvent _) {
    if (!_active) return;
    _c.springTo(1, spring: Springs.press, reduceMotion: context.reduceMotion);
  }

  void _up([Object? _]) {
    _c.springTo(0, spring: Springs.standard, reduceMotion: context.reduceMotion);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return Semantics(
      button: widget.onTap != null,
      enabled: _active,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: _active
            ? (widget.cursor ?? SystemMouseCursors.click)
            : MouseCursor.defer,
        child: Listener(
          onPointerDown: _down,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: GestureDetector(
            behavior: widget.behavior,
            onTap: _active && widget.onTap != null
                ? () {
                    if (widget.haptic) HapticFeedback.selectionClick();
                    widget.onTap!();
                  }
                : null,
            onTapCancel: _up,
            onLongPress: _active && widget.onLongPress != null
                ? () {
                    HapticFeedback.mediumImpact();
                    _up();
                    widget.onLongPress!();
                  }
                : null,
            child: AnimatedBuilder(
              animation: _c,
              child: widget.child,
              builder: (context, child) {
                final v = _c.value;
                if (reduce) {
                  return Opacity(opacity: 1 - 0.3 * v.clamp(0, 1), child: child);
                }
                return Transform.scale(
                  scale: 1 - (1 - widget.scale) * v,
                  child: child,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
