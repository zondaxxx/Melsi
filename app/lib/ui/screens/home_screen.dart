import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/game_presets.dart';
import '../../features/doctor/doctor_widgets.dart';
import '../../features/motion/rolling_number.dart';
import '../../features/motion/status_pulse.dart';
import '../../l10n/l10n.dart';
import '../../services/engine_api.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../state/traffic.dart';
import '../shell.dart';
import '../slots/home_slots.dart';
import '../theme/pressable.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/connect_button.dart';
import '../widgets/dashboard_tools.dart';
import '../widgets/format.dart';
import '../widgets/page.dart';
import '../widgets/route_field.dart';
import '../widgets/segmented.dart';
import 'add_sheet.dart';
import 'server_switcher.dart';

/// Widest the live column gets on desktop. The connect button, the server
/// card and the traffic card all share this one width — one grid line, not
/// two.
const double _kMainMaxWidth = 600;
const double _kRailWidth = 320;

/// Two columns need the live column plus the rail; below this the rail
/// stacks under the live column as on phones.
const double _kTwoColumnMin = 840;

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final wide = context.isWide;
    // Same content column as every other page, so the headline's left edge
    // is the other tabs' title edge; on desktop the live column and the rail
    // split that column between them.
    return PageScaffold(
      title: l('tab.home'),
      maxContentWidth: 1040,
      compactLeading: wide ? const SizedBox.shrink() : const Wordmark(),
      slivers: [
        SliverToBoxAdapter(
          child: LayoutBuilder(builder: (context, box) {
            final twoColumn = box.maxWidth >= _kTwoColumnMin;
            final status = app.displayStatus;
            final connected = status == VpnStatus.connected;
            // Telemetry exists only once a session does.
            final session = connected || status == VpnStatus.connecting;
            final hasServer = app.activeNode != null;

            final traffic = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SectionHeader(l('home.traffic')),
              _TrafficPanel(traffic: app.traffic, idle: !connected),
              HomeSlots.afterTraffic(context, app),
            ]);

            final main = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _RouteStage(app: app, status: status, tall: twoColumn),
              const SizedBox(height: Space.l),
              Overline(l('dashboard.eyebrow')),
              const SizedBox(height: Space.s),
              _Status(app: app),
              const SizedBox(height: Space.l),
              ConnectButton(
                status: status,
                height: wide ? 64 : 60,
                hasServer: hasServer,
                noServerLabel: app.nodes.isEmpty ? l('servers.add') : l('home.chooseServer'),
                onTap: hasServer
                    ? app.toggle
                    : () => app.nodes.isEmpty ? showAddSheet(context) : showServerSwitcher(context),
              ),
              HomeSlots.underButton(context, app),
              SectionHeader(l('home.server'),
                  padding: const EdgeInsets.fromLTRB(Space.xs, Space.xl, Space.xs, Space.s + 2)),
              _NodePanel(app: app),
              HomeSlots.connectionRoute(context, app),
              const DashboardTools(),
              const HomeFavorites(),
              // Telemetry appears with the session (dashes while the tunnel
              // comes up, live once connected). An empty chart is not
              // information, on a phone or a desktop.
              if (twoColumn) ...[
                HomeSlots.afterNodePanel(context, app),
                _Reveal(visible: session, child: DashboardDetails(child: traffic)),
              ],
            ]);

            Widget side({EdgeInsetsGeometry? firstHeaderPadding, bool alerts = true}) =>
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (alerts) HomeSlots.railTop(context, app),
                  SectionHeader(l('home.quick'), padding: firstHeaderPadding),
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

            if (!twoColumn) {
              return Padding(
                padding: const EdgeInsets.only(top: Space.m),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // Warnings sit above the map on a phone so they stay in
                  // the first screen. On a wide layout they stay in the rail.
                  HomeSlots.railTop(context, app),
                  main,
                  HomeSlots.afterNodePanel(context, app),
                  side(alerts: false),
                  _Reveal(visible: session, child: DashboardDetails(child: traffic)),
                ]),
              );
            }
            // Wide: live column on the left (capped, left-aligned; the map,
            // status and connect button share the cap), controls in a fixed
            // rail on the right. The server stays in the live column, under
            // the connect control.
            return Padding(
              padding: const EdgeInsets.only(top: Space.s),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _kMainMaxWidth),
                      child: main,
                    ),
                  ),
                ),
                const SizedBox(width: Space.x4),
                SizedBox(
                  width: _kRailWidth,
                  child: side(
                      firstHeaderPadding:
                          const EdgeInsets.fromLTRB(Space.xs, Space.s, Space.xs, Space.s + 2)),
                ),
              ]),
            );
          }),
        ),
      ],
    );
  }
}

/// The map sits above the status. Origin is the last real (pre-VPN) IP.
/// The flight waits for the post-VPN exit lookup and lands on that country,
/// which can differ from the server address in the subscription.
class _RouteStage extends StatelessWidget {
  const _RouteStage({required this.app, required this.status, required this.tall});
  final AppState app;
  final VpnStatus status;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final net = FeaturesScope.maybeOf(context)?.netcheck;
    final height = tall ? 248.0 : 196.0;
    if (net == null) {
      return RouteField(status: status, height: height, exitSkipped: true);
    }
    return ListenableBuilder(
      listenable: net,
      builder: (context, _) {
        final exit = net.exitIp;
        final connected = status == VpnStatus.connected;
        final ready = connected && _located(exit);
        return RouteField(
          originCode: net.realIp?.countryCode,
          originLat: net.realIp?.latitude,
          originLon: net.realIp?.longitude,
          exitCode: ready ? exit?.countryCode : null,
          exitLat: ready ? exit?.latitude : null,
          exitLon: ready ? exit?.longitude : null,
          exitReady: ready,
          exitFailed: connected && net.error && exit == null,
          exitSkipped: !app.settings.ipCheck,
          status: status,
          height: height,
        );
      },
    );
  }
}

bool _located(IpInfo? info) {
  if (info == null) return false;
  final code = info.countryCode?.trim();
  if (code != null && code.length == 2) return true;
  return info.latitude != null && info.longitude != null;
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

/// The headline of the page: a 10px dot in the meaning colour, the status
/// at title size, and — while connected — the session timer in tabular mono
/// at the same size. The state is readable without reading the button.
/// Errors add their message underneath.
class _Status extends StatelessWidget {
  const _Status({required this.app});
  final AppState app;

  static const double _dot = 10;
  static const double _gap = Space.m;

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
    final style = t.monoDisplay.copyWith(fontSize: 28, height: 1.1);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: StatusPulse(
                key: ValueKey(s),
                color: color,
                size: _dot,
                hollow: s == VpnStatus.stopped,
                active: s == VpnStatus.connected),
          ),
          const SizedBox(width: _gap),
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(l('status.${s.name}'),
                  key: ValueKey(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style),
            ),
          ),
        ]),
      if (s == VpnStatus.connected)
        Padding(
          padding: const EdgeInsets.only(top: Space.xs, left: _dot + _gap),
          child: _Timer(since: app.sessionSince ?? DateTime.now()),
        ),
      AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: note == null
            ? SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.only(left: _dot + _gap),
                  child: HomeSlots.statusNote(context, app),
                ),
              )
            : Padding(
                padding: const EdgeInsets.only(top: Space.xs, left: _dot + _gap),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(note,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: t.footnote.copyWith(color: s == VpnStatus.error ? c.danger : null)),
                  // An error is a question; the diagnostics answer it.
                  if (s == VpnStatus.error)
                    PressableScale(
                      scale: 0.97,
                      behavior: HitTestBehavior.deferToChild,
                      semanticLabel: l('home.diagnose'),
                      onTap: () => showDoctorSheet(context),
                      child: Padding(
                        padding: const EdgeInsets.only(top: Space.xs),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.troubleshoot_rounded, size: 15, color: c.label),
                          const SizedBox(width: Space.xs + 1),
                          Text(l('home.diagnose'),
                              style: t.footnote.copyWith(
                                  color: c.label, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    ),
                ]),
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
    return MonoNumber(s,
        semanticsLabel: s,
        style: context.t.monoLarge.copyWith(fontSize: 16, color: context.c.secondaryLabel));
  }
}

// ------------------------------------------------------------------ node panel

/// The active server. One affordance: the whole card opens the switcher
/// (the trailing chevron says so). "Авто" sits next to the name when smart
/// selection is on. Latency is shown as a value when known — measuring
/// lives in the switcher and the Servers list.
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
    final failed = node != null && (app.latencies[node.id]?.failed ?? false);
    final sw = app.proxyGroup?.lastSwitch;
    final sub = app.subscriptionById(node?.subscriptionId);

    return PressableScale(
      key: const ValueKey('home-node-panel'),
      scale: 0.99,
      semanticLabel: l('switcher.title'),
      onTap: () => node == null ? showAddSheet(context) : showServerSwitcher(context),
      child: Hoverable(
        builder: (context, hovered, pressed) => Panel(
          padding: EdgeInsets.zero,
          color: interactiveSurface(c, c.surface, hovered: hovered, pressed: pressed),
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
                        Icon(Icons.add_rounded, color: c.secondaryLabel, size: 20),
                      ])
                    : Row(children: [
                        CountryCode(node.countryCode),
                        const SizedBox(width: Space.m),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Flexible(
                                  child: Text(nodeTitle(node),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: t.headline),
                                ),
                                if (auto) ...[
                                  const SizedBox(width: Space.s),
                                  Tag(l('home.smartBadge')),
                                ],
                              ]),
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
                        if (!connected && (lat != null || failed)) ...[
                          const SizedBox(width: Space.m),
                          LatencyChip(ms: lat, failed: failed, label: l('ping.timeout')),
                        ],
                        const SizedBox(width: Space.s),
                        Icon(Icons.chevron_right, color: c.secondaryLabel, size: 18),
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
    // The engine writes the reason ("джиттер 3 мс против 21 мс"); binding
    // each number to its unit keeps a lone "мс" off the second line.
    final reason = bindUnits(sw.reason!);
    final text = sw.at == null
        ? l('home.switchedReason', {'reason': reason})
        : l('home.switchedAgo', {
            'ago': formatAgo(l, DateTime.now().difference(sw.at!)),
            'reason': reason,
          });
    return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t.footnote);
  }
}

// ------------------------------------------------------------------ traffic

/// Speeds, a two-line sparkline with its scale printed top-right ("макс.
/// 2.8 МБ/с" — a word, so it is never mistaken for the upload figure), totals.
/// The two captions carry line swatches (solid / dashed, painted in the
/// chart's own pattern) and so double as the legend; both live values are
/// set in the label colour — the swatch alone tells the series apart.
/// [idle] (not connected) prints dashes and an empty plot with a "нет
/// данных" caption instead of the peak.
class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({required this.traffic, this.idle = false});
  final TrafficMonitor traffic;
  final bool idle;

  static const double _chartHeight = 52;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    return Panel(
      padding: EdgeInsets.zero,
      child: ListenableBuilder(
        listenable: traffic,
        builder: (context, _) {
          final peak = SpeedChartPainter.peak(traffic.downHistory, traffic.upHistory);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.l, 0),
                child: Row(children: [
                  Expanded(
                    child: _Speed(
                      glyph: '↓',
                      bps: idle ? null : traffic.down,
                      label: l('home.down'),
                      swatch: SeriesSwatch(color: c.label),
                    ),
                  ),
                  Expanded(
                    child: _Speed(
                      glyph: '↑',
                      bps: idle ? null : traffic.up,
                      label: l('home.up'),
                      swatch: SeriesSwatch(color: c.secondaryLabel, dashed: true),
                    ),
                  ),
                ]),
              ),
              // Scale caption on its own line above the chart so it never
              // collides with the line, then the sparkline.
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, Space.m),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      idle ? l('chart.noData') : l('chart.peak', {'v': formatSpeed(peak, l: l)}),
                      style: t.monoSmall.copyWith(color: c.tertiaryLabel),
                    ),
                  ),
                  const SizedBox(height: Space.xs),
                  SizedBox(
                    height: _chartHeight,
                    child: idle
                        // Empty plot: just the baseline the series would sit on.
                        ? const Align(alignment: Alignment.bottomCenter, child: Hairline())
                        : CustomPaint(
                            size: Size.infinite,
                            painter: SpeedChartPainter(
                              down: traffic.downHistory,
                              up: traffic.upHistory,
                              downColor: c.label,
                              upColor: c.secondaryLabel,
                            ),
                          ),
                  ),
                ]),
              ),
              const Hairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m + 2),
                child: MetricsRow(items: [
                  (l('home.downloaded'), idle ? '—' : formatBytes(traffic.downTotal, l: l), null),
                  (l('home.uploaded'), idle ? '—' : formatBytes(traffic.upTotal, l: l), null),
                  (l('home.connections'), idle ? '—' : '${traffic.connections}', null),
                ]),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Speed: line swatch + overline label, then a large tabular mono number
/// with its unit. A null [bps] prints a dash (no data).
class _Speed extends StatelessWidget {
  const _Speed({
    required this.glyph,
    required this.bps,
    required this.label,
    this.swatch,
  });
  final String glyph;
  final int? bps;
  final String label;
  final Widget? swatch;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final (v, unit) = bps == null ? ('—', '') : splitSpeed(bps!, l: context.l);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (swatch != null) ...[swatch!, const SizedBox(width: 6)],
        Flexible(child: Overline('$glyph $label')),
      ]),
      const SizedBox(height: 4),
      Semantics(
        label: '$label $v $unit',
        child: ExcludeSemantics(
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Flexible(
              child: MonoNumber(v,
                  style: t.monoLarge.copyWith(color: bps == null ? c.tertiaryLabel : c.label)),
            ),
            if (unit.isNotEmpty)
              Text(' $unit',
                  maxLines: 1, softWrap: false, style: t.mono.copyWith(color: c.tertiaryLabel)),
          ]),
        ),
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
            ? l.plural(kGamePresets.where((preset) => app.game.gameIds.contains(preset.id) &&
                preset.supportsPlatform(app.platform)).length + app.game.customApps.length, 'n.games')
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
      _QuickRow(
        title: l('dashboard.ads'),
        on: app.routing.blockAds,
        onChanged: (v) => app.updateRouting((r) => r.blockAds = v),
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
              // The current value is data: label colour, not the muted grey.
              Text(value!, style: context.t.callout.copyWith(color: context.c.label)),
              const SizedBox(width: Space.m),
            ],
            MSwitch(value: on, onChanged: onChanged),
          ]),
        ),
      );
}
