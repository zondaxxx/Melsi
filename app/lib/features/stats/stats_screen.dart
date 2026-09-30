import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/features.dart';
import '../../ui/screens/servers_screen.dart' show confirm;
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/format.dart';
import '../../ui/widgets/page.dart';
import '../../ui/widgets/segmented.dart';
import 'day_bars.dart';
import 'stats_models.dart';
import 'stats_widgets.dart';

/// Opens the Stats screen: pushed on phones, a sheet (a centred dialog) on
/// wide layouts where a full-screen route would swallow the sidebar.
Future<void> openStatsScreen(BuildContext context) {
  if (context.isWide) {
    return showMelsiSheet<void>(
      context,
      expand: true,
      builder: (_) => const StatsScreen(sheet: true),
    );
  }
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StatsScreen()));
}

/// 7 / 30 / 90 days of traffic and the session list.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, this.sheet = false});

  /// Rendered inside [showMelsiSheet] (own header, no app bar).
  final bool sheet;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  static const _ranges = [7, 30, 90];

  int? _range;

  /// Bars grow from the baseline once, on the frame after the first paint.
  bool _grown = false;

  /// Bar under the mouse, and the one the last tap pinned (touch has no
  /// hover; a tap keeps the caption until the same bar is tapped again).
  int? _hover;
  int? _pinned;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _grown = true);
    });
  }

  StatsService get _stats => context.features.stats;

  /// The grow-in: critically damped, a touch slower than the UI standard so
  /// ninety bars rising together read as one motion, not a flicker.
  static final _grow = Springs.of(0.55, 1.0);

  void _setRange(int v) {
    setState(() {
      _range = v;
      _hover = null;
      _pinned = null;
    });
    _stats.setRange(v);
  }

  /// Finger lifted after scrubbing: the last bar stays pinned so the
  /// caption survives the release.
  void _release() => setState(() {
        _pinned = _hover ?? _pinned;
        _hover = null;
      });

  Future<void> _delete(SessionRecord s) async {
    final l = context.l;
    final ok = await confirm(
      context,
      title: l('stats.deleteTitle'),
      message: l('stats.deleteText', {'name': _nodeTitle(s.nodeName)}),
      destructive: l('common.delete'),
    );
    if (ok && mounted) _stats.deleteSession(s.id);
  }

  Future<void> _clear() async {
    final l = context.l;
    final ok = await confirm(
      context,
      title: l('stats.clearTitle'),
      message: l('stats.clearText'),
      destructive: l('common.clear'),
    );
    if (ok && mounted) _stats.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final stats = _stats;
    final range = _range ??= stats.preferredRange;
    final reduce = context.reduceMotion;

    final body = ListenableBuilder(
      listenable: stats,
      builder: (context, _) {
        final days = stats.lastDays(range);
        final total = stats.totals(range);
        final hasData = days.any((d) => !d.isEmpty);
        final sessions = stats.sessions;
        final shown = _hover ?? _pinned;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Segmented<int>(
              value: range,
              onChanged: _setRange,
              segments: [for (final r in _ranges) Segment(r, l('stats.range$r'))],
            ),
            const SizedBox(height: Space.l),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.m + 2),
                    child: MetricsRow(items: [
                      (l('stats.down'), hasData ? formatBytes(total.down, l: l) : '—', null),
                      (l('stats.up'), hasData ? formatBytes(total.up, l: l) : '—', null),
                      (l('stats.time'), hasData ? formatStatsTime(total.seconds, l) : '—', null),
                    ]),
                  ),
                  const Hairline(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.s),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            hasData
                                ? l('stats.max', {'v': formatBytes(DayBarsPainter.peak(days), l: l)})
                                : l('chart.noData'),
                            style: t.monoSmall.copyWith(color: c.tertiaryLabel),
                          ),
                        ),
                        const SizedBox(height: Space.xs),
                        SizedBox(
                          height: 132,
                          child: SpringValue(
                            // Reduced motion: the bars are simply there.
                            target: reduce || _grown ? 1 : 0,
                            spring: _grow,
                            builder: (context, v, _) => _BarChart(
                              days: days,
                              labels: _labelsFor(days, l),
                              progress: v,
                              shown: shown,
                              onHover: (i) => setState(() => _hover = i),
                              onRelease: _release,
                              onTap: (i) => setState(() => _pinned = _pinned == i ? null : i),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SectionHeader(l('stats.sessions')),
            if (sessions.isEmpty)
              Panel(
                padding: EdgeInsets.zero,
                child: EmptyState(
                  icon: Icons.bar_chart_rounded,
                  title: l('stats.empty'),
                  message: l('stats.emptyText'),
                ),
              )
            else
              GroupCard(children: [
                for (final s in sessions)
                  _SessionRow(record: s, onDelete: s.isOpen ? null : () => _delete(s)),
                RowTile(
                  key: const ValueKey('stats-clear'),
                  title: l('stats.clear'),
                  destructive: true,
                  onTap: _clear,
                ),
              ]),
            SectionFooter(l('stats.note')),
          ],
        );
        final bottom = MediaQuery.paddingOf(context).bottom + Space.xxl;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: EdgeInsets.fromLTRB(Space.gutter, Space.s, Space.gutter, bottom),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: content,
              ),
            ),
          ],
        );
      },
    );

    if (widget.sheet) {
      return Column(
        children: [
          SheetHeader(title: l('stats.title')),
          const Hairline(),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        flexibleSpace: const Chrome(child: SizedBox.expand()),
        title: Text(l('stats.title'), style: t.headline),
      ),
      body: body,
    );
  }

  /// 7 days: a weekday letter under every bar. Longer ranges: the first
  /// and last day as dates, plus each month's first day between them (kept
  /// away from the ends so the labels never touch).
  static Map<int, String> _labelsFor(List<DayTotal> days, L10n l) {
    final n = days.length;
    if (n == 0) return const {};
    if (n <= 7) return weekdayLabels(days, l);
    String date(DayTotal d) {
      final t = d.date;
      return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
    }

    final out = <int, String>{0: date(days.first), n - 1: date(days.last)};
    for (var i = 1; i < n - 1; i++) {
      if (days[i].date.day == 1 && i >= n * 0.15 && i <= n * 0.85) out[i] = date(days[i]);
    }
    return out;
  }
}

/// The bar chart with scrubbing: hovering (mouse) or tapping / dragging
/// (touch) picks a bar, and a caption with the date and the values floats
/// above it, clamped to the chart's edges.
class _BarChart extends StatelessWidget {
  const _BarChart({
    required this.days,
    required this.labels,
    required this.progress,
    required this.shown,
    required this.onHover,
    required this.onRelease,
    required this.onTap,
  });

  final List<DayTotal> days;
  final Map<int, String> labels;
  final double progress;
  final int? shown;
  final ValueChanged<int?> onHover;
  final VoidCallback onRelease;
  final ValueChanged<int> onTap;

  /// Wide enough for "↓512.3 МБ ↑123.4 МБ · 5:20 ч" in 12px mono, narrower
  /// than the chart of a 360px phone (296px inside the panel).
  static const double _captionWidth = 224;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      int hit(Offset p) => DayBarsPainter.hitIndex(p.dx, w, days.length);
      final i = shown;
      final d = i != null && i >= 0 && i < days.length ? days[i] : null;
      return MouseRegion(
        onHover: (e) => onHover(hit(e.localPosition)),
        onExit: (_) => onHover(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (e) => onTap(hit(e.localPosition)),
          onHorizontalDragStart: (e) => onHover(hit(e.localPosition)),
          onHorizontalDragUpdate: (e) => onHover(hit(e.localPosition)),
          onHorizontalDragEnd: (_) => onRelease(),
          onHorizontalDragCancel: onRelease,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DayBars(days: days, labels: labels, progress: progress, highlight: i),
              if (d != null)
                Positioned(
                  top: 0,
                  left: ((i! + 0.5) * (w / days.length) - _captionWidth / 2)
                      .clamp(0.0, (w - _captionWidth).clamp(0.0, double.infinity)),
                  width: _captionWidth.clamp(0.0, w),
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
                      decoration: ShapeDecoration(
                        color: c.surfaceRaised,
                        shape: Radii.shape(Radii.s,
                            side: BorderSide(color: c.separator, width: kHairline)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(formatStatsDate(d.date, l), style: t.caption),
                          const SizedBox(height: 2),
                          Text(
                            d.isEmpty
                                ? l('chart.noData')
                                : '↓${formatBytes(d.down, l: l)} ↑${formatBytes(d.up, l: l)} · ${formatStatsTime(d.seconds, l)}',
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: t.mono.copyWith(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

/// One session: country box, server name, start (and the switch count when
/// there was any); on the right the bytes moved and the length, both in
/// mono. A running session shows a "Сейчас" tag instead of a length. Long
/// press deletes (closed sessions only).
class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.record, this.onDelete});
  final SessionRecord record;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final s = record;
    final start = '${formatStatsDate(s.start, l)}, ${formatStatsClock(s.start)}';
    final sub = s.switches > 0 ? '$start · ${l('stats.switches', {'n': '${s.switches}'})}' : start;
    final row = RowTile(
      leading: CountryCode(s.countryCode),
      title: _nodeTitle(s.nodeName),
      subtitle: sub,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '↓${formatBytes(s.down, l: l)} ↑${formatBytes(s.up, l: l)}',
            maxLines: 1,
            softWrap: false,
            style: t.mono,
          ),
          const SizedBox(height: 3),
          if (s.isOpen)
            Tag(l('stats.live'))
          else
            Text(formatDuration(s.duration!),
                maxLines: 1, style: t.mono.copyWith(color: c.secondaryLabel)),
        ],
      ),
    );
    if (onDelete == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () {
        HapticFeedback.mediumImpact();
        onDelete!();
      },
      child: row,
    );
  }
}

/// The server name without a leading flag emoji (the [CountryCode] box
/// carries the country); a dash when the session had no server.
String _nodeTitle(String name) {
  final s = name
      .replaceFirst(
          RegExp(r'^(?:[\u{1F1E6}-\u{1F1FF}]{2}|\u{1F3F4}[\u{E0061}-\u{E007A}]+\u{E007F})\s*',
              unicode: true),
          '')
      .trim();
  if (s.isNotEmpty) return s;
  return name.trim().isEmpty ? '—' : name.trim();
}
