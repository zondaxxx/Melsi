import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_state.dart';
import '../../state/commands.dart';
import '../../state/feature_service.dart';
import '../../ui/screens/logs_screen.dart';
import '../../ui/shell.dart' show AppTab;
import '../../ui/widgets/common.dart' show nodeTitle;
import '../../ui/widgets/format.dart';
import 'palette_shell.dart' show findShellNav;

/// Group keys every command is filed under. Other features use the same
/// keys so their commands land in the same sections.
abstract final class PaletteGroups {
  static const servers = 'palette.g.servers';
  static const actions = 'palette.g.actions';
  static const settings = 'palette.g.settings';
  static const tabs = 'palette.g.tabs';
  static const tools = 'palette.g.tools';
  static const recent = 'palette.g.recent';
}

/// Feeds the command registry with the built-in commands: tabs, connect /
/// disconnect, one command per server, the quick toggles, smart modes,
/// routing presets, theme, language and the tools. Other features register
/// their own commands; nothing here knows about them.
///
/// Commands are re-registered only when something they show changes (a
/// state-aware title, a server's latency, the locale), so the registry does
/// not churn on every app-state notification.
class PaletteService extends FeatureService {
  PaletteService(super.app, super.features);

  /// Ids of recently executed commands, newest first (this session only).
  final List<String> recentIds = [];
  static const maxRecents = 8;

  bool _listening = false;
  String? _signature;

  /// Ids this service currently has in the registry, so a command that no
  /// longer applies (reconnect once disconnected, a removed server) is
  /// unregistered rather than left behind.
  final Set<String> _registered = {};

  @override
  Future<void> load() async {
    if (!_listening) {
      _listening = true;
      app.addListener(_sync);
    }
    _sync();
  }

  @override
  void onVpn(VpnStatus prev, VpnStatus next) => _sync();

  @override
  void dispose() {
    if (_listening) app.removeListener(_sync);
    super.dispose();
  }

  /// Remembers that [id] ran, so the empty-query view offers it first.
  void markUsed(String id) {
    recentIds
      ..remove(id)
      ..insert(0, id);
    if (recentIds.length > maxRecents) recentIds.removeLast();
    notifyListeners();
  }

  /// The commands that matter most in the current state, best first — what
  /// the palette shows under the recents when nothing has been typed.
  List<String> suggestedIds() {
    final live = app.connected || app.busy;
    final hasNodes = app.nodes.isNotEmpty;
    return [
      if (!hasNodes) 'tab.servers',
      'vpn.toggle',
      if (live) 'vpn.reconnect',
      'toggle.smart',
      if (hasNodes) 'servers.pingAll',
      'toggle.game',
      'toggle.killSwitch',
      'toggle.antiDpi',
      if (_hasRemoteSubs) 'servers.updateAll',
      'tools.logs',
      'tab.settings',
    ];
  }

  bool get _hasRemoteSubs => app.subscriptions.any((s) => s.url != null);

  // ------------------------------------------------------------ registration

  void _sync() {
    final l = L10n(L10n.resolve(app.settings.locale));
    final sig = _signatureOf(l.locale);
    if (sig == _signature) return;
    _signature = sig;

    final cmds = <AppCommand>[
      ..._tabCommands(),
      ..._vpnCommands(),
      ..._toggleCommands(),
      ..._choiceCommands(l),
      ..._toolCommands(l),
      ..._nodeCommands(l),
    ];
    final ids = {for (final c in cmds) c.id};
    for (final gone in _registered.difference(ids)) {
      features.commands.unregister(gone);
    }
    _registered
      ..clear()
      ..addAll(ids);
    features.commands.registerAll(cmds);
  }

  /// Everything a registered command displays or depends on. Latency is
  /// part of it because it is the server row's subtitle.
  String _signatureOf(String locale) {
    final b = StringBuffer()
      ..write(locale)
      ..write('|')
      ..write(app.displayStatus.name)
      ..write('|')
      ..write(_hasRemoteSubs)
      ..write('|');
    for (final n in app.nodes) {
      b
        ..write(n.id)
        ..write(':')
        ..write(n.name)
        ..write(':')
        ..write(n.countryCode)
        ..write(':')
        ..write(app.latencyOf(n))
        ..write(':')
        ..write(app.isFavourite(n.id) ? 'f' : '-')
        ..write(';');
    }
    return b.toString();
  }

  List<AppCommand> _tabCommands() => [
        for (final (tab, icon) in const [
          (AppTab.home, Icons.shield_outlined),
          (AppTab.servers, Icons.dns_outlined),
          (AppTab.routing, Icons.alt_route_rounded),
          (AppTab.game, Icons.sports_esports_outlined),
          (AppTab.settings, Icons.tune_rounded),
        ])
          AppCommand(
            id: 'tab.${tab.name}',
            titleKey: 'tab.${tab.name}',
            group: PaletteGroups.tabs,
            icon: icon,
            keywords: const ['tab', 'go', 'раздел', 'вкладка'],
            // The shell's navigator sits below the context the shortcut is
            // bound to, so it is located at run time.
            run: (context) async => findShellNav(context)?.go(tab),
          ),
      ];

  List<AppCommand> _vpnCommands() {
    final s = app.displayStatus;
    final live = s == VpnStatus.connected || s == VpnStatus.connecting;
    return [
      AppCommand(
        id: 'vpn.toggle',
        titleKey: live ? 'home.disconnect' : 'home.connect',
        group: PaletteGroups.actions,
        icon: live ? Icons.stop_circle_outlined : Icons.power_settings_new_rounded,
        keywords: const ['vpn', 'connect', 'disconnect', 'подключение', 'отключение'],
        run: (_) => app.toggle(),
      ),
      if (live)
        AppCommand(
          id: 'vpn.reconnect',
          titleKey: 'palette.reconnect',
          group: PaletteGroups.actions,
          icon: Icons.refresh_rounded,
          keywords: const ['vpn', 'restart', 'перезапуск'],
          run: (_) => app.reconnect(),
        ),
    ];
  }

  List<AppCommand> _toggleCommands() => [
        AppCommand(
          id: 'toggle.smart',
          titleKey: 'quick.smart',
          group: PaletteGroups.settings,
          icon: Icons.auto_awesome_outlined,
          keywords: const ['auto', 'smart', 'авто', 'умный'],
          isOn: () => app.settings.autoSelect,
          run: (_) => app.setAutoSelect(!app.settings.autoSelect),
        ),
        AppCommand(
          id: 'toggle.game',
          titleKey: 'quick.game',
          group: PaletteGroups.settings,
          icon: Icons.sports_esports_outlined,
          keywords: const ['game', 'gaming', 'игры'],
          isOn: () => app.game.enabled,
          run: (_) async => app.updateGame((g) => g.enabled = !g.enabled),
        ),
        AppCommand(
          id: 'toggle.killSwitch',
          titleKey: 'quick.killSwitch',
          group: PaletteGroups.settings,
          icon: Icons.security_rounded,
          keywords: const ['strict', 'route', 'leak', 'защита'],
          isOn: () => app.settings.killSwitch,
          run: (_) async => app.updateSettings((s) => s.killSwitch = !s.killSwitch),
        ),
        AppCommand(
          id: 'toggle.antiDpi',
          titleKey: 'quick.antiDpi',
          group: PaletteGroups.settings,
          icon: Icons.blur_on_rounded,
          keywords: const ['dpi', 'fragment', 'tls', 'фрагментация'],
          isOn: () => app.settings.antiDpi,
          run: (_) async => app.updateSettings((s) => s.antiDpi = !s.antiDpi),
        ),
      ];

  /// Radio-style choices: the row title is the option, the subtitle names
  /// the setting it belongs to, and `isOn` marks the current pick.
  List<AppCommand> _choiceCommands(L10n l) => [
        for (final m in SmartMode.values)
          AppCommand(
            id: 'smart.${m.name}',
            titleKey: 'smart.${m.name}',
            group: PaletteGroups.settings,
            icon: Icons.auto_awesome_outlined,
            subtitle: l('settings.smartMode'),
            keywords: ['smart', 'mode', m.name, 'режим'],
            isOn: () => app.settings.smartMode == m,
            run: (_) => app.setSmartMode(m),
          ),
        for (final p in RoutingPreset.values)
          AppCommand(
            id: 'preset.${p.name}',
            titleKey: 'preset.${p.name}',
            group: PaletteGroups.settings,
            icon: Icons.alt_route_rounded,
            subtitle: l('home.routing'),
            keywords: ['routing', 'preset', p.name, 'маршрут'],
            isOn: () => app.routing.preset == p,
            run: (_) async => app.updateRouting((r) => r.preset = p),
          ),
        for (final (mode, icon) in const [
          ('light', Icons.light_mode_outlined),
          ('dark', Icons.dark_mode_outlined),
          ('system', Icons.brightness_auto_outlined),
        ])
          AppCommand(
            id: 'theme.$mode',
            titleKey: 'theme.$mode',
            group: PaletteGroups.settings,
            icon: icon,
            subtitle: l('settings.theme'),
            keywords: ['theme', mode, 'тема', 'оформление'],
            isOn: () => app.settings.themeMode == mode,
            run: (_) async =>
                app.updateSettings((s) => s.themeMode = mode, affectsConfig: false),
          ),
        for (final (code, titleKey) in const [
          ('ru', 'palette.lang.ru'),
          ('en', 'palette.lang.en'),
          (null, 'theme.system'),
        ])
          AppCommand(
            id: 'lang.${code ?? 'system'}',
            titleKey: titleKey,
            group: PaletteGroups.settings,
            icon: Icons.translate_rounded,
            subtitle: l('settings.language'),
            keywords: ['language', 'locale', code ?? 'system', 'язык'],
            isOn: () => app.settings.locale == code,
            run: (_) async =>
                app.updateSettings((s) => s.locale = code, affectsConfig: false),
          ),
      ];

  List<AppCommand> _toolCommands(L10n l) => [
        if (app.nodes.isNotEmpty)
          AppCommand(
            id: 'servers.pingAll',
            titleKey: app.connected ? 'servers.pingAllUrl' : 'servers.pingAllTcp',
            group: PaletteGroups.tools,
            icon: Icons.speed_rounded,
            keywords: const ['ping', 'latency', 'test', 'пинг', 'задержка'],
            run: (_) => app.pingAll(),
          ),
        if (_hasRemoteSubs)
          AppCommand(
            id: 'servers.updateAll',
            titleKey: 'servers.updateAll',
            group: PaletteGroups.tools,
            icon: Icons.sync_rounded,
            keywords: const ['subscription', 'refresh', 'подписки'],
            run: (_) => app.updateAllSubscriptions(),
          ),
        AppCommand(
          id: 'tools.export',
          titleKey: 'settings.export',
          group: PaletteGroups.tools,
          icon: Icons.file_download_outlined,
          subtitle: l('settings.exportHint'),
          keywords: const ['export', 'config', 'json', 'sing-box', 'экспорт'],
          run: (_) => _export(app),
        ),
        AppCommand(
          id: 'tools.logs',
          titleKey: 'settings.logs',
          group: PaletteGroups.tools,
          icon: Icons.receipt_long_outlined,
          keywords: const ['log', 'logs', 'debug', 'логи'],
          run: (context) => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => LogsScreen(state: app))),
        ),
      ];

  List<AppCommand> _nodeCommands(L10n l) => [
        for (final n in app.nodes)
          AppCommand(
            id: 'node.${n.id}',
            titleKey: nodeTitle(n),
            group: PaletteGroups.servers,
            icon: app.isFavourite(n.id) ? Icons.star_rounded : Icons.dns_outlined,
            subtitle: '${n.protocol.label} · ${formatMs(app.latencyOf(n), l)}',
            keywords: [
              if (n.countryCode != null) n.countryCode!,
              n.server,
              n.protocol.label,
              if (app.isFavourite(n.id)) 'fav',
              ?app.subscriptionById(n.subscriptionId)?.name,
            ],
            run: (_) => app.selectNode(n.id),
          ),
      ];

  /// Same flow as Settings › Export: share sheet on phones, a save dialog
  /// on desktop, the clipboard if the dialog is unavailable.
  static Future<void> _export(AppState app) async {
    String json;
    try {
      json = await app.exportConfig();
    } catch (e) {
      app.notice('notice.exportFailed', kind: NoticeKind.error, detail: '$e');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(json));
    if (Platform.isAndroid || Platform.isIOS) {
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, name: 'melsi-config.json', mimeType: 'application/json')],
        fileNameOverrides: const ['melsi-config.json'],
      ));
      return;
    }
    try {
      final loc = await getSaveLocation(
          suggestedName: 'melsi-config.json',
          acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])]);
      if (loc == null) return;
      await File(loc.path).writeAsBytes(bytes);
      app.notice('notice.exported', kind: NoticeKind.success, detail: loc.path);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: json));
      app.notice('notice.exportCopied', kind: NoticeKind.success);
    }
  }
}
