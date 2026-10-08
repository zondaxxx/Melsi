// The speed test sheet (dialog on wide layouts): node line, phase
// overline, one large springing number, a live sparkline, the three
// metrics filling in as phases finish, run/cancel, and the node's history.

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/features.dart';
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/charts.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/format.dart';
import '../../ui/widgets/page.dart';

Future<void> showSpeedTestSheet(BuildContext context) =>
    showMelsiSheet<void>(context, builder: (_) => const SpeedTestSheet());

class SpeedTestSheet extends StatelessWidget {
  const SpeedTestSheet({super.key});

  static const double _chartHeight = 52;

  /// Subscriptions at or past this share of their quota get the amber note.
  static const double _quotaWarn = 0.9;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final net = context.features.netcheck;
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final connected = app.connected;
    final node = connected ? app.activeNode : null;
    final key = net.speedKey;
    final quota = app.subscriptions.any((s) {
      final total = s.total;
      if (total == null || total <= 0) return false;
      return ((s.download ?? 0) + (s.upload ?? 0)) / total >= _quotaWarn;
    });

    return ListenableBuilder(
      listenable: net,
      builder: (context, _) {
        final running = net.speedRunning;
        final done = net.phase == SpeedPhase.done && net.result != null;
        final phaseKey = switch (net.phase) {
          SpeedPhase.idle => null,
          SpeedPhase.ping => 'speed.phase.ping',
          SpeedPhase.down => 'speed.phase.down',
          SpeedPhase.up => 'speed.phase.up',
          SpeedPhase.done => 'speed.phase.done',
        };
        // The big number: live speed while measuring, the download result
        // once finished, a dash before the first run.
        final double? big = switch (net.phase) {
          SpeedPhase.down || SpeedPhase.up => net.currentBps,
          SpeedPhase.done => net.result?.down,
          _ => null,
        };
        final ping = running || done ? net.livePing ?? net.result?.ping : null;
        final down = done ? net.result?.down : net.liveDown;
        final up = done ? net.result?.up : null;
        // History: the run that just finished is on top of the list too.
        final history = net.resultsFor(key).where((r) => !done || r.at != net.result!.at).toList();

        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SheetHeader(title: l('speed.title')),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _NodeLine(node: node),
                const SizedBox(height: Space.xl),
                Overline(phaseKey == null ? l('speed.title') : l(phaseKey)),
                const SizedBox(height: Space.xs),
                _BigNumber(bps: big, pinging: net.phase == SpeedPhase.ping, ping: ping),
                const SizedBox(height: Space.m),
                SizedBox(
                  height: _chartHeight,
                  child: net.samples.length >= 2
                      ? CustomPaint(
                          size: Size.infinite,
                          painter: SpeedChartPainter(
                            down: net.samples,
                            up: const [],
                            downColor: c.label,
                            upColor: c.secondaryLabel,
                          ),
                        )
                      : const Align(alignment: Alignment.bottomCenter, child: Hairline()),
                ),
                const SizedBox(height: Space.m),
                const Hairline(),
                const SizedBox(height: Space.m),
                MetricsRow(items: [
                  (l('speed.phase.ping'), formatMs(ping, l), ping == null ? null : c.latency(ping)),
                  (l('speed.phase.down'), down == null ? '—' : formatSpeed(down, l: l), null),
                  (l('speed.phase.up'), up == null ? '—' : formatSpeed(up, l: l), null),
                ]),
                const SizedBox(height: Space.xl),
                PrimaryButton(
                  key: const ValueKey('speed-run'),
                  label: running ? l('speed.cancel') : l('speed.run'),
                  icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  expand: true,
                  onTap: running ? net.cancelSpeedTest : () => net.runSpeedTest(),
                ),
                const SizedBox(height: Space.m),
                Text(l('speed.note'), style: t.footnote),
                if (net.speedFailed && !running) ...[
                  const SizedBox(height: Space.xs),
                  Text(l('speed.failedAt', {
                    'phase': l('speed.phase.${net.failedPhase?.name ?? 'down'}'),
                    'reason': l(net.speedErrorKey, net.speedErrorArgs),
                  }), style: t.caption.copyWith(color: c.warning)),
                ],
                if (quota) ...[
                  const SizedBox(height: Space.xs),
                  Text(l('speed.quota'), style: t.caption.copyWith(color: c.warning)),
                ],
                if (history.isNotEmpty) ...[
                  const SizedBox(height: Space.l),
                  const Hairline(),
                  const SizedBox(height: Space.m),
                  Overline(l('speed.previous')),
                  const SizedBox(height: Space.s),
                  for (final r in history) ...[
                    Text(
                      l('speed.prev', {
                        'ago': formatAgo(l, net.now().difference(r.at)),
                        'd': formatSpeed(r.down, l: l),
                        'u': formatSpeed(r.up, l: l),
                      }),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.mono.copyWith(color: c.secondaryLabel),
                    ),
                    const SizedBox(height: Space.xs),
                  ],
                ],
              ]),
            ),
          ]),
        );
      },
    );
  }
}

/// Country box + name of the node under test; «напрямую» when the tunnel
/// is down (the test still runs and measures the bare link).
class _NodeLine extends StatelessWidget {
  const _NodeLine({required this.node});
  final ProxyNode? node;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final n = node;
    return Row(children: [
      CountryCode(n?.countryCode),
      const SizedBox(width: Space.m),
      Expanded(
        child: Text(
          n == null ? l('speed.direct') : nodeTitle(n),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: n == null ? t.body.copyWith(color: c.secondaryLabel) : t.headline,
        ),
      ),
      if (n != null) ...[
        const SizedBox(width: Space.s),
        ProtocolBadge(n.protocol),
      ],
    ]);
  }
}

/// The headline figure. Springs between readings (reduced motion: snaps);
/// while pinging it shows the ping, before the first run a dash.
class _BigNumber extends StatelessWidget {
  const _BigNumber({required this.bps, required this.pinging, required this.ping});
  final double? bps;
  final bool pinging;
  final int? ping;

  /// The spring runs in MiB/s so its settle tolerance is meaningful.
  static const double _mib = 1024 * 1024;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final l = context.l;
    Widget line(String v, String unit, {bool muted = false}) => Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(v,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: t.monoDisplay.copyWith(color: muted ? c.tertiaryLabel : c.label)),
            ),
            if (unit.isNotEmpty)
              Text(' $unit',
                  maxLines: 1, softWrap: false, style: t.mono.copyWith(color: c.tertiaryLabel)),
          ],
        );
    if (pinging) {
      final ms = ping;
      return line(ms == null ? '…' : '$ms', ms == null ? '' : l('unit.ms', {'n': ''}).trim(),
          muted: ms == null);
    }
    final v = bps;
    if (v == null) return line('—', '', muted: true);
    if (context.reduceMotion) {
      final (n, u) = splitSpeed(v, l: l);
      return line(n, u);
    }
    return SpringValue(
      target: v / _mib,
      spring: Springs.of(0.5, 1.0),
      builder: (context, value, _) {
        final (n, u) = splitSpeed((value * _mib).clamp(0, double.infinity), l: l);
        return line(n, u);
      },
    );
  }
}
