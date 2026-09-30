import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/country.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../theme/glass.dart';
import '../theme/pressable.dart';
import '../theme/theme.dart';

/// Section title above a group of cards.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding});
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding ??
            const EdgeInsets.fromLTRB(Space.xs, Space.xxl, Space.xs, Space.s),
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: context.t.headline.copyWith(fontSize: 18, letterSpacing: -0.3)),
            ),
            ?trailing,
          ],
        ),
      );
}

/// Small label at the top of a card ("Сервер", "Трафик"): sentence case,
/// secondary colour, semibold — the same everywhere.
class CardLabel extends StatelessWidget {
  const CardLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 22,
        child: Row(children: [
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.footnote.copyWith(fontWeight: FontWeight.w600)),
          ),
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
        padding: const EdgeInsets.fromLTRB(Space.l, Space.s, Space.l, 0),
        child: Text(text, style: context.t.footnote),
      );
}

/// Grouped rows in one card with inset hairline separators.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children, this.inset = 58});
  final List<Widget> children;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i < children.length - 1) {
        items.add(Padding(
          padding: EdgeInsetsDirectional.only(start: inset),
          child: Container(height: 0.5, color: context.c.separator),
        ));
      }
    }
    return Card2(
      padding: EdgeInsets.zero,
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(Radii.l),
        child: Column(mainAxisSize: MainAxisSize.min, children: items),
      ),
    );
  }
}

/// Rounded-square coloured icon used at the start of rows.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, required this.color, this.size = 30});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: ShapeDecoration(
          shape: Radii.shape(size * 0.28),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.lerp(color, Colors.white, 0.12)!, color],
          ),
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.6),
      );
}

/// A settings-style row.
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
          horizontal: Space.l, vertical: dense ? Space.s : Space.m - 1),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: Space.m + 2)],
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
          if (trailing != null) ...[const SizedBox(width: Space.s), trailing!],
          if (chevron) ...[
            const SizedBox(width: Space.xs),
            Icon(Icons.chevron_right_rounded, color: c.tertiaryLabel, size: 22),
          ],
        ],
      ),
    );
    if (onTap != null) {
      row = _Highlight(onTap: onTap!, child: row);
    }
    return ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: row);
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
                      ? context.c.fill.withValues(alpha: 0.5)
                      : Colors.transparent,
              child: widget.child,
            ),
          ),
        ),
      );
}

/// iOS-style switch (with a light haptic on flip).
class MSwitch extends StatelessWidget {
  const MSwitch({super.key, required this.value, required this.onChanged, this.color});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? color;

  @override
  Widget build(BuildContext context) => CupertinoSwitch(
        value: value,
        activeTrackColor: color ?? context.c.success,
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
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? leading;
  final Color? color;

  @override
  Widget build(BuildContext context) => RowTile(
        title: title,
        subtitle: subtitle,
        leading: leading,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: MSwitch(value: value, onChanged: onChanged, color: color),
      );
}

/// Quiet protocol tag. Deliberately neutral: the node name usually already
/// says the protocol, so the badge is a scannable hint, not a headline.
/// UDP-native protocols (good for games) get a faint warm tint.
class ProtocolBadge extends StatelessWidget {
  const ProtocolBadge(this.protocol, {super.key});
  final ProxyProtocol protocol;

  static Color colorFor(ProxyProtocol p, MelsiColors c) =>
      p.udpNative ? const Color(0xFFE8773A) : c.secondaryLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = colorFor(protocol, c);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: ShapeDecoration(
        color: protocol.udpNative
            ? color.withValues(alpha: c.isDark ? 0.16 : 0.10)
            : c.fill,
        shape: Radii.shape(Radii.xs - 1),
      ),
      child: Text(protocol.label,
          style: context.t.caption2.copyWith(
              color: protocol.udpNative ? color : c.secondaryLabel,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.15)),
    );
  }
}

/// Latency pill: "48 мс" on a soft tint of its quality colour. Unknown shows
/// a quiet "—" which, when [onTest] is set, is tappable to measure just that
/// node. Shows a spinner while testing.
class LatencyChip extends StatelessWidget {
  const LatencyChip({
    super.key,
    this.ms,
    this.testing = false,
    this.failed = false,
    this.label,
    this.onTest,
  });
  final int? ms;
  final bool testing;
  final bool failed;
  final String? label;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    Widget child;
    if (testing) {
      child = const SizedBox(
          key: ValueKey('t'),
          width: 52,
          height: 24,
          child: Center(child: CupertinoActivityIndicator(radius: 7)));
    } else if (ms == null && !failed) {
      child = Container(
        key: const ValueKey('u'),
        width: onTest == null ? 52 : 28,
        height: 28,
        alignment: Alignment.center,
        decoration: onTest == null
            ? null
            : BoxDecoration(color: c.fill, shape: BoxShape.circle),
        child: onTest == null
            ? Text('—', style: context.t.footnote.copyWith(color: c.tertiaryLabel))
            : Icon(Icons.speed_rounded, size: 15, color: c.secondaryLabel),
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
      child = Container(
        key: ValueKey('$ms$failed'),
        height: 24,
        constraints: const BoxConstraints(minWidth: 52),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: color.withValues(alpha: c.isDark ? 0.18 : 0.12),
          shape: Radii.shape(Radii.pill),
        ),
        child: Text(
          failed ? (label ?? '×') : l('unit.ms', {'n': '$ms'}),
          style: context.t.mono.copyWith(
              fontSize: 12.5,
              color: failed || c.isDark ? color : Color.lerp(color, Colors.black, 0.18)),
        ),
      );
      if (onTest != null) {
        child = PressableScale(key: child.key, scale: 0.92, onTap: onTest, child: child);
      }
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      transitionBuilder: (w, a) => FadeTransition(
          opacity: a, child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(a), child: w)),
      child: child,
    );
  }
}

/// Evenly spaced live metrics, label over tabular value.
class MetricsRow extends StatelessWidget {
  const MetricsRow({super.key, required this.items});
  final List<(String, String, Color?)> items;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Space.s + 2),
      decoration: ShapeDecoration(color: c.fill, shape: Radii.shape(Radii.m)),
      child: IntrinsicHeight(
        child: Row(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) VerticalDivider(width: 1, thickness: 0.5, color: c.separator, indent: 4, endIndent: 4),
            Expanded(
              child: Column(children: [
                Text(items[i].$1, style: context.t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(items[i].$2,
                    maxLines: 1,
                    style: context.t.mono.copyWith(fontSize: 16, color: items[i].$3 ?? c.label)),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Stat chip: small caption over a value ("Jitter / 3 ms").
class StatChip extends StatelessWidget {
  const StatChip({super.key, required this.label, required this.value, this.color, this.icon});
  final String label;
  final String value;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Space.m - 2, vertical: Space.s - 2),
        decoration: ShapeDecoration(color: context.c.fill, shape: Radii.shape(Radii.s)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color ?? context.c.secondaryLabel),
              const SizedBox(width: 4),
            ],
            Text(label, style: context.t.caption),
            const SizedBox(width: 6),
            Text(value,
                style: context.t.mono.copyWith(fontSize: 13, color: color ?? context.c.label)),
          ],
        ),
      );
}

/// Emoji flags don't render on Windows (no flag glyphs) and are unreliable
/// on Linux, so there we draw the ISO code instead.
final bool emojiFlagsSupported = !(Platform.isWindows || Platform.isLinux);

/// Node name without a leading flag emoji (the [FlagBadge] shows it).
String nodeTitle(ProxyNode n) {
  final s = n.name.replaceFirst(RegExp(r'^(?:[\u{1F1E6}-\u{1F1FF}]{2}|\u{1F3F4}[\u{E0061}-\u{E007A}]+\u{E007F})\s*', unicode: true), '');
  return s.isEmpty ? n.name : s;
}

/// Round flag — emoji where the platform renders flags, ISO code otherwise.
class FlagBadge extends StatelessWidget {
  const FlagBadge(this.countryCode, {super.key, this.size = 34});
  final String? countryCode;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cc = countryCode;
    Widget inner;
    if (cc == null || cc.length != 2) {
      inner = Icon(Icons.public_rounded, size: size * 0.55, color: c.secondaryLabel);
    } else if (emojiFlagsSupported) {
      inner = Text(flagEmoji(cc),
          style: TextStyle(fontSize: size * 0.56, height: 1.1), textAlign: TextAlign.center);
    } else {
      inner = Text(cc.toUpperCase(),
          style: context.t.caption2.copyWith(
              fontSize: size * 0.32, fontWeight: FontWeight.w700, color: c.label, letterSpacing: 0.3));
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.fill,
        border: Border.all(color: c.separator.withValues(alpha: 0.6), width: 0.5),
      ),
      child: inner,
    );
  }
}

/// Primary call-to-action: gradient pill.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.expand = false,
    this.gradient,
    this.busy = false,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool expand;
  final Gradient? gradient;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onTap != null && !busy;
    return PressableScale(
      onTap: enabled ? onTap : null,
      haptic: true,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled || busy ? 1 : 0.45,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: Space.xl),
          decoration: ShapeDecoration(
            gradient: gradient ?? c.accentGradient,
            shape: Radii.shape(Radii.m),
            shadows: [
              BoxShadow(
                  color: c.accent.withValues(alpha: 0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 6)),
            ],
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                const CupertinoActivityIndicator(color: Colors.white, radius: 9)
              else if (icon != null)
                Icon(icon, color: c.onAccent, size: 20),
              if (busy || icon != null) const SizedBox(width: Space.s),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.headline.copyWith(color: c.onAccent, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Secondary: neutral fill.
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
    final fg = color ?? c.accent;
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: Space.l),
        decoration: ShapeDecoration(
          color: fg.withValues(alpha: c.isDark ? 0.18 : 0.1),
          shape: Radii.shape(Radii.m),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 19, color: fg), const SizedBox(width: 6)],
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.callout.copyWith(color: fg, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular icon button (toolbar actions).
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.color,
    this.busy = false,
    this.size = 36,
    this.filled = false,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final bool busy;
  final double size;

  /// Primary action: accent gradient fill with a white glyph.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget w = PressableScale(
      onTap: busy ? null : onTap,
      scale: 0.9,
      semanticLabel: tooltip,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: onTap == null && !busy ? 0.4 : 1,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: filled ? null : c.fill,
            gradient: filled ? c.accentGradient : null,
            shape: BoxShape.circle,
            boxShadow: filled
                ? [BoxShadow(color: c.accent.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 3))]
                : null,
          ),
          child: busy
              ? CupertinoActivityIndicator(radius: 8, color: filled ? Colors.white : null)
              : Icon(icon, size: size * 0.53, color: filled ? Colors.white : (color ?? c.accent)),
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
          Container(
            width: 72,
            height: 72,
            decoration: ShapeDecoration(
              shape: Radii.shape(22),
              gradient: LinearGradient(colors: [
                c.accent.withValues(alpha: 0.16),
                c.accent2.withValues(alpha: 0.16),
              ]),
            ),
            child: Icon(icon, size: 34, color: c.accent),
          ),
          const SizedBox(height: Space.l),
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

/// Small pill label ("Умный выбор").
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.icon, this.color, this.filled = false});
  final String text;
  final IconData? icon;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final col = color ?? context.c.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: filled ? col : col.withValues(alpha: context.c.isDark ? 0.2 : 0.12),
        shape: Radii.shape(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: filled ? Colors.white : col),
          const SizedBox(width: 4),
        ],
        Text(text,
            style: context.t.caption2.copyWith(
                color: filled ? Colors.white : col, letterSpacing: 0.1)),
      ]),
    );
  }
}

/// Tappable neutral tile (fill background) with press feedback.
class PressableScaleCard extends StatelessWidget {
  const PressableScaleCard({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.symmetric(vertical: Space.l, horizontal: Space.s)});
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => PressableScale(
        onTap: onTap,
        haptic: true,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: onTap == null ? 0.5 : 1,
          child: Container(
            padding: padding,
            decoration: ShapeDecoration(color: context.c.fill, shape: Radii.shape(Radii.m)),
            child: child,
          ),
        ),
      );
}
