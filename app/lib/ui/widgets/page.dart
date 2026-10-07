import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme/entrance.dart';
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

  /// When set, the page shows this widget (e.g. a wordmark) in place of a
  /// large title: at rest it sits on the same top line as the other tabs'
  /// titles, and slides up into the inline bar as content scrolls. Pass
  /// [SizedBox.shrink] on wide layouts where the sidebar already carries the
  /// brand; the header is then just the 48px bar and content starts on the
  /// title line ([titleTop]).
  final Widget? compactLeading;

  /// Where the large title's top edge lands on every page (below the status
  /// bar): the line Home aligns its status headline to on wide layouts.
  static const double titleTop = _LargeTitleHeader._bar;

  /// Line height of the large title (28px at 1.15).
  static const double titleLine = 32;

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
        physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: compactLeading != null
                ? _CompactHeader(
                    leading: compactLeading!,
                    // A shrunk leading has nothing to align: no title band.
                    large: compactLeading is SizedBox ? 0 : _CompactHeader.leadingBand,
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

/// Inline bar whose [leading] (the wordmark) rests on the title line like
/// the other tabs' large titles, then slides up into the bar as content
/// scrolls; the chrome fades in with it. With [large] 0 there is no title
/// band and the header is just the bar.
class _CompactHeader extends SliverPersistentHeaderDelegate {
  _CompactHeader({
    required this.leading,
    required this.large,
    required this.actions,
    required this.topPadding,
    required this.hPad,
  });

  final Widget leading;
  final double large;
  final List<Widget> actions;
  final double topPadding;
  final double hPad;

  static const _bar = _LargeTitleHeader._bar;

  /// One 24px line for the 19px wordmark plus the 12px the large title
  /// keeps below itself.
  static const double _leadingLine = 24;
  static const double leadingBand = _leadingLine + Space.m;

  @override
  double get minExtent => topPadding + _bar;
  @override
  double get maxExtent => topPadding + _bar + large;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    // With no title band the header never shrinks, so the chrome keys off
    // overlap instead (and fades in via AnimatedOpacity below).
    final p = large == 0 ? (overlapsContent ? 1.0 : 0.0) : (shrinkOffset / large).clamp(0.0, 1.0);
    // At rest the leading's top is the title line; collapsed, it is centred
    // in the bar.
    final restTop = topPadding + _bar;
    final barTop = topPadding + (_bar - _leadingLine) / 2;
    final leadingTop = large == 0 ? barTop : lerpDouble(restTop, barTop, p)!;
    final actionsWidth = actions.isEmpty ? 0.0 : actions.length * (32 + Space.s);
    return Stack(fit: StackFit.expand, children: [
      if (large == 0)
        AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: p,
          child: const Chrome(child: SizedBox.expand()),
        )
      else
        Chrome(opacity: p, child: const SizedBox.expand()),
      Positioned(
        top: leadingTop,
        left: hPad,
        right: hPad + actionsWidth,
        height: _leadingLine,
        child: Align(alignment: Alignment.centerLeft, child: leading),
      ),
      if (actions.isNotEmpty)
        Positioned(
          top: topPadding,
          right: hPad,
          height: _bar,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final a in actions) ...[const SizedBox(width: Space.s), a],
          ]),
        ),
    ]);
  }

  @override
  bool shouldRebuild(_CompactHeader old) =>
      old.leading != leading ||
      old.large != large ||
      old.actions != actions ||
      old.topPadding != topPadding ||
      old.hPad != hPad;
}

/// Opens [builder] as a bottom sheet on phones (it grows from the bottom edge
/// it's attached to) and as a centred dialog on wide layouts (520px wide,
/// 640px tall — 720 with [expand]; on phones [expand] pins the sheet to 86%
/// of the screen).
///
/// Motion: the sheet springs up ([Springs.sheet]) and a drag-dismiss turns the
/// release velocity into a spring fling; the dialog scales 0.96→1 with a fade
/// on a spring, the barrier fades in ~200ms and the close reverses in 160ms
/// (ease-in). Reduced motion: a 160ms cross-fade, nothing moves or scales. The
/// transition controller is created per call, owned by the route and disposed
/// with it — after the exit animation, so nothing ticks past the pop.
Future<T?> showMelsiSheet<T>(BuildContext context,
    {required WidgetBuilder builder, bool expand = false}) {
  final reduce = context.reduceMotion;
  final navigator = Navigator.of(context, rootNavigator: context.isWide);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final localizations = MaterialLocalizations.of(context);
  final barrier = Colors.black.withValues(alpha: 0.4);

  if (context.isWide) {
    return navigator.push(_MelsiDialogRoute<T>(
      reduceMotion: reduce,
      barrierColor: barrier,
      barrierLabel: localizations.modalBarrierDismissLabel,
      pageBuilder: (ctx, _, _) => themes.wrap(SafeArea(
        child: Dialog(
          insetPadding: const EdgeInsets.all(Space.x3),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 520, maxHeight: expand ? 720 : 640),
            child: Builder(builder: builder),
          ),
        ),
      )),
    ));
  }

  final controller = _SheetMotionController(
    vsync: navigator,
    spring: reduce ? null : Springs.sheet,
  );
  Widget content(BuildContext ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 4 + the grip's 12px box puts the 4px bar on the same 8..12px line
          // the plain handle used to sit on.
          const SizedBox(height: 4),
          const _SheetGrip(),
          Flexible(
            child: expand
                ? SizedBox(
                    height: MediaQuery.sizeOf(ctx).height * 0.86, child: builder(ctx))
                : builder(ctx),
          ),
        ],
      );
  return navigator.push(_MelsiSheetRoute<T>(
    controller: controller,
    capturedThemes: themes,
    barrierLabel: localizations.scrimLabel,
    barrierOnTapHint: localizations.scrimOnTapHint(localizations.bottomSheetLabel),
    modalBarrierColor: barrier,
    // With reduced motion the sheet's own surface is drawn inside the fade so
    // the whole thing cross-fades in place instead of the Material popping in.
    backgroundColor: reduce ? Colors.transparent : null,
    elevation: reduce ? 0 : null,
    sheetAnimationStyle: reduce
        ? const AnimationStyle(curve: Threshold(0), reverseCurve: Threshold(0))
        : const AnimationStyle(curve: Curves.linear, reverseCurve: Curves.easeIn),
    builder: (ctx) {
      if (!reduce) return content(ctx);
      return FadeTransition(
        opacity: controller,
        child: Material(
          color: ctx.c.surfaceRaised,
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.l))),
          child: content(ctx),
        ),
      );
    },
  ));
}

/// Bounded 0–1 transition controller whose *entrance* is a spring: the route
/// calls [forward] on push (and [BottomSheet] on a released drag), and both
/// continue from the current value and velocity. Drag-dismiss flings use a
/// critically damped sibling of the sheet spring ([fling] rejects underdamped
/// ones). With [spring] null (reduced motion) it is a plain 160ms controller.
class _SheetMotionController extends AnimationController {
  _SheetMotionController({required super.vsync, required this.spring})
      : super(
          duration: const Duration(milliseconds: 160),
          reverseDuration: Duration(milliseconds: spring == null ? 160 : 220),
        );

  final SpringDescription? spring;

  static final _flingSpring = Springs.of(0.3, 1.0);

  @override
  TickerFuture forward({double? from}) {
    final s = spring;
    if (s == null) return super.forward(from: from);
    if (from != null) value = from;
    return animateWith(
        SettlingSpring(s, start: value, end: upperBound, velocity: velocity));
  }

  @override
  TickerFuture fling({
    double velocity = 1.0,
    SpringDescription? springDescription,
    AnimationBehavior? animationBehavior,
  }) =>
      super.fling(
        velocity: velocity,
        springDescription: springDescription ?? (spring == null ? null : _flingSpring),
        animationBehavior: animationBehavior,
      );
}

/// The framework's modal sheet route with a controller it owns: disposing in
/// [dispose] (after the exit transition and the route's own listeners are
/// gone) is the one moment that is guaranteed leak- and use-after-dispose-free.
class _MelsiSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _MelsiSheetRoute({
    required _SheetMotionController controller,
    required super.builder,
    required super.capturedThemes,
    required super.barrierLabel,
    required super.barrierOnTapHint,
    required super.modalBarrierColor,
    required super.backgroundColor,
    required super.elevation,
    required super.sheetAnimationStyle,
  }) : super(
          transitionAnimationController: controller,
          isScrollControlled: true,
          useSafeArea: true,
        );

  @override
  void dispose() {
    super.dispose();
    transitionAnimationController!.dispose();
  }
}

/// Desktop counterpart: a general dialog route whose entrance controller is
/// spring-driven (scale 0.96→1 + fade) and whose close is a 160ms ease-in.
class _MelsiDialogRoute<T> extends RawDialogRoute<T> {
  _MelsiDialogRoute({
    required this.reduceMotion,
    required super.pageBuilder,
    required super.barrierColor,
    required super.barrierLabel,
  }) : super(transitionDuration: Duration(milliseconds: reduceMotion ? 160 : 200));

  final bool reduceMotion;

  static final _spring = Springs.of(0.32, 1.0);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  AnimationController createAnimationController() =>
      _DialogMotionController(vsync: navigator!,
          spring: reduceMotion ? null : _spring,
          duration: transitionDuration,
          reverseDuration: reverseTransitionDuration);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (reduceMotion) return FadeTransition(opacity: animation, child: child);
    // The spring shapes the entrance; the exit gets its own ease-in.
    final curved = CurvedAnimation(
        parent: animation, curve: Curves.linear, reverseCurve: Curves.easeIn);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// Route-owned controller for the dialog: spring on [forward], durations on
/// [reverse]; disposed by the route.
class _DialogMotionController extends AnimationController {
  _DialogMotionController({
    required super.vsync,
    required this.spring,
    required super.duration,
    required super.reverseDuration,
  });

  final SpringDescription? spring;

  @override
  TickerFuture forward({double? from}) {
    final s = spring;
    if (s == null) return super.forward(from: from);
    if (from != null) value = from;
    return animateWith(
        SettlingSpring(s, start: value, end: upperBound, velocity: velocity));
  }
}

/// The sheet's drag handle: 32px at rest, springs to 40px while a pointer is
/// down on it ([Springs.press]) as a hint that the sheet can be thrown. A
/// [Listener] rather than a gesture so the sheet's own drag still wins.
class _SheetGrip extends StatefulWidget {
  const _SheetGrip();

  @override
  State<_SheetGrip> createState() => _SheetGripState();
}

class _SheetGripState extends State<_SheetGrip> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    final width = reduce ? 32.0 : (_down ? 40.0 : 32.0);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: SizedBox(
        width: 64,
        height: 12,
        child: Center(
          child: SpringValue(
            target: width,
            spring: Springs.press,
            builder: (context, w, _) => Container(
              width: w,
              height: 4,
              decoration: ShapeDecoration(
                  color: context.c.fillStrong, shape: Radii.shape(2)),
            ),
          ),
        ),
      ),
    );
  }
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
