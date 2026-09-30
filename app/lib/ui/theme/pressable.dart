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

/// Pointer hover / pressed tracking for desktop affordances. [builder]
/// receives `hovered` (mouse only — touch never hovers) and `pressed`
/// (pointer down, any device). Wrap the *painted* surface in this so the
/// fill can change; combine with [PressableScale] for the press-scale.
class Hoverable extends StatefulWidget {
  const Hoverable({super.key, required this.builder, this.enabled = true, this.cursor});
  final Widget Function(BuildContext context, bool hovered, bool pressed) builder;
  final bool enabled;
  final MouseCursor? cursor;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: widget.enabled ? (widget.cursor ?? SystemMouseCursors.click) : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
              _hover = false;
              _down = false;
            }),
        child: Listener(
          behavior: HitTestBehavior.deferToChild,
          onPointerDown: (_) => setState(() => _down = true),
          onPointerUp: (_) => setState(() => _down = false),
          onPointerCancel: (_) => setState(() => _down = false),
          child: widget.builder(
              context, widget.enabled && _hover, widget.enabled && _down),
        ),
      );
}

/// Surface colour for an interactive element: [base] at rest, the fill
/// tokens blended in on hover and press.
Color interactiveSurface(MelsiColors c, Color base, {required bool hovered, required bool pressed}) {
  if (pressed) return Color.alphaBlend(c.fillStrong, base);
  if (hovered) return Color.alphaBlend(c.fill, base);
  return base;
}
