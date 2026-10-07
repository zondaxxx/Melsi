import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/page.dart';
import '../widgets/segmented.dart';
import 'app_picker.dart';

class RoutingScreen extends StatelessWidget {
  const RoutingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final c = context.c;
    final r = app.routing;
    return PageScaffold(
      title: l('tab.routing'),
      slivers: [
        SliverToBoxAdapter(
            child: SectionHeader(l('routing.preset'),
                padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, Space.s + 2))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            for (final p in RoutingPreset.values)
              _PresetRow(
                preset: p,
                selected: r.preset == p,
                onTap: () => app.updateRouting((x) => x.preset = p),
              ),
          ]),
        ),
        SliverToBoxAdapter(child: SectionHeader(l('routing.apps'))),
        SliverToBoxAdapter(child: _PerApp(app: app)),
        SliverToBoxAdapter(child: SectionHeader(l('routing.filters'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            SwitchRow(
              title: l('routing.blockAds'),
              subtitle: l('routing.blockAdsHint'),
              value: r.blockAds,
              onChanged: (v) => app.updateRouting((x) => x.blockAds = v),
            ),
            SwitchRow(
              title: l('routing.bypassLan'),
              subtitle: l('routing.bypassLanHint'),
              value: r.bypassLan,
              onChanged: (v) => app.updateRouting((x) => x.bypassLan = v),
            ),
            SwitchRow(
              title: l('routing.blockQuic'),
              subtitle: l('routing.blockQuicHint'),
              value: r.blockQuic,
              onChanged: (v) => app.updateRouting((x) => x.blockQuic = v),
            ),
          ]),
        ),
        SliverToBoxAdapter(child: SectionHeader(l('routing.domains'))),
        SliverToBoxAdapter(
          child: GroupCard(children: [
            _DomainRow(
              title: l('routing.domainsDirect'),
              list: r.directDomains,
              onSave: (v) => app.updateRouting((x) => x.directDomains = v),
            ),
            _DomainRow(
              title: l('routing.domainsProxy'),
              list: r.proxyDomains,
              onSave: (v) => app.updateRouting((x) => x.proxyDomains = v),
            ),
            _DomainRow(
              title: l('routing.domainsBlock'),
              list: r.blockDomains,
              onSave: (v) => app.updateRouting((x) => x.blockDomains = v),
              color: c.danger,
            ),
          ]),
        ),
        SliverToBoxAdapter(child: SectionFooter(l('routing.domainsHint'))),
      ],
    );
  }
}

/// Routing mode as a radio row: name, one-line description, check.
class _PresetRow extends StatelessWidget {
  const _PresetRow({required this.preset, required this.selected, required this.onTap});
  final RoutingPreset preset;
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
        title: l('preset.${preset.name}'),
        subtitle: l('preset.${preset.name}.desc'),
        trailing: SizedBox(
          width: 22,
          child: SpringValue(
            target: selected ? 1 : 0,
            spring: Springs.momentum,
            builder: (context, v, child) => Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
            child: Icon(Icons.check_rounded, color: c.accent, size: 18),
          ),
        ),
        onTap: onTap,
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
      return Panel(
        child: Text(l('routing.iosNoPerApp'), style: context.t.footnote),
      );
    }
    final r = app.routing;
    // Segmented control + helper sit bare on the page, exactly as the
    // routing preset does on Home: a control is never nested in a card.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Segmented<AppRoutingMode>(
        value: r.appMode,
        onChanged: (m) => app.updateRouting((x) => x.appMode = m),
        segments: [
          Segment(AppRoutingMode.off, l('appMode.off')),
          Segment(AppRoutingMode.onlySelected, l('appMode.onlySelected')),
          Segment(AppRoutingMode.bypassSelected, l('appMode.bypassSelected')),
        ],
      ),
      SectionFooter(l('appMode.${r.appMode.name}.desc')),
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
                side: BorderSide(color: c.separator, width: kHairline),
                shape: Radii.shape(Radii.s),
                labelStyle: context.t.subhead,
              ),
          ]),
        const SizedBox(height: Space.m),
        Align(
          alignment: Alignment.centerLeft,
          child: SecondaryButton(
            icon: Icons.add_rounded,
            label: r.appRules.isEmpty
                ? l('routing.pickApps')
                : l('routing.pickAppsN', {'n': '${r.appRules.length}'}),
            onTap: () async {
              final v = await pickApps(context, selected: r.appRules, title: l('routing.apps'));
              if (v != null) app.updateRouting((x) => x.appRules = v);
            },
          ),
        ),
      ],
    ]);
  }
}

class _DomainRow extends StatelessWidget {
  const _DomainRow({
    required this.title,
    required this.list,
    required this.onSave,
    this.color,
  });
  final String title;
  final List<String> list;
  final ValueChanged<List<String>> onSave;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    return RowTile(
      title: title,
      trailing: Text(list.isEmpty ? l('common.none') : '${list.length}',
          style: context.t.mono.copyWith(color: c.secondaryLabel)),
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
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(title: widget.title),
        Padding(
          padding: EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: _ctrl,
                minLines: 8,
                maxLines: 14,
                autofocus: true,
                style: context.t.mono,
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
      ]),
    );
  }
}
