import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/format.dart';
import 'day_bars.dart';
import 'stats_models.dart';
import 'stats_screen.dart';

/// Home, after the speed panel: today's bytes and connected time, and a
/// seven-day strip so today has a scale. Shown only when there is something
/// to show — today has data, or a session is running (then the numbers
/// climb with the live traffic).
class TodayStatsCard extends StatelessWidget {
  const TodayStatsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final stats = context.features.stats;
    final traffic = context.appRead.traffic;
    return ListenableBuilder(
      listenable: Listenable.merge([stats, traffic]),
      builder: (context, _) {
        final today = stats.todayTotal;
        if (stats.current == null && today.isEmpty) return const SizedBox.shrink();
        final l = context.l;
        final days = stats.lastDays(7);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              l('stats.today'),
              trailing: ToolButton(
                key: const ValueKey('stats-today-open'),
                icon: Icons.bar_chart_rounded,
                size: 28,
                tooltip: l('stats.title'),
                onTap: () => openStatsScreen(context),
              ),
            ),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m + 2),
                    child: MetricsRow(items: [
                      (l('stats.down'), formatBytes(today.down, l: l), null),
                      (l('stats.up'), formatBytes(today.up, l: l), null),
                      (l('stats.time'), formatStatsTime(today.seconds, l), null),
                    ]),
                  ),
                  const Hairline(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.s),
                    child: SizedBox(
                      height: 56,
                      child: DayBars(days: days, labels: weekdayLabels(days, l)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Settings › Tools: the row that opens the Stats screen.
List<Widget> statsRows(BuildContext context, AppState app) => [
      RowTile(
        key: const ValueKey('stats-row'),
        title: context.l('stats.title'),
        chevron: true,
        onTap: () => openStatsScreen(context),
      ),
    ];

/// One weekday letter under each of the 7-day bars (Monday = first form of
/// `stats.weekdays`).
Map<int, String> weekdayLabels(List<DayTotal> days, L10n l) {
  final letters = l('stats.weekdays').split('|');
  if (letters.length != 7) return const {};
  return {for (var i = 0; i < days.length; i++) i: letters[days[i].date.weekday - 1]};
}

/// Connected time for a metric column: "12 мин" under an hour, "5:20 ч"
/// under 100 hours, "312 ч" beyond — short enough for a third of a 360px
/// panel, tabular so columns line up, and the unit sits after a non-breaking
/// space so [MetricsRow] sets it a step quieter.
String formatStatsTime(int seconds, L10n l) {
  final mins = seconds ~/ 60;
  final h = mins ~/ 60;
  if (h == 0) return l('stats.mins', {'n': '$mins'});
  if (h < 100) {
    return l('stats.hoursMins', {'h': '$h', 'm': (mins % 60).toString().padLeft(2, '0')});
  }
  return l('stats.hours', {'n': '$h'});
}

/// "1 окт" / "Oct 1".
String formatStatsDate(DateTime d, L10n l) {
  final months = l('stats.months').split('|');
  final m = months.length == 12 ? months[d.month - 1] : '${d.month}';
  return l('stats.date', {'d': '${d.day}', 'm': m});
}

/// "12:05" — session start time.
String formatStatsClock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
