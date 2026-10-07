import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/features.dart';
import '../../ui/theme/pressable.dart';
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import 'palette_search.dart';

/// Finder key of the search field (tests type into it).
const Key kPaletteFieldKey = ValueKey('palette-field');

/// The palette body: a search field over grouped results, driven entirely
/// by the [CommandRegistry]. Keyboard: ↑/↓ move, Enter runs, Esc closes,
/// Tab / Shift+Tab jump between groups. The highlighted row is the neutral
/// fill; the accent appears only on the check mark of an `isOn` command.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.host});

  /// A long-lived context under the shell; commands run against it once
  /// the palette has closed.
  final BuildContext host;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _Section {
  _Section(this.group, this.items);
  final String group;
  final List<AppCommand> items;
}

class _CommandPaletteState extends State<CommandPalette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _selectedKey = GlobalKey();
  int _selected = 0;
  Offset? _pointer;
  Listenable? _registry;

  static const _ru = L10n('ru');
  static const _en = L10n('en');
  static const _maxResults = 40;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final f = context.features;
    final r = Listenable.merge([f.commands, f.palette]);
    if (_registry != r) {
      _registry?.removeListener(_rebuild);
      _registry = r..addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    _registry?.removeListener(_rebuild);
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onQuery() => setState(() => _selected = 0);

  // ------------------------------------------------------------- results

  List<_Section> _sections(Features f) {
    final q = _query.text.trim();
    final all = f.commands.all;
    if (q.isEmpty) return _suggested(f, all);

    final scored = <(AppCommand, double)>[];
    for (final c in all) {
      final s = math.max(
        paletteScore(q, _ru(c.titleKey), c.keywords),
        paletteScore(q, _en(c.titleKey), c.keywords),
      );
      if (s > 0) scored.add((c, s));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    // Groups appear in the order their best hit ranks; within a group hits
    // stay sorted by score.
    final byGroup = <String, _Section>{};
    for (final (c, _) in scored.take(_maxResults)) {
      byGroup.putIfAbsent(c.group, () => _Section(c.group, [])).items.add(c);
    }
    return byGroup.values.toList();
  }

  /// Empty query: recents, then favourite servers, then the six commands
  /// that matter most right now (grouped under their own headers).
  List<_Section> _suggested(Features f, List<AppCommand> all) {
    final seen = <String>{};
    final out = <_Section>[];
    List<AppCommand> pick(Iterable<String> ids) => [
          for (final id in ids)
            if (seen.add(id)) ?f.commands.byId(id),
        ];

    final recents = pick(f.palette.recentIds);
    if (recents.isNotEmpty) out.add(_Section(PaletteGroups.recent, recents));

    final favs = pick(f.app.favouriteIds.map((id) => 'node.$id'));
    if (favs.isNotEmpty) out.add(_Section(PaletteGroups.servers, favs));

    final actions = pick(f.palette.suggestedIds()).take(6);
    final byGroup = <String, _Section>{};
    for (final c in actions) {
      byGroup.putIfAbsent(c.group, () => _Section(c.group, [])).items.add(c);
    }
    out.addAll(byGroup.values);
    return out;
  }

  // ------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent e, List<_Section> sections) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final flat = [for (final s in sections) ...s.items];
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      if (e is KeyDownEvent) Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(flat, 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(flat, -1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.tab) {
      _jumpGroup(sections, flat, HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (e is KeyDownEvent && flat.isNotEmpty) {
        _run(flat[_selected.clamp(0, flat.length - 1)]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(List<AppCommand> flat, int delta) {
    if (flat.isEmpty) return;
    final next = (_selected + delta) % flat.length;
    _select(next < 0 ? next + flat.length : next, reveal: delta > 0 ? 1 : -1);
  }

  void _jumpGroup(List<_Section> sections, List<AppCommand> flat, int delta) {
    if (sections.length < 2) return;
    var offset = 0;
    var current = 0;
    for (var i = 0; i < sections.length; i++) {
      final n = sections[i].items.length;
      if (_selected >= offset && _selected < offset + n) {
        current = i;
        break;
      }
      offset += n;
    }
    final target = (current + delta + sections.length) % sections.length;
    var start = 0;
    for (var i = 0; i < target; i++) {
      start += sections[i].items.length;
    }
    _select(start, reveal: delta);
  }

  /// [reveal] says which way the selection moved so the list only scrolls
  /// when the row is actually out of view (no recentring on every step).
  void _select(int i, {int reveal = 0}) {
    if (i == _selected) return;
    setState(() => _selected = i);
    if (reveal == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignmentPolicy: reveal > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  Future<void> _run(AppCommand cmd) async {
    HapticFeedback.selectionClick();
    context.features.palette.markUsed(cmd.id);
    final host = widget.host;
    Navigator.of(context).pop();
    if (!host.mounted) return;
    try {
      await cmd.run(host);
    } catch (e) {
      debugPrint('palette: ${cmd.id} failed: $e');
    }
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    // Subscribes to the app so `isOn` marks and titles stay live.
    context.app;
    final f = context.features;
    final sections = _sections(f);
    final flat = [for (final s in sections) ...s.items];
    if (_selected >= flat.length) _selected = math.max(0, flat.length - 1);
    final empty = _query.text.trim().isEmpty;
    final size = MediaQuery.sizeOf(context);
    final maxHeight = math.min(520.0, size.height * 0.72);

    return Semantics(
      container: true,
      label: l('palette.title'),
      child: SafeArea(
        child: Align(
          alignment: const Alignment(0, -0.6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.l),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
              child: _Enter(
                child: Focus(
                  onKeyEvent: (n, e) => _onKey(n, e, sections),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Panel(
                      color: c.surfaceRaised,
                      radius: Radii.l,
                      padding: EdgeInsets.zero,
                      clip: true,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _field(context),
                          const Hairline(),
                          Flexible(
                            child: flat.isEmpty
                                ? _empty(context)
                                : SingleChildScrollView(
                                    controller: _scroll,
                                    padding: const EdgeInsets.all(Space.s),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: _rows(sections),
                                    ),
                                  ),
                          ),
                          if (empty) ...[
                            const Hairline(),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  Space.l, Space.s + 1, Space.l, Space.s + 1),
                              child: Text(
                                l('palette.hintRow', {'k': _shortcutLabel}),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.t.caption.copyWith(color: c.tertiaryLabel),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _shortcutLabel =>
      defaultTargetPlatform == TargetPlatform.macOS ? '⌘K' : 'Ctrl+K';

  Widget _field(BuildContext context) {
    final c = context.c;
    return TextField(
      key: kPaletteFieldKey,
      controller: _query,
      autofocus: true,
      style: context.t.body,
      textInputAction: TextInputAction.none,
      decoration: InputDecoration(
        hintText: context.l('palette.hint'),
        filled: false,
        isDense: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.l),
        prefixIcon: Icon(Icons.search_rounded, size: 20, color: c.tertiaryLabel),
        prefixIconConstraints: const BoxConstraints(minWidth: 48),
      ),
    );
  }

  Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.xxl),
        child: Text(context.l('palette.empty'),
            textAlign: TextAlign.center, style: context.t.footnote),
      );

  List<Widget> _rows(List<_Section> sections) {
    final out = <Widget>[];
    var i = 0;
    for (final s in sections) {
      out.add(Padding(
        padding: EdgeInsets.fromLTRB(Space.m, out.isEmpty ? Space.xs : Space.m, Space.m, Space.xs),
        child: Overline(context.l(s.group)),
      ));
      for (final cmd in s.items) {
        final index = i++;
        final selected = index == _selected;
        out.add(_Row(
          key: selected ? _selectedKey : ValueKey(cmd.id),
          command: cmd,
          selected: selected,
          onTap: () => _run(cmd),
          // Hover follows the pointer only when it actually moves; a list
          // that scrolls under a resting cursor keeps the keyboard's pick.
          onHover: (p) {
            if (p != _pointer) {
              _pointer = p;
              _select(index);
            }
          },
        ));
      }
    }
    return out;
  }
}

/// One result: icon, title (+ subtitle), and for toggles the on/off state
/// with an accent check when on.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.command,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });
  final AppCommand command;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onHover;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final l = context.l;
    final on = command.isOn?.call();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (e) => onHover(e.position),
      onHover: (e) => onHover(e.position),
      child: PressableScale(
        scale: 0.99,
        onTap: onTap,
        semanticLabel: l(command.titleKey),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: selected ? c.fill : Colors.transparent,
            shape: Radii.shape(Radii.s),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s + 2),
            child: Row(children: [
              Icon(command.icon, size: 18, color: c.secondaryLabel),
              const SizedBox(width: Space.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l(command.titleKey),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: t.body),
                  if (command.subtitle != null)
                    Text(command.subtitle!,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption),
                ]),
              ),
              if (on != null) ...[
                const SizedBox(width: Space.m),
                if (on) ...[
                  Icon(Icons.check_rounded, size: 16, color: c.accent),
                  const SizedBox(width: Space.xs),
                ],
                Text(on ? l('palette.on') : l('palette.off'),
                    style: t.caption.copyWith(color: on ? c.label : c.tertiaryLabel)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Entrance: 98% → 100% on a quick critically damped spring, started on
/// the first frame so it springs from the initial value. With reduced
/// motion the target is 1 from the start and nothing scales (the route's
/// own fade is the whole transition).
class _Enter extends StatefulWidget {
  const _Enter({required this.child});
  final Widget child;

  @override
  State<_Enter> createState() => _EnterState();
}

class _EnterState extends State<_Enter> {
  bool _in = false;
  static final _spring = Springs.of(0.28, 1.0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return SpringValue(
      target: reduce || _in ? 1 : 0.98,
      spring: _spring,
      child: widget.child,
      builder: (context, v, child) => Transform.scale(scale: v, child: child),
    );
  }
}
