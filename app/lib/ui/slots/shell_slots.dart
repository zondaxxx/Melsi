// Extension points of the shell (shortcuts and overlays).

import 'package:flutter/widgets.dart';

import '../../features/clipboard/clipboard_offer.dart';
import '../../features/palette/palette_shell.dart';

abstract final class ShellSlots {
  /// Extra keyboard shortcuts (spread first; the shell's own win on clash).
  static Map<ShortcutActivator, VoidCallback> shortcuts(BuildContext context) =>
      paletteShortcuts(context);

  /// Wraps the shell's scaffold with feature overlays.
  static Widget overlays(BuildContext context, Widget child) => ClipboardOfferHost(child: child);
}
