import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../ui/shell.dart';
import '../../ui/theme/theme.dart';
import 'command_palette.dart';

/// Shell shortcuts contributed by the command palette: Cmd/Ctrl+K on wide
/// layouts only. On phones the map is empty and nothing is rendered. The
/// shortcut is ignored while a text field has focus, so typing "k" with a
/// modifier in the Servers search never steals the keystroke.
Map<ShortcutActivator, VoidCallback> paletteShortcuts(BuildContext context) {
  if (!context.isWide) return const {};
  void open() {
    if (isEditingText()) return;
    showCommandPalette(context);
  }

  return {
    const SingleActivator(LogicalKeyboardKey.keyK, control: true): open,
    const SingleActivator(LogicalKeyboardKey.keyK, meta: true): open,
  };
}

/// Whether the primary focus sits inside an [EditableText].
bool isEditingText() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null || !ctx.mounted) return false;
  if (ctx.widget is EditableText) return true;
  try {
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  } catch (_) {
    return false;
  }
}

bool _open = false;

/// Opens the palette as a centred-high dialog over a 30% barrier. It fades
/// in with the route and springs from 98% to full size (a plain fade with
/// reduced motion); commands run against [context] after it closes.
Future<void> showCommandPalette(BuildContext context) {
  if (_open) return Future.value();
  _open = true;
  final reduce = context.reduceMotion;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.l('common.close'),
    barrierColor: Colors.black.withValues(alpha: 0.3),
    transitionDuration: Duration(milliseconds: reduce ? 120 : 200),
    pageBuilder: (_, _, _) => CommandPalette(host: context),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  ).whenComplete(() => _open = false);
}

/// The shell's [ShellNav] as seen from [context]. The shortcut map is built
/// with the shell's own context, which sits *above* [ShellNav], so an
/// inherited lookup finds nothing there; the element chain between the two
/// is short and fixed, so it is walked instead.
ShellNav? findShellNav(BuildContext context) {
  final direct = ShellNav.maybeOf(context);
  if (direct != null) return direct;
  if (!context.mounted) return null;
  ShellNav? found;
  void visit(Element e, int depth) {
    if (found != null || depth > 24) return;
    final w = e.widget;
    if (w is ShellNav) {
      found = w;
      return;
    }
    e.visitChildElements((c) => visit(c, depth + 1));
  }

  context.visitChildElements((c) => visit(c, 0));
  return found;
}
