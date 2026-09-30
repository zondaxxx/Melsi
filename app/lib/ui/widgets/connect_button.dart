import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../theme/pressable.dart';
import '../theme/theme.dart';

/// The connect control: a wide, tactile button whose label and colour state
/// the action.
///
/// * Idle: solid accent, "Подключиться".
/// * Connecting / stopping: neutral, a small spinner, the action is "Отмена".
/// * Connected: neutral with a hairline, "Отключить".
/// * Error: neutral with a red hairline, "Подключиться" (retry).
///
/// Presses down instantly (spring scale) and fires a haptic on commit; colour
/// springs between states. A medium haptic confirms the connection, a heavy
/// one an error. Reduced motion: state changes cross-fade.
class ConnectButton extends StatefulWidget {
  const ConnectButton({super.key, required this.status, required this.onTap, this.height = 52});

  final VpnStatus status;
  final VoidCallback onTap;
  final double height;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton> with SingleTickerProviderStateMixin {
  /// 0 = accent (idle), 1 = neutral (busy / connected).
  late final AnimationController _level =
      AnimationController.unbounded(vsync: this, value: _target(widget.status));

  static double _target(VpnStatus s) => switch (s) {
        VpnStatus.stopped || VpnStatus.error => 0,
        _ => 1,
      };

  @override
  void didUpdateWidget(ConnectButton old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) {
      _level.springTo(_target(widget.status),
          spring: Springs.of(0.4, 1.0), reduceMotion: context.reduceMotion);
      if (widget.status == VpnStatus.connected) {
        HapticFeedback.mediumImpact();
      } else if (widget.status == VpnStatus.error) {
        HapticFeedback.heavyImpact();
      }
    }
  }

  @override
  void dispose() {
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    final s = widget.status;
    final busy = s == VpnStatus.connecting || s == VpnStatus.stopping;
    final label = switch (s) {
      VpnStatus.connected => l('home.disconnect'),
      VpnStatus.connecting => l('common.cancel'),
      VpnStatus.stopping => l('status.stopping'),
      _ => l('home.connect'),
    };
    final enabled = s != VpnStatus.stopping;

    return PressableScale(
      scale: 0.985,
      haptic: false,
      enabled: enabled,
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: Semantics(
        button: true,
        label: label,
        child: AnimatedBuilder(
          animation: _level,
          builder: (context, _) {
            final v = _level.value.clamp(0.0, 1.0);
            final bg = Color.lerp(c.accent, c.surface, v)!;
            final fg = Color.lerp(c.onAccent, c.label, v)!;
            final edge = Color.lerp(
                c.accent, s == VpnStatus.error ? c.danger : c.separator, v)!;
            return Container(
              height: widget.height,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: bg,
                shape: Radii.shape(Radii.m, side: BorderSide(color: edge, width: kHairline)),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
                child: Row(
                  key: ValueKey(label),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy) ...[
                      CupertinoActivityIndicator(radius: 7, color: fg),
                      const SizedBox(width: Space.s + 2),
                    ],
                    Text(label,
                        style: context.t.headline.copyWith(
                            color: fg.withValues(alpha: enabled ? 1 : 0.5), fontSize: 15)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
