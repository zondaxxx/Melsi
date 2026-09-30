import 'package:flutter/material.dart';

import '../../core/game_presets.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../theme/glass.dart';
import '../theme/pressable.dart';
import '../theme/theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/format.dart';
import '../widgets/page.dart';
import '../widgets/segmented.dart';
import 'app_picker.dart';

const _gameA = Color(0xFFFF6A3D);
const _gameB = Color(0xFFE8457C);
const _gameC = Color(0xFF7B5CFF);

enum _GameFilter { all, pc, mobile }

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  _GameFilter _filter = _GameFilter.all;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final g = app.game;
    final presets = kGamePresets.where((p) => switch (_filter) {
          _GameFilter.all => true,
          _GameFilter.pc => p.desktopProcesses.isNotEmpty,
          _GameFilter.mobile => p.androidPackages.isNotEmpty,
        }).toList();
    final gameNode = app.nodeById(g.gameNodeId);

    return PageScaffold(
      title: l('tab.gameTitle'),
      slivers: [
        SliverToBoxAdapter(child: _Hero(enabled: g.enabled, onChanged: (v) => app.updateGame((x) => x.enabled = v))),
        if (g.enabled && app.displayStatus == VpnStatus.connected)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: Space.m),
              child: _GameRoutePanel(app: app),
            ),
          ),
        SliverToBoxAdapter(
          child: SectionHeader(
            l('game.games'),
            trailing: Text(
                l('game.selectedN', {'n': '${g.gameIds.length + g.customApps.length}'}),
                style: context.t.footnote),
          ),
        ),
        SliverToBoxAdapter(
          child: Segmented<_GameFilter>(
            value: _filter,
            onChanged: (f) => setState(() => _filter = f),
            segments: [
              Segment(_GameFilter.all, l('game.all')),
              Segment(_GameFilter.pc, l('game.pc'), icon: Icons.desktop_windows_rounded),
              Segment(_GameFilter.mobile, l('game.mobile'), icon: Icons.phone_iphone_rounded),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        SliverLayoutBuilder(builder: (context, constraints) {
          final w = constraints.crossAxisExtent;
          final cols = w >= 700 ? 4 : w >= 480 ? 3 : 2;
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: Space.m,
              crossAxisSpacing: Space.m,
              mainAxisExtent: 116,
            ),
            itemCount: presets.length,
            itemBuilder: (context, i) {
              final p = presets[i];
              final sel = g.gameIds.contains(p.id);
              return _GameTile(
                preset: p,
                selected: sel,
                onTap: () => app.updateGame((x) {
                  final ids = {...x.gameIds};
                  sel ? ids.remove(p.id) : ids.add(p.id);
                  x.gameIds = ids;
                  if (!sel && !x.enabled) x.enabled = true;
                }),
              );
            },
          );
        }),
        SliverToBoxAdapter(child: SectionHeader(l('game.custom'))),
        SliverToBoxAdapter(
          child: Card2(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(app.isIOS ? l('game.customIos') : l('game.customHint'), style: context.t.footnote),
              if (g.customApps.isNotEmpty) ...[
                const SizedBox(height: Space.m),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final a in g.customApps)
                    InputChip(
                      label: Text(a.label ?? a.id),
                      onDeleted: () => app.updateGame(
                          (x) => x.customApps = x.customApps.where((e) => e.id != a.id).toList()),
                      backgroundColor: c.fill,
                      side: BorderSide.none,
                      shape: Radii.shape(Radii.pill),
                      labelStyle: context.t.subhead,
                    ),
                ]),
              ],
              if (!app.isIOS) ...[
                const SizedBox(height: Space.m),
                SecondaryButton(
                  icon: Icons.add_rounded,
                  label: l('game.addApps'),
                  color: _gameB,
                  onTap: () async {
                    final v = await pickApps(context, selected: g.customApps, title: l('game.custom'));
                    if (v != null) app.updateGame((x) => x.customApps = v);
                  },
                ),
              ],
            ]),
          ),
        ),
        SliverToBoxAdapter(child: SectionHeader(l('game.options'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            RowTile(
              leading: const IconTile(Icons.hub_rounded, color: _gameC),
              title: l('game.node'),
              subtitle: gameNode == null ? l('game.nodeAutoHint') : null,
              trailing: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(gameNode == null ? l('game.nodeAuto') : nodeTitle(gameNode),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.callout.copyWith(color: c.secondaryLabel)),
              ),
              chevron: true,
              onTap: () => _pickGameNode(context, app),
            ),
            SwitchRow(
              leading: IconTile(Icons.download_rounded, color: c.success),
              title: l('game.directDownloads'),
              subtitle: l('game.directDownloadsHint'),
              value: g.directDownloads,
              onChanged: (v) => app.updateGame((x) => x.directDownloads = v),
            ),
            SwitchRow(
              leading: const IconTile(Icons.bolt_rounded, color: _gameA),
              title: l('game.preferUdp'),
              subtitle: l('game.preferUdpHint'),
              value: g.preferUdpProtocols,
              onChanged: (v) => app.updateGame((x) => x.preferUdpProtocols = v),
            ),
            SwitchRow(
              leading: const IconTile(Icons.speed_rounded, color: _gameB),
              title: l('game.lowLatency'),
              subtitle: l('game.lowLatencyHint'),
              value: g.lowLatencyStack,
              onChanged: (v) => app.updateGame((x) => x.lowLatencyStack = v),
            ),
          ]),
        ),
      ],
    );
  }

  Future<void> _pickGameNode(BuildContext context, AppState app) async {
    final l = context.l;
    final nodes = [...app.nodes]..sort((a, b) {
        final u = (b.protocol.udpNative ? 1 : 0) - (a.protocol.udpNative ? 1 : 0);
        if (u != 0) return u;
        return (app.latencyOf(a) ?? 1 << 30).compareTo(app.latencyOf(b) ?? 1 << 30);
      });
    final result = await showMelsiSheet<String>(context, expand: true, builder: (ctx) {
      final c = ctx.c;
      Widget check(bool on) => SizedBox(
          width: 24, child: on ? Icon(Icons.check_rounded, color: c.accent) : null);
      return Column(children: [
        SheetHeader(title: l('game.node')),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.xl),
            children: [
              GroupCard(children: [
                RowTile(
                  leading: const IconTile(Icons.auto_awesome_rounded, color: _gameC),
                  title: l('game.nodeAuto'),
                  subtitle: l('game.nodeAutoHint'),
                  trailing: check(app.game.gameNodeId == null),
                  onTap: () => Navigator.pop(ctx, ''),
                ),
              ]),
              const SizedBox(height: Space.l),
              GroupCard(children: [
                for (final n in nodes)
                  RowTile(
                    dense: true,
                    leading: FlagBadge(n.countryCode, size: 30),
                    title: nodeTitle(n),
                    subtitle: n.protocol.udpNative ? '${n.protocol.label} · UDP' : n.protocol.label,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      LatencyChip(ms: app.latencyOf(n)),
                      const SizedBox(width: Space.s),
                      check(app.game.gameNodeId == n.id),
                    ]),
                    onTap: () => Navigator.pop(ctx, n.id),
                  ),
              ]),
            ],
          ),
        ),
      ]);
    });
    if (result != null) await app.setGameNode(result.isEmpty ? null : result);
  }
}

// ------------------------------------------------------------------ hero

class _Hero extends StatefulWidget {
  const _Hero({required this.enabled, required this.onChanged});
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  State<_Hero> createState() => _HeroState();
}

/// Compact hero: title + one line + the master switch, decoration kept in
/// its own corner. The explanation lives behind "How it works".
class _HeroState extends State<_Hero> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final enabled = widget.enabled;
    return SpringValue(
      target: enabled ? 1 : 0,
      builder: (context, v, _) {
        final t = v.clamp(0.0, 1.0);
        return Container(
          decoration: ShapeDecoration(
            shape: Radii.shape(Radii.xl),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(const Color(0xFF3A3452), _gameA, t)!,
                Color.lerp(const Color(0xFF302A48), _gameB, t)!,
                Color.lerp(const Color(0xFF26223C), _gameC, t)!,
              ],
            ),
            shadows: context.c.isDark
                ? null
                : [
                    BoxShadow(
                      color: _gameB.withValues(alpha: 0.08 + 0.16 * t),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
          ),
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(Radii.xl),
            child: Stack(children: [
              // Decoration: bottom-right, well clear of the switch.
              Positioned(
                right: -18,
                bottom: -26,
                child: Transform.rotate(
                  angle: -0.3 + 0.08 * t,
                  child: Icon(Icons.sports_esports_rounded,
                      size: 118, color: Colors.white.withValues(alpha: 0.07 + 0.05 * t)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.xl, Space.l + 2, Space.l, Space.s),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: PressableScale(
                        scale: 0.99,
                        haptic: true,
                        onTap: () => widget.onChanged(!enabled),
                        semanticLabel: l('game.heroTitle'),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l('game.heroTitle'),
                              style: context.t.title2.copyWith(color: Colors.white)),
                          const SizedBox(height: 3),
                          Text(
                            l('game.heroSub'),
                            style: context.t.subhead
                                .copyWith(color: Colors.white.withValues(alpha: 0.85)),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(width: Space.m),
                    MSwitch(
                      value: enabled,
                      onChanged: widget.onChanged,
                      color: Colors.white.withValues(alpha: 0.38),
                    ),
                  ]),
                  const SizedBox(height: Space.s),
                  PressableScale(
                    scale: 0.98,
                    onTap: () => setState(() => _open = !_open),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.s),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(l('game.howItWorks'),
                            style: context.t.footnote.copyWith(
                                color: Colors.white, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 2),
                        SpringValue(
                          target: _open ? 0.5 : 0,
                          builder: (context, v, child) =>
                              Transform.rotate(angle: v * 3.1416, child: child),
                          child: const Icon(Icons.expand_more_rounded, size: 18, color: Colors.white),
                        ),
                      ]),
                    ),
                  ),
                  AnimatedSize(
                    duration: Duration(milliseconds: context.reduceMotion ? 1 : 320),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: !_open
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(bottom: Space.m, right: Space.xl),
                            child: Column(children: [
                              _Benefit(icon: Icons.graphic_eq_rounded, text: l('game.benefit1')),
                              _Benefit(icon: Icons.download_done_rounded, text: l('game.benefit2')),
                              _Benefit(icon: Icons.bolt_rounded, text: l('game.benefit3')),
                            ]),
                          ),
                  ),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Space.s),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Icon(icon, size: 14, color: Colors.white),
          ),
          const SizedBox(width: Space.m - 2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(text,
                  style: context.t.footnote.copyWith(color: Colors.white, fontWeight: FontWeight.w500)),
            ),
          ),
        ]),
      );
}

// ------------------------------------------------------------------ live panel

class _GameRoutePanel extends StatelessWidget {
  const _GameRoutePanel({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final group = app.gameGroup;
    final node = app.nodeByTag(group?.current);
    final stat = group?.currentStat;
    final lat = stat?.latencyMs;
    return Card2(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const _LiveDot(),
          const SizedBox(width: Space.s),
          Expanded(child: Text(l('game.route'), style: context.t.headline)),
          Pill(group?.auto == false ? l('game.pinned') : l('game.nodeAuto'),
              icon: group?.auto == false ? Icons.push_pin_rounded : Icons.auto_awesome_rounded,
              color: _gameC),
        ]),
        const SizedBox(height: Space.m),
        if (group == null)
          Text(l('game.routeWaiting'), style: context.t.footnote)
        else ...[
          Row(children: [
            FlagBadge(node?.countryCode, size: 36),
            const SizedBox(width: Space.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((node == null ? null : nodeTitle(node)) ?? group.current ?? '—',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t.headline),
                if (node != null) ...[const SizedBox(height: 3), ProtocolBadge(node.protocol)],
              ]),
            ),
            Text(lat == null ? '—' : '$lat',
                style: context.t.title1.copyWith(
                    color: c.latency(lat), fontFeatures: const [FontFeature.tabularFigures()])),
            if (lat != null)
              Padding(
                padding: const EdgeInsets.only(left: 3, top: 8),
                child: Text(l('unit.ms', {'n': ''}).trim(), style: context.t.caption),
              ),
          ]),
          const SizedBox(height: Space.m),
          SizedBox(
            height: 56,
            child: CustomPaint(
              size: Size.infinite,
              painter: LatencyChartPainter(
                samples: app.gameLatencyHistory,
                color: _gameB,
                failColor: c.danger,
                gridColor: c.separator.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: Space.m),
          MetricsRow(items: [
            (l('stat.jitter'), formatMs(stat?.jitterMs, l), null),
            (
              l('stat.loss'),
              stat?.loss == null ? '—' : formatLoss(stat!.loss!),
              (stat?.loss ?? 0) > 0.02 ? c.warning : null,
            ),
            (l('stat.score'), stat?.score == null ? '—' : stat!.score!.toStringAsFixed(1), null),
          ]),
          if (group.lastSwitch?.reason != null) ...[
            const SizedBox(height: Space.m),
            Text(
              group.lastSwitch!.at == null
                  ? l('home.switchedReason', {'reason': group.lastSwitch!.reason!})
                  : l('home.switchedAgo', {
                      'ago': formatAgo(l, DateTime.now().difference(group.lastSwitch!.at!)),
                      'reason': group.lastSwitch!.reason!,
                    }),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.t.footnote,
            ),
          ],
        ],
      ]),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.c.success;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => SizedBox.square(
        dimension: 14,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            width: 6 + 8 * _c.value,
            height: 6 + 8 * _c.value,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.4 * (1 - _c.value))),
          ),
          Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ tiles

class _GameTile extends StatelessWidget {
  const _GameTile({required this.preset, required this.selected, required this.onTap});
  final GamePreset preset;
  final bool selected;
  final VoidCallback onTap;

  /// Deterministic per-game gradient so each tile has its own identity.
  static (Color, Color) colors(String id) {
    var h = 0;
    for (final u in id.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    final a = HSLColor.fromAHSL(1, hue, 0.72, 0.56).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 38) % 360, 0.78, 0.46).toColor();
    return (a, b);
  }

  static String initials(String name) {
    final words = name
        .replaceAll(RegExp(r'[^A-Za-zА-Яа-я0-9 ]'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.substring(0, words.first.length.clamp(0, 2)).toUpperCase();
    }
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (a, b) = colors(preset.id);
    final pc = preset.desktopProcesses.isNotEmpty;
    final mobile = preset.androidPackages.isNotEmpty;
    return PressableScale(
      haptic: true,
      onTap: onTap,
      semanticLabel: preset.name,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(Space.m),
        decoration: ShapeDecoration(
          color: selected
              ? Color.alphaBlend(a.withValues(alpha: c.isDark ? 0.2 : 0.1), c.surface)
              : c.surface,
          shape: Radii.shape(Radii.l,
              side: BorderSide(color: selected ? a : Colors.transparent, width: 1.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                shape: Radii.shape(12),
                gradient: LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b]),
              ),
              child: Text(initials(preset.name),
                  style: context.t.headline.copyWith(color: Colors.white, letterSpacing: -0.5)),
            ),
            const Spacer(),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
              child: selected
                  ? Icon(Icons.check_circle_rounded, key: const ValueKey(1), color: a, size: 22)
                  : Icon(Icons.circle_outlined, key: const ValueKey(0), color: c.tertiaryLabel, size: 22),
            ),
          ]),
          const Spacer(),
          Text(preset.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(children: [
            if (pc) Icon(Icons.desktop_windows_rounded, size: 12, color: c.secondaryLabel),
            if (pc && mobile) const SizedBox(width: 4),
            if (mobile) Icon(Icons.phone_iphone_rounded, size: 12, color: c.secondaryLabel),
          ]),
        ]),
      ),
    );
  }
}
