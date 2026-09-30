import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/country.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../theme/glass.dart';
import '../theme/pressable.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/format.dart';
import '../widgets/page.dart';
import 'add_sheet.dart';
import 'reconnect_banner.dart';

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

    final viaUrl = app.connected;
    return PageScaffold(
      title: l('tab.servers'),
      subtitle: app.nodes.isEmpty
          ? null
          : Text('${l.plural(app.nodes.length, 'n.servers')} · ${viaUrl ? l('ping.url') : l('ping.tcp')}'),
      actions: [
        _SortButton(value: _sort, onChanged: (s) => setState(() => _sort = s)),
        CircleIconButton(
          icon: Icons.speed_rounded,
          tooltip: viaUrl ? l('servers.pingAllUrl') : l('servers.pingAllTcp'),
          busy: app.pingingAll,
          onTap: app.nodes.isEmpty ? null : app.pingAll,
        ),
        CircleIconButton(
          icon: Icons.add_rounded,
          tooltip: l('servers.add'),
          onTap: () => showAddSheet(context),
        ),
      ],
      slivers: [
        const SliverToBoxAdapter(child: ReconnectBanner()),
        if (app.nodes.isEmpty && app.subscriptions.isEmpty)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.public_rounded,
              title: l('servers.emptyTitle'),
              message: l('servers.emptyText'),
              action: PrimaryButton(
                label: l('servers.add'),
                icon: Icons.add_rounded,
                onTap: () => showAddSheet(context),
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(child: _searchBar(app, l, c)),
          for (final (sub, nodes) in groups)
            if (!_filtering || nodes.isNotEmpty) ...[
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
                    child: Card2(
                      child: Text(
                        app.updating.contains(sub?.id) ? l('servers.updating') : l('servers.groupEmpty'),
                        style: context.t.footnote,
                      ),
                    ),
                  )
                else
                  SliverList.builder(
                    itemCount: nodes.length,
                    itemBuilder: (context, i) => _NodeRow(
                      node: nodes[i],
                      first: i == 0,
                      last: i == nodes.length - 1,
                    ),
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
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Column(children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          style: context.t.body,
          decoration: InputDecoration(
            hintText: l('servers.search'),
            prefixIcon: Icon(Icons.search_rounded, color: c.secondaryLabel, size: 20),
            prefixIconConstraints: const BoxConstraints(minWidth: 40),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.cancel_rounded, size: 18, color: c.tertiaryLabel),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
        const SizedBox(height: Space.s),
        SizedBox(
          height: 34,
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
                label: _country == null ? l('servers.country') : '${flagEmoji(_country!)} $_country',
                active: _country != null,
                options: [
                  (null, l('common.all')),
                  for (final cc in countries) (cc, '${flagEmoji(cc)}  $cc'),
                ],
                onSelected: (v) => setState(() => _country = v),
              ),
              if (app.subscriptions.any((s) => s.url != null)) ...[
                const SizedBox(width: Space.s),
                _ActionChip(
                  icon: Icons.sync_rounded,
                  label: l('servers.updateAll'),
                  busy: app.updating.isNotEmpty,
                  onTap: app.updateAllSubscriptions,
                ),
              ],
            ],
          ),
        ),
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
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final s in NodeSort.values)
          PopupMenuItem(
            value: s,
            child: Row(children: [
              SizedBox(
                width: 24,
                child: s == value ? Icon(Icons.check_rounded, size: 18, color: context.c.accent) : null,
              ),
              Text(l('sort.${s.name}')),
            ]),
          ),
      ],
      child: const IgnorePointer(
        child: CircleIconButton(icon: Icons.swap_vert_rounded, onTap: _noop),
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
      onSelected: (i) => onSelected(options[i].$1),
      constraints: const BoxConstraints(maxHeight: 420, minWidth: 160),
      itemBuilder: (_) => [
        for (var i = 0; i < options.length; i++)
          PopupMenuItem(value: i, height: 40, child: Text(options[i].$2)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: active ? c.accent.withValues(alpha: 0.15) : c.fill,
          shape: Radii.shape(Radii.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: context.t.subhead.copyWith(
                  fontWeight: FontWeight.w600, color: active ? c.accent : c.label)),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 18, color: active ? c.accent : c.secondaryLabel),
        ]),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.icon, required this.label, required this.onTap, this.busy = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PressableScale(
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: ShapeDecoration(color: c.fill, shape: Radii.shape(Radii.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          busy
              ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, size: 16, color: c.accent),
          const SizedBox(width: 6),
          Text(label, style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ group header

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.sub, required this.count, required this.collapsed, required this.onToggle});
  final Subscription? sub;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final s = sub;
    final used = (s?.upload ?? 0) + (s?.download ?? 0);
    final total = s?.total ?? 0;
    final frac = total > 0 ? (used / total).clamp(0.0, 1.0) : null;
    final expire = s?.expire;
    final daysLeft = expire?.difference(DateTime.now()).inDays;
    final updating = s != null && app.updating.contains(s.id);

    return Padding(
      padding: const EdgeInsets.only(top: Space.xl, bottom: Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: PressableScale(
                scale: 0.99,
                onTap: onToggle,
                child: Row(children: [
                  SpringValue(
                    target: collapsed ? -0.25 : 0,
                    builder: (context, v, child) => Transform.rotate(angle: v * 6.2832, child: child),
                    child: Icon(Icons.expand_more_rounded, color: c.secondaryLabel, size: 22),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      s?.name ?? l('servers.manual'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.headline.copyWith(fontSize: 18, letterSpacing: -0.3),
                    ),
                  ),
                  const SizedBox(width: Space.s),
                  Text('$count', style: context.t.footnote),
                ]),
              ),
            ),
            if (s != null && s.url != null)
              updating
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: l('servers.update'),
                      onPressed: () => app.updateSubscription(s.id),
                      icon: Icon(Icons.sync_rounded, size: 20, color: c.accent),
                    ),
            if (s != null) _SubMenu(sub: s),
          ]),
          if (s != null && (frac != null || expire != null || s.updatedAt != null)) ...[
            const SizedBox(height: Space.xs),
            Padding(
              padding: const EdgeInsets.only(left: 26, right: Space.s),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (frac != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 5,
                      child: Stack(children: [
                        Container(color: c.fill),
                        FractionallySizedBox(
                          widthFactor: frac,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: frac > 0.9
                                  ? LinearGradient(colors: [c.warning, c.danger])
                                  : c.accentGradient,
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Wrap(spacing: Space.m, children: [
                  if (frac != null)
                    Text('${formatBytes(used)} / ${formatBytes(total)}', style: context.t.caption),
                  if (expire != null)
                    Text(
                      daysLeft! < 0
                          ? l('sub.expired')
                          : l('sub.expires', {'d': '${expire.day.toString().padLeft(2, '0')}.${expire.month.toString().padLeft(2, '0')}.${expire.year}', 'n': '$daysLeft'}),
                      style: context.t.caption.copyWith(color: daysLeft < 3 ? c.danger : null),
                    ),
                  if (s.updatedAt != null)
                    Text(l('sub.updated', {'t': _time(s.updatedAt!)}), style: context.t.caption),
                ]),
                if (s.announce != null && s.announce!.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(s.announce!, style: context.t.caption.copyWith(color: c.info), maxLines: 3, overflow: TextOverflow.ellipsis),
                ],
              ]),
            ),
          ],
        ],
      ),
    );
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
      icon: Icon(Icons.more_horiz_rounded, color: c.secondaryLabel),
      onSelected: (v) async {
        switch (v) {
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
        PopupMenuItem(value: 'rename', child: _mi(Icons.edit_rounded, l('common.rename'))),
        if (sub.url != null) ...[
          PopupMenuItem(value: 'copy', child: _mi(Icons.link_rounded, l('sub.copyUrl'))),
          PopupMenuItem(value: 'interval', child: _mi(Icons.schedule_rounded, l('sub.interval'))),
        ],
        if (sub.webPageUrl != null || sub.supportUrl != null)
          PopupMenuItem(value: 'web', child: _mi(Icons.open_in_new_rounded, l('sub.site'))),
        PopupMenuItem(value: 'delete', child: _mi(Icons.delete_rounded, l('common.delete'), color: c.danger)),
      ],
    );
  }
}

Widget _mi(IconData icon, String text, {Color? color}) => Builder(
      builder: (context) => Row(children: [
        Icon(icon, size: 19, color: color ?? context.c.secondaryLabel),
        const SizedBox(width: Space.m),
        Text(text, style: TextStyle(color: color)),
      ]),
    );

// ------------------------------------------------------------------ node row

class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.node, required this.first, required this.last});
  final ProxyNode node;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.c;
    final selected = app.selectedNode?.id == node.id && !app.settings.autoSelect;
    final active = app.connected && app.activeNode?.id == node.id;
    final lat = app.latencies[node.id];
    final ms = lat?.ms ?? app.statOf(node)?.latencyMs;
    final radius = BorderRadius.vertical(
      top: first ? const Radius.circular(Radii.l) : Radius.zero,
      bottom: last ? const Radius.circular(Radii.l) : Radius.zero,
    );

    final row = PressableScale(
      scale: 0.985,
      onTap: () => app.selectNode(node.id),
      onLongPress: () => showNodeActions(context, node),
      child: GestureDetector(
        onSecondaryTap: () => showNodeActions(context, node),
        child: Container(
          decoration: ShapeDecoration(
            color: selected || active
                ? Color.alphaBlend(c.accent.withValues(alpha: c.isDark ? 0.14 : 0.07), c.surface)
                : c.surface,
            shape: RoundedSuperellipseBorder(borderRadius: radius),
          ),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.m - 1),
              child: Row(children: [
                FlagBadge(node.countryCode, size: 34),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(nodeTitle(node),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.callout.copyWith(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Row(children: [
                      ProtocolBadge(node.protocol),
                      if (active) ...[
                        const SizedBox(width: 6),
                        Pill(context.l('servers.active'), color: c.success),
                      ],
                    ]),
                  ]),
                ),
                const SizedBox(width: Space.s),
                Tooltip(
                  message: lat == null
                      ? ''
                      : lat.viaUrl
                          ? context.l('ping.url')
                          : context.l('ping.tcp'),
                  child: LatencyChip(
                    ms: ms,
                    testing: app.pinging.contains(node.id),
                    failed: lat != null && lat.failed,
                    label: context.l('ping.timeout'),
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: AnimatedScale(
                    scale: selected ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutBack,
                    child: Icon(Icons.check_rounded, color: c.accent, size: 22),
                  ),
                ),
              ]),
            ),
            if (!last)
              Padding(
                padding: const EdgeInsets.only(left: 62),
                child: Container(height: 0.5, color: c.separator),
              ),
          ]),
        ),
      ),
    );

    return Dismissible(
      key: ValueKey('node-${node.id}-${node.subscriptionId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Space.xl),
        decoration: ShapeDecoration(color: c.danger, shape: RoundedSuperellipseBorder(borderRadius: radius)),
        child: const Icon(Icons.delete_rounded, color: Colors.white),
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
  return showMelsiSheet(context, builder: (ctx) {
    void close() => Navigator.of(ctx).pop();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SheetHeader(title: nodeTitle(node)),
          GroupCard(children: [
            RowTile(
              leading: IconTile(Icons.check_circle_rounded, color: c.accent),
              title: l('node.select'),
              onTap: () {
                close();
                app.selectNode(node.id);
              },
            ),
            RowTile(
              leading: IconTile(Icons.speed_rounded, color: c.success),
              title: app.connected ? l('servers.pingAllUrl') : l('ping.tcp'),
              onTap: () {
                close();
                app.pingNode(node.id);
              },
            ),
            if (node.rawLink != null) ...[
              RowTile(
                leading: IconTile(Icons.link_rounded, color: c.info),
                title: l('node.copyLink'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: node.rawLink!));
                  close();
                  app.notice('notice.copied');
                },
              ),
              RowTile(
                leading: IconTile(Icons.qr_code_rounded, color: const Color(0xFF5856D6)),
                title: l('node.qr'),
                onTap: () {
                  close();
                  showQr(context, node);
                },
              ),
            ],
            RowTile(
              leading: IconTile(Icons.edit_rounded, color: c.warning),
              title: l('common.rename'),
              onTap: () async {
                close();
                final name = await promptText(context, title: l('common.rename'), initial: node.name);
                if (name != null && name.trim().isNotEmpty) app.renameNode(node.id, name.trim());
              },
            ),
            RowTile(
              leading: IconTile(Icons.delete_rounded, color: c.danger),
              title: l('common.delete'),
              destructive: true,
              onTap: () {
                close();
                app.removeNode(node.id);
              },
            ),
          ]),
          const SizedBox(height: Space.s),
          Text('${node.server}:${node.port}', style: context.t.caption),
        ]),
      ),
    );
  });
}

Future<void> showQr(BuildContext context, ProxyNode node) {
  final l = context.l;
  return showMelsiSheet(context, builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SheetHeader(title: nodeTitle(node)),
            Container(
              padding: const EdgeInsets.all(Space.l),
              decoration: ShapeDecoration(color: Colors.white, shape: Radii.shape(Radii.l)),
              child: QrImageView(
                data: node.rawLink!,
                size: 240,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF0B0B12)),
                dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF0B0B12)),
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
              const SizedBox(width: Space.m),
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
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l('common.cancel'))),
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
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l('common.cancel'))),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(destructive, style: TextStyle(color: context.c.danger, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
  return r ?? false;
}
