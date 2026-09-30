import 'package:flutter/material.dart';

import '../../core/game_presets.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../theme/pressable.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/format.dart';
import '../widgets/page.dart';
import '../widgets/segmented.dart';
import 'app_picker.dart';

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
        // The master control. The page title already names the feature, so
        // the row carries only its state ("Включён" / "Выключен") with the
        // switch, and what the mode does lives inside the card as the
        // sublabel rather than floating between two cards.
        SliverToBoxAdapter(
          child: GroupCard(children: [
            SwitchRow(
              title: g.enabled ? l('game.active') : l('game.inactive'),
              subtitle: l('game.heroSub'),
              value: g.enabled,
              onChanged: (v) => app.updateGame((x) => x.enabled = v),
            ),
          ]),
        ),
        if (g.enabled && app.displayStatus == VpnStatus.connected) ...[
          SliverToBoxAdapter(child: SectionHeader(l('game.route'))),
          SliverToBoxAdapter(child: _GameRoutePanel(app: app)),
        ],
        // The count is set in the same small-caps style as the label so the
        // pair reads as one row on one baseline.
        SliverToBoxAdapter(
          child: SectionHeader(
            l('game.games'),
            trailing: Overline(
              l('game.selectedN', {'n': '${g.gameIds.length + g.customApps.length}'}),
              color: c.tertiaryLabel,
            ),
          ),
        ),
        // Capped so three segments never stretch across a 1200px column.
        SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Segmented<_GameFilter>(
                value: _filter,
                onChanged: (f) => setState(() => _filter = f),
                segments: [
                  Segment(_GameFilter.all, l('game.all')),
                  Segment(_GameFilter.pc, l('game.pc'), icon: Icons.desktop_windows_outlined),
                  Segment(_GameFilter.mobile, l('game.mobile'), icon: Icons.smartphone_rounded),
                ],
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        // Dense wrapped chips. Platform glyphs appear only in the mixed
        // "Все" list, where they carry information; under a platform filter
        // they would repeat the filter on every chip.
        SliverToBoxAdapter(
          child: Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            children: [
              for (final p in presets)
                _GameChip(
                  preset: p,
                  platforms: _filter == _GameFilter.all,
                  selected: g.gameIds.contains(p.id),
                  onTap: () => app.updateGame((x) {
                    final ids = {...x.gameIds};
                    final sel = ids.contains(p.id);
                    sel ? ids.remove(p.id) : ids.add(p.id);
                    x.gameIds = ids;
                    if (!sel && !x.enabled) x.enabled = true;
                  }),
                ),
            ],
          ),
        ),
        SliverToBoxAdapter(child: SectionHeader(l('game.custom'))),
        SliverToBoxAdapter(
          child: Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.isIOS ? l('game.customIos') : l('game.customHint'), style: context.t.footnote),
              if (g.customApps.isNotEmpty) ...[
                const SizedBox(height: Space.m),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final a in g.customApps)
                    InputChip(
                      label: Text(a.label ?? a.id),
                      onDeleted: () => app.updateGame(
                          (x) => x.customApps = x.customApps.where((e) => e.id != a.id).toList()),
                      deleteIconColor: c.secondaryLabel,
                      backgroundColor: c.fill,
                      side: BorderSide(color: c.separator, width: kHairline),
                      shape: Radii.shape(Radii.s),
                      labelStyle: context.t.subhead,
                    ),
                ]),
              ],
              if (!app.isIOS) ...[
                const SizedBox(height: Space.m),
                SecondaryButton(
                  icon: Icons.add_rounded,
                  label: l('game.addApps'),
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
              title: l('game.directDownloads'),
              subtitle: l('game.directDownloadsHint'),
              value: g.directDownloads,
              onChanged: (v) => app.updateGame((x) => x.directDownloads = v),
            ),
            SwitchRow(
              title: l('game.preferUdp'),
              subtitle: l('game.preferUdpHint'),
              value: g.preferUdpProtocols,
              onChanged: (v) => app.updateGame((x) => x.preferUdpProtocols = v),
            ),
            SwitchRow(
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
          width: 22, child: on ? Icon(Icons.check_rounded, size: 18, color: c.accent) : null);
      return Column(children: [
        SheetHeader(title: l('game.node')),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.xl),
            children: [
              GroupCard(children: [
                RowTile(
                  title: l('game.nodeAuto'),
                  subtitle: l('game.nodeAutoHint'),
                  trailing: check(app.game.gameNodeId == null),
                  onTap: () => Navigator.pop(ctx, ''),
                ),
              ]),
              const SizedBox(height: Space.m),
              GroupCard(children: [
                for (final n in nodes)
                  RowTile(
                    dense: true,
                    leading: CountryCode(n.countryCode),
                    title: nodeTitle(n),
                    subtitleWidget: Text(
                        n.protocol.udpNative
                            ? '${n.protocol.label.toUpperCase()} · UDP'
                            : n.protocol.label.toUpperCase(),
                        style: ctx.t.monoSmall),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      LatencyChip(ms: app.latencyOf(n)),
                      const SizedBox(width: Space.m),
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

// ------------------------------------------------------------------ live panel

/// The live game route: the server (code, name, protocol · mode · live
/// "Активен" — the same inline idiom as the server lists),
/// the latency sparkline with its scale printed as a word, then the same
/// ПИНГ / ДЖИТТЕР / ПОТЕРИ row the Home server card uses. The ping is a
/// metric like the others, not a display-size hero.
class _GameRoutePanel extends StatelessWidget {
  const _GameRoutePanel({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final group = app.gameGroup;
    final node = app.nodeByTag(group?.current);
    final stat = group?.currentStat;
    final lat = stat?.latencyMs;
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (group == null)
          Padding(
            padding: const EdgeInsets.all(Space.l),
            child: Row(children: [
              const _LiveDot(),
              const SizedBox(width: Space.s + 2),
              Text(l('game.routeWaiting'), style: t.footnote),
            ]),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.l, Space.m),
            child: Row(children: [
              CountryCode(node?.countryCode),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((node == null ? null : nodeTitle(node)) ?? group.current ?? '—',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: t.headline),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (node != null) ...[
                      ProtocolBadge(node.protocol),
                      Text(' · ', style: t.monoSmall.copyWith(color: c.tertiaryLabel)),
                    ],
                    Text((group.auto == false ? l('game.pinned') : l('game.nodeAuto')).toUpperCase(),
                        style: t.monoSmall),
                    const SizedBox(width: Space.s + 2),
                    const _LiveDot(),
                    const SizedBox(width: 5),
                    Text(l('servers.active'), style: t.caption.copyWith(color: c.success)),
                  ]),
                ]),
              ),
            ]),
          ),
          // Scale caption on its own line, then the sparkline (no grid).
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (LatencyChartPainter.peak(app.gameLatencyHistory) case final int peak)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(l('chart.peak', {'v': formatMs(peak, l)}),
                      style: t.monoSmall.copyWith(color: c.tertiaryLabel)),
                ),
              const SizedBox(height: Space.xs),
              SizedBox(
                height: 48,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: LatencyChartPainter(
                    samples: app.gameLatencyHistory,
                    color: c.label,
                    failColor: c.danger,
                  ),
                ),
              ),
            ]),
          ),
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
          if (group.lastSwitch?.reason != null) ...[
            const Hairline(),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, Space.s + 2, Space.l, Space.m),
              child: Text(
                group.lastSwitch!.at == null
                    ? l('home.switchedReason', {'reason': group.lastSwitch!.reason!})
                    : l('home.switchedAgo', {
                        'ago': formatAgo(l, DateTime.now().difference(group.lastSwitch!.at!)),
                        'reason': group.lastSwitch!.reason!,
                      }),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.footnote,
              ),
            ),
          ],
        ],
      ]),
    );
  }
}

/// Live indicator: a green dot with a slow, soft breathing ring while the
/// game route is being measured (still with reduced motion).
class _LiveDot extends StatefulWidget {
  const _LiveDot();
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

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
        dimension: 12,
        child: Stack(alignment: Alignment.center, children: [
          Container(
            width: 6 + 6 * _c.value,
            height: 6 + 6 * _c.value,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.3 * (1 - _c.value))),
          ),
          StatusDot(color, size: 6),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ chips

/// A game as a compact chip: name, then (optionally) small platform glyphs.
/// Selected is a 1px accent stroke at 40% plus an accent check; unselected a
/// hairline. Hover / press fill on desktop, press-scale everywhere.
class _GameChip extends StatelessWidget {
  const _GameChip({
    required this.preset,
    required this.selected,
    required this.onTap,
    this.platforms = true,
  });
  final GamePreset preset;
  final bool selected;
  final VoidCallback onTap;
  final bool platforms;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final pc = platforms && preset.desktopProcesses.isNotEmpty;
    final mobile = platforms && preset.androidPackages.isNotEmpty;
    return Semantics(
      button: true,
      selected: selected,
      label: preset.name,
      child: PressableScale(
        haptic: true,
        onTap: onTap,
        scale: 0.97,
        child: Hoverable(
          builder: (context, hovered, pressed) => AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 34,
            padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m - 2, 0),
            decoration: ShapeDecoration(
              color: interactiveSurface(c, c.surface, hovered: hovered, pressed: pressed),
              shape: Radii.shape(Radii.s + 2,
                  side: BorderSide(
                      color: selected ? c.accent.withValues(alpha: 0.4) : c.separator,
                      width: kHairline)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              // Flexible so a long name ellipsises instead of overflowing
              // the row on narrow phones.
              Flexible(
                child: Text(preset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.subhead.copyWith(
                        fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
              ),
              if (pc || mobile) const SizedBox(width: Space.s),
              if (pc) Icon(Icons.desktop_windows_outlined, size: 12, color: c.tertiaryLabel),
              if (pc && mobile) const SizedBox(width: 3),
              if (mobile) Icon(Icons.smartphone_rounded, size: 12, color: c.tertiaryLabel),
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                child: selected
                    ? Padding(
                        padding: const EdgeInsets.only(left: Space.s),
                        child: Icon(Icons.check_rounded, color: c.accent, size: 15),
                      )
                    : const SizedBox(width: 2),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
