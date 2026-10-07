import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../features/doctor/doctor_widgets.dart';
import '../../features/netcheck/speed_test_sheet.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../theme/pressable.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import 'common.dart';
import 'format.dart';
import 'page.dart';

class DashboardTools extends StatelessWidget {
  const DashboardTools({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l('dashboard.tools')),
        LayoutBuilder(
          builder: (context, box) {
            final width = (box.maxWidth - Space.s * 2) / 3;
            return Wrap(
              spacing: Space.s,
              runSpacing: Space.s,
              children: [
                for (final action in [
                  (
                    'speed',
                    Icons.speed_rounded,
                    () => showSpeedTestSheet(context),
                  ),
                  (
                    'doctor',
                    Icons.troubleshoot_rounded,
                    () => showDoctorSheet(context),
                  ),
                  (
                    'timer',
                    Icons.timer_outlined,
                    () => showDisconnectTimer(context),
                  ),
                ])
                  SizedBox(
                    width: width,
                    child: PressableScale(
                      key: ValueKey('dashboard-${action.$1}'),
                      semanticLabel: l('dashboard.${action.$1}'),
                      onTap: action.$3,
                      child: Panel(
                        radius: Radii.l,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.xs,
                          vertical: Space.l,
                        ),
                        child: Column(
                          children: [
                            Icon(action.$2, size: 22, color: context.c.label),
                            const SizedBox(height: Space.s),
                            Text(
                              l('dashboard.${action.$1}'),
                              textAlign: TextAlign.center,
                              style: context.t.caption,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        if (app.disconnectAt != null) const DisconnectCountdown(),
      ],
    );
  }
}

Future<void> showDisconnectTimer(BuildContext context) => showMelsiSheet<void>(
  context,
  builder: (context) {
    final app = context.app;
    final l = context.l;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(title: l('dashboard.timerTitle')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.l),
            child: Text(l('dashboard.timerHint'), style: context.t.footnote),
          ),
          if (!app.connected)
            Padding(
              padding: const EdgeInsets.all(Space.l),
              child: Text(
                l('dashboard.timerConnect'),
                style: context.t.headline,
              ),
            ),
          for (final minutes in [15, 30, 60, 120])
            RowTile(
              key: ValueKey('timer-$minutes'),
              title: l('dashboard.minutes', {'n': '$minutes'}),
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: context.c.tertiaryLabel,
              ),
              onTap: app.connected
                  ? () {
                      app.scheduleDisconnect(Duration(minutes: minutes));
                      Navigator.of(context).pop();
                    }
                  : null,
            ),
          RowTile(
            key: const ValueKey('timer-cancel'),
            title: l('dashboard.timerOff'),
            onTap: () {
              app.scheduleDisconnect(null);
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(height: Space.l),
        ],
      ),
    );
  },
);

class DisconnectCountdown extends StatefulWidget {
  const DisconnectCountdown({super.key});

  @override
  State<DisconnectCountdown> createState() => _DisconnectCountdownState();
}

class _DisconnectCountdownState extends State<DisconnectCountdown> {
  late final Timer _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deadline = context.app.disconnectAt;
    if (deadline == null) return const SizedBox.shrink();
    final remaining = deadline.difference(DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(top: Space.s),
      child: Row(
        children: [
          Icon(Icons.timer_outlined, size: 16, color: context.c.accent),
          const SizedBox(width: Space.s),
          Expanded(
            child: Text(
              context.l('dashboard.timerActive', {
                'time': formatDuration(
                  remaining.isNegative ? Duration.zero : remaining,
                ),
              }),
              style: context.t.footnote,
            ),
          ),
          ToolButton(
            icon: Icons.close_rounded,
            tooltip: context.l('dashboard.timerOff'),
            onTap: () => context.appRead.scheduleDisconnect(null),
          ),
        ],
      ),
    );
  }
}

class HomeFavorites extends StatelessWidget {
  const HomeFavorites({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final nodes = app.favouriteIds
        .map(app.nodeById)
        .whereType<ProxyNode>()
        .toList();
    if (nodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(context.l('dashboard.favorites')),
        Wrap(
          spacing: Space.s,
          runSpacing: Space.s,
          children: [
            for (final node in nodes)
              Semantics(
                selected: app.activeNode?.id == node.id,
                child: PressableScale(
                  key: ValueKey('home-favorite-${node.id}'),
                  semanticLabel: nodeTitle(node),
                  onTap: app.busy || app.applying
                      ? null
                      : () => app.selectNode(node.id),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Panel(
                      radius: Radii.pill,
                      border: app.activeNode?.id == node.id
                          ? context.c.accent
                          : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.m,
                        vertical: Space.m,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.star_border,
                            size: 16,
                            color: app.activeNode?.id == node.id
                                ? context.c.accent
                                : context.c.secondaryLabel,
                          ),
                          const SizedBox(width: Space.s),
                          Flexible(
                            child: Text(
                              nodeTitle(node),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.t.subhead,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class DashboardDetails extends StatefulWidget {
  const DashboardDetails({super.key, required this.child});
  final Widget child;

  @override
  State<DashboardDetails> createState() => _DashboardDetailsState();
}

class _DashboardDetailsState extends State<DashboardDetails> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: Space.xl),
      Semantics(
        expanded: _expanded,
        child: PressableScale(
          key: const ValueKey('dashboard-details'),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Panel(
            radius: Radii.l,
            child: Row(
              children: [
                Icon(Icons.insights_rounded, color: context.c.secondaryLabel),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l('dashboard.details'),
                        style: context.t.headline,
                      ),
                      const SizedBox(height: Space.xs),
                      Text(
                        context.l('dashboard.detailsHint'),
                        style: context.t.footnote,
                      ),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: Duration(
                    milliseconds: context.reduceMotion ? 0 : 240,
                  ),
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: context.c.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (context.reduceMotion)
        (_expanded ? widget.child : const SizedBox(width: double.infinity))
      else
        AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? widget.child
              : const SizedBox(width: double.infinity),
        ),
    ],
  );
}
