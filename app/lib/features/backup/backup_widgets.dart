import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import 'backup_sheet.dart';

/// Settings › Tools rows: save / restore, plus the text variants for
/// moving a setup between a desktop and a phone without a file.
List<Widget> backupRows(BuildContext context, AppState app) {
  final l = context.l;
  final c = context.c;
  Widget glyph(IconData i) => Icon(i, size: 18, color: c.secondaryLabel);
  return [
    RowTile(
      key: const ValueKey('backup-save'),
      title: l('backup.save'),
      subtitle: l('backup.saveHint'),
      trailing: glyph(Icons.save_alt_rounded),
      onTap: () => saveBackup(context),
    ),
    RowTile(
      key: const ValueKey('backup-restore'),
      title: l('backup.restore'),
      chevron: true,
      onTap: () => restoreBackupFromFile(context),
    ),
    RowTile(
      key: const ValueKey('backup-copy'),
      title: l('backup.copyText'),
      trailing: glyph(Icons.copy_rounded),
      onTap: () => copyBackupAsText(context),
    ),
    RowTile(
      key: const ValueKey('backup-paste'),
      title: l('backup.pasteText'),
      chevron: true,
      onTap: () => restoreBackupFromText(context),
    ),
  ];
}
