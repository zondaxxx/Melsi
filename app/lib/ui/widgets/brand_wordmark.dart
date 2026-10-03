import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

class Wordmark extends StatefulWidget {
  const Wordmark({super.key, this.size = 19, this.glow = false});

  final double size;
  final bool glow;

  @override
  State<Wordmark> createState() => _WordmarkState();
}

class _WordmarkState extends State<Wordmark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _light = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.glow || context.reduceMotion) {
      _light.value = 1;
    } else if (_light.isDismissed && TickerMode.valuesOf(context).enabled) {
      _light.forward();
    }
  }

  @override
  void dispose() {
    _light.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.c;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _light,
        builder: (context, child) {
          final intensity = widget.glow
              ? math.sin(_light.value * math.pi)
              : 0.0;
          return Text(
            'Melsi',
            style: context.t.title3.copyWith(
              fontSize: widget.size,
              fontWeight: widget.glow ? FontWeight.w800 : FontWeight.w700,
              letterSpacing: -widget.size * 0.045,
              height: 1.15,
              shadows: widget.glow
                  ? [
                      Shadow(
                        color: colors.accent.withValues(
                          alpha: 0.2 + intensity * 0.3,
                        ),
                        blurRadius: 18 + intensity * 24,
                      ),
                      Shadow(
                        color: colors.accent.withValues(alpha: 0.5),
                        offset: const Offset(0, 2),
                        blurRadius: 1,
                      ),
                    ]
                  : null,
            ),
          );
        },
      ),
    );
  }
}
