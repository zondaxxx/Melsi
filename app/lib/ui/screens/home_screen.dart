import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../services/engine_api.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/traffic.dart';
import '../shell.dart';
import '../theme/pressable.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/connect_button.dart';
import '../widgets/format.dart';
import '../widgets/page.dart';
import '../widgets/segmented.dart';
import 'add_sheet.dart';
import 'server_switcher.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final wide = context.isWide;
    return PageScaffold(
      title: l('tab.home'),
      maxContentWidth: wide ? 1040 : 760,
      compactLeading: wide ? const SizedBox.shrink() : const Wordmark(),
      slivers: [
        SliverToBoxAdapter(
          child: LayoutBuilder(builder: (context, box) {
            final connected = app.displayStatus == VpnStatus.connected;
            final main = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Status(app: app),
              const SizedBox(height: Space.l),
              ConnectButton(status: app.displayStatus, onTap: app.toggle),
              SectionHeader(
                l('home.server'),
                trailing: app.settings.autoSelect ? Tag(l('home.smartBadge')) : null,
              ),
              _NodePanel(app: app),
              _Reveal(
                visible: connected,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SectionHeader(l('home.traffic')),
                  _TrafficPanel(traffic: app.traffic, connected: connected),
                ]),
              ),
            ]);
            final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionHeader(l('home.quick')),
              _QuickToggles(app: app),
              SectionHeader(l('home.routing')),
              Segmented<RoutingPreset>(
                value: app.routing.preset,
                onChanged: (p) => app.updateRouting((r) => r.preset = p),
                segments: [
                  for (final p in RoutingPreset.values) Segment(p, l('preset.${p.name}.short')),
                ],
              ),
              SectionFooter(l('preset.${app.routing.preset.name}.desc')),
            ]);
            if (box.maxWidth < 820) {
              return Padding(
                padding: const EdgeInsets.only(top: Space.m),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [main, side]),
              );
            }
            // Wide: live column on the left, controls on the right. The side
            // column drops its first header's top margin to align with the
            // status line.
            return Padding(
              padding: const EdgeInsets.only(top: Space.xl),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: main),
                const SizedBox(width: Space.x4),
                SizedBox(
                  width: 320,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SectionHeader(l('home.quick'),
                        padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.s + 2)),
                    _QuickToggles(app: app),
                    SectionHeader(l('home.routing')),
                    Segmented<RoutingPreset>(
                      value: app.routing.preset,
                      onChanged: (p) => app.updateRouting((r) => r.preset = p),
                      segments: [
                        for (final p in RoutingPreset.values)
                          Segment(p, l('preset.${p.name}.short')),
                      ],
                    ),
                    SectionFooter(l('preset.${app.routing.preset.name}.desc')),
                  ]),
                ),
              ]),
            );
          }),
        ),
      ],
    );
  }
}

/// Springs a block open/closed (height + fade) as it becomes relevant.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return AnimatedSize(
      duration: Duration(milliseconds: reduce ? 1 : 380),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: Duration(milliseconds: reduce ? 150 : 260),
        switchInCurve: Curves.easeOut,
        transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
        child: visible
            ? KeyedSubtree(key: const ValueKey(1), child: child)
            : const SizedBox(key: ValueKey(0), width: double.infinity),
      ),
    );
  }
}

// ------------------------------------------------------------------ status

/// One line: a dot in the meaning colour, the status, and — while connected —
/// the session timer in tabular mono. Errors add their message underneath.
class _Status extends StatelessWidget {
  const _Status({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final s = app.displayStatus;
    final color = switch (s) {
      VpnStatus.connected => c.success,
      VpnStatus.connecting || VpnStatus.stopping => c.warning,
      VpnStatus.error => c.danger,
      VpnStatus.stopped => c.tertiaryLabel,
    };
    final String? note = switch (s) {
      VpnStatus.error => app.vpnState.message == 'permission'
          ? l('notice.permissionDenied')
          : (app.vpnState.message ?? l('status.error')),
      VpnStatus.stopped when app.nodes.isEmpty => l('home.addServerHint'),
      _ => null,
    };

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 24,
        child: Row(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: StatusDot(color, key: ValueKey(s), hollow: s == VpnStatus.stopped),
          ),
          const SizedBox(width: Space.s + 2),
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(l('status.${s.name}'),
                  key: ValueKey(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.headline.copyWith(fontSize: 15)),
            ),
          ),
          if (s == VpnStatus.connected) ...[
            Text(' · ', style: t.headline.copyWith(fontSize: 15, color: c.tertiaryLabel)),
            _Timer(since: app.sessionSince ?? DateTime.now()),
          ],
        ]),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: note == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: Space.xs, left: Space.l + 2),
                child: Text(note,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: t.footnote.copyWith(color: s == VpnStatus.error ? c.danger : null)),
              ),
      ),
    ]);
  }
}

class _Timer extends StatefulWidget {
  const _Timer({required this.since});
  final DateTime since;
  @override
  State<_Timer> createState() => _TimerState();
}

class _TimerState extends State<_Timer> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = formatDuration(DateTime.now().difference(widget.since));
    return Text(s,
        semanticsLabel: s,
        style: context.t.mono.copyWith(fontSize: 15, color: context.c.secondaryLabel));
  }
}

// ------------------------------------------------------------------ node panel

class _NodePanel extends StatelessWidget {
  const _NodePanel({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final node = app.activeNode;
    final auto = app.settings.autoSelect;
    final connected = app.displayStatus == VpnStatus.connected;
    final stat = node == null ? null : app.statOf(node);
    final lat = node == null ? null : app.latencyOf(node);
    final sw = app.proxyGroup?.lastSwitch;
    final sub = app.subscriptionById(node?.subscriptionId);

    return PressableScale(
      key: const ValueKey('home-node-panel'),
      scale: 0.99,
      semanticLabel: l('switcher.title'),
      onTap: () => node == null ? showAddSheet(context) : showServerSwitcher(context),
      child: Panel(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.m, Space.m + 2),
              child: node == null
                  ? Row(children: [
                      Expanded(
                        child: Text(l('home.noServer'),
                            style: t.body.copyWith(color: c.secondaryLabel)),
                      ),
                      Icon(Icons.add_rounded, color: c.accent, size: 20),
                    ])
                  : Row(children: [
                      CountryCode(node.countryCode),
                      const SizedBox(width: Space.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(nodeTitle(node),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.headline),
                            const SizedBox(height: 3),
                            Row(children: [
                              ProtocolBadge(node.protocol),
                              if (sub != null) ...[
                                Text(' · ', style: t.monoSmall.copyWith(color: c.tertiaryLabel)),
                                Flexible(
                                  child: Text(sub.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: t.caption),
                                ),
                              ],
                            ]),
                          ],
                        ),
                      ),
                      if (!connected) ...[
                        const SizedBox(width: Space.m),
                        LatencyChip(
                          ms: lat,
                          testing: app.pinging.contains(node.id),
                          failed: app.latencies[node.id]?.failed ?? false,
                          label: l('ping.timeout'),
                          onTest: () => app.pingNode(node.id),
                        ),
                      ],
                      const SizedBox(width: Space.s),
                      Icon(Icons.unfold_more_rounded, color: c.tertiaryLabel, size: 18),
                    ]),
            ),
            if (node != null && connected) ...[
              const Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m + 2),
                child: MetricsRow(items: [
                  (l('stat.latency'), formatMs(lat, l), lat == null ? null : c.latency(lat)),
                  (l('stat.jitter'), formatMs(stat?.jitterMs, l), null),
                  (
                    l('stat.loss'),
                    stat?.loss == null ? '—' : formatLoss(stat!.loss!),
                    (stat?.loss ?? 0) > 0.02 ? c.warning : null,
                  ),
                ]),
              ),
            ],
            if (auto && connected && sw?.reason != null) ...[
              const Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.s + 2, Space.l, Space.m),
                child: _SwitchReason(sw: sw!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SwitchReason extends StatelessWidget {
  const _SwitchReason({required this.sw});
  final LastSwitch sw;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final text = sw.at == null
        ? l('home.switchedReason', {'reason': sw.reason!})
        : l('home.switchedAgo', {
            'ago': formatAgo(l, DateTime.now().difference(sw.at!)),
            'reason': sw.reason!,
          });
    return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t.footnote);
  }
}

// ------------------------------------------------------------------ traffic

class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({required this.traffic, required this.connected});
  final TrafficMonitor traffic;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    return Panel(
      padding: EdgeInsets.zero,
      child: ListenableBuilder(
        listenable: traffic,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.l, 0),
                child: Row(children: [
                  Expanded(child: _Speed(glyph: '↓', bps: traffic.down, label: l('home.down'))),
                  Expanded(child: _Speed(glyph: '↑', bps: traffic.up, label: l('home.up'), quiet: true)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m),
                child: SizedBox(
                  height: 56,
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: SpeedChartPainter(
                      down: traffic.downHistory,
                      up: traffic.upHistory,
                      downColor: c.label,
                      upColor: c.tertiaryLabel,
                      gridColor: c.separator,
                    ),
                  ),
                ),
              ),
              const Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m + 2),
                child: MetricsRow(items: [
                  (l('home.downloaded'), formatBytes(traffic.downTotal, l: l), null),
                  (l('home.uploaded'), formatBytes(traffic.upTotal, l: l), null),
                  (l('home.connections'), connected ? '${traffic.connections}' : '—', null),
                ]),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Speed: overline label, then a large tabular mono number with its unit.
class _Speed extends StatelessWidget {
  const _Speed({required this.glyph, required this.bps, required this.label, this.quiet = false});
  final String glyph;
  final int bps;
  final String label;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final (v, unit) = splitSpeed(bps, l: context.l);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Overline('$glyph $label'),
      const SizedBox(height: 4),
      Text.rich(
        TextSpan(children: [
          TextSpan(text: v, style: t.monoLarge.copyWith(color: quiet ? c.secondaryLabel : c.label)),
          TextSpan(text: ' $unit', style: t.mono.copyWith(color: c.tertiaryLabel)),
        ]),
        maxLines: 1,
        overflow: TextOverflow.fade,
        softWrap: false,
        semanticsLabel: '$label $v $unit',
      ),
    ]);
  }
}

// ------------------------------------------------------------------ quick toggles

/// Quick settings as plain switch rows: title, current value, switch.
class _QuickToggles extends StatelessWidget {
  const _QuickToggles({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return GroupCard(children: [
      _QuickRow(
        title: l('quick.smart'),
        value: app.settings.autoSelect ? l('smart.${app.settings.smartMode.name}.short') : null,
        on: app.settings.autoSelect,
        onChanged: app.setAutoSelect,
      ),
      _QuickRow(
        title: l('quick.game'),
        value: app.game.enabled
            ? l('quick.gameOn', {'n': '${app.game.gameIds.length + app.game.customApps.length}'})
            : null,
        on: app.game.enabled,
        onChanged: (v) => app.updateGame((g) => g.enabled = v),
      ),
      _QuickRow(
        title: l('quick.killSwitch'),
        on: app.settings.killSwitch,
        onChanged: (v) => app.updateSettings((s) => s.killSwitch = v),
      ),
      _QuickRow(
        title: l('quick.antiDpi'),
        on: app.settings.antiDpi,
        onChanged: (v) => app.updateSettings((s) => s.antiDpi = v),
      ),
    ]);
  }
}

class _QuickRow extends StatelessWidget {
  const _QuickRow({required this.title, required this.on, required this.onChanged, this.value});
  final String title;
  final String? value;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
        toggled: on,
        child: RowTile(
          dense: true,
          title: title,
          onTap: () => onChanged(!on),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (value != null) ...[
              Text(value!, style: context.t.footnote),
              const SizedBox(width: Space.m),
            ],
            MSwitch(value: on, onChanged: onChanged),
          ]),
        ),
      );
}
