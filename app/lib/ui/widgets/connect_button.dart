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
/// * Connected: neutral with a visible 1px stroke (30% label, both themes,
///   so it reads as a control rather than another card), "Отключить".
/// * Error: neutral with a red hairline, "Подключиться" (retry).
/// * No server ([hasServer] false): still the accent — it is the one
///   primary action of an empty Home, "Добавить сервер" / "Выбрать сервер",
///   and [onTap] opens the add flow or the switcher (the caller decides).
///
/// 52px on phones, 56px on wide layouts; the caller constrains the width
/// (full column on phones, the live column on desktop).
///
/// Presses down instantly (spring scale) and fires a haptic on commit; colour
/// springs between states. A medium haptic confirms the connection, a heavy
/// one an error. Reduced motion: state changes cross-fade.
class ConnectButton extends StatefulWidget {
  const ConnectButton({
    super.key,
    required this.status,
    required this.onTap,
    this.hasServer = true,
    this.noServerLabel,
    this.height = 52,
  });

  final VpnStatus status;
  final VoidCallback onTap;

  /// Whether there is anything to connect to. When false the button turns
  /// neutral and shows [noServerLabel] (falls back to "Добавить сервер").
  final bool hasServer;
  final String? noServerLabel;
  final double height;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton> with SingleTickerProviderStateMixin {
  /// 0 = accent (idle), 1 = neutral (busy / connected).
  late final AnimationController _level = AnimationController.unbounded(
      vsync: this, value: _target(widget.status, widget.hasServer));

  static double _target(VpnStatus s, bool hasServer) => switch (s) {
        VpnStatus.stopped || VpnStatus.error => 0,
        _ => 1,
      };

  @override
  void didUpdateWidget(ConnectButton old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status || old.hasServer != widget.hasServer) {
      _level.springTo(_target(widget.status, widget.hasServer),
          spring: Springs.of(0.4, 1.0), reduceMotion: context.reduceMotion);
    }
    if (old.status != widget.status) {
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
    final idle = s == VpnStatus.stopped || s == VpnStatus.error;
    final label = switch (s) {
      VpnStatus.connected => l('home.disconnect'),
      VpnStatus.connecting => l('common.cancel'),
      VpnStatus.stopping => l('status.stopping'),
      _ when !widget.hasServer => widget.noServerLabel ?? l('servers.add'),
      _ => l('home.connect'),
    };
    // Without a server the idle button leads to the add flow / switcher: a
    // real action, so it keeps the accent — the same primary as the empty
    // Servers page. It only loses the error stroke, which is not its fault.
    final adding = idle && !widget.hasServer;
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
            // Neutral state: a raised surface with a stroke strong enough to
            // read as a button on the dark background.
            final neutralBg = c.isDark ? c.surfaceRaised : c.surface;
            final neutralEdge = c.label.withValues(alpha: 0.3);
            final bg = Color.lerp(c.accent, neutralBg, v)!;
            final fg = Color.lerp(c.onAccent, c.label, v)!;
            final edge = Color.lerp(
                c.accent, s == VpnStatus.error && !adding ? c.danger : neutralEdge, v)!;
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
                    Flexible(child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.headline.copyWith(
                            color: fg.withValues(alpha: enabled ? 1 : 0.5), fontSize: 15))),
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
