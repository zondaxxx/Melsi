import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme/surfaces.dart';
import '../theme/theme.dart';

/// Space the shell's bottom chrome occupies (tab bar).
class ShellInsets extends InheritedWidget {
  const ShellInsets({super.key, required this.bottom, required super.child});
  final double bottom;

  static double bottomOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellInsets>()?.bottom ??
      MediaQuery.paddingOf(context).bottom;

  @override
  bool updateShouldNotify(ShellInsets old) => old.bottom != bottom;
}

/// Page with a title that collapses into a solid inline header (with a
/// hairline) as content scrolls underneath it. Content is centred and
/// width-capped on wide screens.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.actions = const [],
    this.maxContentWidth = 760,
    this.controller,
    this.subtitle,
    this.compactLeading,
  });

  /// When set, the page uses a compact inline bar showing this widget (e.g.
  /// a wordmark) instead of a large title. Pass [SizedBox.shrink] on wide
  /// layouts where the sidebar already carries the brand.
  final Widget? compactLeading;

  final String title;
  final Widget? subtitle;
  final List<Widget> actions;
  final List<Widget> slivers;
  final double maxContentWidth;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final gutter = box.maxWidth >= 600 ? Space.gutterWide : Space.gutter;
      final h = math.max(gutter, (box.maxWidth - maxContentWidth) / 2);
      final top = MediaQuery.paddingOf(context).top;
      return CustomScrollView(
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: compactLeading != null
                ? _CompactHeader(
                    leading: compactLeading!,
                    actions: actions,
                    topPadding: top,
                    hPad: h,
                  )
                : _LargeTitleHeader(
                    title: title,
                    subtitle: subtitle,
                    actions: actions,
                    topPadding: top,
                    hPad: h,
                  ),
          ),
          for (final s in slivers)
            SliverPadding(padding: EdgeInsets.symmetric(horizontal: h), sliver: s),
          SliverToBoxAdapter(
            child: SizedBox(height: ShellInsets.bottomOf(context) + Space.x3),
          ),
        ],
      );
    });
  }
}

class _LargeTitleHeader extends SliverPersistentHeaderDelegate {
  _LargeTitleHeader({
    required this.title,
    required this.subtitle,
    required this.actions,
    required this.topPadding,
    required this.hPad,
  });

  final String title;
  final Widget? subtitle;
  final List<Widget> actions;
  final double topPadding;
  final double hPad;

  static const _bar = 48.0;
  double get _large => subtitle == null ? 44.0 : 64.0;

  @override
  double get minExtent => topPadding + _bar;
  @override
  double get maxExtent => topPadding + _bar + _large;

  /// Height of the tool buttons that sit on the title row.
  static const _actionSize = 36.0;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final p = (shrinkOffset / _large).clamp(0.0, 1.0);
    final inlineOpacity = ((p - 0.55) / 0.45).clamp(0.0, 1.0);
    final titleTop = topPadding + _bar - shrinkOffset.clamp(0, _large) * 0.35;
    // Title line is ~32px; the actions are vertically centred on it, then
    // glide up into the inline bar as the title collapses.
    final actionsTop = lerpDouble(titleTop - 2, topPadding + (_bar - _actionSize) / 2, p)!;
    final actionsWidth = actions.isEmpty ? 0.0 : actions.length * (_actionSize + Space.s);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Solid chrome fades in only once content is actually underneath.
        Chrome(opacity: p, child: const SizedBox.expand()),
        // Inline bar.
        Positioned(
          top: topPadding,
          left: hPad,
          right: hPad + actionsWidth,
          height: _bar,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Opacity(
              opacity: inlineOpacity,
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.headline),
            ),
          ),
        ),
        // Large title, slides up under the bar and fades.
        Positioned(
          left: hPad,
          right: hPad + actionsWidth,
          top: titleTop,
          child: IgnorePointer(
            child: Opacity(
              opacity: (1 - p * 1.6).clamp(0.0, 1.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.title1),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    DefaultTextStyle.merge(style: context.t.footnote, child: subtitle!),
                  ],
                ],
              ),
            ),
          ),
        ),
        // Tool buttons: on the title row at rest, in the bar when collapsed.
        if (actions.isNotEmpty)
          Positioned(
            right: hPad,
            top: actionsTop,
            height: _actionSize,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in actions) ...[const SizedBox(width: Space.s), a],
              ],
            ),
          ),
      ],
    );
  }

  @override
  bool shouldRebuild(_LargeTitleHeader old) =>
      old.title != title ||
      old.actions != actions ||
      old.topPadding != topPadding ||
      old.hPad != hPad ||
      old.subtitle != subtitle;
}

/// Compact inline bar (no large title). The chrome fades in once content
/// actually scrolls underneath.
class _CompactHeader extends SliverPersistentHeaderDelegate {
  _CompactHeader({
    required this.leading,
    required this.actions,
    required this.topPadding,
    required this.hPad,
  });

  final Widget leading;
  final List<Widget> actions;
  final double topPadding;
  final double hPad;

  static const _bar = 48.0;

  @override
  double get minExtent => topPadding + _bar;
  @override
  double get maxExtent => topPadding + _bar;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final p = (shrinkOffset / 16).clamp(0.0, 1.0);
    return Stack(fit: StackFit.expand, children: [
      Chrome(opacity: p, child: const SizedBox.expand()),
      Positioned(
        top: topPadding,
        left: hPad,
        right: hPad,
        height: _bar,
        child: Row(children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: leading)),
          for (final a in actions) ...[const SizedBox(width: Space.s), a],
        ]),
      ),
    ]);
  }

  @override
  bool shouldRebuild(_CompactHeader old) =>
      old.leading != leading ||
      old.actions != actions ||
      old.topPadding != topPadding ||
      old.hPad != hPad;
}

/// Opens [builder] as a bottom sheet on phones and a centred dialog on wide
/// screens (the sheet grows from the bottom edge it's attached to).
Future<T?> showMelsiSheet<T>(BuildContext context,
    {required WidgetBuilder builder, bool expand = false}) {
  if (context.isWide) {
    return showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(Space.x3),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 520, maxHeight: expand ? 720 : 640),
          child: builder(ctx),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      reverseDuration: Duration(milliseconds: 260),
    ),
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(
          width: 32,
          height: 4,
          decoration: ShapeDecoration(
              color: ctx.c.fillStrong, shape: Radii.shape(2)),
        ),
        Flexible(
          child: expand
              ? SizedBox(
                  height: MediaQuery.sizeOf(ctx).height * 0.86, child: builder(ctx))
              : builder(ctx),
        ),
      ],
    ),
  );
}

/// Standard sheet header: title + optional close / done. It always sits at
/// the sheet's edge — never inside a padded body — so the title lands flush
/// on the same 16px gutter as the cards below and the 32px close button's
/// glyph ends on the cards' right edge.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title, this.trailing, this.leading});
  final String title;
  final Widget? trailing;
  final Widget? leading;

  /// Trailing controls are 32px squares around a 20px glyph: pull the row
  /// in by the 6px of dead space so the glyph aligns with the content edge.
  static const double _trailingBleed = (SheetClose.size - 20) / 2;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(
            Space.l, Space.m, Space.l - _trailingBleed, Space.m),
        child: Row(
          children: [
            ?leading,
            Expanded(child: Text(title, style: context.t.title3)),
            trailing ?? const SheetClose(),
          ],
        ),
      );
}

/// Quiet close control for sheets.
class SheetClose extends StatelessWidget {
  const SheetClose({super.key});
  static const double size = 32;
  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: () => Navigator.of(context).maybePop(),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: size, height: size),
        icon: Icon(Icons.close_rounded, size: 20, color: context.c.secondaryLabel),
      );
}
