import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/page.dart';
import '../widgets/segmented.dart';
import 'logs_screen.dart';
import 'servers_screen.dart' show promptText;

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const appVersion = '1.0.0';

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final s = app.settings;

    Future<void> editText(String title, String initial, void Function(String v) apply,
        {bool number = false}) async {
      final v = await promptText(context, title: title, initial: initial, number: number);
      if (v != null && v.trim().isNotEmpty) apply(v.trim());
    }

    /// Row value: text in secondary; numbers and hosts in mono.
    Widget value(String v, {bool mono = false}) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 170),
          child: Text(v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono
                  ? t.mono.copyWith(color: c.secondaryLabel)
                  : t.callout.copyWith(color: c.secondaryLabel)),
        );

    /// A labelled segmented control inside a panel.
    Widget choice(String label, Widget control, String? desc) => Panel(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.l, Space.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Overline(label),
            const SizedBox(height: Space.s + 2),
            control,
            if (desc != null) ...[
              const SizedBox(height: Space.s + 2),
              Text(desc, style: t.footnote),
            ],
          ]),
        );

    return PageScaffold(
      title: l('tab.settings'),
      maxContentWidth: 720,
      slivers: [
        // ------------------------------------------------ smart
        SliverToBoxAdapter(
            child: SectionHeader(l('settings.smart'),
                padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, Space.s + 2))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            SwitchRow(
              title: l('quick.smart'),
              subtitle: l('settings.smartHint'),
              value: s.autoSelect,
              onChanged: app.setAutoSelect,
            ),
            for (final m in SmartMode.values)
              _ModeRow(
                mode: m,
                selected: s.smartMode == m,
                onTap: () {
                  HapticFeedback.selectionClick();
                  app.setSmartMode(m);
                },
              ),
          ]),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            RowTile(
              title: l('settings.probeUrl'),
              trailing: value(Uri.tryParse(s.probeUrl)?.host ?? s.probeUrl, mono: true),
              chevron: true,
              onTap: () => editText(l('settings.probeUrl'), s.probeUrl,
                  (v) => app.updateSettings((x) => x.probeUrl = v)),
            ),
            RowTile(
              title: l('settings.probeInterval'),
              trailing: value(l('unit.sec', {'n': '${s.probeIntervalSec}'}), mono: true),
              chevron: true,
              onTap: () => editText(l('settings.probeInterval'), '${s.probeIntervalSec}', (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 10) app.updateSettings((x) => x.probeIntervalSec = n);
              }, number: true),
            ),
            if (app.displayStatus == VpnStatus.connected && s.autoSelect)
              RowTile(
                title: l('settings.probeNow'),
                trailing: Icon(Icons.refresh_rounded, size: 18, color: c.accent),
                onTap: () {
                  HapticFeedback.lightImpact();
                  app.probeNow();
                },
              ),
          ]),
        ),
        // ------------------------------------------------ DNS
        SliverToBoxAdapter(child: SectionHeader(l('settings.dns'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            RowTile(
              title: l('settings.remoteDns'),
              trailing: value(_short(s.remoteDns), mono: true),
              chevron: true,
              onTap: () => editText(l('settings.remoteDns'), s.remoteDns,
                  (v) => app.updateSettings((x) => x.remoteDns = v)),
            ),
            RowTile(
              title: l('settings.directDns'),
              trailing: value(_short(s.directDns), mono: true),
              chevron: true,
              onTap: () => editText(l('settings.directDns'), s.directDns,
                  (v) => app.updateSettings((x) => x.directDns = v)),
            ),
          ]),
        ),
        SliverToBoxAdapter(child: SectionFooter(l('settings.dnsHint'))),
        // ------------------------------------------------ network
        SliverToBoxAdapter(child: SectionHeader(l('settings.network'))),
        if (app.isDesktopPlatform) ...[
          SliverToBoxAdapter(
            child: choice(
              l('settings.captureMode'),
              Segmented<CaptureMode>(
                value: s.captureMode,
                onChanged: (m) => app.updateSettings((x) => x.captureMode = m),
                segments: [
                  Segment(CaptureMode.tun, 'TUN'),
                  Segment(CaptureMode.systemProxy, l('settings.systemProxy')),
                ],
              ),
              l('capture.${s.captureMode.name}.desc'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        ],
        SliverToBoxAdapter(
          child: choice(
            l('settings.tunStack'),
            Segmented<TunStack>(
              value: s.tunStack,
              onChanged: (v) => app.updateSettings((x) => x.tunStack = v),
              segments: const [
                Segment(TunStack.system, 'System'),
                Segment(TunStack.gvisor, 'gVisor'),
                Segment(TunStack.mixed, 'Mixed'),
              ],
            ),
            l('stack.${s.tunStack.name}.desc'),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            RowTile(
              title: 'MTU',
              trailing: value('${s.mtu}', mono: true),
              chevron: true,
              onTap: () => editText('MTU', '${s.mtu}', (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 1280 && n <= 65535) app.updateSettings((x) => x.mtu = n);
              }, number: true),
            ),
            SwitchRow(
              title: 'IPv6',
              value: s.ipv6,
              onChanged: (v) => app.updateSettings((x) => x.ipv6 = v),
            ),
            SwitchRow(
              title: l('quick.killSwitch'),
              subtitle: l('settings.killSwitchHint'),
              value: s.killSwitch,
              onChanged: (v) => app.updateSettings((x) => x.killSwitch = v),
            ),
            SwitchRow(
              title: l('quick.antiDpi'),
              subtitle: l('settings.antiDpiHint'),
              value: s.antiDpi,
              onChanged: (v) => app.updateSettings((x) => x.antiDpi = v),
            ),
            SwitchRow(
              title: l('settings.allowLan'),
              subtitle: l('settings.allowLanHint'),
              value: s.allowLan,
              onChanged: (v) => app.updateSettings((x) => x.allowLan = v),
            ),
            RowTile(
              title: l('settings.mixedPort'),
              trailing: value('${s.mixedPort}', mono: true),
              chevron: true,
              onTap: () => editText(l('settings.mixedPort'), '${s.mixedPort}', (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0 && n < 65536) app.updateSettings((x) => x.mixedPort = n);
              }, number: true),
            ),
          ]),
        ),
        // ------------------------------------------------ app
        SliverToBoxAdapter(child: SectionHeader(l('settings.app'))),
        SliverToBoxAdapter(
          child: Panel(
            padding: const EdgeInsets.fromLTRB(Space.l, Space.m + 2, Space.l, Space.l),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Overline(l('settings.theme')),
              const SizedBox(height: Space.s + 2),
              Segmented<String>(
                value: s.themeMode,
                onChanged: (v) => app.updateSettings((x) => x.themeMode = v, affectsConfig: false),
                segments: [
                  Segment('system', l('theme.system')),
                  Segment('light', l('theme.light')),
                  Segment('dark', l('theme.dark')),
                ],
              ),
              const SizedBox(height: Space.l),
              Overline(l('settings.language')),
              const SizedBox(height: Space.s + 2),
              Segmented<String>(
                value: s.locale ?? 'system',
                onChanged: (v) => app.updateSettings((x) => x.locale = v == 'system' ? null : v,
                    affectsConfig: false),
                segments: [
                  Segment('system', l('theme.system')),
                  const Segment('ru', 'Русский'),
                  const Segment('en', 'English'),
                ],
              ),
            ]),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            SwitchRow(
              title: l('settings.connectOnLaunch'),
              value: s.connectOnLaunch,
              onChanged: (v) => app.updateSettings((x) => x.connectOnLaunch = v, affectsConfig: false),
            ),
            RowTile(
              title: l('settings.logLevel'),
              trailing: PopupMenuButton<LogLevel>(
                initialValue: s.logLevel,
                position: PopupMenuPosition.under,
                onSelected: (v) => app.updateSettings((x) => x.logLevel = v),
                itemBuilder: (_) => [
                  for (final v in LogLevel.values) PopupMenuItem(value: v, child: Text(v.name)),
                ],
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  value(s.logLevel.name, mono: true),
                  const SizedBox(width: 2),
                  Icon(Icons.unfold_more_rounded, size: 16, color: c.tertiaryLabel),
                ]),
              ),
            ),
          ]),
        ),
        // ------------------------------------------------ tools
        SliverToBoxAdapter(child: SectionHeader(l('settings.tools'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            RowTile(
              title: l('settings.logs'),
              chevron: true,
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => LogsScreen(state: app))),
            ),
            RowTile(
              title: l('settings.export'),
              subtitle: l('settings.exportHint'),
              chevron: true,
              onTap: () => _export(context, app),
            ),
          ]),
        ),
        // ------------------------------------------------ about
        SliverToBoxAdapter(child: SectionHeader(l('settings.about'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            RowTile(
              title: 'Melsi',
              trailing: value(appVersion, mono: true),
            ),
            RowTile(
              title: l('settings.core'),
              trailing: value(
                  app.coreVersion ?? (app.isDesktopPlatform ? l('settings.coreMissing') : 'sing-box 1.14'),
                  mono: true),
            ),
          ]),
        ),
        SliverToBoxAdapter(child: SectionFooter(l('settings.aboutText'))),
      ],
    );
  }

  /// "https://1.1.1.1/dns-query" → "1.1.1.1" for the row's value.
  static String _short(String v) {
    final u = Uri.tryParse(v);
    return u != null && u.host.isNotEmpty ? u.host : v;
  }

  Future<void> _export(BuildContext context, AppState app) async {
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
      final loc = await getSaveLocation(suggestedName: 'melsi-config.json', acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ]);
      if (loc == null) return;
      await File(loc.path).writeAsBytes(bytes);
      app.notice('notice.exported', kind: NoticeKind.success, detail: loc.path);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: json));
      app.notice('notice.exportCopied', kind: NoticeKind.success);
    }
  }
}

/// One option of the smart-selection mode: a radio row. Only the selected
/// option shows its description, so the list stays short.
class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.mode, required this.selected, required this.onTap});
  final SmartMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: RowTile(
        dense: true,
        leading: const SizedBox(width: Space.s),
        title: l('smart.${mode.name}'),
        subtitleWidget: AnimatedSize(
          duration: Duration(milliseconds: context.reduceMotion ? 1 : 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: selected
              ? Text(l('smart.${mode.name}.desc'), style: context.t.footnote)
              : const SizedBox(width: double.infinity),
        ),
        trailing: SizedBox(
          width: 22,
          child: SpringValue(
            target: selected ? 1 : 0,
            spring: Springs.momentum,
            builder: (context, v, child) => Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
            child: Icon(Icons.check_rounded, size: 18, color: c.accent),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
