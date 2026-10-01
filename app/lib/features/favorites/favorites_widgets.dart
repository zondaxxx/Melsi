import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../ui/screens/servers_screen.dart' show NodeRow;
import '../../ui/theme/pressable.dart';
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/format.dart';

// ------------------------------------------------------------------ servers page

/// Servers page: the "Избранное" panel above the subscription groups, in
/// the same panel-with-header idiom as a group. Nothing while there are no
/// favourites, and nothing while the user is [filtering] — the rows are
/// unfiltered copies and would contradict the search.
///
/// The slot passes no filtering flag; the servers screen can forward its
/// own (`favoritesSlivers(context, app, filtering: _filtering)`).
List<Widget> favoritesSlivers(BuildContext context, AppState app, {bool filtering = false}) {
  final favs = app.favouriteNodes;
  if (favs.isEmpty || filtering) return const [];
  final c = context.c;
  return [
    const SliverToBoxAdapter(child: SizedBox(height: Space.l)),
    DecoratedSliver(
      decoration: ShapeDecoration(
        color: c.surface,
        shape: Radii.shape(Radii.m, side: BorderSide(color: c.separator, width: kHairline)),
      ),
      sliver: SliverMainAxisGroup(slivers: [
        SliverToBoxAdapter(child: _FavoritesHeader(count: favs.length)),
        SliverList.builder(
          itemCount: favs.length,
          itemBuilder: (context, i) => _Appear(
            key: ValueKey('fav-${favs[i].id}'),
            child: NodeRow(node: favs[i], last: i == favs.length - 1),
          ),
        ),
      ]),
    ),
  ];
}

/// Mirrors the subscription group header: title in headline, count in
/// muted mono, hairline underneath. A star stands where the group's
/// collapse chevron is (favourites never collapse).
class _FavoritesHeader extends StatelessWidget {
  const _FavoritesHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, Space.s),
        child: SizedBox(
          height: 36,
          child: Row(children: [
            Icon(Icons.star_rounded, color: c.tertiaryLabel, size: 20),
            const SizedBox(width: Space.xs),
            Flexible(
              child: Text(context.l('fav.title'),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: t.headline),
            ),
            const SizedBox(width: Space.s),
            Text('$count', style: t.mono.copyWith(color: c.tertiaryLabel)),
          ]),
        ),
      ),
      const Hairline(),
    ]);
  }
}

/// One-shot fade-in for a row that just arrived in a section (a pin, a
/// recent pick). Reduced motion: appears in place.
class _Appear extends StatefulWidget {
  const _Appear({super.key, required this.child});
  final Widget child;

  @override
  State<_Appear> createState() => _AppearState();
}

class _AppearState extends State<_Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  late final CurvedAnimation _fade = CurvedAnimation(parent: _c, curve: Curves.easeOut);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (context.reduceMotion) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _fade, child: widget.child);
}

// ------------------------------------------------------------------ star

/// Node row trailing: the pin star. Label colour only — a favourite is a
/// bookmark, not a selection. On phones it appears only once pinned (the
/// actions sheet pins); with a mouse an outline star sits in every row,
/// visible on hover, so a pin is one click.
class FavoriteStar extends StatefulWidget {
  const FavoriteStar({super.key, required this.node});
  final ProxyNode node;

  /// Glyph box; the row's latency column follows after [gap].
  static const double size = 22;
  static const double gap = Space.m;

  @override
  State<FavoriteStar> createState() => _FavoriteStarState();
}

class _FavoriteStarState extends State<FavoriteStar> with SingleTickerProviderStateMixin {
  /// 0 → 1 spring driving the pop; rests at 1.
  late final AnimationController _pop = AnimationController.unbounded(vsync: this, value: 1);
  bool _hover = false;
  bool? _wasPinned;

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _toggle(AppState app) {
    HapticFeedback.selectionClick();
    app.toggleFavourite(widget.node.id);
  }

  /// Piecewise map of the spring value to scale: 0 → 1.15 (at 0.7) → 1, so
  /// the star lands with a small pop rather than a plain zoom.
  static double _scale(double v) {
    final t = v.clamp(0.0, 1.0);
    return t < 0.7 ? t / 0.7 * 1.15 : 1.15 - (t - 0.7) / 0.3 * 0.15;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.c;
    final l = context.l;
    final pinned = app.isFavourite(widget.node.id);
    final pointer = app.isDesktopPlatform;

    // Pop only on the transition to pinned (never on first build).
    if (_wasPinned != null && _wasPinned != pinned && pinned && !context.reduceMotion) {
      _pop.value = 0;
      _pop.springTo(1, spring: Springs.momentum);
    }
    _wasPinned = pinned;

    if (!pinned && !pointer) return const SizedBox.shrink();

    final label = pinned ? l('fav.remove') : l('fav.add');
    final visible = pinned || _hover;
    Widget star = AnimatedBuilder(
      animation: _pop,
      builder: (context, child) => Transform.scale(scale: _scale(_pop.value), child: child),
      child: Icon(
        pinned ? Icons.star_rounded : Icons.star_outline_rounded,
        size: 18,
        color: pinned ? c.label : c.tertiaryLabel,
      ),
    );
    star = AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: visible ? 1 : 0,
      child: star,
    );
    Widget box = SizedBox.square(dimension: FavoriteStar.size, child: Center(child: star));
    if (pointer) {
      box = MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: box,
      );
    }
    Widget button = PressableScale(
      scale: 0.85,
      semanticLabel: label,
      onTap: () => _toggle(app),
      child: box,
    );
    if (pointer) button = Tooltip(message: label, child: button);
    return Padding(padding: const EdgeInsets.only(right: FavoriteStar.gap), child: button);
  }
}

// ------------------------------------------------------------------ actions sheet

/// Node actions sheet: "В избранное" / "Убрать из избранного".
List<Widget> favoriteActionRows(BuildContext context, ProxyNode node, VoidCallback close) {
  final app = context.appRead;
  final l = context.l;
  final pinned = app.isFavourite(node.id);
  return [
    RowTile(
      dense: true,
      leading: Icon(pinned ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 18, color: context.c.secondaryLabel),
      title: pinned ? l('fav.remove') : l('fav.add'),
      onTap: () {
        // The sheet was opened from a row that may be the favourites copy:
        // toggling now would unmount it while the sheet is still animating
        // out (and the sheet rebuilds against that row's context). Apply
        // once the route has left the screen.
        final route = ModalRoute.of(context);
        close();
        HapticFeedback.selectionClick();
        void apply() => app.toggleFavourite(node.id);
        if (route == null) {
          apply();
        } else {
          route.completed.then((_) => apply());
        }
      },
    ),
  ];
}

// ------------------------------------------------------------------ quick switcher

/// Quick switcher: the blocks above the full list (only while the search
/// is empty — the switcher spreads the slot only then).
List<Widget> switcherTopBlocks(BuildContext context, AppState app) => [
      ...bestByCountryStrip(context, app),
      ...favoritesSwitcherBlock(context, app),
    ];

/// "Недавние" (up to three recent picks that are not pinned) and
/// "Избранное" cards, each a titled [GroupCard] of switcher-style rows.
/// Rows moving between the two fade rather than jump.
List<Widget> favoritesSwitcherBlock(BuildContext context, AppState app) {
  final favs = app.favouriteNodes;
  final favIds = favs.map((n) => n.id).toSet();
  final recents = app.recentNodes.where((n) => !favIds.contains(n.id)).take(3).toList();
  final l = context.l;
  return [
    if (recents.isNotEmpty) ...[
      _SwitcherBlockLabel(l('fav.recent')),
      _FadingCard(nodes: recents, keyPrefix: 'recent'),
      const SizedBox(height: Space.m),
    ],
    if (favs.isNotEmpty) ...[
      _SwitcherBlockLabel(l('fav.title')),
      _FadingCard(nodes: favs, keyPrefix: 'fav'),
      const SizedBox(height: Space.m),
    ],
  ];
}

/// Overline above a switcher block: the same 4px inset as page sections,
/// without their 32px top gap (the sheet is already tight).
class _SwitcherBlockLabel extends StatelessWidget {
  const _SwitcherBlockLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.s + 2),
        child: Overline(text),
      );
}

/// A [GroupCard] of switcher rows that cross-fades when its membership
/// changes (a row pinned from "Недавние" reappears under "Избранное").
class _FadingCard extends StatelessWidget {
  const _FadingCard({required this.nodes, required this.keyPrefix});
  final List<ProxyNode> nodes;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, ?current],
      ),
      child: GroupCard(
        key: ValueKey('$keyPrefix:${nodes.map((n) => n.id).join(',')}'),
        children: [for (final n in nodes) SwitcherNodeRow(node: n)],
      ),
    );
  }
}

/// One server row in the switcher's favourites / recents cards: the same
/// columns as the switcher's own rows (country, title, protocol ·
/// subscription, latency, check) so the lists read as one.
class SwitcherNodeRow extends StatelessWidget {
  const SwitcherNodeRow({super.key, required this.node});
  final ProxyNode node;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.c;
    final t = context.t;
    final l = context.l;
    final selected = !app.settings.autoSelect && app.selectedNode?.id == node.id;
    final lat = app.latencies[node.id];
    final sub = app.subscriptionById(node.subscriptionId);
    return RowTile(
      dense: true,
      leading: CountryCode(node.countryCode),
      title: nodeTitle(node),
      subtitleWidget: Row(children: [
        ProtocolBadge(node.protocol),
        if (sub != null) ...[
          Text(' · ', style: t.monoSmall.copyWith(color: c.tertiaryLabel)),
          Flexible(
            child: Text(sub.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption),
          ),
        ],
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        LatencyChip(
          ms: app.latencyOf(node),
          testing: app.pinging.contains(node.id),
          failed: lat != null && lat.failed,
          label: l('ping.timeout'),
          onTest: () => app.pingNode(node.id),
        ),
        const SizedBox(width: Space.m),
        SizedBox(
          width: 22,
          child: SpringValue(
            target: selected ? 1 : 0,
            spring: Springs.momentum,
            builder: (context, v, child) =>
                Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
            child: Icon(Icons.check_rounded, color: c.accent, size: 18),
          ),
        ),
      ]),
      onTap: () => pickNode(context, node.id),
    );
  }
}

/// Selects [id] and closes the switcher (the switcher's own row idiom).
void pickNode(BuildContext context, String id) {
  HapticFeedback.selectionClick();
  context.appRead.selectNode(id);
  Navigator.of(context).maybePop();
}

// ------------------------------------------------------------------ best per country

/// "Лучший по стране": one chip per country with a measured latency,
/// fastest first. Hidden with fewer than two countries — one chip would
/// only repeat the list below.
List<Widget> bestByCountryStrip(BuildContext context, AppState app) {
  final best = app.bestByCountry();
  if (best.length < 2) return const [];
  final entries = <(String, ProxyNode, int)>[];
  for (final e in best.entries) {
    final n = app.nodeById(e.value);
    final ms = n == null ? null : app.latencyOf(n);
    if (n == null || ms == null) continue;
    entries.add((e.key, n, ms));
  }
  if (entries.length < 2) return const [];
  entries.sort((a, b) => a.$3.compareTo(b.$3));
  return [
    _SwitcherBlockLabel(context.l('fav.best')),
    _ChipStrip(entries: entries),
    const SizedBox(height: Space.m),
  ];
}

class _ChipStrip extends StatelessWidget {
  const _ChipStrip({required this.entries});
  final List<(String, ProxyNode, int)> entries;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final current = app.settings.autoSelect ? null : app.selectedNode?.id;
    return SizedBox(
      height: 32,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => const LinearGradient(
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.92, 1],
        ).createShader(r),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(right: Space.xl),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(width: Space.s),
          itemBuilder: (context, i) {
            final (cc, node, ms) = entries[i];
            return CountryChip(
              countryCode: cc,
              ms: ms,
              selected: node.id == current,
              onTap: () => pickNode(context, node.id),
            );
          },
        ),
      ),
    );
  }
}

/// Country code box + mono latency in a hairline chip. Neutral throughout:
/// the selected chip fills, it does not turn orange.
class CountryChip extends StatelessWidget {
  const CountryChip({
    super.key,
    required this.countryCode,
    required this.ms,
    required this.onTap,
    this.selected = false,
  });
  final String countryCode;
  final int ms;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    return PressableScale(
      onTap: onTap,
      scale: 0.95,
      semanticLabel: '${countryCode.toUpperCase()} ${formatMs(ms, l)}',
      child: Hoverable(
        builder: (context, hovered, pressed) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(5, 0, 10, 0),
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: interactiveSurface(c, selected ? c.fillStrong : c.surface,
                hovered: hovered, pressed: pressed),
            shape: Radii.shape(Radii.s + 1,
                side: BorderSide(color: c.separator, width: kHairline)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            CountryCode(countryCode, width: 28),
            const SizedBox(width: 6),
            Text(formatMs(ms, l),
                style: context.t.mono.copyWith(
                    fontSize: 12,
                    color: c.label,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}
