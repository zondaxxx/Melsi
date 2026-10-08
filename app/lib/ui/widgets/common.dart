import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../theme/pressable.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';

/// Small uppercase tracked label. The workhorse of the hierarchy: section
/// headers, panel labels, metric captions all use it.
class Overline extends StatelessWidget {
  const Overline(this.text, {super.key, this.color, this.maxLines = 1});
  final String text;
  final Color? color;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: context.t.overline.copyWith(color: color),
      );
}

/// Section title above a group of panels.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding});
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding ??
            const EdgeInsets.fromLTRB(Space.xs, Space.x3, Space.xs, Space.s + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Overline(title)),
            ?trailing,
          ],
        ),
      );
}

/// Label at the top of a panel ("Сервер", "Трафик").
class CardLabel extends StatelessWidget {
  const CardLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 20,
        child: Row(children: [
          Expanded(child: Overline(text)),
          ?trailing,
        ]),
      );
}

/// Footnote under a group.
class SectionFooter extends StatelessWidget {
  const SectionFooter(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.xs, Space.s + 2, Space.xs, 0),
        child: Text(text, style: context.t.footnote),
      );
}

/// Grouped rows in one panel with inset hairline separators.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children, this.inset = Space.l});
  final List<Widget> children;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i < children.length - 1) items.add(Hairline(inset: inset));
    }
    return Panel(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: items),
    );
  }
}

/// A settings-style row: title (+ subtitle), optional trailing value, chevron.
class RowTile extends StatelessWidget {
  const RowTile({
    super.key,
    required this.title,
    this.titleMaxLines = 1,
    this.subtitle,
    this.subtitleWidget,
    this.leading,
    this.trailing,
    this.onTap,
    this.chevron = false,
    this.destructive = false,
    this.dense = false,
  });

  final String title;
  final int titleMaxLines;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final bool destructive;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    Widget row = Padding(
      padding: EdgeInsets.symmetric(
          horizontal: Space.l, vertical: dense ? Space.s + 1 : Space.m),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: Space.m)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: t.body.copyWith(color: destructive ? c.danger : c.label)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: t.footnote),
                ],
                if (subtitleWidget != null) ...[
                  const SizedBox(height: 3),
                  subtitleWidget!,
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: Space.m), trailing!],
          if (chevron) ...[
            const SizedBox(width: Space.s),
            Icon(Icons.chevron_right_rounded, color: c.tertiaryLabel, size: 18),
          ],
        ],
      ),
    );
    if (onTap != null) {
      row = _Highlight(onTap: onTap!, child: row);
    }
    return ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: row);
  }
}

/// Row highlight that appears on pointer-down (not on release).
class _Highlight extends StatefulWidget {
  const _Highlight({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;
  @override
  State<_Highlight> createState() => _HighlightState();
}

class _HighlightState extends State<_Highlight> {
  bool _down = false;
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          onPointerDown: (_) => setState(() => _down = true),
          onPointerUp: (_) => setState(() => _down = false),
          onPointerCancel: (_) => setState(() => _down = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapCancel: () => setState(() => _down = false),
            child: ColoredBox(
              color: _down
                  ? context.c.fillStrong
                  : _hover
                      ? context.c.fill
                      : Colors.transparent,
              child: widget.child,
            ),
          ),
        ),
      );
}

/// Switch (with a light haptic on flip). "On" is the accent: it is an
/// interactive state, not a health signal. The off track is a touch
/// stronger than the neutral fill in dark so it stays visible on a card.
class MSwitch extends StatelessWidget {
  const MSwitch({super.key, required this.value, required this.onChanged, this.color});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? color;

  @override
  Widget build(BuildContext context) => CupertinoSwitch(
        value: value,
        thumbColor: Colors.white,
        activeTrackColor: color ?? context.c.accent,
        inactiveTrackColor: context.c.offTrack,
        onChanged: onChanged == null
            ? null
            : (v) {
                HapticFeedback.lightImpact();
                onChanged!(v);
              },
      );
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.color,
    this.dense = false,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? leading;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) => RowTile(
        title: title,
        subtitle: subtitle,
        leading: leading,
        dense: dense,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: MSwitch(value: value, onChanged: onChanged, color: color),
      );
}

/// Protocol as a small monospaced tag. One neutral style for every
/// protocol: the name is what matters, not a colour code.
class ProtocolBadge extends StatelessWidget {
  const ProtocolBadge(this.protocol, {super.key});
  final ProxyProtocol protocol;

  @override
  Widget build(BuildContext context) =>
      Text(protocol.label.toUpperCase(), style: context.t.monoSmall);
}

/// Latency in the user's preferred format. Visibility is presentation only;
/// tapping a visible value still measures that node when [onTest] is set.
class LatencyChip extends StatelessWidget {
  const LatencyChip({
    super.key,
    this.ms,
    this.testing = false,
    this.failed = false,
    this.label,
    this.onTest,
    this.size = 13,
    this.alignment = Alignment.centerRight,
  });
  final int? ms;
  final bool testing;
  final bool failed;
  final String? label;
  final VoidCallback? onTest;
  final double size;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.maybeOf(context)?.settings;
    if (settings?.showPing == false) return const SizedBox.shrink();
    final format = settings?.pingDisplay ?? PingDisplay.number;
    final c = context.c;
    final l = context.l;
    final unknown = ms == null && !failed;
    final description = testing
        ? l('ping.testing')
        : failed
            ? l('ping.timeout')
            : unknown
                ? l('ping.unknown')
                : l('unit.ms', {'n': '$ms'});
    Widget child;
    if (testing) {
      child = const SizedBox(
          key: ValueKey('t'),
          width: 44,
          height: 22,
          child: Center(child: CupertinoActivityIndicator(radius: 6)));
    } else {
      final color = failed ? c.danger : c.latency(ms);
      final strength = ms == null || ms! <= 0 ? 0 : ms! < 100 ? 3 : ms! < 250 ? 2 : 1;
      child = SizedBox(
        key: ValueKey('$ms-$failed-${format.name}'),
        width: unknown && format == PingDisplay.number ? 44 : null,
        height: 22,
        child: Align(
          alignment: alignment,
          widthFactor: 1,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: alignment,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (format != PingDisplay.number)
                failed
                    ? Icon(Icons.close_rounded, size: 14, color: color)
                    : Row(
                        key: ValueKey('ping-indicator-$strength'),
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var i = 0; i < 3; i++)
                            Container(
                              width: 3,
                              height: 4 + i * 3,
                              margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
                              decoration: BoxDecoration(
                                color: i < strength ? color : c.tertiaryLabel.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                        ],
                      ),
              if (format == PingDisplay.both) const SizedBox(width: 5),
              if (format != PingDisplay.indicator)
                Text(
                  failed ? (label ?? '×') : unknown ? '—' : l('unit.ms', {'n': '$ms'}),
                  maxLines: 1,
                  style: failed
                      ? context.t.caption.copyWith(fontSize: size, color: color, fontWeight: FontWeight.w500)
                      : context.t.mono.copyWith(fontSize: size, color: color),
                ),
            ]),
          ),
        ),
      );
      if (onTest != null) {
        child = PressableScale(key: child.key, scale: 0.94, haptic: unknown, onTap: onTest, child: child);
      }
    }
    final semantics = '${l('stat.latency')}: $description';
    return Semantics(
      label: semantics,
      button: onTest != null && !testing,
      onTap: testing ? null : onTest,
      excludeSemantics: true,
      child: Tooltip(
        message: unknown && onTest != null && !testing ? l('ping.test') : semantics,
        excludeFromSemantics: true,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
          child: child,
        ),
      ),
    );
  }
}

/// Metrics in columns: overline label over a tabular mono value, separated
/// by hairlines. No fill — the type does the work. A label that does not
/// fit its column (360px phones) scales down a step rather than truncating.
/// One rule for units everywhere: the number carries the colour, a trailing
/// unit ("мс", "ГБ") is set in the same mono a step quieter; a lone dash
/// means "no data" and is tertiary.
class MetricsRow extends StatelessWidget {
  const MetricsRow({super.key, required this.items, this.large = false, this.valueWidgets = const {}});
  final List<(String, String, Color?)> items;
  final bool large;
  final Map<int, Widget> valueWidgets;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    return IntrinsicHeight(
      child: Row(children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(width: Space.m),
            VerticalDivider(width: kHairline, thickness: kHairline, color: c.separator),
            const SizedBox(width: Space.m),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Overline(items[i].$1),
                ),
              ),
              const SizedBox(height: 4),
              valueWidgets[i] ?? _metric(items[i].$2, (large ? t.monoLarge : t.mono.copyWith(fontSize: 15)),
                  items[i].$3 ?? c.label, c.tertiaryLabel),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// "48 мс" → number in [color], unit in [unitColor]; "—" alone in [unitColor].
/// The formatter joins number and unit with a non-breaking space, so the
/// split accepts either kind.
Widget _metric(String value, TextStyle style, Color color, Color unitColor) {
  if (value == '—') {
    return Text(value, maxLines: 1, softWrap: false, style: style.copyWith(color: unitColor));
  }
  final sp = value.lastIndexOf(RegExp(r'[ \u00A0]'));
  final split = sp > 0 && RegExp(r'^[\d.,:]+$').hasMatch(value.substring(0, sp));
  return Text.rich(
    split
        ? TextSpan(children: [
            TextSpan(text: value.substring(0, sp), style: style.copyWith(color: color)),
            TextSpan(text: value.substring(sp), style: style.copyWith(color: unitColor)),
          ])
        : TextSpan(text: value, style: style.copyWith(color: color)),
    maxLines: 1,
    overflow: TextOverflow.fade,
    softWrap: false,
  );
}

/// Emoji flags don't render on Windows (no flag glyphs) and are unreliable
/// on Linux, so there we show the ISO code instead.
final bool emojiFlagsSupported = !(Platform.isWindows || Platform.isLinux);

/// Node name without a leading flag emoji (the [CountryCode] box carries
/// the country).
String nodeTitle(ProxyNode n) {
  final s = n.name.replaceFirst(RegExp(r'^(?:[\u{1F1E6}-\u{1F1FF}]{2}|\u{1F3F4}[\u{E0061}-\u{E007A}]+\u{E007F})\s*', unicode: true), '');
  return s.isEmpty ? n.name : s;
}

/// ISO country code in a small monospaced box. Unknown → "—".
class CountryCode extends StatelessWidget {
  const CountryCode(this.countryCode, {super.key, this.width = 30});
  final String? countryCode;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cc = countryCode;
    return Container(
      width: width,
      height: 20,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: c.fill,
        shape: Radii.shape(Radii.xs, side: BorderSide(color: c.separator, width: kHairline)),
      ),
      child: Text(
        cc == null || cc.length != 2 ? '—' : cc.toUpperCase(),
        style: context.t.monoSmall.copyWith(color: c.label, letterSpacing: 0.6),
      ),
    );
  }
}

/// Primary call-to-action: solid accent, no shadow. Disabled it drops to the
/// neutral strong fill with tertiary text, so the accent never appears
/// washed out as a third colour.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.expand = false,
    this.busy = false,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool expand;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onTap != null && !busy;
    final live = enabled || busy;
    final fg = live ? c.onAccent : c.tertiaryLabel;
    return PressableScale(
      onTap: enabled ? onTap : null,
      haptic: true,
      scale: 0.98,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        decoration: ShapeDecoration(
            color: live ? c.accent : c.fillStrong, shape: Radii.shape(Radii.m)),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              CupertinoActivityIndicator(color: c.onAccent, radius: 8)
            else if (icon != null)
              Icon(icon, color: fg, size: 18),
            if (busy || icon != null) const SizedBox(width: Space.s),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.subhead.copyWith(color: fg, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Secondary: hairline outline, label colour.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, this.icon, this.onTap, this.expand = false, this.color});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool expand;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = color ?? c.label;
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: Space.l),
        decoration: ShapeDecoration(
          color: c.surface,
          shape: Radii.shape(Radii.m, side: BorderSide(color: c.separator, width: kHairline)),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 17, color: fg), const SizedBox(width: 6)],
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.subhead.copyWith(color: fg, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square icon button for toolbars: outlined surface, label-colour glyph.
/// Always neutral — the accent belongs to the primary action of the page,
/// never to a tool in its header.
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.color,
    this.busy = false,
    this.size = 32,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final bool busy;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onTap != null && !busy;
    Widget w = PressableScale(
      onTap: busy ? null : onTap,
      scale: 0.92,
      semanticLabel: tooltip,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: onTap == null && !busy ? 0.4 : 1,
        child: Hoverable(
          enabled: enabled,
          builder: (context, hovered, pressed) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: size,
            height: size,
            decoration: ShapeDecoration(
              color: interactiveSurface(c, c.surface, hovered: hovered, pressed: pressed),
              shape: Radii.shape(Radii.s,
                  side: BorderSide(color: c.separator, width: kHairline)),
            ),
            child: busy
                ? const CupertinoActivityIndicator(radius: 7)
                : Icon(icon, size: size * 0.56, color: color ?? c.label),
          ),
        ),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: c.tertiaryLabel),
          const SizedBox(height: Space.m),
          Text(title, style: context.t.title3, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: Space.s),
            Text(message!,
                style: context.t.callout.copyWith(color: c.secondaryLabel),
                textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: Space.xl), action!],
        ],
      ),
    );
  }
}

/// Small uppercase tag with a hairline border ("Умный выбор", "Авто").
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final col = color ?? c.secondaryLabel;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      decoration: ShapeDecoration(
        shape: Radii.shape(Radii.xs, side: BorderSide(color: color ?? c.separator, width: kHairline)),
      ),
      child: Text(text.toUpperCase(),
          style: context.t.overline.copyWith(color: col, fontSize: 10, letterSpacing: 0.7)),
    );
  }
}

/// Tappable neutral panel with press feedback.
class PressableScaleCard extends StatelessWidget {
  const PressableScaleCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.symmetric(vertical: Space.l, horizontal: Space.s)});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => PressableScale(
        onTap: onTap,
        haptic: true,
        scale: 0.98,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: onTap == null ? 0.5 : 1,
          child: Hoverable(
            enabled: onTap != null,
            builder: (context, hovered, pressed) => Panel(
              padding: padding,
              color: interactiveSurface(context.c, context.c.surface, hovered: hovered, pressed: pressed),
              child: child,
            ),
          ),
        ),
      );
}

/// Status dot: 8px, meaning colour. [pulse] adds a soft one-off ring while a
/// state is in flux (never loops once settled).
class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key, this.size = 8, this.hollow = false});
  final Color color;
  final double size;
  final bool hollow;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: hollow ? Colors.transparent : color,
          border: hollow ? Border.all(color: color, width: 1.5) : null,
        ),
      );
}
