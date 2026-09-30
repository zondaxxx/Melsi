import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../theme/glass.dart';
import '../theme/pressable.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/page.dart';
import '../widgets/segmented.dart';
import 'app_picker.dart';

class RoutingScreen extends StatelessWidget {
  const RoutingScreen({super.key});

  static IconData presetIcon(RoutingPreset p) => switch (p) {
        RoutingPreset.global => Icons.public_rounded,
        RoutingPreset.smartRu => Icons.auto_awesome_rounded,
        RoutingPreset.blockedOnly => Icons.lock_open_rounded,
        RoutingPreset.direct => Icons.near_me_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final r = app.routing;
    return PageScaffold(
      title: l('tab.routing'),
      slivers: [
        SliverToBoxAdapter(child: SectionHeader(l('routing.preset'), padding: const EdgeInsets.fromLTRB(4, 4, 4, 8))),
        SliverToBoxAdapter(
          child: LayoutBuilder(builder: (context, box) {
            final cols = box.maxWidth >= 620 ? 2 : 1;
            final w = (box.maxWidth - Space.m * (cols - 1)) / cols;
            return Wrap(spacing: Space.m, runSpacing: Space.s, children: [
              for (final p in RoutingPreset.values)
                SizedBox(
                  width: w,
                  child: _PresetCard(
                    preset: p,
                    selected: r.preset == p,
                    onTap: () => app.updateRouting((x) => x.preset = p),
                  ),
                ),
            ]);
          }),
        ),
        SliverToBoxAdapter(child: SectionHeader(l('routing.apps'))),
        SliverToBoxAdapter(child: _PerApp(app: app)),
        SliverToBoxAdapter(child: SectionHeader(l('routing.filters'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            SwitchRow(
              leading: IconTile(Icons.block_rounded, color: c.danger),
              title: l('routing.blockAds'),
              subtitle: l('routing.blockAdsHint'),
              value: r.blockAds,
              onChanged: (v) => app.updateRouting((x) => x.blockAds = v),
            ),
            SwitchRow(
              leading: IconTile(Icons.router_rounded, color: c.info),
              title: l('routing.bypassLan'),
              subtitle: l('routing.bypassLanHint'),
              value: r.bypassLan,
              onChanged: (v) => app.updateRouting((x) => x.bypassLan = v),
            ),
          ]),
        ),
        SliverToBoxAdapter(child: SectionHeader(l('routing.domains'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            _DomainRow(
              icon: Icons.near_me_rounded,
              color: c.success,
              title: l('routing.domainsDirect'),
              list: r.directDomains,
              onSave: (v) => app.updateRouting((x) => x.directDomains = v),
            ),
            _DomainRow(
              icon: Icons.vpn_lock_rounded,
              color: c.accent,
              title: l('routing.domainsProxy'),
              list: r.proxyDomains,
              onSave: (v) => app.updateRouting((x) => x.proxyDomains = v),
            ),
            _DomainRow(
              icon: Icons.block_rounded,
              color: c.danger,
              title: l('routing.domainsBlock'),
              list: r.blockDomains,
              onSave: (v) => app.updateRouting((x) => x.blockDomains = v),
            ),
          ]),
        ),
        SliverToBoxAdapter(child: SectionFooter(l('routing.domainsHint'))),
      ],
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset, required this.selected, required this.onTap});
  final RoutingPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    return PressableScale(
      haptic: true,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(Space.m + 2, Space.m, Space.m + 2, Space.m + 2),
        decoration: ShapeDecoration(
          color: selected
              ? Color.alphaBlend(c.accent.withValues(alpha: c.isDark ? 0.18 : 0.08), c.surface)
              : c.surface,
          shape: Radii.shape(Radii.l,
              side: BorderSide(
                  color: selected ? c.accent.withValues(alpha: c.isDark ? 0.9 : 0.75) : Colors.transparent,
                  width: 1.5)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 36,
            height: 36,
            decoration: ShapeDecoration(
              shape: Radii.shape(12),
              gradient: selected ? c.accentGradient : null,
              color: selected ? null : c.fill,
            ),
            child: Icon(RoutingScreen.presetIcon(preset),
                color: selected ? Colors.white : c.secondaryLabel, size: 19),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(l('preset.${preset.name}'),
                    style: context.t.headline.copyWith(color: selected ? c.accent : c.label)),
              ),
              const SizedBox(height: 2),
              Text(l('preset.${preset.name}.desc'), style: context.t.footnote),
            ]),
          ),
          const SizedBox(width: Space.s),
          SpringValue(
            target: selected ? 1 : 0,
            spring: Springs.momentum,
            builder: (context, v, child) => Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
            child: Icon(Icons.check_circle_rounded, color: c.accent, size: 22),
          ),
        ]),
      ),
    );
  }
}

class _PerApp extends StatelessWidget {
  const _PerApp({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    if (app.isIOS) {
      return Card2(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_rounded, color: c.info),
          const SizedBox(width: Space.m),
          Expanded(child: Text(l('routing.iosNoPerApp'), style: context.t.callout)),
        ]),
      );
    }
    final r = app.routing;
    return Card2(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Segmented<AppRoutingMode>(
          value: r.appMode,
          onChanged: (m) => app.updateRouting((x) => x.appMode = m),
          segments: [
            Segment(AppRoutingMode.off, l('appMode.off')),
            Segment(AppRoutingMode.onlySelected, l('appMode.onlySelected')),
            Segment(AppRoutingMode.bypassSelected, l('appMode.bypassSelected')),
          ],
        ),
        const SizedBox(height: Space.m),
        Text(l('appMode.${r.appMode.name}.desc'), style: context.t.footnote),
        if (r.appMode != AppRoutingMode.off) ...[
          const SizedBox(height: Space.m),
          if (r.appRules.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final a in r.appRules)
                InputChip(
                  label: Text(a.label ?? a.id),
                  onDeleted: () => app.updateRouting(
                      (x) => x.appRules = x.appRules.where((e) => e.id != a.id).toList()),
                  deleteIconColor: c.secondaryLabel,
                  backgroundColor: c.fill,
                  side: BorderSide.none,
                  shape: Radii.shape(Radii.pill),
                  labelStyle: context.t.subhead,
                ),
            ]),
          const SizedBox(height: Space.m),
          SecondaryButton(
            icon: Icons.apps_rounded,
            label: r.appRules.isEmpty
                ? l('routing.pickApps')
                : l('routing.pickAppsN', {'n': '${r.appRules.length}'}),
            onTap: () async {
              final v = await pickApps(context, selected: r.appRules, title: l('routing.apps'));
              if (v != null) app.updateRouting((x) => x.appRules = v);
            },
          ),
        ],
      ]),
    );
  }
}

class _DomainRow extends StatelessWidget {
  const _DomainRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.list,
    required this.onSave,
  });
  final IconData icon;
  final Color color;
  final String title;
  final List<String> list;
  final ValueChanged<List<String>> onSave;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return RowTile(
      leading: IconTile(icon, color: color),
      title: title,
      trailing: Text(list.isEmpty ? l('common.none') : '${list.length}', style: context.t.callout.copyWith(color: context.c.secondaryLabel)),
      chevron: true,
      onTap: () async {
        final v = await showMelsiSheet<List<String>>(context,
            builder: (_) => _DomainEditor(title: title, initial: list));
        if (v != null) onSave(v);
      },
    );
  }
}

class _DomainEditor extends StatefulWidget {
  const _DomainEditor({required this.title, required this.initial});
  final String title;
  final List<String> initial;
  @override
  State<_DomainEditor> createState() => _DomainEditorState();
}

class _DomainEditorState extends State<_DomainEditor> {
  late final _ctrl = TextEditingController(text: widget.initial.join('\n'));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<String> _parse() => _ctrl.text
      .split(RegExp(r'[\s,;]+'))
      .map((e) => e.trim().toLowerCase().replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'^\*?\.'), '').split('/').first)
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList();

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SheetHeader(title: widget.title),
          TextField(
            controller: _ctrl,
            minLines: 8,
            maxLines: 14,
            autofocus: true,
            style: context.t.callout.copyWith(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(hintText: 'example.com\nyoutube.com'),
          ),
          const SizedBox(height: Space.s),
          Text(l('routing.domainsHint'), style: context.t.caption),
          const SizedBox(height: Space.l),
          PrimaryButton(
            label: l('common.save'),
            expand: true,
            onTap: () => Navigator.of(context).pop(_parse()),
          ),
        ]),
      ),
    );
  }
}
