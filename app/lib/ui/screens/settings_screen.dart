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
import '../theme/glass.dart';
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
    final s = app.settings;

    Future<void> editText(String title, String initial, void Function(String v) apply,
        {bool number = false}) async {
      final v = await promptText(context, title: title, initial: initial, number: number);
      if (v != null && v.trim().isNotEmpty) apply(v.trim());
    }

    Widget value(String v) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.t.callout.copyWith(color: c.secondaryLabel)),
        );

    return PageScaffold(
      title: l('tab.settings'),
      maxContentWidth: 720,
      slivers: [
        // ------------------------------------------------ smart
        SliverToBoxAdapter(child: SectionHeader(l('settings.smart'), padding: const EdgeInsets.fromLTRB(4, 4, 4, 8))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            SwitchRow(
              leading: IconTile(Icons.auto_awesome_rounded, color: c.accent),
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
              leading: IconTile(Icons.travel_explore_rounded, color: c.info),
              title: l('settings.probeUrl'),
              trailing: value(Uri.tryParse(s.probeUrl)?.host ?? s.probeUrl),
              chevron: true,
              onTap: () => editText(l('settings.probeUrl'), s.probeUrl,
                  (v) => app.updateSettings((x) => x.probeUrl = v)),
            ),
            RowTile(
              leading: IconTile(Icons.timer_rounded, color: c.warning),
              title: l('settings.probeInterval'),
              trailing: value(l('unit.sec', {'n': '${s.probeIntervalSec}'})),
              chevron: true,
              onTap: () => editText(l('settings.probeInterval'), '${s.probeIntervalSec}', (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 10) app.updateSettings((x) => x.probeIntervalSec = n);
              }, number: true),
            ),
            if (app.displayStatus == VpnStatus.connected && s.autoSelect)
              RowTile(
                leading: IconTile(Icons.refresh_rounded, color: c.success),
                title: l('settings.probeNow'),
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
              leading: IconTile(Icons.dns_rounded, color: c.accent),
              title: l('settings.remoteDns'),
              trailing: value(_short(s.remoteDns)),
              chevron: true,
              onTap: () => editText(l('settings.remoteDns'), s.remoteDns,
                  (v) => app.updateSettings((x) => x.remoteDns = v)),
            ),
            RowTile(
              leading: IconTile(Icons.dns_outlined, color: c.success),
              title: l('settings.directDns'),
              trailing: value(_short(s.directDns)),
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
            child: Card2(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(l('settings.captureMode'), style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: Space.s),
                Segmented<CaptureMode>(
                  value: s.captureMode,
                  onChanged: (m) => app.updateSettings((x) => x.captureMode = m),
                  segments: [
                    Segment(CaptureMode.tun, 'TUN', icon: Icons.lan_rounded),
                    Segment(CaptureMode.systemProxy, l('settings.systemProxy'), icon: Icons.settings_ethernet_rounded),
                  ],
                ),
                const SizedBox(height: Space.s),
                Text(l('capture.${s.captureMode.name}.desc'), style: context.t.footnote),
              ]),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        ],
        SliverToBoxAdapter(
          child: Card2(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(l('settings.tunStack'), style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: Space.s),
              Segmented<TunStack>(
                value: s.tunStack,
                onChanged: (v) => app.updateSettings((x) => x.tunStack = v),
                segments: const [
                  Segment(TunStack.system, 'System'),
                  Segment(TunStack.gvisor, 'gVisor'),
                  Segment(TunStack.mixed, 'Mixed'),
                ],
              ),
              const SizedBox(height: Space.s),
              Text(l('stack.${s.tunStack.name}.desc'), style: context.t.footnote),
            ]),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: Space.m)),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            RowTile(
              leading: IconTile(Icons.straighten_rounded, color: c.info),
              title: 'MTU',
              trailing: value('${s.mtu}'),
              chevron: true,
              onTap: () => editText('MTU', '${s.mtu}', (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 1280 && n <= 65535) app.updateSettings((x) => x.mtu = n);
              }, number: true),
            ),
            SwitchRow(
              leading: IconTile(Icons.six_ft_apart_rounded, color: c.accent2),
              title: 'IPv6',
              value: s.ipv6,
              onChanged: (v) => app.updateSettings((x) => x.ipv6 = v),
            ),
            SwitchRow(
              leading: IconTile(Icons.lock_rounded, color: const Color(0xFF14A8C9)),
              title: l('quick.killSwitch'),
              subtitle: l('settings.killSwitchHint'),
              value: s.killSwitch,
              onChanged: (v) => app.updateSettings((x) => x.killSwitch = v),
            ),
            SwitchRow(
              leading: IconTile(Icons.content_cut_rounded, color: const Color(0xFFD9468A)),
              title: l('quick.antiDpi'),
              subtitle: l('settings.antiDpiHint'),
              value: s.antiDpi,
              onChanged: (v) => app.updateSettings((x) => x.antiDpi = v),
            ),
            SwitchRow(
              leading: IconTile(Icons.wifi_tethering_rounded, color: c.success),
              title: l('settings.allowLan'),
              subtitle: l('settings.allowLanHint'),
              value: s.allowLan,
              onChanged: (v) => app.updateSettings((x) => x.allowLan = v),
            ),
            RowTile(
              leading: IconTile(Icons.input_rounded, color: c.warning),
              title: l('settings.mixedPort'),
              trailing: value('${s.mixedPort}'),
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
          child: Card2(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(l('settings.theme'), style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: Space.s),
              Segmented<String>(
                value: s.themeMode,
                onChanged: (v) => app.updateSettings((x) => x.themeMode = v, affectsConfig: false),
                segments: [
                  Segment('system', l('theme.system'), icon: Icons.brightness_auto_rounded),
                  Segment('light', l('theme.light'), icon: Icons.light_mode_rounded),
                  Segment('dark', l('theme.dark'), icon: Icons.dark_mode_rounded),
                ],
              ),
              const SizedBox(height: Space.l),
              Text(l('settings.language'), style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: Space.s),
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
              leading: IconTile(Icons.play_circle_rounded, color: c.success),
              title: l('settings.connectOnLaunch'),
              value: s.connectOnLaunch,
              onChanged: (v) => app.updateSettings((x) => x.connectOnLaunch = v, affectsConfig: false),
            ),
            RowTile(
              leading: const IconTile(Icons.bug_report_rounded, color: Color(0xFF8E8E93)),
              title: l('settings.logLevel'),
              trailing: PopupMenuButton<LogLevel>(
                initialValue: s.logLevel,
                position: PopupMenuPosition.under,
                onSelected: (v) => app.updateSettings((x) => x.logLevel = v),
                itemBuilder: (_) => [
                  for (final v in LogLevel.values) PopupMenuItem(value: v, child: Text(v.name)),
                ],
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  value(s.logLevel.name),
                  Icon(Icons.unfold_more_rounded, size: 18, color: c.tertiaryLabel),
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
              leading: IconTile(Icons.receipt_long_rounded, color: c.info),
              title: l('settings.logs'),
              chevron: true,
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => LogsScreen(state: app))),
            ),
            RowTile(
              leading: IconTile(Icons.ios_share_rounded, color: c.accent),
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
              leading: IconTile(Icons.shield_rounded, color: c.accent),
              title: 'Melsi',
              trailing: value(appVersion),
            ),
            RowTile(
              leading: IconTile(Icons.memory_rounded, color: c.accent2),
              title: l('settings.core'),
              trailing: value(app.coreVersion ?? (app.isDesktopPlatform ? l('settings.coreMissing') : 'sing-box 1.14')),
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

/// One option of the smart-selection mode: a radio row with the same tile
/// style as every other row. Only the selected option shows its
/// description, so the list stays short.
class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.mode, required this.selected, required this.onTap});
  final SmartMode mode;
  final bool selected;
  final VoidCallback onTap;

  static (IconData, Color) look(SmartMode m) => switch (m) {
        SmartMode.latency => (Icons.flash_on_rounded, const Color(0xFFFF9F0A)),
        SmartMode.balanced => (Icons.balance_rounded, const Color(0xFF5B50F0)),
        SmartMode.stability => (Icons.shield_rounded, const Color(0xFF14A8C9)),
        SmartMode.game => (Icons.sports_esports_rounded, const Color(0xFFE8457C)),
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final (icon, color) = look(mode);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: RowTile(
        leading: IconTile(icon, color: color),
        title: l('smart.${mode.name}'),
        subtitleWidget: AnimatedSize(
          duration: Duration(milliseconds: context.reduceMotion ? 1 : 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: selected
              ? Text(l('smart.${mode.name}.desc'), style: context.t.footnote)
              : const SizedBox(width: double.infinity),
        ),
        trailing: SizedBox(
          width: 24,
          child: SpringValue(
            target: selected ? 1 : 0,
            spring: Springs.momentum,
            builder: (context, v, child) => Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
            child: Icon(Icons.check_rounded, color: c.accent),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}
