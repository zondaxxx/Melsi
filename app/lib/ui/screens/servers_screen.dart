import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/compatibility_core.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../slots/servers_slots.dart';
import '../theme/entrance.dart';
import '../theme/pressable.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/format.dart';
import '../widgets/page.dart';
import 'add_sheet.dart';

/// Size of the tool buttons on the title row.
const double _kToolSize = 36;

class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final _search = TextEditingController();
  final Set<String> _collapsed = {};
  NodeSort _sort = NodeSort.none;
  ProxyProtocol? _protocol;
  String? _country;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _filtering =>
      _search.text.trim().isNotEmpty || _protocol != null || _country != null;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;

    final groups = <(Subscription?, List<ProxyNode>)>[];
    for (final s in app.subscriptions) {
      groups.add((s, _nodes(app, s.id)));
    }
    if (app.hasManualNodes) groups.add((null, _nodes(app, null)));

    final empty = app.nodes.isEmpty && app.subscriptions.isEmpty;
    // An emptied list enters again the next time it fills.
    if (app.nodes.isEmpty) StaggeredEntrance.reset('servers');
    final entranceOffsets = <String?, int>{};
    var entranceOffset = 0;
    for (final (subscription, groupNodes) in groups) {
      entranceOffsets[subscription?.id] = entranceOffset;
      if (!_collapsed.contains(subscription?.id ?? '_')) {
        entranceOffset += groupNodes.length;
      }
    }
    final viaUrl = app.connected;
    final subs = app.subscriptions.length;
    return PageScaffold(
      title: l('tab.servers'),
      subtitle: app.nodes.isEmpty
          ? null
          : Text([
              l.plural(app.nodes.length, 'n.servers'),
              if (subs > 0) l.plural(subs, 'n.subs'),
            ].join(' · ')),
      // Tool buttons share the title row (36px square, right-aligned).
      actions: [
        if (!empty) ...[
          _SortButton(value: _sort, onChanged: (s) => setState(() => _sort = s)),
          ToolButton(
            icon: Icons.speed_rounded,
            size: _kToolSize,
            tooltip: viaUrl ? l('servers.pingAllUrl') : l('servers.pingAllTcp'),
            busy: app.pingingAll,
            onTap: app.nodes.isEmpty ? null : app.pingAll,
          ),
        ],
        ToolButton(
          icon: Icons.add_rounded,
          size: _kToolSize,
          tooltip: l('servers.add'),
          onTap: () => showAddSheet(context),
        ),
      ],
      slivers: [
        // The empty state sits a little above the geometric centre of the
        // remaining viewport (the buttons pull the visual mass down).
        if (empty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: Space.x4),
                child: ServersEmptyState(),
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(child: _searchBar(app, l, c)),
          ...ServersSlots.beforeGroups(context, app, filtering: _filtering),
          for (final (i, (sub, nodes)) in groups.indexed)
            if (!_filtering || nodes.isNotEmpty) ...[
              SliverToBoxAdapter(child: SizedBox(height: i == 0 ? Space.l : Space.m)),
              DecoratedSliver(
                decoration: ShapeDecoration(
                  color: c.surface,
                  shape: Radii.shape(Radii.m, side: BorderSide(color: c.separator, width: kHairline)),
                ),
                sliver: SliverMainAxisGroup(slivers: [
                  SliverToBoxAdapter(
                    child: _GroupHeader(
                      sub: sub,
                      count: sub == null ? nodes.length : app.nodesOf(sub.id).length,
                      collapsed: _collapsed.contains(sub?.id ?? '_'),
                      onToggle: () => setState(() {
                        final k = sub?.id ?? '_';
                        _collapsed.contains(k) ? _collapsed.remove(k) : _collapsed.add(k);
                      }),
                    ),
                  ),
                  if (!_collapsed.contains(sub?.id ?? '_'))
                    if (nodes.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.l),
                          child: Text(
                            app.updating.contains(sub?.id) ? l('servers.updating') : l('servers.groupEmpty'),
                            style: context.t.footnote,
                          ),
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: nodes.length,
                        itemBuilder: (context, i) => StaggeredEntrance(
                          group: 'servers',
                          index: entranceOffsets[sub?.id]! + i,
                          child: NodeRow(
                            node: nodes[i],
                            last: i == nodes.length - 1,
                          ),
                        ),
                      ),
                ]),
              ),
            ],
        ],
      ],
    );
  }

  List<ProxyNode> _nodes(AppState app, String? subId) => app.filteredNodes(
        subscriptionId: subId,
        allSubscriptions: false,
        query: _search.text,
        protocol: _protocol,
        country: _country,
        sort: _sort,
      );

  Widget _searchBar(AppState app, L10n l, MelsiColors c) {
    final countries = app.countries.toList()..sort();
    final protocols = app.protocols.toList()..sort((a, b) => a.label.compareTo(b.label));
    final canUpdate = app.subscriptions.any((s) => s.url != null);
    // The long placeholder truncates mid-word under ~380px; use the short one.
    final narrow = MediaQuery.sizeOf(context).width < 380;
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Column(children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          style: context.t.body,
          decoration: InputDecoration(
            hintText: narrow ? l('servers.searchShort') : l('servers.search'),
            prefixIcon: Icon(Icons.search_rounded, color: c.tertiaryLabel, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 38),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: l('common.clear'),
                    icon: Icon(Icons.close_rounded, size: 16, color: c.tertiaryLabel),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
        const SizedBox(height: Space.s),
        SizedBox(
          height: 30,
          child: Row(children: [
            Expanded(
              child: _FadeEdges(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _FilterChip(
                      label: _protocol?.label ?? l('servers.protocol'),
                      active: _protocol != null,
                      options: [
                        (null, l('common.all')),
                        for (final p in protocols) (p, p.label),
                      ],
                      onSelected: (p) => setState(() => _protocol = p),
                    ),
                    const SizedBox(width: Space.s),
                    _FilterChip<String?>(
                      label: _country == null ? l('servers.country') : countryLabel(_country!),
                      active: _country != null,
                      options: [
                        (null, l('common.all')),
                        for (final cc in countries) (cc, countryLabel(cc)),
                      ],
                      onSelected: (v) => setState(() => _country = v),
                    ),
                    if (_filtering) ...[
                      const SizedBox(width: Space.s),
                      _ActionChip(
                        icon: Icons.close_rounded,
                        label: l('servers.reset'),
                        onTap: () => setState(() {
                          _protocol = null;
                          _country = null;
                          _search.clear();
                        }),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (canUpdate) ...[
              const SizedBox(width: Space.s),
              ToolButton(
                icon: Icons.sync_rounded,
                size: 30,
                tooltip: l('servers.updateAll'),
                busy: app.updating.isNotEmpty,
                onTap: app.updateAllSubscriptions,
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Country as its ISO code (flags are carried by [CountryCode] boxes).
String countryLabel(String cc) => cc.toUpperCase();

/// Fades the end of a horizontal scroller so clipped chips read as
/// "there's more", not as a layout bug.
class _FadeEdges extends StatelessWidget {
  const _FadeEdges({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => const LinearGradient(
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.9, 1],
        ).createShader(r),
        child: child,
      );
}

/// First-run state: one primary action, two shortcuts. Buttons run to the
/// page gutter on phones (capped only on wide layouts).
class ServersEmptyState extends StatelessWidget {
  const ServersEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final mobile = Platform.isAndroid || Platform.isIOS;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.dns_outlined, size: 28, color: c.tertiaryLabel),
        const SizedBox(height: Space.l),
        Text(l('servers.emptyTitle'), style: context.t.title3, textAlign: TextAlign.center),
        const SizedBox(height: Space.s),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Text(l('servers.emptyText'),
              style: context.t.callout.copyWith(color: c.secondaryLabel), textAlign: TextAlign.center),
        ),
        const SizedBox(height: Space.xxl),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PrimaryButton(
              label: l('servers.addSub'),
              expand: true,
              onTap: () => showAddSheet(context),
            ),
            const SizedBox(height: Space.s),
            Row(children: [
              Expanded(
                child: SecondaryButton(
                  label: l('add.paste'),
                  expand: true,
                  onTap: () => importFromClipboard(context),
                ),
              ),
              if (mobile) ...[
                const SizedBox(width: Space.s),
                Expanded(
                  child: SecondaryButton(
                    label: l('add.scanShort'),
                    expand: true,
                    onTap: () => importFromQr(context),
                  ),
                ),
              ],
            ]),
          ]),
        ),
        ServersSlots.emptyHint(context),
      ]),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.value, required this.onChanged});
  final NodeSort value;
  final ValueChanged<NodeSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return PopupMenuButton<NodeSort>(
      tooltip: l('servers.sort'),
      initialValue: value,
      onSelected: (v) {
        HapticFeedback.selectionClick();
        onChanged(v);
      },
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final s in NodeSort.values)
          PopupMenuItem(
            value: s,
            child: Row(children: [
              SizedBox(
                width: 24,
                child: s == value ? Icon(Icons.check_rounded, size: 16, color: context.c.accent) : null,
              ),
              Text(l('sort.${s.name}')),
            ]),
          ),
      ],
      child: IgnorePointer(
        child: ToolButton(
          icon: value == NodeSort.none ? Icons.swap_vert_rounded : Icons.sort_rounded,
          size: _kToolSize,
          onTap: _noop,
        ),
      ),
    );
  }

  static void _noop() {}
}

class _FilterChip<T> extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.options,
    required this.onSelected,
  });
  final String label;
  final bool active;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PopupMenuButton<int>(
      position: PopupMenuPosition.under,
      tooltip: '',
      onSelected: (i) => onSelected(options[i].$1),
      constraints: const BoxConstraints(maxHeight: 420, minWidth: 160),
      itemBuilder: (_) => [
        for (var i = 0; i < options.length; i++)
          PopupMenuItem(value: i, height: 38, child: Text(options[i].$2)),
      ],
      child: Hoverable(
        builder: (context, hovered, pressed) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.only(left: 10, right: 6),
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: interactiveSurface(c, c.surface, hovered: hovered, pressed: pressed),
            shape: Radii.shape(Radii.s,
                side: BorderSide(color: active ? c.accent : c.separator, width: kHairline)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: context.t.caption.copyWith(
                    fontSize: 13, color: active ? c.accent : c.label)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more_rounded, size: 16, color: active ? c.accent : c.tertiaryLabel),
          ]),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PressableScale(
      onTap: onTap,
      haptic: true,
      child: Hoverable(
        builder: (context, hovered, pressed) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.only(left: 8, right: 10),
          alignment: Alignment.center,
          decoration: ShapeDecoration(
              color: interactiveSurface(c, Color.alphaBlend(c.fill, c.background),
                  hovered: hovered, pressed: pressed),
              shape: Radii.shape(Radii.s, side: BorderSide(color: c.separator, width: kHairline))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: c.secondaryLabel),
            const SizedBox(width: 4),
            Text(label, style: context.t.caption.copyWith(fontSize: 13, color: c.label)),
          ]),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ group header

/// Top of a subscription's panel: name, count, usage bar, expiry. Node rows
/// continue the same panel underneath.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.sub,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });
  final Subscription? sub;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final s = sub;
    final used = (s?.upload ?? 0) + (s?.download ?? 0);
    final total = s?.total ?? 0;
    final frac = total > 0 ? (used / total).clamp(0.0, 1.0) : null;
    final expire = s?.expire;
    final daysLeft = expire?.difference(DateTime.now()).inDays;
    final updating = s != null && app.updating.contains(s.id);
    String two(int n) => n.toString().padLeft(2, '0');

    final meta = <String>[
      if (expire != null && daysLeft! >= 0)
        l('sub.until', {'d': '${two(expire.day)}.${two(expire.month)}.${expire.year}'}),
      if (s?.updatedAt != null) l('sub.updated', {'t': _time(s!.updatedAt!)}),
    ];
    final hasMeta = s != null && (frac != null || meta.isNotEmpty || (daysLeft ?? 0) < 0);
    // The 36px menu square already leaves ~8px under the title glyphs; with
    // only a caption below (no usage line and bar) the row gives up its
    // bottom padding so the caption sits close to the name.
    final tight = hasMeta && frac == null;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, tight ? 0 : Space.s),
        child: Row(children: [
          Expanded(
            child: PressableScale(
              scale: 0.99,
              onTap: onToggle,
              semanticLabel: s?.name ?? l('servers.manual'),
              child: Row(children: [
                SpringValue(
                  target: collapsed ? -0.25 : 0,
                  builder: (context, v, child) => Transform.rotate(angle: v * 6.2832, child: child),
                  child: Icon(Icons.expand_more_rounded, color: c.tertiaryLabel, size: 20),
                ),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: Text(
                    s?.name ?? l('servers.manual'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.headline,
                  ),
                ),
                const SizedBox(width: Space.s),
                Text('$count', style: t.mono.copyWith(color: c.tertiaryLabel)),
              ]),
            ),
          ),
          // One sync glyph on the page: the filter row updates every
          // subscription; this one's own refresh lives in its "…" menu.
          // Only the progress shows here.
          if (updating)
            const SizedBox.square(
              dimension: 36,
              child: Center(
                  child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5))),
            ),
          if (s != null) _SubMenu(sub: s),
        ]),
      ),
      if (hasMeta)
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (frac != null) ...[
              Row(children: [
                Expanded(
                  child: Text(
                    l('sub.usage', {'used': formatBytes(used, l: l), 'total': formatBytes(total, l: l)}),
                    style: t.mono.copyWith(color: c.secondaryLabel),
                  ),
                ),
                if (daysLeft != null)
                  Text(
                    daysLeft < 0 ? l('sub.expired') : l('sub.daysLeft', {'n': '$daysLeft'}),
                    // A measured value like the usage beside it: mono. A word
                    // ("Подписка истекла") stays in the UI sans.
                    style: (daysLeft < 0 ? t.footnote : t.mono).copyWith(
                        color: daysLeft < 3 ? c.danger : c.secondaryLabel,
                        fontWeight: daysLeft < 3 ? FontWeight.w600 : null),
                  ),
              ]),
              const SizedBox(height: 6),
              // Track + fill. The fill needs tight constraints to paint:
              // an unpositioned child-less ColoredBox collapses to zero.
              ClipRRect(
                borderRadius: BorderRadius.circular(1),
                child: SizedBox(
                  height: 3,
                  width: double.infinity,
                  child: Stack(children: [
                    Positioned.fill(child: ColoredBox(color: c.fillStrong)),
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: frac,
                        child: ColoredBox(color: frac > 0.9 ? c.warning : c.label),
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 6),
            ] else if (daysLeft != null && daysLeft < 0) ...[
              Text(l('sub.expired'), style: t.footnote.copyWith(color: c.danger)),
              const SizedBox(height: 2),
            ],
            if (meta.isNotEmpty) Text(meta.join(' · '), style: t.caption),
            if (s.announce != null && s.announce!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(s.announce!,
                  style: t.caption.copyWith(color: c.label),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis),
            ],
          ]),
        ),
      if (!collapsed) const Hairline(),
    ]);
  }

  static String _time(DateTime t) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (now.difference(t).inHours < 24 && now.day == t.day) return '${two(t.hour)}:${two(t.minute)}';
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }
}

class _SubMenu extends StatelessWidget {
  const _SubMenu({required this.sub});
  final Subscription sub;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final app = context.appRead;
    final c = context.c;
    return PopupMenuButton<String>(
      tooltip: l('common.more'),
      position: PopupMenuPosition.under,
      // A 36px square like the sync button beside it (the default icon
      // button is 48px and would pad every header, quota or not).
      child: SizedBox.square(
        dimension: 36,
        child: Center(child: Icon(Icons.more_horiz_rounded, size: 20, color: c.secondaryLabel)),
      ),
      onSelected: (v) async {
        switch (v) {
          case 'update':
            HapticFeedback.lightImpact();
            app.updateSubscription(sub.id);
          case 'rename':
            final name = await promptText(context, title: l('common.rename'), initial: sub.name);
            if (name != null && name.trim().isNotEmpty) app.renameSubscription(sub.id, name.trim());
          case 'copy':
            await Clipboard.setData(ClipboardData(text: sub.url ?? ''));
            app.notice('notice.copied');
          case 'interval':
            final v = await promptText(context,
                title: l('sub.interval'), initial: '${sub.updateIntervalHours}', number: true);
            final h = int.tryParse(v ?? '');
            if (h != null && h > 0) app.setSubscriptionInterval(sub.id, h);
          case 'web':
            final u = Uri.tryParse(sub.webPageUrl ?? sub.supportUrl ?? '');
            if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
          case 'delete':
            final ok = await confirm(context,
                title: l('sub.deleteTitle'), message: l('sub.deleteText', {'name': sub.name}), destructive: l('common.delete'));
            if (ok) app.removeSubscription(sub.id);
        }
      },
      itemBuilder: (_) => [
        if (sub.url != null)
          PopupMenuItem(value: 'update', child: _mi(Icons.sync_rounded, l('servers.update'))),
        PopupMenuItem(value: 'rename', child: _mi(Icons.edit_outlined, l('common.rename'))),
        if (sub.url != null) ...[
          PopupMenuItem(value: 'copy', child: _mi(Icons.link_rounded, l('sub.copyUrl'))),
          PopupMenuItem(value: 'interval', child: _mi(Icons.schedule_rounded, l('sub.interval'))),
        ],
        if (sub.webPageUrl != null || sub.supportUrl != null)
          PopupMenuItem(value: 'web', child: _mi(Icons.open_in_new_rounded, l('sub.site'))),
        PopupMenuItem(value: 'delete', child: _mi(Icons.delete_outline_rounded, l('common.delete'), color: c.danger)),
      ],
    );
  }
}

Widget _mi(IconData icon, String text, {Color? color}) => Builder(
      builder: (context) => Row(children: [
        Icon(icon, size: 17, color: color ?? context.c.secondaryLabel),
        const SizedBox(width: Space.m),
        Text(text, style: TextStyle(color: color)),
      ]),
    );

// ------------------------------------------------------------------ node row

/// One server in a subscription panel. Public so feature modules and tests
/// can find it by type.
class NodeRow extends StatelessWidget {
  const NodeRow({super.key, required this.node, required this.last});
  final ProxyNode node;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.c;
    final t = context.t;
    final l = context.l;
    final selected = app.selectedNode?.id == node.id && !app.settings.autoSelect;
    final active = app.connected && app.activeNode?.id == node.id;
    final lat = app.latencies[node.id];
    final ms = lat?.ms ?? app.statOf(node)?.latencyMs;
    final radius = BorderRadius.vertical(
      bottom: last ? const Radius.circular(Radii.m) : Radius.zero,
    );

    final row = PressableScale(
      scale: 0.99,
      onTap: () {
        HapticFeedback.selectionClick();
        app.selectNode(node.id);
      },
      onLongPress: () => showNodeActions(context, node),
      child: GestureDetector(
        onSecondaryTap: () => showNodeActions(context, node),
        child: Hoverable(
          builder: (context, hovered, pressed) => AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: ShapeDecoration(
              // Selected and hovered share the quiet fill; pressed is stronger.
              color: pressed
                  ? c.fillStrong
                  : (selected || hovered)
                      ? c.fill
                      : Colors.transparent,
              shape: RoundedRectangleBorder(borderRadius: radius),
            ),
            child: Column(children: [
              // Trailing: latency, 12px, 22px check — the same inset as the
              // switcher's rows, so the latency column sits on one line
              // across both lists.
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m - 1, Space.l, Space.m - 1),
                child: Row(children: [
                  CountryCode(node.countryCode),
                  const SizedBox(width: Space.m),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(nodeTitle(node),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.body.copyWith(fontWeight: FontWeight.w500)),
                      const SizedBox(height: 3),
                      Wrap(spacing: Space.s, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        ProtocolBadge(node.protocol),
                        if (CompatibilityCore.needsMihomo(node.outbound)) ...[
                          Text(CompatibilityCore.nameFor(node), style: t.caption),
                        ],
                        if (active)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            StatusDot(c.success, size: 6),
                            const SizedBox(width: 5),
                            Text(l('servers.active'),
                                style: t.caption.copyWith(color: c.success)),
                          ]),
                      ]),
                    ]),
                  ),
                  const SizedBox(width: Space.m),
                  ServersSlots.nodeTrailing(context, node),
                  Tooltip(
                    message: lat == null
                        ? ''
                        : lat.viaUrl
                            ? l('ping.url')
                            : l('ping.tcp'),
                    child: LatencyChip(
                      ms: ms,
                      testing: app.pinging.contains(node.id),
                      failed: lat != null && lat.failed,
                      label: l('ping.timeout'),
                      onTest: () => app.pingNode(node.id),
                    ),
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
              ),
              if (!last) const Hairline(inset: Space.l),
            ]),
          ),
        ),
      ),
    );

    return Dismissible(
      key: ValueKey('node-${node.id}-${node.subscriptionId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Space.xl),
        decoration: ShapeDecoration(color: c.danger, shape: RoundedRectangleBorder(borderRadius: radius)),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 20),
      ),
      onDismissed: (_) {
        HapticFeedback.mediumImpact();
        app.removeNode(node.id);
      },
      child: row,
    );
  }
}

/// Node actions: ping, copy link, QR, rename, delete.
Future<void> showNodeActions(BuildContext context, ProxyNode node) {
  final app = context.appRead;
  final l = context.l;
  final c = context.c;
  Widget ic(IconData i, {Color? color}) => Icon(i, size: 18, color: color ?? c.secondaryLabel);
  return showMelsiSheet(context, builder: (ctx) {
    void close() => Navigator.of(ctx).pop();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: Space.l),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SheetHeader(title: nodeTitle(node)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.l),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              GroupCard(children: [
                RowTile(
                  dense: true,
                  leading: ic(Icons.check_rounded),
                  title: l('node.select'),
                  onTap: () {
                    close();
                    app.selectNode(node.id);
                  },
                ),
                RowTile(
                  dense: true,
                  leading: ic(Icons.speed_rounded),
                  title: app.connected ? l('servers.pingAllUrl') : l('ping.tcp'),
                  onTap: () {
                    close();
                    app.pingNode(node.id);
                  },
                ),
                if (node.rawLink != null) ...[
                  RowTile(
                    dense: true,
                    leading: ic(Icons.link_rounded),
                    title: l('node.copyLink'),
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: node.rawLink!));
                      close();
                      app.notice('notice.copied');
                    },
                  ),
                  RowTile(
                    dense: true,
                    leading: ic(Icons.qr_code_2_rounded),
                    title: l('node.qr'),
                    onTap: () {
                      close();
                      showQr(context, node);
                    },
                  ),
                ],
                RowTile(
                  dense: true,
                  leading: ic(Icons.edit_outlined),
                  title: l('common.rename'),
                  onTap: () async {
                    close();
                    final name = await promptText(context, title: l('common.rename'), initial: node.name);
                    if (name != null && name.trim().isNotEmpty) app.renameNode(node.id, name.trim());
                  },
                ),
                ...ServersSlots.nodeActions(ctx, node, close),
                RowTile(
                  dense: true,
                  leading: ic(Icons.delete_outline_rounded, color: c.danger),
                  title: l('common.delete'),
                  destructive: true,
                  onTap: () {
                    close();
                    app.removeNode(node.id);
                  },
                ),
              ]),
              const SizedBox(height: Space.m),
              Padding(
                padding: const EdgeInsets.only(left: Space.xs),
                // The sheet outlives the row that opened it: read the theme
                // from the sheet's own context.
                child: Text('${node.server}:${node.port}',
                    style: ctx.t.monoSmall),
              ),
            ]),
          ),
        ]),
      ),
    );
  });
}

Future<void> showQr(BuildContext context, ProxyNode node) {
  final l = context.l;
  return showMelsiSheet(context, builder: (ctx) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SheetHeader(title: nodeTitle(node)),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.xl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.all(Space.l),
                  decoration: ShapeDecoration(
                      color: Colors.white,
                      shape: Radii.shape(Radii.m, side: BorderSide(color: ctx.c.separator, width: kHairline))),
                  child: QrImageView(
                    data: node.rawLink!,
                    size: 232,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF1B1A17)),
                    dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square, color: Color(0xFF1B1A17)),
                  ),
                ),
                const SizedBox(height: Space.l),
                Row(children: [
                  Expanded(
                    child: SecondaryButton(
                      label: l('node.copyLink'),
                      icon: Icons.copy_rounded,
                      expand: true,
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: node.rawLink!));
                        context.appRead.notice('notice.copied');
                      },
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  Expanded(
                    child: SecondaryButton(
                      label: l('common.share'),
                      icon: Icons.ios_share_rounded,
                      expand: true,
                      onTap: () => SharePlus.instance.share(ShareParams(text: node.rawLink!)),
                    ),
                  ),
                ]),
            ]),
          ),
        ]),
      ));
}

// ------------------------------------------------------------------ dialogs

Future<String?> promptText(BuildContext context,
    {required String title, String? initial, bool number = false, String? hint}) {
  final ctrl = TextEditingController(text: initial);
  final l = context.l;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l('common.cancel'), style: TextStyle(color: context.c.secondaryLabel))),
        TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(l('common.ok'))),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context,
    {required String title, required String message, required String destructive}) async {
  final l = context.l;
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l('common.cancel'), style: TextStyle(color: context.c.secondaryLabel))),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(destructive, style: TextStyle(color: context.c.danger, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
  return r ?? false;
}
