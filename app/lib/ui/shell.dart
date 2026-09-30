import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/vpn_controller.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'screens/game_screen.dart';
import 'screens/home_screen.dart';
import 'screens/routing_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/settings_screen.dart';
import 'theme/pressable.dart';
import 'theme/surfaces.dart';
import 'theme/theme.dart';
import 'widgets/apply_toast.dart';
import 'widgets/common.dart';
import 'widgets/page.dart';

enum AppTab { home, servers, routing, game, settings }

/// Lets any screen switch tabs (e.g. tapping the node panel on Home).
class ShellNav extends InheritedWidget {
  const ShellNav({super.key, required this.go, required this.current, required super.child});
  final void Function(AppTab tab) go;
  final AppTab current;

  static ShellNav of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellNav>()!;

  static ShellNav? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShellNav>();

  @override
  bool updateShouldNotify(ShellNav old) => old.current != current;
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  AppTab _tab = AppTab.home;
  StreamSubscription<Notice>? _notices;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: () => context.appRead.onResume());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _notices ??= context.appRead.notices.listen(_showNotice);
  }

  @override
  void dispose() {
    _notices?.cancel();
    _life.dispose();
    super.dispose();
  }

  void _showNotice(Notice n) {
    if (!mounted) return;
    final l = context.l;
    final c = context.c;
    var text = l(n.key, n.args);
    if (n.detail != null && n.detail!.isNotEmpty) text = '$text\n${n.detail}';
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final bottom = context.isWide ? Space.l : _tabBarHeight(context) + Space.s;
    messenger.showSnackBar(SnackBar(
      margin: EdgeInsets.fromLTRB(Space.l, 0, Space.l, bottom),
      duration: Duration(seconds: n.kind == NoticeKind.error ? 5 : 3),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: StatusDot(switch (n.kind) {
              NoticeKind.success => c.success,
              NoticeKind.error => c.danger,
              NoticeKind.info => c.isDark ? c.secondaryLabel : c.background.withValues(alpha: 0.6),
            }),
          ),
          const SizedBox(width: Space.m),
          Expanded(child: Text(text, maxLines: 6, overflow: TextOverflow.ellipsis)),
        ],
      ),
    ));
    if (n.kind == NoticeKind.error) HapticFeedback.heavyImpact();
  }

  static const double _barHeight = 54;

  static double _tabBarHeight(BuildContext context) =>
      _barHeight + MediaQuery.paddingOf(context).bottom;

  void _go(AppTab t) {
    if (t == _tab) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = t);
  }

  @override
  Widget build(BuildContext context) {
    final wide = context.isWide;
    final pages = [
      const HomeScreen(),
      const ServersScreen(),
      const RoutingScreen(),
      const GameScreen(),
      const SettingsScreen(),
    ];
    final bottomBar = wide ? 0.0 : _tabBarHeight(context);

    final stack = _FadeIndexedStack(index: _tab.index, children: pages);

    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < AppTab.values.length; i++) ...{
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: true):
              () => _go(AppTab.values[i]),
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: true):
              () => _go(AppTab.values[i]),
        },
      },
      child: Focus(
        autofocus: true,
        child: ShellNav(
          go: _go,
          current: _tab,
          child: Scaffold(
            backgroundColor: context.c.background,
            body: wide
                ? Row(
                    children: [
                      _Sidebar(current: _tab, onSelect: _go),
                      Expanded(
                        child: ShellInsets(
                          bottom: 0,
                          child: MediaQuery.removePadding(
                            context: context,
                            removeLeft: true,
                            child: Stack(children: [
                              Positioned.fill(child: stack),
                              const Positioned(
                                left: 0,
                                right: 0,
                                bottom: Space.xxl,
                                child: Center(child: ApplyToast()),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ],
                  )
                : ShellInsets(
                    bottom: bottomBar,
                    child: Stack(
                      children: [
                        Positioned.fill(child: stack),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: bottomBar + Space.m,
                          child: const Center(child: ApplyToast()),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _TabBar(current: _tab, onSelect: _go),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  const _TabItem(this.tab, this.icon, this.iconActive, this.label);
  final AppTab tab;
  final IconData icon;
  final IconData iconActive;
  final String label;
}

List<_TabItem> _items(L10n l) => [
      _TabItem(AppTab.home, Icons.shield_outlined, Icons.shield_rounded, l('tab.home')),
      _TabItem(AppTab.servers, Icons.dns_outlined, Icons.dns_rounded, l('tab.servers')),
      _TabItem(AppTab.routing, Icons.alt_route_rounded, Icons.alt_route_rounded, l('tab.routing')),
      _TabItem(AppTab.game, Icons.sports_esports_outlined, Icons.sports_esports_rounded, l('tab.game')),
      _TabItem(AppTab.settings, Icons.tune_rounded, Icons.tune_rounded, l('tab.settings')),
    ];

/// Flat tab bar: solid background, hairline on top, equal-width items. The
/// selected item is the one drawn in the label colour; nothing else moves.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onSelect});
  final AppTab current;
  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final items = _items(context.l);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Chrome(
      edge: ChromeEdge.top,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: SizedBox(
          height: _ShellState._barHeight,
          child: Row(
            children: [
              for (final it in items)
                Expanded(
                  child: Semantics(
                    selected: it.tab == current,
                    child: PressableScale(
                      scale: 0.9,
                      semanticLabel: it.label,
                      onTap: () => onSelect(it.tab),
                      child: _TabButton(item: it, selected: it.tab == current),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.item, required this.selected});
  final _TabItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = selected ? c.label : c.tertiaryLabel;
    return SizedBox.expand(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: Icon(selected ? item.iconActive : item.icon,
                key: ValueKey(selected), color: color, size: 22),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(item.label,
                  maxLines: 1,
                  softWrap: false,
                  style: context.t.caption.copyWith(
                      color: color,
                      fontSize: 10.5,
                      height: 1.15,
                      letterSpacing: 0.1,
                      fontWeight: FontWeight.w500)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Desktop/tablet sidebar: solid surface, hairline on the trailing edge,
/// wordmark, nav, connection status at the bottom.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.current, required this.onSelect});
  final AppTab current;
  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = context.app;
    final items = _items(context.l);
    final top = MediaQuery.paddingOf(context).top;
    return SizedBox(
      width: 236,
      child: Chrome(
        edge: ChromeEdge.end,
        color: c.isDark ? c.background : c.background,
        child: Padding(
          padding: EdgeInsets.fromLTRB(Space.m, top + Space.xl, Space.m, Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: Space.m),
                child: Wordmark(),
              ),
              const SizedBox(height: Space.x3),
              for (final it in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _SidebarItem(
                      item: it, selected: it.tab == current, onTap: () => onSelect(it.tab)),
                ),
              const Spacer(),
              _SidebarStatus(state: app),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({required this.item, required this.selected, required this.onTap});
  final _TabItem item;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final sel = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PressableScale(
        scale: 0.985,
        onTap: widget.onTap,
        semanticLabel: widget.item.label,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          decoration: ShapeDecoration(
            color: sel
                ? c.fillStrong
                : _hover
                    ? c.fill
                    : Colors.transparent,
            shape: Radii.shape(Radii.s + 1),
          ),
          child: Row(children: [
            Icon(sel ? widget.item.iconActive : widget.item.icon,
                size: 18, color: sel ? c.label : c.secondaryLabel),
            const SizedBox(width: Space.m),
            Text(widget.item.label,
                style: context.t.subhead.copyWith(
                    fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                    color: sel ? c.label : c.secondaryLabel)),
          ]),
        ),
      ),
    );
  }
}

class _SidebarStatus extends StatelessWidget {
  const _SidebarStatus({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    final s = state.displayStatus;
    final color = switch (s) {
      VpnStatus.connected => c.success,
      VpnStatus.connecting || VpnStatus.stopping => c.warning,
      VpnStatus.error => c.danger,
      VpnStatus.stopped => c.tertiaryLabel,
    };
    final node = state.activeNode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Hairline(),
        const SizedBox(height: Space.m),
        Row(children: [
          StatusDot(color, hollow: s == VpnStatus.stopped),
          const SizedBox(width: Space.s + 2),
          Expanded(
            child: Text(l('status.${s.name}'),
                style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
          ),
        ]),
        if (node != null) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: Space.l + 2),
            child: Text(nodeTitle(node),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t.caption),
          ),
        ],
      ]),
    );
  }
}

/// Brand: a plain wordmark. No tile, no gradient.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 19});
  final double size;

  @override
  Widget build(BuildContext context) => Text('Melsi',
      style: context.t.title3.copyWith(
          fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -0.6));
}

/// IndexedStack that keeps pages alive and cross-fades between them, with a
/// tiny upward settle (disabled with reduced motion).
class _FadeIndexedStack extends StatefulWidget {
  const _FadeIndexedStack({required this.index, required this.children});
  final int index;
  final List<Widget> children;
  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 240), value: 1);

  @override
  void didUpdateWidget(_FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, reduce ? 0 : (1 - t) * 6),
            child: child,
          ),
        );
      },
      child: IndexedStack(
        index: widget.index,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            TickerMode(enabled: i == widget.index, child: widget.children[i]),
        ],
      ),
    );
  }
}
