// Double VPN UI: the Settings section, the "via <entry>" footnote under the
// Home server card and the "Use as entry" node action. The feature owns no
// service — every widget reads `app.chain` and mutates it through
// `AppState.updateChain`, which re-applies the tunnel while connected.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import 'chain_commands.dart';
import 'chain_picker.dart';

/// Home: the "via `<entry>`" footnote under the server card. Shown while the
/// running tunnel is chained, or as soon as the user has an entry set with
/// the chain on (so the row appears the moment they flip the switch, not
/// after the reconnect). Draws in with a 6px rise + fade; static with
/// reduced motion.
class ChainLine extends StatelessWidget {
  const ChainLine({super.key});

  @override
  Widget build(BuildContext context) {
    ensureChainCommands(context);
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final connected = app.displayStatus == VpnStatus.connected;
    final built = app.lastBuilt;
    final live = connected && (built?.chainActive ?? false);
    final chosen = app.nodeById(app.chain.entryNodeId);
    final entry = live ? (app.nodeByTag(built!.entryTag) ?? chosen) : chosen;
    final show = entry != null && (live || app.chain.enabled);

    Widget row = const SizedBox.shrink();
    if (entry != null) {
      // The template carries the name's slot; split on it so the country
      // box sits exactly where the name begins in either language.
      const marker = '⁣';
      final parts = l('chain.via', {'entry': marker}).split(marker);
      final prefix = parts.first;
      final suffix = parts.length > 1 ? parts[1] : '';
      row = Padding(
        key: const ValueKey('home-chain-line'),
        padding: const EdgeInsets.fromLTRB(Space.xs, Space.s + 2, Space.xs, 0),
        child: Row(children: [
          Icon(Icons.route_rounded, size: 14, color: c.tertiaryLabel),
          const SizedBox(width: Space.s),
          if (prefix.trim().isNotEmpty) ...[
            Text(prefix.trimRight(), style: t.footnote),
            const SizedBox(width: Space.s - 2),
          ],
          CountryCode(entry.countryCode, width: 26),
          const SizedBox(width: Space.s - 2),
          Flexible(
            child: Text(nodeTitle(entry),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: t.footnote),
          ),
          if (suffix.trim().isNotEmpty) Text(suffix, style: t.footnote),
        ]),
      );
    }

    if (context.reduceMotion) return show ? row : const SizedBox.shrink();
    return SpringValue(
      target: show ? 1 : 0,
      child: row,
      builder: (context, v, child) {
        final p = v.clamp(0.0, 1.0);
        // Fully faded out and not coming back: give the space up.
        if (!show && p < 0.01) return const SizedBox.shrink();
        return Opacity(
          opacity: p,
          child: Transform.translate(offset: Offset(0, (1 - p) * 6), child: child),
        );
      },
    );
  }
}

/// Settings: the "Double VPN" section (slivers) after the probe section.
List<Widget> chainSettingsSlivers(BuildContext context, AppState app) {
  ensureChainCommands(context);
  final l = context.l;
  final c = context.c;
  final t = context.t;
  final entry = app.nodeById(app.chain.entryNodeId);
  final narrow = MediaQuery.sizeOf(context).width < 400;

  return [
    SliverToBoxAdapter(child: SectionHeader(l('chain.title'))),
    SliverToBoxAdapter(
      child: GroupCard(children: [
        SwitchRow(
          title: l('chain.enable'),
          subtitle: l('chain.hint'),
          value: app.chain.enabled,
          onChanged: (v) {
            app.updateChain((x) => x.enabled = v);
            // Switching on without an entry is a no-op for the tunnel; ask
            // for the entry right away instead of leaving a dead switch.
            if (v && app.chain.entryNodeId == null) showChainPicker(context);
          },
        ),
        RowTile(
          title: l('chain.entry'),
          // On a 360px phone the title needs the room: the country box
          // steps aside and the name gets a shorter cap.
          trailing: entry == null
              ? Text(l('chain.none'),
                  style: t.callout.copyWith(color: c.tertiaryLabel))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!narrow) ...[
                    CountryCode(entry.countryCode, width: 26),
                    const SizedBox(width: Space.s),
                  ],
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: narrow ? 110 : 170),
                    child: Text(nodeTitle(entry),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.callout.copyWith(color: c.secondaryLabel)),
                  ),
                ]),
          chevron: true,
          onTap: () => showChainPicker(context),
        ),
      ]),
    ),
    SliverToBoxAdapter(child: SectionFooter(l('chain.footer'))),
  ];
}

/// Node actions sheet: "Сделать входным" row. Endpoints (WireGuard) can't be
/// an entry, so the row stays but is inert and says why. [close] pops the
/// sheet.
List<Widget> chainActionRows(BuildContext context, ProxyNode node, VoidCallback close) {
  final app = context.appRead;
  final l = context.l;
  final c = context.c;
  final endpoint = node.protocol.isEndpoint;
  final isEntry = app.chain.entryNodeId == node.id;
  return [
    Opacity(
      opacity: endpoint ? 0.55 : 1,
      child: RowTile(
        dense: true,
        leading: Icon(Icons.route_rounded, size: 18, color: c.secondaryLabel),
        title: l('chain.useAsEntry'),
        subtitle: endpoint
            ? l('chain.noEndpoint')
            : isEntry && app.chain.enabled
                ? l('chain.isEntry')
                : null,
        trailing: isEntry && !endpoint
            ? Icon(Icons.check_rounded, size: 18, color: c.accent)
            : null,
        onTap: endpoint
            ? null
            : () {
                close();
                HapticFeedback.selectionClick();
                app.updateChain((x) {
                  x.enabled = true;
                  x.entryNodeId = node.id;
                });
              },
      ),
    ),
  ];
}
