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
import '../theme/glass.dart';
import '../theme/pressable.dart';
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
      maxContentWidth: wide ? 980 : 760,
      compactLeading: wide ? const SizedBox.shrink() : const _Wordmark(),
      slivers: [
        SliverToBoxAdapter(
          child: LayoutBuilder(builder: (context, box) {
            final connected = app.displayStatus == VpnStatus.connected;
            final node = _NodeCard(app: app);
            final traffic = _Reveal(
              visible: connected,
              child: _TrafficCard(traffic: app.traffic, connected: connected),
            );
            if (box.maxWidth < 820) {
              return Column(children: [
                _Hero(app: app),
                node,
                _Reveal(
                  visible: connected,
                  child: Padding(
                    padding: const EdgeInsets.only(top: Space.m),
                    child: _TrafficCard(traffic: app.traffic, connected: connected),
                  ),
                ),
              ]);
            }
            // Wide: control column on the left, live cards on the right.
            return Padding(
              padding: const EdgeInsets.only(top: Space.l),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 340, child: _Hero(app: app, large: true)),
                const SizedBox(width: Space.xxl),
                Expanded(
                  child: Column(children: [
                    const SizedBox(height: Space.s),
                    node,
                    const SizedBox(height: Space.m),
                    traffic,
                  ]),
                ),
              ]),
            );
          }),
        ),
        SliverToBoxAdapter(child: SectionHeader(l('home.quick'))),
        SliverToBoxAdapter(child: _QuickToggles(app: app)),
        SliverToBoxAdapter(child: SectionHeader(l('home.routing'))),
        SliverToBoxAdapter(
          child: Segmented<RoutingPreset>(
            height: 38,
            value: app.routing.preset,
            onChanged: (p) => app.updateRouting((r) => r.preset = p),
            segments: [
              for (final p in RoutingPreset.values) Segment(p, l('preset.${p.name}.short')),
            ],
          ),
        ),
        SliverToBoxAdapter(child: SectionFooter(l('preset.${app.routing.preset.name}.desc'))),
      ],
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const MelsiLogo(size: 28),
        const SizedBox(width: Space.s + 2),
        Text('Melsi', style: context.t.title3.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
      ]);
}

/// Springs a card open/closed (height + fade) as it becomes relevant.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return AnimatedSize(
      duration: Duration(milliseconds: reduce ? 1 : 420),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: Duration(milliseconds: reduce ? 150 : 320),
        switchInCurve: Curves.easeOut,
        transitionBuilder: (w, a) => FadeTransition(
          opacity: a,
          child: reduce
              ? w
              : ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(a), child: w),
        ),
        child: visible
            ? KeyedSubtree(key: const ValueKey(1), child: child)
            : const SizedBox(key: ValueKey(0), width: double.infinity),
      ),
    );
  }
}

// ------------------------------------------------------------------ hero

class _Hero extends StatelessWidget {
  const _Hero({required this.app, this.large = false});
  final AppState app;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final s = app.displayStatus;
    final h = MediaQuery.sizeOf(context).height;
    final size = large ? 188.0 : (h < 760 || MediaQuery.sizeOf(context).width < 380 ? 150.0 : 168.0);

    final Widget detail = switch (s) {
      VpnStatus.connected => _Timer(key: const ValueKey('timer'), since: app.sessionSince ?? DateTime.now()),
      VpnStatus.error => Padding(
          key: const ValueKey('err'),
          padding: const EdgeInsets.symmetric(horizontal: Space.l),
          child: Text(
            app.vpnState.message == 'permission'
                ? l('notice.permissionDenied')
                : (app.vpnState.message ?? l('status.error')),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: context.t.footnote.copyWith(color: c.danger),
          ),
        ),
      VpnStatus.connecting => Text(l('home.connectingHint'),
          key: const ValueKey('hint-c'),
          textAlign: TextAlign.center,
          style: context.t.subhead.copyWith(color: c.secondaryLabel)),
      _ => Text(app.nodes.isEmpty ? l('home.addServerHint') : l('home.tapToConnect'),
          key: const ValueKey('hint'),
          textAlign: TextAlign.center,
          style: context.t.subhead.copyWith(color: c.secondaryLabel)),
    };

    return Padding(
      padding: EdgeInsets.only(bottom: large ? 0 : Space.l),
      child: Column(
        children: [
          ConnectButton(status: s, size: size, onTap: app.toggle),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(a),
                child: child,
              ),
            ),
            child: Text(
              l('status.${s.name}'),
              key: ValueKey(s),
              style: context.t.title2.copyWith(
                color: switch (s) {
                  VpnStatus.connected => c.success,
                  VpnStatus.error => c.danger,
                  _ => c.label,
                },
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: detail,
            ),
          ),
          if (app.nodes.isEmpty && s == VpnStatus.stopped) ...[
            const SizedBox(height: Space.l),
            PrimaryButton(
              label: l('servers.addSub'),
              icon: Icons.add_rounded,
              onTap: () => showAddSheet(context),
            ),
          ],
        ],
      ),
    );
  }
}

class _Timer extends StatefulWidget {
  const _Timer({super.key, required this.since});
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
  Widget build(BuildContext context) => Text(
        formatDuration(DateTime.now().difference(widget.since)),
        semanticsLabel: formatDuration(DateTime.now().difference(widget.since)),
        style: context.t.display.copyWith(fontSize: 38, fontWeight: FontWeight.w500, letterSpacing: -1.1),
      );
}

// ------------------------------------------------------------------ node card

class _NodeCard extends StatelessWidget {
  const _NodeCard({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final node = app.activeNode;
    final auto = app.settings.autoSelect;
    final connected = app.displayStatus == VpnStatus.connected;
    final stat = node == null ? null : app.statOf(node);
    final lat = node == null ? null : app.latencyOf(node);
    final sw = app.proxyGroup?.lastSwitch;
    final sub = app.subscriptionById(node?.subscriptionId);

    return PressableScale(
      scale: 0.98,
      semanticLabel: l('switcher.title'),
      onTap: () => node == null ? showAddSheet(context) : showServerSwitcher(context),
      child: Card2(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.m, Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CardLabel(
              l('home.server'),
              trailing: auto ? Pill(l('home.smartBadge'), icon: Icons.auto_awesome_rounded) : null,
            ),
            const SizedBox(height: Space.m),
            if (node == null)
              Row(children: [
                Expanded(
                  child: Text(l('home.noServer'),
                      style: context.t.headline.copyWith(color: c.secondaryLabel)),
                ),
                Icon(Icons.add_circle_rounded, color: c.accent),
              ])
            else
              Row(children: [
                FlagBadge(node.countryCode, size: 40),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nodeTitle(node),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.headline),
                      const SizedBox(height: 3),
                      Row(children: [
                        ProtocolBadge(node.protocol),
                        if (sub != null) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(sub.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.t.caption),
                          ),
                        ],
                      ]),
                    ],
                  ),
                ),
                if (!connected) ...[
                  const SizedBox(width: Space.s),
                  LatencyChip(
                    ms: lat,
                    testing: app.pinging.contains(node.id),
                    failed: app.latencies[node.id]?.failed ?? false,
                    label: l('ping.timeout'),
                    onTest: () => app.pingNode(node.id),
                  ),
                ],
                const SizedBox(width: Space.xs),
                Icon(Icons.unfold_more_rounded, color: c.tertiaryLabel, size: 20),
              ]),
            if (node != null && connected) ...[
              const SizedBox(height: Space.m),
              MetricsRow(items: [
                (l('stat.latency'), formatMs(lat, l), lat == null ? null : c.latency(lat)),
                (l('stat.jitter'), formatMs(stat?.jitterMs, l), null),
                (
                  l('stat.loss'),
                  stat?.loss == null ? '—' : formatLoss(stat!.loss!),
                  (stat?.loss ?? 0) > 0.02 ? c.warning : null,
                ),
              ]),
            ],
            if (auto && connected && sw?.reason != null) ...[
              const SizedBox(height: Space.m),
              _SwitchReason(sw: sw!),
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
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(Icons.swap_horiz_rounded, size: 16, color: context.c.accent),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t.footnote),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ traffic

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.traffic, required this.connected});
  final TrafficMonitor traffic;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    return Card2(
      padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.l, Space.l),
      child: ListenableBuilder(
        listenable: traffic,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CardLabel(l('home.traffic')),
              const SizedBox(height: Space.s),
              Row(children: [
                Expanded(child: _Speed(icon: Icons.south_rounded, color: c.success, bps: traffic.down, label: l('home.down'))),
                Expanded(child: _Speed(icon: Icons.north_rounded, color: c.accent2, bps: traffic.up, label: l('home.up'))),
              ]),
              const SizedBox(height: Space.m),
              SizedBox(
                height: 64,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: SpeedChartPainter(
                    down: traffic.downHistory,
                    up: traffic.upHistory,
                    downColor: c.success,
                    upColor: c.accent2,
                    gridColor: c.separator.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(height: Space.m),
              Row(children: [
                Expanded(child: _Total(label: l('home.downloaded'), value: formatBytes(traffic.downTotal, l: l))),
                Expanded(child: _Total(label: l('home.uploaded'), value: formatBytes(traffic.upTotal, l: l))),
                Expanded(child: _Total(label: l('home.connections'), value: connected ? '${traffic.connections}' : '—')),
              ]),
            ],
          );
        },
      ),
    );
  }
}

class _Speed extends StatelessWidget {
  const _Speed({required this.icon, required this.color, required this.bps, required this.label});
  final IconData icon;
  final Color color;
  final int bps;
  final String label;

  @override
  Widget build(BuildContext context) {
    final (v, unit) = splitSpeed(bps, l: context.l);
    return Row(children: [
      Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
        child: Icon(icon, size: 16, color: color),
      ),
      const SizedBox(width: Space.s),
      Flexible(
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: v, style: context.t.title2.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            TextSpan(text: ' $unit', style: context.t.caption),
          ]),
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          semanticsLabel: '$label $v $unit',
        ),
      ),
    ]);
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: context.t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(value, style: context.t.mono.copyWith(fontSize: 14)),
        ],
      );
}

// ------------------------------------------------------------------ quick toggles

class _QuickToggles extends StatelessWidget {
  const _QuickToggles({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final tiles = [
      _Toggle(
        icon: Icons.auto_awesome_rounded,
        color: c.accent,
        title: l('quick.smart'),
        subtitle: app.settings.autoSelect ? l('smart.${app.settings.smartMode.name}.short') : l('common.off'),
        value: app.settings.autoSelect,
        onChanged: app.setAutoSelect,
      ),
      _Toggle(
        icon: Icons.sports_esports_rounded,
        color: const Color(0xFFFF7A1A),
        title: l('quick.game'),
        subtitle: app.game.enabled
            ? l('quick.gameOn', {'n': '${app.game.gameIds.length + app.game.customApps.length}'})
            : l('common.off'),
        value: app.game.enabled,
        onChanged: (v) => app.updateGame((g) => g.enabled = v),
      ),
      _Toggle(
        icon: Icons.lock_rounded,
        color: const Color(0xFF14A8C9),
        title: l('quick.killSwitch'),
        subtitle: app.settings.killSwitch ? l('common.on') : l('common.off'),
        value: app.settings.killSwitch,
        onChanged: (v) => app.updateSettings((s) => s.killSwitch = v),
      ),
      _Toggle(
        icon: Icons.content_cut_rounded,
        color: const Color(0xFFD9468A),
        title: l('quick.antiDpi'),
        subtitle: app.settings.antiDpi ? l('common.on') : l('common.off'),
        value: app.settings.antiDpi,
        onChanged: (v) => app.updateSettings((s) => s.antiDpi = v),
      ),
    ];
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 640 ? 4 : 2;
      final w = (box.maxWidth - Space.s * (cols - 1)) / cols;
      return Wrap(
        spacing: Space.s,
        runSpacing: Space.s,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }
}

/// Compact Control-Center-style toggle: the icon tile fills with colour when
/// on; the whole tile is the hit target.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      toggled: value,
      child: PressableScale(
        haptic: true,
        onTap: () => onChanged(!value),
        semanticLabel: title,
        child: SpringValue(
          target: value ? 1 : 0,
          builder: (context, v, _) {
            final t = v.clamp(0.0, 1.0);
            return Card2(
              padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.s, Space.m),
              radius: Radii.l,
              border: BorderSide(color: color.withValues(alpha: (c.isDark ? 0.45 : 0.35) * t), width: 1),
              color: Color.lerp(c.surface,
                  Color.alphaBlend(color.withValues(alpha: c.isDark ? 0.18 : 0.08), c.surface), t),
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: ShapeDecoration(
                    shape: Radii.shape(10),
                    color: Color.lerp(c.fill, color, t),
                  ),
                  child: Icon(icon, size: 19, color: Color.lerp(c.secondaryLabel, Colors.white, t)),
                ),
                const SizedBox(width: Space.s + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(title,
                            maxLines: 1,
                            style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.caption.copyWith(
                              color: Color.lerp(c.secondaryLabel,
                                  c.isDark ? color : Color.lerp(color, Colors.black, 0.2), t))),
                    ],
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}
