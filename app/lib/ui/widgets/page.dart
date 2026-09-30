import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/theme.dart';

/// Space the shell's floating chrome occupies at the bottom (tab bar).
class ShellInsets extends InheritedWidget {
  const ShellInsets({super.key, required this.bottom, required super.child});
  final double bottom;

  static double bottomOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellInsets>()?.bottom ??
      MediaQuery.paddingOf(context).bottom;

  @override
  bool updateShouldNotify(ShellInsets old) => old.bottom != bottom;
}

/// Page with an Apple-style large title that collapses into a translucent
/// inline header as content scrolls underneath it. Content is centred and
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

  static const _bar = 52.0;
  double get _large => subtitle == null ? 50.0 : 72.0;

  @override
  double get minExtent => topPadding + _bar;
  @override
  double get maxExtent => topPadding + _bar + _large;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final c = context.c;
    final p = (shrinkOffset / _large).clamp(0.0, 1.0);
    final inlineOpacity = ((p - 0.55) / 0.45).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Material fades in only once content is actually underneath.
        if (p > 0)
          Opacity(
            opacity: p,
            child: const Glass(
              radius: 0,
              edge: false,
              child: SizedBox.expand(),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(height: 0.5, color: c.separator.withValues(alpha: p)),
        ),
        // Inline bar.
        Positioned(
          top: topPadding,
          left: hPad,
          right: hPad - 4,
          height: _bar,
          child: Row(
            children: [
              Expanded(
                child: Opacity(
                  opacity: inlineOpacity,
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.headline),
                ),
              ),
              for (final a in actions) ...[const SizedBox(width: Space.s), a],
            ],
          ),
        ),
        // Large title, slides up under the bar and fades.
        Positioned(
          left: hPad,
          right: hPad,
          top: topPadding + _bar - shrinkOffset.clamp(0, _large) * 0.35,
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
                      style: context.t.largeTitle),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    DefaultTextStyle.merge(style: context.t.footnote, child: subtitle!),
                  ],
                ],
              ),
            ),
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

/// Compact inline bar (no large title). The material fades in once content
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

  static const _bar = 52.0;

  @override
  double get minExtent => topPadding + _bar;
  @override
  double get maxExtent => topPadding + _bar;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final c = context.c;
    final p = (shrinkOffset / 16).clamp(0.0, 1.0);
    return Stack(fit: StackFit.expand, children: [
      if (p > 0)
        Opacity(
          opacity: p,
          child: const Glass(radius: 0, edge: false, child: SizedBox.expand()),
        ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(height: 0.5, color: c.separator.withValues(alpha: p)),
      ),
      Positioned(
        top: topPadding,
        left: hPad,
        right: hPad - 4,
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
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(Space.x3),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 540, maxHeight: expand ? 720 : 640),
          child: builder(ctx),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      reverseDuration: Duration(milliseconds: 260),
    ),
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        Container(
          width: 36,
          height: 5,
          decoration: ShapeDecoration(
              color: ctx.c.tertiaryLabel, shape: Radii.shape(3)),
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

/// Standard sheet header: title + optional close / done.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title, this.trailing, this.leading});
  final String title;
  final Widget? trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.s, Space.s),
        child: Row(
          children: [
            ?leading,
            Expanded(child: Text(title, style: context.t.title3)),
            trailing ??
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(color: context.c.fill, shape: BoxShape.circle),
                    child: Icon(Icons.close_rounded, size: 18, color: context.c.secondaryLabel),
                  ),
                ),
          ],
        ),
      );
}
