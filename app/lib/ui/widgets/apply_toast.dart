import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../theme/theme.dart';

/// Small floating notice that reports settings being applied to the running
/// tunnel: "Applying settings…" → "Done". Springs up from the tab bar and
/// back down along the same path; never blocks input.
class ApplyToast extends StatefulWidget {
  const ApplyToast({super.key});

  @override
  State<ApplyToast> createState() => _ApplyToastState();
}

class _ApplyToastState extends State<ApplyToast> {
  ApplyPhase _shown = ApplyPhase.applying;
  ApplyPhase _last = ApplyPhase.idle;

  static bool _visible(ApplyPhase p) =>
      p == ApplyPhase.applying || p == ApplyPhase.done || p == ApplyPhase.failed;

  @override
  Widget build(BuildContext context) {
    final phase = context.app.applyPhase;
    final visible = _visible(phase);
    if (visible) _shown = phase; // keep the last content while springing out
    if (phase != _last) {
      if (phase == ApplyPhase.done) HapticFeedback.lightImpact();
      _last = phase;
    }
    final reduce = context.reduceMotion;
    return IgnorePointer(
      child: SpringValue(
        target: visible ? 1 : 0,
        spring: Springs.of(0.42, 0.82),
        builder: (context, v, child) {
          final t = v.clamp(0.0, 1.0);
          if (t <= 0.001) return const SizedBox.shrink();
          return Opacity(
            opacity: (t * 1.8).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, reduce ? 0 : (1 - v) * 14),
              child: child,
            ),
          );
        },
        child: Semantics(
          liveRegion: true,
          child: _Notice(phase: _shown),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.phase});
  final ApplyPhase phase;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    final (Widget icon, String text) = switch (phase) {
      ApplyPhase.done => (
          Icon(Icons.check_rounded, size: 16, color: c.success),
          l('apply.done'),
        ),
      ApplyPhase.failed => (
          Icon(Icons.priority_high_rounded, size: 16, color: c.danger),
          l('apply.failed'),
        ),
      _ => (
          const SizedBox.square(dimension: 16, child: CupertinoActivityIndicator(radius: 7)),
          l('apply.applying'),
        ),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: c.surfaceRaised,
        shape: Radii.shape(Radii.m, side: BorderSide(color: c.separator, width: kHairline)),
        shadows: c.isDark
            ? null
            : [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.s + 1, Space.l, Space.s + 1),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Row(
              key: ValueKey(phase),
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(width: Space.s),
                Text(text, style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
