import 'package:flutter/material.dart';

import 'tokens.dart';

/// The one card level: an opaque surface with a hairline border, no shadow.
/// Everything grouped in the app sits in a [Panel]; rows inside it are
/// separated with [Hairline]s.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.l),
    this.radius = Radii.m,
    this.color,
    this.border,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color? border;

  /// Clip children to the rounded shape (for full-bleed row highlights).
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final side = BorderSide(
      color: border ?? (context.highContrast ? c.label.withValues(alpha: 0.5) : c.separator),
      width: kHairline,
    );
    Widget body = Padding(padding: padding, child: child);
    if (clip) {
      body = ClipRRect(borderRadius: BorderRadius.circular(radius), child: body);
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: color ?? c.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius), side: side),
      ),
      child: body,
    );
  }
}

/// 1px divider. [inset] indents it from the leading edge so it aligns with
/// row text rather than the panel edge.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.inset = 0, this.color});
  final double inset;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsetsDirectional.only(start: inset),
        child: SizedBox(
          height: kHairline,
          width: double.infinity,
          child: ColoredBox(color: color ?? context.c.separator),
        ),
      );
}

/// Solid chrome for headers and bars: background colour + a hairline on the
/// edge facing content. Replaces translucent material.
class Chrome extends StatelessWidget {
  const Chrome({
    super.key,
    required this.child,
    this.edge = ChromeEdge.bottom,
    this.opacity = 1,
    this.color,
  });

  final Widget child;
  final ChromeEdge edge;

  /// Fades the fill and hairline together (used while content scrolls under
  /// a header).
  final double opacity;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final line = BorderSide(color: c.separator.withValues(alpha: c.separator.a * opacity), width: kHairline);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (color ?? c.background).withValues(alpha: opacity),
        border: switch (edge) {
          ChromeEdge.bottom => Border(bottom: line),
          ChromeEdge.top => Border(top: line),
          ChromeEdge.end => BorderDirectional(end: line),
          ChromeEdge.none => null,
        },
      ),
      child: child,
    );
  }
}

enum ChromeEdge { top, bottom, end, none }
