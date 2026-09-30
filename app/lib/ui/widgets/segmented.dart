import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

class Segment<T> {
  const Segment(this.value, this.label, {this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

/// Sliding segmented control: a flat track with a hairline, the thumb is a
/// raised surface. The thumb springs (with a hint of momentum) from wherever
/// it currently is, so rapid taps retarget smoothly. Dragging across the
/// track moves the selection 1:1.
///
/// The track fills its column up to [maxWidth] and then stays put on the
/// leading edge, under its section label: three or four segments never
/// stretch across a wide page.
class Segmented<T> extends StatefulWidget {
  const Segmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.height = 34,
    this.maxWidth = kMaxWidth,
  });

  /// The one cap every segmented control in the app shares.
  static const double kMaxWidth = 420;

  final List<Segment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  final double height;
  final double maxWidth;

  @override
  State<Segmented<T>> createState() => _SegmentedState<T>();
}

class _SegmentedState<T> extends State<Segmented<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pos = AnimationController.unbounded(
      vsync: this, value: _index.toDouble());

  int get _index {
    final i = widget.segments.indexWhere((s) => s.value == widget.value);
    return i < 0 ? 0 : i;
  }

  @override
  void didUpdateWidget(Segmented<T> old) {
    super.didUpdateWidget(old);
    if (_pos.value != _index) {
      _pos.springTo(_index.toDouble(),
          spring: Springs.momentum, reduceMotion: context.reduceMotion);
    }
  }

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (widget.onChanged == null) return;
    final v = widget.segments[i].value;
    if (v != widget.value) {
      HapticFeedback.selectionClick();
      widget.onChanged!(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final n = widget.segments.length;
    const pad = 3.0;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final segW = (w - pad * 2) / n;
          int hit(double dx) => ((dx - pad) / segW).floor().clamp(0, n - 1);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _select(hit(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) {
              final i = hit(d.localPosition.dx);
              if (widget.segments[i].value != widget.value) _select(i);
            },
            child: Container(
              height: widget.height,
              padding: const EdgeInsets.all(pad),
              decoration: ShapeDecoration(
                color: c.fill,
                shape: Radii.shape(Radii.m - 2,
                    side: BorderSide(color: c.separator, width: kHairline)),
              ),
              child: Stack(
                children: [
                  AnimatedBuilder(
                    animation: _pos,
                    builder: (context, _) => Positioned(
                      left: _pos.value * segW,
                      top: 0,
                      bottom: 0,
                      width: segW,
                      child: Container(
                        decoration: ShapeDecoration(
                          color: c.isDark ? c.fillStrong : c.surface,
                          shape: Radii.shape(Radii.s,
                              side: BorderSide(color: c.separator, width: kHairline)),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        Expanded(
                          child: Semantics(
                            button: true,
                            selected: i == _index,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (widget.segments[i].icon != null) ...[
                                      Icon(widget.segments[i].icon, size: 14,
                                          color: i == _index ? c.label : c.secondaryLabel),
                                      const SizedBox(width: 5),
                                    ],
                                    Flexible(
                                      child: Text(
                                        widget.segments[i].label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.t.subhead.copyWith(
                                          fontSize: 13,
                                          fontWeight: i == _index ? FontWeight.w600 : FontWeight.w500,
                                          color: i == _index ? c.label : c.secondaryLabel,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
