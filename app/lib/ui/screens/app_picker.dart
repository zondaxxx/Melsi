import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../services/platform_apps.dart';
import '../../state/app_scope.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/page.dart';

/// Pick apps (Android: installed packages with icons; desktop: running
/// processes + manual entry). Returns the new selection, or null if
/// cancelled.
Future<List<AppRule>?> pickApps(BuildContext context,
    {required List<AppRule> selected, required String title}) {
  return showMelsiSheet<List<AppRule>>(context,
      expand: true, builder: (_) => AppPicker(selected: selected, title: title));
}

class AppPicker extends StatefulWidget {
  const AppPicker({super.key, required this.selected, required this.title});
  final List<AppRule> selected;
  final String title;

  @override
  State<AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<AppPicker> {
  late final Map<String, AppRule> _sel = {for (final a in widget.selected) a.id: a};
  final _search = TextEditingController();
  final _manual = TextEditingController();
  List<InstalledApp>? _apps;
  bool _showSystem = false;

  @override
  void initState() {
    super.initState();
    context.appRead.apps.list().then((a) {
      if (mounted) setState(() => _apps = a);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _manual.dispose();
    super.dispose();
  }

  void _toggle(InstalledApp a) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_sel.remove(a.id) == null) _sel[a.id] = AppRule(id: a.id, label: a.label);
    });
  }

  void _addManual() {
    final v = _manual.text.trim();
    if (v.isEmpty) return;
    setState(() {
      _sel[v] = AppRule(id: v, label: v);
      _manual.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final apps = context.appRead.apps;
    final q = _search.text.trim().toLowerCase();
    final known = {for (final a in _apps ?? const <InstalledApp>[]) a.id};
    // Selected entries that aren't in the scanned list (manual / not running).
    final extra = _sel.values.where((r) => !known.contains(r.id)).toList();
    final list = (_apps ?? const <InstalledApp>[])
        .where((a) => _showSystem || !a.system || _sel.containsKey(a.id))
        .where((a) => q.isEmpty || a.label.toLowerCase().contains(q) || a.id.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) {
        final sa = _sel.containsKey(a.id) ? 0 : 1, sb = _sel.containsKey(b.id) ? 0 : 1;
        return sa != sb ? sa - sb : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    return Column(children: [
      SheetHeader(
        title: widget.title,
        trailing: TextButton(
          onPressed: () => Navigator.of(context).pop(_sel.values.toList()),
          child: Text(l('common.done')),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.l),
        child: Column(children: [
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: l('apps.search'),
              prefixIcon: Icon(Icons.search_rounded, size: 18, color: c.tertiaryLabel),
              prefixIconConstraints: const BoxConstraints(minWidth: 38),
            ),
          ),
          if (apps.isAndroid)
            SwitchRow(
              dense: true,
              title: l('apps.system'),
              value: _showSystem,
              onChanged: (v) => setState(() => _showSystem = v),
            )
          else ...[
            const SizedBox(height: Space.s),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _manual,
                  onSubmitted: (_) => _addManual(),
                  decoration: InputDecoration(hintText: l('apps.manualHint')),
                ),
              ),
              const SizedBox(width: Space.s),
              ToolButton(icon: Icons.add_rounded, onTap: _addManual, size: 40),
            ]),
            const SizedBox(height: Space.s),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(l('apps.desktopHint'), style: context.t.caption),
            ),
          ],
          const SizedBox(height: Space.s),
        ]),
      ),
      Expanded(
        child: _apps == null
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.xl),
                children: [
                  for (final r in extra)
                    _AppRow(
                      id: r.id,
                      label: r.label ?? r.id,
                      selected: true,
                      onTap: () => setState(() => _sel.remove(r.id)),
                    ),
                  for (final a in list)
                    _AppRow(
                      id: a.id,
                      label: a.label,
                      selected: _sel.containsKey(a.id),
                      icon: apps.isAndroid ? apps.icon(a.id) : null,
                      onTap: () => _toggle(a),
                    ),
                  if (list.isEmpty && extra.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(Space.x3),
                      child: Text(l('apps.none'), textAlign: TextAlign.center, style: context.t.footnote),
                    ),
                ],
              ),
      ),
    ]);
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.id, required this.label, required this.selected, required this.onTap, this.icon});
  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Future<Uint8List?>? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final placeholder = Container(
      decoration: ShapeDecoration(
          color: c.fill,
          shape: Radii.shape(Radii.s, side: BorderSide(color: c.separator, width: kHairline))),
      alignment: Alignment.center,
      child: Text(label.isEmpty ? '?' : label.characters.first.toUpperCase(),
          style: context.t.mono.copyWith(color: c.secondaryLabel)),
    );
    return RowTile(
      dense: true,
      leading: SizedBox.square(
        dimension: 30,
        child: icon == null
            ? placeholder
            : FutureBuilder<Uint8List?>(
                future: icon,
                builder: (context, s) => s.data == null
                    ? placeholder
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.s),
                        child: Image.memory(s.data!, gaplessPlayback: true)),
              ),
      ),
      title: label,
      subtitle: label == id ? null : id,
      onTap: onTap,
      trailing: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? c.accent : Colors.transparent,
          border: Border.all(color: selected ? c.accent : c.tertiaryLabel, width: 1.5),
        ),
        child: selected ? Icon(Icons.check_rounded, size: 14, color: c.onAccent) : null,
      ),
    );
  }
}
