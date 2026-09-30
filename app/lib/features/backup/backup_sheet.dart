// The restore sheet and the save / open / copy / paste flows around it.
// These are plain functions (not widgets) because the Settings rows and
// the command palette both call them.

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../ui/screens/servers_screen.dart' show promptText;
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/page.dart';
import '../../ui/widgets/segmented.dart';

/// Writes a backup: the share sheet on phones, a save dialog on desktop,
/// the clipboard when the dialog is unavailable (mirrors the config export).
Future<void> saveBackup(BuildContext context) async {
  final app = context.appRead;
  final backup = context.features.backup;
  final json = backup.export();
  final name = backup.suggestedFileName();
  final bytes = Uint8List.fromList(utf8.encode(json));
  if (Platform.isAndroid || Platform.isIOS) {
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, name: name, mimeType: 'application/json')],
      fileNameOverrides: [name],
    ));
    return;
  }
  try {
    final loc = await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
    ]);
    if (loc == null) return;
    await File(loc.path).writeAsBytes(bytes);
    app.notice('backup.saved', kind: NoticeKind.success, detail: loc.path);
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: json));
    app.notice('backup.copied', kind: NoticeKind.success);
  }
}

/// Puts the backup on the clipboard (desktop → phone via any messenger).
Future<void> copyBackupAsText(BuildContext context) async {
  final app = context.appRead;
  await Clipboard.setData(ClipboardData(text: context.features.backup.export()));
  app.notice('backup.copied', kind: NoticeKind.success);
}

/// Picks a `.json` file and opens the restore sheet for it.
Future<void> restoreBackupFromFile(BuildContext context) async {
  final app = context.appRead;
  String text;
  try {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
      XTypeGroup(label: 'All'),
    ]);
    if (f == null) return;
    text = await f.readAsString();
  } catch (e) {
    app.notice('notice.fileFailed', kind: NoticeKind.error, detail: '$e');
    return;
  }
  if (context.mounted) await showBackupSheet(context, text);
}

/// Asks for pasted backup text and opens the restore sheet for it.
Future<void> restoreBackupFromText(BuildContext context) async {
  final l = context.l;
  final text = await promptText(context, title: l('backup.pasteText'), hint: '{ "melsi_backup": 1, … }');
  if (text == null || text.trim().isEmpty) return;
  if (context.mounted) await showBackupSheet(context, text);
}

/// Inspects [json] and, when it is a backup, lets the user replace or merge.
/// Anything else posts `backup.invalid` and returns.
Future<void> showBackupSheet(BuildContext context, String json) async {
  final app = context.appRead;
  final backup = context.features.backup;
  final BackupSummary summary;
  try {
    summary = backup.inspect(json);
  } on FormatException {
    app.notice('backup.invalid', kind: NoticeKind.error);
    return;
  }
  await showMelsiSheet<void>(
    context,
    builder: (_) => BackupSheet(json: json, summary: summary),
  );
}

enum RestoreMode { replace, merge }

/// "Restore backup": what the file holds, replace / merge, one primary
/// action. The danger colour appears only as the footnote under "Replace".
class BackupSheet extends StatefulWidget {
  const BackupSheet({super.key, required this.json, required this.summary});
  final String json;
  final BackupSummary summary;

  @override
  State<BackupSheet> createState() => _BackupSheetState();
}

class _BackupSheetState extends State<BackupSheet> {
  RestoreMode _mode = RestoreMode.replace;
  bool _busy = false;

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      await context.features.backup.restore(widget.json, merge: _mode == RestoreMode.merge);
      HapticFeedback.lightImpact();
      nav.pop();
    } on FormatException {
      // Notice already posted by the service; keep the sheet so the user
      // can pick another file.
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "2026-10-01 · macOS · 1.0.0": all data, so mono.
  String _meta() {
    final s = widget.summary;
    final parts = <String>[];
    final d = s.createdAt;
    if (d != null) {
      String two(int n) => n.toString().padLeft(2, '0');
      parts.add('${d.year}-${two(d.month)}-${two(d.day)}');
    }
    if (s.platform != null) parts.add(_platformName(s.platform!));
    if (s.app != null) parts.add(s.app!);
    return parts.join(' · ');
  }

  static String _platformName(String os) => switch (os) {
        'macos' => 'macOS',
        'ios' => 'iOS',
        'android' => 'Android',
        'windows' => 'Windows',
        'linux' => 'Linux',
        _ => os,
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final s = widget.summary;
    final meta = _meta();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title: l('backup.restoreTitle')),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    l('backup.summary', {
                      'subs': '${s.subscriptions}',
                      'nodes': '${s.nodes}',
                      'favs': '${s.favourites}',
                    }),
                    style: t.headline,
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: Space.xs),
                    Text(meta, style: t.mono.copyWith(color: c.secondaryLabel)),
                  ],
                ]),
              ),
              const SizedBox(height: Space.xl),
              Segmented<RestoreMode>(
                value: _mode,
                onChanged: _busy ? null : (m) => setState(() => _mode = m),
                segments: [
                  Segment(RestoreMode.replace, l('backup.replace')),
                  Segment(RestoreMode.merge, l('backup.merge')),
                ],
              ),
              // The mode's consequence, in place, no size jump between modes.
              AnimatedSwitcher(
                duration: Duration(milliseconds: context.reduceMotion ? 0 : 180),
                child: Padding(
                  key: ValueKey(_mode),
                  padding: const EdgeInsets.fromLTRB(Space.xs, Space.s + 2, Space.xs, 0),
                  child: Text(
                    _mode == RestoreMode.replace ? l('backup.replaceWarn') : l('backup.mergeHint'),
                    style: t.footnote.copyWith(
                        color: _mode == RestoreMode.replace ? c.danger : null),
                  ),
                ),
              ),
              SectionFooter(l('backup.secrets')),
              const SizedBox(height: Space.xxl),
              PrimaryButton(
                label: l('backup.doRestore'),
                expand: true,
                busy: _busy,
                onTap: _restore,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
