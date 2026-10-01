// Home: «Скорость» — the last in-tunnel speed test for the active node, a
// gauge button in the header (and the card itself) opening the test sheet.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/features.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/format.dart';
import 'speed_test_sheet.dart';

/// Lives inside the connected reveal under the traffic card, so it only
/// appears with a session. Shows ping · download · upload of the latest
/// result for this node (live numbers while a test runs) and a caption
/// saying how old it is.
class SpeedTestPanel extends StatelessWidget {
  const SpeedTestPanel({super.key});

  @override
  Widget build(BuildContext context) {
    // Subscribed to the app so the card re-keys when the active node changes.
    context.app;
    final net = context.features.netcheck;
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final key = net.speedKey;
    return ListenableBuilder(
      listenable: net,
      builder: (context, _) {
        final running = net.speedRunning;
        final latest = running
            ? null
            : (net.phase == SpeedPhase.done ? net.result : null) ??
                net.resultsFor(key).firstOrNull;
        final ping = running ? net.livePing : latest?.ping;
        final down = running
            ? (net.phase == SpeedPhase.down ? net.currentBps : net.liveDown)
            : latest?.down;
        final up = running
            ? (net.phase == SpeedPhase.up ? net.currentBps : null)
            : latest?.up;
        final String caption;
        if (running) {
          caption = '${l('speed.phase.${net.phase.name}')}…';
        } else if (net.speedFailed) {
          caption = l('speed.failed');
        } else if (latest != null) {
          caption = formatAgo(l, net.now().difference(latest.at));
        } else {
          caption = l('speed.notMeasured');
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionHeader(
            l('speed.title'),
            trailing: ToolButton(
              key: const ValueKey('speed-open'),
              icon: Icons.speed_rounded,
              tooltip: l('speed.cmd'),
              onTap: () => showSpeedTestSheet(context),
            ),
          ),
          PressableScaleCard(
            onTap: () => showSpeedTestSheet(context),
            padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MetricsRow(items: [
                (l('speed.phase.ping'), formatMs(ping, l), ping == null ? null : c.latency(ping)),
                (l('speed.phase.down'), down == null ? '—' : formatSpeed(down, l: l), null),
                (l('speed.phase.up'), up == null ? '—' : formatSpeed(up, l: l), null),
              ]),
              const SizedBox(height: Space.s),
              Text(caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.caption.copyWith(
                      color: net.speedFailed && !running ? c.warning : c.secondaryLabel)),
            ]),
          ),
        ]);
      },
    );
  }
}
