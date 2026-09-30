import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
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
/// interactive state, not a health signal.
class MSwitch extends StatelessWidget {
  const MSwitch({super.key, required this.value, required this.onChanged, this.color});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? color;

  @override
  Widget build(BuildContext context) => CupertinoSwitch(
        value: value,
        activeTrackColor: color ?? context.c.accent,
        inactiveTrackColor: context.c.fillStrong,
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

/// Latency as right-aligned tabular text coloured by quality. Unknown shows
/// "—" which, when [onTest] is set, is tappable to measure just that node.
/// Shows a spinner while testing.
class LatencyChip extends StatelessWidget {
  const LatencyChip({
    super.key,
    this.ms,
    this.testing = false,
    this.failed = false,
    this.label,
    this.onTest,
    this.size = 13,
  });
  final int? ms;
  final bool testing;
  final bool failed;
  final String? label;
  final VoidCallback? onTest;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    Widget child;
    if (testing) {
      child = const SizedBox(
          key: ValueKey('t'),
          width: 44,
          height: 22,
          child: Center(child: CupertinoActivityIndicator(radius: 6)));
    } else if (ms == null && !failed) {
      child = SizedBox(
        key: const ValueKey('u'),
        width: 44,
        height: 22,
        child: Align(
          alignment: Alignment.centerRight,
          child: onTest == null
              ? Text('—', style: context.t.mono.copyWith(color: c.tertiaryLabel))
              : Icon(Icons.speed_rounded, size: 16, color: c.tertiaryLabel),
        ),
      );
      if (onTest != null) {
        child = Tooltip(
          key: const ValueKey('u'),
          message: l('ping.test'),
          child: PressableScale(scale: 0.9, haptic: true, onTap: onTest, child: child),
        );
      }
    } else {
      final color = failed ? c.danger : c.latency(ms);
      child = SizedBox(
        key: ValueKey('$ms$failed'),
        height: 22,
        child: Align(
          alignment: Alignment.centerRight,
          child: Text(
            failed ? (label ?? '×') : l('unit.ms', {'n': '$ms'}),
            maxLines: 1,
            style: context.t.mono.copyWith(fontSize: size, color: color),
          ),
        ),
      );
      if (onTest != null) {
        child = PressableScale(key: child.key, scale: 0.94, onTap: onTest, child: child);
      }
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
      child: child,
    );
  }
}

/// Metrics in columns: overline label over a tabular mono value, separated
/// by hairlines. No fill — the type does the work.
class MetricsRow extends StatelessWidget {
  const MetricsRow({super.key, required this.items, this.large = false});
  final List<(String, String, Color?)> items;
  final bool large;

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
              Overline(items[i].$1),
              const SizedBox(height: 4),
              Text(items[i].$2,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: (large ? t.monoLarge : t.mono.copyWith(fontSize: 15))
                      .copyWith(color: items[i].$3 ?? c.label)),
            ]),
          ),
        ],
      ]),
    );
  }
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

/// Primary call-to-action: solid accent, no shadow.
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
    return PressableScale(
      onTap: enabled ? onTap : null,
      haptic: true,
      scale: 0.98,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled || busy ? 1 : 0.45,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: Space.xl),
          decoration: ShapeDecoration(color: c.accent, shape: Radii.shape(Radii.m - 2)),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                CupertinoActivityIndicator(color: c.onAccent, radius: 8)
              else if (icon != null)
                Icon(icon, color: c.onAccent, size: 18),
              if (busy || icon != null) const SizedBox(width: Space.s),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.subhead.copyWith(color: c.onAccent, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
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
          shape: Radii.shape(Radii.m - 2, side: BorderSide(color: c.separator, width: kHairline)),
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

/// Square icon button for toolbars. [filled] makes it the accent primary.
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.color,
    this.busy = false,
    this.size = 32,
    this.filled = false,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final bool busy;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget w = PressableScale(
      onTap: busy ? null : onTap,
      scale: 0.92,
      semanticLabel: tooltip,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: onTap == null && !busy ? 0.4 : 1,
        child: Container(
          width: size,
          height: size,
          decoration: ShapeDecoration(
            color: filled ? c.accent : c.surface,
            shape: Radii.shape(Radii.s + 1,
                side: filled ? BorderSide.none : BorderSide(color: c.separator, width: kHairline)),
          ),
          child: busy
              ? CupertinoActivityIndicator(radius: 7, color: filled ? c.onAccent : null)
              : Icon(icon, size: size * 0.56, color: filled ? c.onAccent : (color ?? c.label)),
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
          child: Panel(padding: padding, child: child),
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
