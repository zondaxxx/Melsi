import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../shell.dart';
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
    final nodes = app.filteredNodes(query: _search.text, sort: NodeSort.latency);
    final auto = app.settings.autoSelect;
    final current = app.activeNode;

    return Column(children: [
      SheetHeader(
        title: l('switcher.title'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleIconButton(
            icon: Icons.speed_rounded,
            size: 30,
            tooltip: app.connected ? l('servers.pingAllUrl') : l('servers.pingAllTcp'),
            busy: app.pingingAll,
            onTap: app.pingAll,
          ),
          const SizedBox(width: Space.xs),
          IconButton(
            tooltip: l('common.close'),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: c.fill, shape: BoxShape.circle),
              child: Icon(Icons.close_rounded, size: 18, color: c.secondaryLabel),
            ),
          ),
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
              prefixIcon: Icon(Icons.search_rounded, color: c.secondaryLabel, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 40),
            ),
          ),
        ),
      Expanded(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              Space.l, Space.xs, Space.l, Space.xl + MediaQuery.paddingOf(context).bottom),
          children: [
            if (_search.text.isEmpty) ...[
              GroupCard(inset: 62, children: [
                RowTile(
                  leading: IconTile(Icons.auto_awesome_rounded, color: c.accent, size: 34),
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
              const SizedBox(height: Space.l),
            ],
            if (nodes.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Text(l('apps.none'), textAlign: TextAlign.center, style: context.t.footnote),
              )
            else
              GroupCard(inset: 62, children: [
                for (final n in nodes) _Row(node: n, app: app, onTap: () => _pick(app, n.id)),
              ]),
            if (widget.onManage != null) ...[
              const SizedBox(height: Space.m),
              Center(
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).maybePop();
                    widget.onManage!();
                  },
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: Text(l('switcher.manage')),
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
    final selected = !app.settings.autoSelect && app.selectedNode?.id == node.id;
    final active = app.connected && app.activeNode?.id == node.id;
    final lat = app.latencies[node.id];
    final sub = app.subscriptionById(node.subscriptionId);
    return RowTile(
      dense: true,
      leading: FlagBadge(node.countryCode, size: 34),
      title: nodeTitle(node),
      subtitleWidget: Row(children: [
        ProtocolBadge(node.protocol),
        if (sub != null) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(sub.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t.caption),
          ),
        ],
        if (active) ...[
          const SizedBox(width: 6),
          Icon(Icons.circle, size: 6, color: c.success),
        ],
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        LatencyChip(
          ms: app.latencyOf(node),
          testing: app.pinging.contains(node.id),
          failed: lat != null && lat.failed,
          label: context.l('ping.timeout'),
          onTest: () => app.pingNode(node.id),
        ),
        const SizedBox(width: Space.s),
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
          child: Icon(Icons.check_rounded, color: context.c.accent, size: 22),
        ),
      );
}
