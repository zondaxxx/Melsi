import 'package:flutter/widgets.dart';

import '../../state/app_state.dart';

/// Wraps the shell to show the "import from clipboard?" offer (stub: passes
/// the child through; the clipboard feature implements it).
class ClipboardOfferHost extends StatelessWidget {
  const ClipboardOfferHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Servers empty state: hint under the buttons (stub: nothing).
class ClipboardEmptyHint extends StatelessWidget {
  const ClipboardEmptyHint({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Settings › App rows: the clipboard watch switch (stub: none).
List<Widget> clipboardSettingsRows(BuildContext context, AppState app) => const [];
