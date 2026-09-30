// Entry-server picker for the double VPN: the switcher's row idiom (country
// box · name · protocol · latency) with a check on the current entry. Rows
// that can't be an entry stay visible but inert, each saying why — the
// user learns the rule instead of wondering where a server went.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/page.dart';

/// Opens the entry picker as a sheet (phone) or dialog (wide).
Future<void> showChainPicker(BuildContext context) {
  final expand = context.appRead.nodes.length > 6;
  return showMelsiSheet(context, expand: expand, builder: (_) => const ChainPicker());
}

class ChainPicker extends StatelessWidget {
  const ChainPicker({super.key});

  void _pick(BuildContext context, AppState app, String id) {
    HapticFeedback.selectionClick();
    app.updateChain((c) => c.entryNodeId = id);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final wide = context.isWide;
    final nodes = app.filteredNodes(sort: NodeSort.latency);
    final exit = app.activeNode;
    final entryId = app.chain.entryNodeId;
    final bottom = MediaQuery.paddingOf(context).bottom;

    Widget body;
    if (nodes.length < 2) {
      body = Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: EmptyState(
          icon: Icons.route_rounded,
          title: l('chain.needTwo'),
          message: l('chain.needTwoHint'),
        ),
      );
    } else {
      body = ListView(
        shrinkWrap: wide,
        padding: EdgeInsets.fromLTRB(Space.l, Space.xs, Space.l, Space.xl + bottom),
        children: [
          GroupCard(children: [
            for (final n in nodes)
              _EntryRow(
                node: n,
                app: app,
                selected: n.id == entryId,
                // The exit can't also be the entry; endpoints can't carry a
                // detour target. Both are said in the row's caption.
                blocker: n.protocol.isEndpoint
                    ? l('chain.noEndpoint')
                    : exit?.id == n.id && n.id != entryId
                        ? l('chain.isExit')
                        : null,
                onTap: () => _pick(context, app, n.id),
              ),
          ]),
        ],
      );
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      SheetHeader(title: l('chain.entry')),
      Flexible(fit: wide || nodes.length < 2 ? FlexFit.loose : FlexFit.tight, child: body),
    ]);
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.node,
    required this.app,
    required this.selected,
    required this.blocker,
    required this.onTap,
  });

  final ProxyNode node;
  final AppState app;
  final bool selected;

  /// Why this row can't be picked (null = pickable).
  final String? blocker;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final lat = app.latencies[node.id];
    final enabled = blocker == null;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: RowTile(
          dense: true,
          leading: CountryCode(node.countryCode),
          title: nodeTitle(node),
          // The reason a row is inert matters more than its protocol, and
          // it has to fit on a 360px phone: it takes the protocol's place.
          subtitleWidget: blocker == null
              ? ProtocolBadge(node.protocol)
              : Text(blocker!, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.caption),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            LatencyChip(
              ms: app.latencyOf(node),
              testing: app.pinging.contains(node.id),
              failed: lat != null && lat.failed,
              label: context.l('ping.timeout'),
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
          onTap: enabled ? onTap : null,
        ),
      ),
    );
  }
}
