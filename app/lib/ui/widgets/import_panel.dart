import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../screens/qr_scan_screen.dart';
import '../theme/theme.dart';
import 'common.dart';

/// The import form shared by the add sheet and the onboarding: shortcut
/// buttons (clipboard, QR on mobile, file), the link / subscription field,
/// an optional name and the submit button. Calls [onImported] with the
/// number of servers added (only when > 0).
class ImportPanel extends StatefulWidget {
  const ImportPanel({
    super.key,
    required this.onImported,
    this.fieldKey = const ValueKey('add-link-field'),
    this.submitKey = const ValueKey('add-submit'),
    this.autofocus = false,
  });

  final ValueChanged<int> onImported;
  final Key fieldKey;
  final Key submitKey;
  final bool autofocus;

  @override
  State<ImportPanel> createState() => _ImportPanelState();
}

class _ImportPanelState extends State<ImportPanel> {
  final _ctrl = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  bool _formats = false;
  late final _formatsTap = TapGestureRecognizer()
    ..onTap = () => setState(() => _formats = true);

  @override
  void dispose() {
    _ctrl.dispose();
    _name.dispose();
    _formatsTap.dispose();
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
      widget.onImported(n);
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
    final mobile = Platform.isAndroid || Platform.isIOS;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Shortcuts as outlined buttons with a leading glyph — the same
        // control Routing and Games use for "Выбрать приложения".
        // Intrinsic widths that wrap, so the three on a phone never
        // truncate their labels.
        AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: _busy ? 0.5 : 1,
          child: Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            children: [
              SecondaryButton(
                icon: Icons.content_paste_rounded,
                label: l('add.clipboard'),
                onTap: _busy ? null : _paste,
              ),
              if (mobile)
                SecondaryButton(
                  icon: Icons.qr_code_scanner_rounded,
                  label: l('add.scan'),
                  onTap: _busy ? null : _scan,
                ),
              SecondaryButton(
                icon: Icons.folder_open_outlined,
                label: l('add.file'),
                onTap: _busy ? null : _file,
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.xxl),
        // Same 4px inset as every section label on the pages.
        Padding(
          padding: const EdgeInsets.only(left: Space.xs),
          child: Overline(l('add.manual')),
        ),
        const SizedBox(height: Space.s + 2),
        TextField(
          key: widget.fieldKey,
          controller: _ctrl,
          autofocus: widget.autofocus,
          minLines: 3,
          maxLines: 6,
          style: context.t.mono,
          decoration: InputDecoration(hintText: l('add.hint')),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Space.s),
        TextField(
          controller: _name,
          style: context.t.callout,
          decoration: InputDecoration(hintText: l('add.nameHint')),
        ),
        const SizedBox(height: Space.s + 2),
        // The field's placeholder already names the formats; below it only
        // the disclosure link remains, unfolding the full list on demand so
        // it never competes with the input.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: _formats
              ? Text(l('add.formatsList'), style: context.t.footnote)
              : Text.rich(
                  TextSpan(
                    text: l('add.formats'),
                    recognizer: _formatsTap,
                    style: TextStyle(color: context.c.label),
                  ),
                  style: context.t.footnote,
                ),
        ),
        const SizedBox(height: Space.l),
        PrimaryButton(
          key: widget.submitKey,
          label: l('add.submit'),
          expand: true,
          busy: _busy,
          onTap: _ctrl.text.trim().isEmpty ? null : () => _import(_ctrl.text),
        ),
      ],
    );
  }
}
