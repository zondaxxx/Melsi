import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'tokens.dart';

enum GlassWeight {
  /// Chrome over content (tab bar, headers, chips).
  regular,

  /// Structural regions (sidebar) — thicker, more opaque.
  heavy,
}

/// A translucent material: backdrop blur + tinted fill + a hairline highlight
/// on the edge that catches the light. With high contrast it becomes solid
/// with a defined border.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = Radii.l,
    this.weight = GlassWeight.regular,
    this.padding,
    this.borderRadius,
    this.edge = true,
    this.shadow = false,
    this.tint,
  });

  final Widget child;
  final double radius;
  final BorderRadius? borderRadius;
  final GlassWeight weight;
  final EdgeInsetsGeometry? padding;
  final bool edge;
  final bool shadow;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final solid = context.highContrast;
    final br = borderRadius ?? BorderRadius.circular(radius);
    final fill = tint ??
        (weight == GlassWeight.heavy ? c.glassHeavy : c.glass);
    final shape = RoundedSuperellipseBorder(
      borderRadius: br,
      side: solid
          ? BorderSide(color: c.label.withValues(alpha: 0.5), width: 1)
          : edge
              ? BorderSide(color: c.glassEdge, width: 0.6)
              : BorderSide.none,
    );
    final sigma = weight == GlassWeight.heavy ? 40.0 : 28.0;

    Widget body = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        color: solid ? (c.isDark ? const Color(0xFF1C1C1E) : Colors.white) : fill,
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    if (!solid) {
      body = ClipRSuperellipse(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.compose(
            outer: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            inner: ColorFilter.matrix(_saturate(1.8)),
          ),
          child: body,
        ),
      );
    }

    if (shadow) {
      body = DecoratedBox(
        decoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(borderRadius: br),
          shadows: [
            BoxShadow(
              color: c.shadow,
              blurRadius: weight == GlassWeight.heavy ? 40 : 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: body,
      );
    }
    return body;
  }

  static List<double> _saturate(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final i = 1 - s;
    return [
      i * r + s, i * g, i * b, 0, 0, //
      i * r, i * g + s, i * b, 0, 0, //
      i * r, i * g, i * b + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }
}

/// Plain opaque card (grouped-list style) with continuous corners.
class Card2 extends StatelessWidget {
  const Card2({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.l),
    this.radius = Radii.l,
    this.color,
    this.gradient,
    this.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Gradient? gradient;
  final BorderSide? border;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: gradient == null ? (color ?? c.surface) : null,
        gradient: gradient,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: border ??
              (context.highContrast
                  ? BorderSide(color: c.separator, width: 1)
                  : c.isDark
                      ? BorderSide(color: c.glassEdge.withValues(alpha: 0.08), width: 0.5)
                      : BorderSide.none),
        ),
        shadows: c.isDark
            ? null
            : [
                BoxShadow(
                    color: c.shadow.withValues(alpha: 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 2)),
              ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
