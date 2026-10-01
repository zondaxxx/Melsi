// Spring motion, expressed the way Apple does: damping ratio + response.
//
// A spring has no duration — its settle time emerges from the parameters,
// and because it always starts from the current value and velocity it can be
// interrupted and retargeted at any moment.

import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

abstract final class Springs {
  /// Converts Apple's (response, dampingRatio) into a mass-1 spring.
  static SpringDescription of(double response, double dampingRatio) {
    final stiffness = math.pow(2 * math.pi / response, 2).toDouble();
    final damping = 4 * math.pi * dampingRatio / response;
    return SpringDescription(mass: 1, stiffness: stiffness, damping: damping);
  }

  /// Default UI spring — critically damped, no overshoot.
  static final standard = of(0.38, 1.0);

  /// Snappy critically damped spring for press feedback.
  static final press = of(0.22, 1.0);

  /// Momentum-driven moves (flicks, sheets, selection indicators that the
  /// user threw) — a touch of bounce.
  static final momentum = of(0.4, 0.8);

  /// Sheets / drawers.
  static final sheet = of(0.3, 0.8);
}

extension SpringDrive on AnimationController {
  /// Springs from the *current* value (and velocity) to [target].
  /// With reduced motion it jumps via a short linear fade instead.
  TickerFuture springTo(
    double target, {
    SpringDescription? spring,
    double? velocity,
    bool reduceMotion = false,
  }) {
    if (reduceMotion) {
      return animateTo(target,
          duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
    }
    final sim = SpringSimulation(
      spring ?? Springs.standard,
      value,
      target,
      velocity ?? this.velocity,
      tolerance: const Tolerance(distance: 0.0005, velocity: 0.01),
    );
    return animateWith(sim);
  }
}

/// A value that springs whenever [target] changes — the declarative way to
/// get spring motion (like SwiftUI's `.animation(.spring)`).
class SpringValue extends StatefulWidget {
  const SpringValue({
    super.key,
    required this.target,
    required this.builder,
    this.spring,
    this.child,
  });

  final double target;
  final SpringDescription? spring;
  final Widget? child;
  final Widget Function(BuildContext context, double value, Widget? child)
      builder;

  @override
  State<SpringValue> createState() => _SpringValueState();
}

class _SpringValueState extends State<SpringValue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(
      vsync: this, value: widget.target);

  @override
  void didUpdateWidget(SpringValue old) {
    super.didUpdateWidget(old);
    if (old.target != widget.target) {
      _c.springTo(widget.target,
          spring: widget.spring,
          reduceMotion: MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) => widget.builder(context, _c.value, child),
      );
}
