import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../theme/glass.dart';
import '../theme/pressable.dart';
import '../theme/theme.dart';

/// "Reconnect to apply" banner — appears (springing open) when a setting
/// that changes the generated config was edited while connected.
class ReconnectBanner extends StatelessWidget {
  const ReconnectBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final show = app.needsReconnect && (app.connected || app.busy);
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !show
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: Space.m),
              child: Card2(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.m, Space.m),
                color: Color.alphaBlend(c.warning.withValues(alpha: 0.14), c.surface),
                border: BorderSide(color: c.warning.withValues(alpha: 0.4)),
                child: Row(children: [
                  Icon(Icons.refresh_rounded, color: c.warning),
                  const SizedBox(width: Space.m),
                  Expanded(
                    child: Text(l('reconnect.text'),
                        style: context.t.subhead.copyWith(fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: Space.s),
                  PressableScale(
                    haptic: true,
                    onTap: app.reconnect,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: ShapeDecoration(color: c.warning, shape: Radii.shape(Radii.pill)),
                      child: Text(l('reconnect.action'),
                          style: context.t.subhead.copyWith(color: Colors.black, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ),
            ),
    );
  }
}
