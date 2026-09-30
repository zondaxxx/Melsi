import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/vpn_controller.dart';
import '../theme/pressable.dart';
import '../theme/theme.dart';

/// The big round connect control.
///
/// * Presses down instantly (spring scale) and fires a haptic on commit.
/// * Colour/glow spring between states: idle (indigo outline) → connecting
///   (indigo→violet fill, rotating arc) → connected (green fill, soft
///   emitting rings). Error tints red.
/// * Reduced motion: no rotation or rings; state changes cross-fade.
class ConnectButton extends StatefulWidget {
  const ConnectButton({super.key, required this.status, required this.onTap, this.size = 184});

  final VpnStatus status;
  final VoidCallback onTap;
  final double size;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton> with TickerProviderStateMixin {
  late final AnimationController _level =
      AnimationController.unbounded(vsync: this, value: _target(widget.status));
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  static double _target(VpnStatus s) => switch (s) {
        VpnStatus.connected => 2,
        VpnStatus.connecting || VpnStatus.stopping => 1,
        _ => 0,
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoops();
  }

  @override
  void didUpdateWidget(ConnectButton old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) {
      _level.springTo(_target(widget.status),
          spring: Springs.of(0.55, 1.0), reduceMotion: context.reduceMotion);
      if (widget.status == VpnStatus.connected) {
        HapticFeedback.heavyImpact();
      } else if (widget.status == VpnStatus.error) {
        HapticFeedback.vibrate();
      }
      _syncLoops();
    }
  }

  void _syncLoops() {
    final reduce = context.reduceMotion;
    final busy = widget.status == VpnStatus.connecting || widget.status == VpnStatus.stopping;
    if (busy && !reduce) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
    if (widget.status == VpnStatus.connected && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _level.dispose();
    _spin.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = widget.size;
    final error = widget.status == VpnStatus.error;
    return SizedBox(
      width: s + 80,
      height: s + 80,
      child: PressableScale(
        scale: 0.94,
        behavior: HitTestBehavior.deferToChild,
        onTap: () {
          HapticFeedback.mediumImpact();
          widget.onTap();
        },
        child: AnimatedBuilder(
          animation: Listenable.merge([_level, _spin, _pulse]),
          builder: (context, _) {
            final lv = _level.value.clamp(0.0, 2.2);
            final a = lv.clamp(0.0, 1.0); // idle → active
            final g = (lv - 1).clamp(0.0, 1.0); // active → connected
            final base = Color.lerp(c.accent, c.success, g)!;
            final base2 = Color.lerp(c.accent2, Color.lerp(c.success, const Color(0xFF00C7BE), 0.55), g)!;
            final tint = error ? c.danger : base;
            final tint2 = error ? Color.lerp(c.danger, c.warning, 0.4)! : base2;
            return CustomPaint(
              painter: _RingsPainter(
                color: tint,
                pulse: _pulse.value,
                pulseOn: g > 0.5 && !context.reduceMotion,
                spin: _spin.value,
                spinOn: widget.status == VpnStatus.connecting ||
                    widget.status == VpnStatus.stopping,
                active: a,
                connected: g,
                track: c.fillStrong,
                accent2: tint2,
                radius: s / 2,
              ),
              child: Center(
                child: Semantics(
                  button: true,
                  label: widget.status.name,
                  child: Container(
                    width: s,
                    height: s,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.lerp(c.surface, tint, a)!,
                          Color.lerp(c.surface, tint2, a)!,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: tint.withValues(alpha: 0.10 + 0.32 * a),
                          blurRadius: 28 + 36 * a,
                          spreadRadius: 2 * a,
                          offset: Offset(0, 10 + 6 * a),
                        ),
                      ],
                      border: Border.all(
                        color: Color.lerp(
                            c.isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white,
                            Colors.white.withValues(alpha: 0.25),
                            a)!,
                        width: 1,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Specular highlight — light catching the top of the dome.
                        Positioned(
                          top: s * 0.06,
                          child: Container(
                            width: s * 0.62,
                            height: s * 0.34,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.all(Radius.elliptical(s * 0.31, s * 0.17)),
                              gradient: RadialGradient(
                                center: const Alignment(0, -0.6),
                                radius: 0.9,
                                colors: [
                                  Colors.white.withValues(alpha: c.isDark ? 0.07 + 0.13 * a : 0.6 * (1 - a) + 0.2 * a),
                                  Colors.white.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                        _PowerGlyph(
                          size: s * 0.34,
                          color: Color.lerp(tint, Colors.white, a)!,
                          color2: Color.lerp(tint2, Colors.white, a)!,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PowerGlyph extends StatelessWidget {
  const _PowerGlyph({required this.size, required this.color, required this.color2});
  final double size;
  final Color color;
  final Color color2;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _PowerPainter(color, color2),
      );
}

class _PowerPainter extends CustomPainter {
  _PowerPainter(this.color, this.color2);
  final Color color;
  final Color color2;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..shader = LinearGradient(colors: [color, color2])
          .createShader(Offset.zero & size)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.105
      ..strokeCap = StrokeCap.round;
    const gap = 0.62;
    canvas.drawArc(Rect.fromCircle(center: center, radius: r * 0.82),
        -math.pi / 2 + gap, 2 * math.pi - 2 * gap, false, paint);
    canvas.drawLine(center.translate(0, -r * 1.02), center.translate(0, -r * 0.18), paint);
  }

  @override
  bool shouldRepaint(_PowerPainter old) => old.color != color || old.color2 != color2;
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({
    required this.color,
    required this.accent2,
    required this.pulse,
    required this.pulseOn,
    required this.spin,
    required this.spinOn,
    required this.active,
    required this.connected,
    required this.track,
    required this.radius,
  });

  final Color color;
  final Color accent2;
  final double pulse;
  final bool pulseOn;
  final double spin;
  final bool spinOn;
  final double active;
  final double connected;
  final Color track;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final ringR = radius + 13;

    // Emitting rings (connected): two staggered waves, low opacity.
    if (pulseOn) {
      for (final phase in [0.0, 0.5]) {
        final t = (pulse + phase) % 1.0;
        final eased = Curves.easeOut.transform(t);
        final r = ringR + 2 + eased * 26;
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color.withValues(alpha: 0.35 * (1 - t) * connected),
        );
      }
    }

    // Track.
    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = track,
    );

    final rect = Rect.fromCircle(center: center, radius: ringR);
    if (spinOn) {
      // Rotating comet arc.
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(spin * 2 * math.pi);
      canvas.translate(-center.dx, -center.dy);
      canvas.drawArc(
        rect,
        0,
        math.pi * 1.1,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            colors: [color.withValues(alpha: 0), color, accent2],
            stops: const [0.0, 0.6, 1.0],
            endAngle: math.pi * 1.1,
          ).createShader(rect),
      );
      canvas.restore();
    } else if (connected > 0.01) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * connected.clamp(0, 1),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            colors: [color, accent2, color],
            transform: const GradientRotation(-math.pi / 2),
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => true;
}
