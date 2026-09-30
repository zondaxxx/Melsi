import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';
import '../widgets/page.dart';
import 'qr_scan_screen.dart';

Future<void> showAddSheet(BuildContext context) =>
    showMelsiSheet(context, builder: (_) => const AddSheet());

/// Add servers: paste a link / subscription URL, scan a QR (mobile), import
/// from the clipboard or a file.
class AddSheet extends StatefulWidget {
  const AddSheet({super.key});

  @override
  State<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<AddSheet> {
  final _ctrl = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _import(String text, {String? name}) async {
    if (text.trim().isEmpty) return;
    setState(() => _busy = true);
    final n = await context.appRead.importText(text,
        name: (name ?? _name.text).trim().isEmpty ? null : (name ?? _name.text).trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (n > 0) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      if (mounted) context.appRead.notice('notice.clipboardEmpty');
      return;
    }
    _ctrl.text = text.trim();
    await _import(text);
  }

  Future<void> _scan() async {
    final v = await Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const QrScanScreen()),
    );
    if (v != null && mounted) {
      _ctrl.text = v;
      await _import(v);
    }
  }

  Future<void> _file() async {
    try {
      final f = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: 'Config', extensions: ['txt', 'yaml', 'yml', 'json', 'conf']),
        XTypeGroup(label: 'All'),
      ]);
      if (f == null) return;
      final text = await f.readAsString();
      var name = f.name;
      final dot = name.lastIndexOf('.');
      if (dot > 0) name = name.substring(0, dot);
      await _import(text, name: name);
    } catch (e) {
      if (mounted) context.appRead.notice('notice.fileFailed', detail: '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final mobile = Platform.isAndroid || Platform.isIOS;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            Space.l, 0, Space.l, Space.l + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: l('add.title')),
            Row(children: [
              Expanded(
                child: _Source(
                  icon: Icons.content_paste_rounded,
                  color: c.accent,
                  label: l('add.clipboard'),
                  onTap: _busy ? null : _paste,
                ),
              ),
              if (mobile) ...[
                const SizedBox(width: Space.m),
                Expanded(
                  child: _Source(
                    icon: Icons.qr_code_scanner_rounded,
                    color: const Color(0xFF14A8C9),
                    label: l('add.scan'),
                    onTap: _busy ? null : _scan,
                  ),
                ),
              ],
              const SizedBox(width: Space.m),
              Expanded(
                child: _Source(
                  icon: Icons.folder_open_rounded,
                  color: const Color(0xFFFF7A1A),
                  label: l('add.file'),
                  onTap: _busy ? null : _file,
                ),
              ),
            ]),
            const SizedBox(height: Space.xl),
            Text(l('add.manual'), style: context.t.subhead.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: Space.s),
            TextField(
              key: const ValueKey('add-link-field'),
              controller: _ctrl,
              minLines: 3,
              maxLines: 6,
              style: context.t.callout.copyWith(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(hintText: l('add.hint')),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Space.s),
            TextField(
              controller: _name,
              style: context.t.callout,
              decoration: InputDecoration(hintText: l('add.nameHint')),
            ),
            const SizedBox(height: Space.s),
            Text(l('add.supported'), style: context.t.caption),
            const SizedBox(height: Space.l),
            PrimaryButton(
              key: const ValueKey('add-submit'),
              label: l('add.submit'),
              icon: Icons.add_rounded,
              expand: true,
              busy: _busy,
              onTap: _ctrl.text.trim().isEmpty ? null : () => _import(_ctrl.text),
            ),
          ],
        ),
      ),
    );
  }
}

class _Source extends StatelessWidget {
  const _Source({required this.icon, required this.color, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PressableScaleCard(
      onTap: onTap,
      child: Column(children: [
        IconTile(icon, color: color, size: 40),
        const SizedBox(height: Space.s),
        Text(label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: context.t.footnote.copyWith(color: c.label, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
