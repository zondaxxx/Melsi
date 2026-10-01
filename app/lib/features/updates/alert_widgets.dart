// Attention row on Home, and the update rows in Settings.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../ui/shell.dart' show AppTab, ShellNav;
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/format.dart';
import '../../ui/widgets/page.dart';
import 'alerts.dart';

/// The Home rail is 320px wide; single-column content is never narrower
/// than 328px (360px phone minus gutters). Narrower than this means we sit
/// at the top of the rail, otherwise above the quick toggles on a phone.
const double _kRailMax = 320;

/// Home rail: at most one row — the most severe alert, a `+N` tag when more
/// are waiting. Enters with a size + fade, the dot breathes once. Tap acts
/// on the alert (or opens the list when there are several); long-press
/// opens the list with dismiss / skip.
class AlertRows extends StatelessWidget {
  const AlertRows({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final updates = context.features.updates;
    final reduce = context.reduceMotion;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final list = alerts(app, updates);
        return LayoutBuilder(builder: (context, box) {
          final inRail = box.maxWidth <= _kRailMax;
          final Widget child = list.isEmpty
              ? const SizedBox(key: ValueKey('alerts-none'), width: double.infinity)
              : Padding(
                  key: ValueKey(list.first.id),
                  // Above the quick toggles the next header brings its own
                  // 32px; in the rail the first header is compact, so the
                  // gap is ours.
                  padding: EdgeInsets.only(
                      top: inRail ? 0 : Space.xl, bottom: inRail ? Space.xl : 0),
                  child: _AlertCard(alerts: list),
                );
          if (reduce) return child;
          return AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOut,
              transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
              child: child,
            ),
          );
        });
      },
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alerts});
  final List<AppAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final first = alerts.first;
    final more = alerts.length - 1;
    void openList() => _showAlertsSheet(context, act: (a) => _act(context, a));
    return Semantics(
      container: true,
      child: GroupCard(children: [
        GestureDetector(
          onLongPress: () {
            HapticFeedback.mediumImpact();
            openList();
          },
          child: RowTile(
            key: const ValueKey('alert-row'),
            leading: _BreathingDot(
              key: ValueKey(first.id),
              color: first.isDanger ? c.danger : c.warning,
            ),
            title: l(first.textKey, first.args),
            titleMaxLines: 2,
            trailing: more > 0 ? Tag('+$more') : null,
            chevron: true,
            onTap: () {
              HapticFeedback.selectionClick();
              if (more > 0) {
                openList();
              } else {
                _act(context, first);
              }
            },
          ),
        ),
      ]),
    );
  }
}

/// Opens the provider's page (or the release page); a subscription without
/// a page leads to the Servers tab. [context] must be inside the shell.
Future<void> _act(BuildContext context, AppAlert a) async {
  final nav = ShellNav.maybeOf(context);
  final u = Uri.tryParse(a.url ?? '');
  if (u != null && (u.scheme == 'https' || u.scheme == 'http')) {
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
      return;
    } catch (_) {
      // No browser / plugin: fall through to the Servers tab.
    }
  }
  if (!a.isUpdate) nav?.go(AppTab.servers);
}

Future<void> _showAlertsSheet(BuildContext context, {required void Function(AppAlert) act}) =>
    showMelsiSheet<void>(context, builder: (_) => _AlertsSheet(act: act));

/// Every current alert as a row: tap acts, the "…" menu dismisses (or
/// skips the version). Closes itself once nothing is left.
class _AlertsSheet extends StatelessWidget {
  const _AlertsSheet({required this.act});
  final void Function(AppAlert) act;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final app = context.app;
    final updates = context.features.updates;
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final list = alerts(app, updates);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: l('alert.title')),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
              child: list.isEmpty
                  ? SectionFooter(l('alert.none'))
                  : GroupCard(children: [
                      for (final a in list)
                        RowTile(
                          leading: StatusDot(a.isDanger ? c.danger : c.warning, size: 6),
                          title: l(a.textKey, a.args),
                          titleMaxLines: 2,
                          trailing: _AlertMenu(alert: a, updates: updates, app: app),
                          onTap: () {
                            Navigator.of(context).pop();
                            act(a);
                          },
                        ),
                    ]),
            ),
          ],
        );
      },
    );
  }
}

class _AlertMenu extends StatelessWidget {
  const _AlertMenu({required this.alert, required this.updates, required this.app});
  final AppAlert alert;
  final UpdateChecker updates;
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    return PopupMenuButton<String>(
      tooltip: l('common.more'),
      position: PopupMenuPosition.under,
      // A 32px square like the sheet's close control.
      child: SizedBox.square(
        dimension: 32,
        child: Center(child: Icon(Icons.more_horiz_rounded, size: 20, color: c.secondaryLabel)),
      ),
      onSelected: (v) {
        HapticFeedback.selectionClick();
        switch (v) {
          case 'dismiss':
            updates.dismiss(alert.id);
          case 'skip':
            updates.skipLatest();
        }
        if (alerts(app, updates).isEmpty) Navigator.of(context).maybePop();
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'dismiss', child: _MenuItem(Icons.visibility_off_outlined, l('alert.dismiss'))),
        if (alert.isUpdate)
          PopupMenuItem(value: 'skip', child: _MenuItem(Icons.skip_next_rounded, l('alert.skipVersion'))),
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: context.c.secondaryLabel),
        const SizedBox(width: Space.m),
        Text(text, style: context.t.body),
      ]);
}

/// 6px status dot that breathes once when it appears: a ring expands and
/// fades over 900ms, then nothing (no loop). Reduced motion: a plain dot.
class _BreathingDot extends StatefulWidget {
  const _BreathingDot({super.key, required this.color});
  final Color color;

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!context.reduceMotion) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const double _size = 6;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 10,
        height: 10,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final t = Curves.easeOut.transform(_c.value);
                if (t <= 0 || t >= 1) return const SizedBox.shrink();
                return Opacity(
                  opacity: (1 - t) * 0.45,
                  child: Transform.scale(
                    scale: 1 + 2.2 * t,
                    child: StatusDot(widget.color, size: _size),
                  ),
                );
              },
            ),
            StatusDot(widget.color, size: _size),
          ],
        ),
      );
}

// ------------------------------------------------------------------ settings

/// Settings › App rows: the daily check switch.
List<Widget> updateSettingsRows(BuildContext context, AppState app) {
  final l = context.l;
  return [
    SwitchRow(
      key: const ValueKey('update-setting'),
      title: l('update.setting'),
      subtitle: l('update.settingHint'),
      value: app.settings.checkUpdates,
      onChanged: (v) {
        app.updateSettings((s) => s.checkUpdates = v, affectsConfig: false);
        // Turning it on is a request to look now (still once a day after).
        if (v) context.features.updates.checkIfDue();
      },
    ),
  ];
}

/// Settings › About rows: "Проверить обновления" with the result as the
/// value; tap checks, or opens the release once one is known.
List<Widget> updateCheckRows(BuildContext context, AppState app) => const [_UpdateCheckRow()];

class _UpdateCheckRow extends StatelessWidget {
  const _UpdateCheckRow();

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final u = context.features.updates;
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final available = u.available;
        final Widget value;
        if (u.checking) {
          value = const SizedBox.square(
              key: ValueKey('checking'), dimension: 18, child: CupertinoActivityIndicator(radius: 7));
        } else if (available) {
          // A newer version is data about this install: label colour.
          value = Text(
            key: const ValueKey('available'),
            l('update.available', {'v': u.latestTag!}),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.callout.copyWith(color: c.label),
          );
        } else if (u.checkedAt != null) {
          value = Text(
            key: const ValueKey('latest'),
            l('update.latest'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.callout.copyWith(color: c.secondaryLabel),
          );
        } else {
          value = Icon(Icons.refresh_rounded,
              key: const ValueKey('never'), size: 18, color: c.secondaryLabel);
        }
        final checked = u.checkedAt;
        return RowTile(
          key: const ValueKey('update-check'),
          title: l('update.check'),
          subtitle: checked == null
              ? null
              : l('update.checked', {'t': formatAgo(l, u.now().difference(checked))}),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: context.reduceMotion ? 0 : 180),
              transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
              child: value,
            ),
          ),
          chevron: available,
          onTap: () {
            HapticFeedback.lightImpact();
            if (available) {
              u.openRelease();
            } else {
              u.checkNow();
            }
          },
        );
      },
    );
  }
}
