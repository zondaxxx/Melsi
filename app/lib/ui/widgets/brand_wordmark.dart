import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// The name, set in the bundled monospace. [glow] plays a single tracking
/// settle (tight to resting) and then stops. Reduced motion and [glow] false
/// paint the resting mark immediately. There is no blur and no loop.
class Wordmark extends StatefulWidget {
  const Wordmark({super.key, this.size = 19, this.glow = false});

  final double size;
  final bool glow;

  @override
  State<Wordmark> createState() => _WordmarkState();
}

class _WordmarkState extends State<Wordmark> with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.glow || context.reduceMotion) {
      _settle.value = 1;
    } else if (_settle.isDismissed && TickerMode.valuesOf(context).enabled) {
      _settle.forward();
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tight = -widget.size * 0.08;
    final rest = -widget.size * 0.03;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _settle,
        builder: (context, _) {
          final t = widget.glow ? _settle.value : 1.0;
          return Text(
            'Melsi',
            style: context.t.title3.copyWith(
              fontSize: widget.size,
              fontWeight: FontWeight.w700,
              letterSpacing: tight + (rest - tight) * t,
              height: 1.0,
            ),
          );
        },
      ),
    );
  }
}
