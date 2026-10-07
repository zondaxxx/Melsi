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
import '../features/motion/status_pulse.dart';
import 'screens/settings_screen.dart';
import 'slots/shell_slots.dart';
import 'theme/pressable.dart';
import 'theme/surfaces.dart';
import 'theme/theme.dart';
import 'widgets/apply_toast.dart';
import 'widgets/brand_wordmark.dart';
import 'widgets/common.dart';
import 'widgets/fade_stack.dart';
import 'widgets/page.dart';

export 'widgets/brand_wordmark.dart' show Wordmark;

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

    final stack = FadeIndexedStack(index: _tab.index, children: pages);

    return CallbackShortcuts(
      bindings: {
        ...ShellSlots.shortcuts(context),
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
          child: ShellSlots.overlays(context, Scaffold(
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
                        // Anchored to the tab bar with a clear gap so it
                        // reads as floating chrome, not a row of the page.
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: bottomBar + Space.xl,
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
          )),
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
      _TabItem(AppTab.home, Icons.shield_outlined, Icons.shield_outlined, l('tab.home')),
      _TabItem(AppTab.servers, Icons.dns_outlined, Icons.dns_outlined, l('tab.servers')),
      _TabItem(AppTab.routing, Icons.alt_route, Icons.alt_route, l('tab.routing')),
      _TabItem(AppTab.game, Icons.sports_esports_outlined, Icons.sports_esports_outlined, l('tab.game')),
      _TabItem(AppTab.settings, Icons.tune, Icons.tune, l('tab.settings')),
    ];

/// Flat tab bar: solid background, hairline on top, equal-width items. The
/// selected item is the filled icon + label at 100%; the rest sit at 55%.
/// Nothing else moves.
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
    final color = selected ? c.label : c.label.withValues(alpha: 0.55);
    return SizedBox.expand(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(selected ? item.iconActive : item.icon, color: color, size: 20),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(item.label,
                  maxLines: 1,
                  softWrap: false,
                  style: context.t.caption.copyWith(
                      color: color,
                      fontSize: 10,
                      height: 1.1,
                      letterSpacing: 0.4,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
            ),
          ),
          const SizedBox(height: 3),
          Container(width: selected ? 12 : 0, height: 2, color: c.accent),
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
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final sel = widget.selected;
    final muted = c.label.withValues(alpha: 0.55);
    return PressableScale(
      scale: 0.985,
      onTap: widget.onTap,
      semanticLabel: widget.item.label,
      child: Hoverable(
        builder: (context, hovered, pressed) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          decoration: ShapeDecoration(
            color: sel || pressed
                ? c.fillStrong
                : hovered
                    ? c.fill
                    : Colors.transparent,
            shape: Radii.shape(Radii.s, side: sel
                ? BorderSide(color: c.accent, width: kHairline)
                : BorderSide.none),
          ),
          child: Row(children: [
            Icon(sel ? widget.item.iconActive : widget.item.icon,
                size: 18, color: sel ? c.label : muted),
            const SizedBox(width: Space.m),
            Expanded(child: Text(widget.item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.subhead.copyWith(
                    fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                    color: sel ? c.label : muted))),
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
          StatusPulse(
              color: color, hollow: s == VpnStatus.stopped, active: s == VpnStatus.connected),
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
