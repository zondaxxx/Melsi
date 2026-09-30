import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../shell.dart';
import '../slots/servers_slots.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/page.dart';

/// Quick server switcher: search, live latency, one tap to switch.
Future<void> showServerSwitcher(BuildContext context) {
  final nav = ShellNav.maybeOf(context);
  return showMelsiSheet(context,
      expand: true, builder: (_) => ServerSwitcher(onManage: nav == null ? null : () => nav.go(AppTab.servers)));
}

class ServerSwitcher extends StatefulWidget {
  const ServerSwitcher({super.key, this.onManage});
  final VoidCallback? onManage;

  @override
  State<ServerSwitcher> createState() => _ServerSwitcherState();
}

class _ServerSwitcherState extends State<ServerSwitcher> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(AppState app, String id) {
    HapticFeedback.selectionClick();
    app.selectNode(id);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    // Sorted by latency, with the active server pinned first so the list
    // never opens with "my server" in second place.
    final nodes = app.filteredNodes(query: _search.text, sort: NodeSort.latency);
    final auto = app.settings.autoSelect;
    final current = app.activeNode;
    if (app.connected && current != null) {
      final i = nodes.indexWhere((n) => n.id == current.id);
      if (i > 0) nodes.insert(0, nodes.removeAt(i));
    }
    // In the desktop dialog the sheet sizes to its content instead of
    // filling the dialog's maximum height.
    final wide = context.isWide;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      SheetHeader(
        title: l('switcher.title'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          ToolButton(
            icon: Icons.speed_rounded,
            size: 30,
            tooltip: app.connected ? l('servers.pingAllUrl') : l('servers.pingAllTcp'),
            busy: app.pingingAll,
            onTap: app.pingAll,
          ),
          const SizedBox(width: Space.s),
          const SheetClose(),
        ]),
      ),
      if (app.nodes.length > 5)
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.s),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            style: context.t.body,
            decoration: InputDecoration(
              hintText: l('servers.search'),
              prefixIcon: Icon(Icons.search_rounded, color: c.tertiaryLabel, size: 18),
              prefixIconConstraints: const BoxConstraints(minWidth: 38),
            ),
          ),
        ),
      Flexible(
        fit: wide ? FlexFit.loose : FlexFit.tight,
        child: ListView(
          shrinkWrap: wide,
          padding: EdgeInsets.fromLTRB(
              Space.l, Space.xs, Space.l, Space.xl + MediaQuery.paddingOf(context).bottom),
          children: [
            if (_search.text.isEmpty) ...[
              GroupCard(children: [
                RowTile(
                  title: l('quick.smart'),
                  subtitle: auto && current != null
                      ? l('switcher.autoNow', {'name': nodeTitle(current)})
                      : l('switcher.autoHint', {'mode': l('smart.${app.settings.smartMode.name}')}),
                  trailing: _Check(on: auto),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    if (!auto) app.setAutoSelect(true);
                    Navigator.of(context).maybePop();
                  },
                ),
              ]),
              const SizedBox(height: Space.m),
              ...SwitcherSlots.top(context, app),
            ],
            if (nodes.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Text(l('apps.none'), textAlign: TextAlign.center, style: context.t.footnote),
              )
            else
              GroupCard(children: [
                for (final n in nodes) _Row(node: n, app: app, onTap: () => _pick(app, n.id)),
              ]),
            if (widget.onManage != null) ...[
              const SizedBox(height: Space.m),
              // A tertiary action: ink, not the accent.
              Center(
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: c.secondaryLabel),
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onManage!();
                  },
                  child: Text(l('switcher.manage'), style: context.t.subhead),
                ),
              ),
            ],
          ],
        ),
      ),
    ]);
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.node, required this.app, required this.onTap});
  final ProxyNode node;
  final AppState app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final selected = !app.settings.autoSelect && app.selectedNode?.id == node.id;
    final active = app.connected && app.activeNode?.id == node.id;
    final lat = app.latencies[node.id];
    final sub = app.subscriptionById(node.subscriptionId);
    return RowTile(
      dense: true,
      leading: CountryCode(node.countryCode),
      title: nodeTitle(node),
      // One column pattern for every row — protocol · subscription — with
      // the same "● Активен" idiom as the Servers list appended on the live
      // one; the subscription name gives way first on a 360px phone.
      subtitleWidget: Row(children: [
        ProtocolBadge(node.protocol),
        if (sub != null) ...[
          Text(' · ', style: t.monoSmall.copyWith(color: c.tertiaryLabel)),
          Flexible(
            child: Text(sub.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption),
          ),
        ],
        if (active) ...[
          const SizedBox(width: Space.s + 2),
          StatusDot(c.success, size: 6),
          const SizedBox(width: 5),
          Text(context.l('servers.active'), style: t.caption.copyWith(color: c.success)),
        ],
      ]),
      // Latency column ends 50px from the edge (16 gutter + 22 check + 12
      // gap), exactly as on the Servers page.
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        LatencyChip(
          ms: app.latencyOf(node),
          testing: app.pinging.contains(node.id),
          failed: lat != null && lat.failed,
          label: context.l('ping.timeout'),
          onTest: () => app.pingNode(node.id),
        ),
        const SizedBox(width: Space.m),
        _Check(on: selected),
      ]),
      onTap: onTap,
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.on});
  final bool on;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 22,
        child: SpringValue(
          target: on ? 1 : 0,
          spring: Springs.momentum,
          builder: (context, v, child) =>
              Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
          child: Icon(Icons.check_rounded, color: context.c.accent, size: 18),
        ),
      );
}
