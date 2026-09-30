import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../theme/theme.dart';
import '../widgets/import_panel.dart';
import '../widgets/page.dart';
import 'qr_scan_screen.dart';

Future<void> showAddSheet(BuildContext context) =>
    showMelsiSheet(context, builder: (_) => const AddSheet());

/// One-tap import of whatever is on the clipboard (link, subscription URL
/// or a whole config).
Future<void> importFromClipboard(BuildContext context) async {
  final app = context.appRead;
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text ?? '';
  if (text.trim().isEmpty) {
    app.notice('notice.clipboardEmpty');
    return;
  }
  final n = await app.importText(text);
  if (n > 0) HapticFeedback.mediumImpact();
}

/// Scan a QR code with the camera and import it.
Future<void> importFromQr(BuildContext context) async {
  final app = context.appRead;
  final v = await Navigator.of(context).push<String>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => const QrScanScreen()),
  );
  if (v == null) return;
  final n = await app.importText(v);
  if (n > 0) HapticFeedback.mediumImpact();
}

/// Add servers: paste a link / subscription URL, scan a QR (mobile), import
/// from the clipboard or a file. The form itself is [ImportPanel].
class AddSheet extends StatelessWidget {
  const AddSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    // The header sits at the sheet edge (its own 16px gutter); only the
    // body is padded, so title and cards share one left edge.
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: Space.l + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: l('add.title')),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.l),
              child: ImportPanel(onImported: (_) => Navigator.of(context).maybePop()),
            ),
          ],
        ),
      ),
    );
  }
}
