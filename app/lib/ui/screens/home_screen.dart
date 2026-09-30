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
import 'reconnect_banner.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    return PageScaffold(
      title: 'Melsi',
      slivers: [
        const SliverToBoxAdapter(child: ReconnectBanner()),
        SliverToBoxAdapter(child: _Hero(app: app)),
        SliverToBoxAdapter(
          child: LayoutBuilder(builder: (context, box) {
            final two = box.maxWidth >= 680;
            final node = _NodeCard(app: app);
            final traffic = _TrafficCard(traffic: app.traffic, connected: app.connected);
            if (!two) {
              return Column(children: [node, const SizedBox(height: Space.m), traffic]);
            }
            return IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: node),
                const SizedBox(width: Space.m),
                Expanded(child: traffic),
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

// ------------------------------------------------------------------ hero

class _Hero extends StatelessWidget {
  const _Hero({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final s = app.vpnState.status;
    final small = MediaQuery.sizeOf(context).width < 380;
    return Padding(
      padding: const EdgeInsets.only(top: Space.s, bottom: Space.xl),
      child: Column(
        children: [
          ConnectButton(
            status: s,
            size: small ? 164 : 184,
            onTap: app.toggle,
          ),
          const SizedBox(height: Space.xs),
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
          SizedBox(
            height: 58,
            child: switch (s) {
              VpnStatus.connected => _Timer(since: app.connectedAt ?? DateTime.now()),
              VpnStatus.error => Padding(
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
                  style: context.t.callout.copyWith(color: c.secondaryLabel)),
              _ => Text(
                  app.nodes.isEmpty ? l('home.addServerHint') : l('home.tapToConnect'),
                  style: context.t.callout.copyWith(color: c.secondaryLabel)),
            },
          ),
          if (app.nodes.isEmpty && s == VpnStatus.stopped)
            PrimaryButton(
              label: l('servers.add'),
              icon: Icons.add_rounded,
              onTap: () => ShellNav.of(context).go(AppTab.servers),
            ),
        ],
      ),
    );
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
  Widget build(BuildContext context) => Text(
        formatDuration(DateTime.now().difference(widget.since)),
        style: context.t.display.copyWith(fontSize: 40, fontWeight: FontWeight.w500, letterSpacing: -1.2),
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
    final stat = node == null ? null : app.statOf(node);
    final lat = node == null ? null : app.latencyOf(node);
    final sw = app.proxyGroup?.lastSwitch;
    final sub = app.subscriptionById(node?.subscriptionId);

    return PressableScale(
      scale: 0.98,
      onTap: () => ShellNav.of(context).go(AppTab.servers),
      child: Card2(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(l('home.server'), style: context.t.caption),
              const Spacer(),
              if (auto)
                Pill(l('home.smartBadge'), icon: Icons.auto_awesome_rounded),
            ]),
            const SizedBox(height: Space.m),
            if (node == null)
              Text(l('home.noServer'), style: context.t.headline.copyWith(color: c.secondaryLabel))
            else
              Row(children: [
                FlagBadge(node.countryCode, size: 42),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nodeTitle(node),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.headline),
                      const SizedBox(height: 4),
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
                Icon(Icons.chevron_right_rounded, color: c.tertiaryLabel),
              ]),
            if (node != null) ...[
              const SizedBox(height: Space.m),
              Wrap(spacing: 6, runSpacing: 6, children: [
                StatChip(
                  icon: Icons.speed_rounded,
                  label: l('stat.latency'),
                  value: lat == null ? '—' : '$lat ms',
                  color: lat == null ? null : c.latency(lat),
                ),
                if (stat?.jitterMs != null)
                  StatChip(icon: Icons.waves_rounded, label: l('stat.jitter'), value: '${stat!.jitterMs} ms'),
                if (stat?.loss != null)
                  StatChip(
                    icon: Icons.grain_rounded,
                    label: l('stat.loss'),
                    value: '${(stat!.loss! * 100).toStringAsFixed(stat.loss! < 0.1 ? 1 : 0)}%',
                    color: stat.loss! > 0.02 ? c.warning : null,
                  ),
              ]),
            ],
            if (auto && app.connected && sw?.reason != null) ...[
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
    final ago = sw.at == null ? '' : ' · ${_ago(l, DateTime.now().difference(sw.at!))}';
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.swap_horiz_rounded, size: 16, color: context.c.accent),
      const SizedBox(width: 6),
      Expanded(
        child: Text('${l('home.switched')}: ${sw.reason}$ago',
            maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t.footnote),
      ),
    ]);
  }

  static String _ago(L10n l, Duration d) {
    if (d.inSeconds < 60) return l('time.justNow');
    if (d.inMinutes < 60) return l('time.minAgo', {'n': '${d.inMinutes}'});
    return l('time.hAgo', {'n': '${d.inHours}'});
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
      child: ListenableBuilder(
        listenable: traffic,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l('home.traffic'), style: context.t.caption),
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
                Expanded(child: _Total(label: l('home.downloaded'), value: formatBytes(traffic.downTotal))),
                Expanded(child: _Total(label: l('home.uploaded'), value: formatBytes(traffic.upTotal))),
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
    final (v, unit) = splitSpeed(bps);
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
          Text(label, style: context.t.caption2, maxLines: 1, overflow: TextOverflow.ellipsis),
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
        subtitle: l('smart.${app.settings.smartMode.name}'),
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
      final w = (box.maxWidth - Space.m * (cols - 1)) / cols;
      return Wrap(
        spacing: Space.m,
        runSpacing: Space.m,
        children: [for (final t in tiles) SizedBox(width: w, child: t)],
      );
    });
  }
}

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
    return PressableScale(
      haptic: true,
      onTap: () => onChanged(!value),
      semanticLabel: title,
      child: SpringValue(
        target: value ? 1 : 0,
        builder: (context, v, _) {
          final t = v.clamp(0.0, 1.0);
          return Card2(
            padding: const EdgeInsets.all(Space.m + 2),
            color: Color.lerp(c.surface, Color.alphaBlend(color.withValues(alpha: c.isDark ? 0.22 : 0.10), c.surface), t),
            border: BorderSide(color: color.withValues(alpha: 0.45 * t), width: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: ShapeDecoration(
                      shape: Radii.shape(10),
                      color: Color.lerp(c.fill, color, t),
                    ),
                    child: Icon(icon, size: 19, color: Color.lerp(c.secondaryLabel, Colors.white, t)),
                  ),
                  const Spacer(),
                  _Dot(on: value, color: color),
                ]),
                const SizedBox(height: Space.m),
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 1),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.caption.copyWith(color: value ? color : c.secondaryLabel)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.on, required this.color});
  final bool on;
  final Color color;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? color : context.c.fillStrong,
          boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)] : null,
        ),
      );
}
