// The doctor sheet: one row per check that fills in as the runner advances,
// a verdict panel with one-tap fixes, and the copy / run-again actions.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../ui/screens/server_switcher.dart';
import '../../ui/screens/settings_screen.dart' show SettingsScreen;
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/page.dart';
import 'verdict.dart';

class DoctorSheet extends StatefulWidget {
  const DoctorSheet({super.key});

  @override
  State<DoctorSheet> createState() => _DoctorSheetState();
}

class _DoctorSheetState extends State<DoctorSheet> {
  late final Diagnostics _doc;

  @override
  void initState() {
    super.initState();
    _doc = context.features.doctor;
    // Opening the sheet is the request: start straight away.
    unawaited(_doc.run());
  }

  @override
  void dispose() {
    // Closing mid-run: the step in flight finishes on its own timeout and
    // its result is dropped; nothing keeps notifying a dead sheet.
    _doc.cancel();
    super.dispose();
  }

  Future<void> _copy(AppState app, L10n l) async {
    final text = doctorReport(
      l: l,
      app: app,
      results: Map.of(_doc.results),
      verdict: _doc.complete ? diagnose(_doc.results) : null,
      appVersion: SettingsScreen.appVersion,
    );
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      // No clipboard on this platform: the toast still confirms the intent.
    }
    HapticFeedback.lightImpact();
    app.notice('notice.copied', kind: NoticeKind.success);
  }

  void _fix(DoctorFix fix, AppState app) {
    HapticFeedback.selectionClick();
    switch (fix) {
      case DoctorFix.antiDpi:
        app.updateSettings((s) => s.antiDpi = true);
        app.notice('doctor.antiDpiOn', kind: NoticeKind.success);
      case DoctorFix.switchServer:
        // Over the doctor, not instead of it: pick a server, come back,
        // tap "Run again".
        unawaited(showServerSwitcher(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final l = context.l;
    final wide = context.isWide;
    return ListenableBuilder(
      listenable: _doc,
      builder: (context, _) {
        const ids = Diagnostics.stepIds;
        final current = _doc.currentStep;
        // Rows up to the step in flight are "reached"; once the run is over
        // (or was cancelled) every row is.
        final reached = _doc.running ? (current == null ? -1 : ids.indexOf(current)) : ids.length;
        final verdict = _doc.complete ? diagnose(_doc.results) : null;
        // A fix already applied is not offered again.
        final fixes = [
          for (final f in verdict?.fixes ?? const <DoctorFix>[])
            if (f != DoctorFix.antiDpi || !app.settings.antiDpi) f,
        ];
        final canCopy = _doc.results.isNotEmpty && !_doc.running;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          SheetHeader(title: l('doctor.title')),
          Flexible(
            // In the desktop dialog the sheet sizes to its content.
            fit: wide ? FlexFit.loose : FlexFit.tight,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  Space.l, Space.xs, Space.l, Space.xl + MediaQuery.paddingOf(context).bottom),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                GroupCard(children: [
                  for (final (i, id) in ids.indexed)
                    _StepRow(
                      key: ValueKey(id),
                      id: id,
                      result: _doc.results[id],
                      active: _doc.running && current == id,
                      reached: i <= reached,
                    ),
                ]),
                const SizedBox(height: Space.m),
                _VerdictPanel(
                  verdict: verdict,
                  running: _doc.running,
                  fixes: fixes,
                  onFix: (f) => _fix(f, app),
                ),
                const SizedBox(height: Space.m),
                _Actions(
                  copy: canCopy ? () => _copy(app, l) : null,
                  againLabel: _doc.running ? l('common.cancel') : l('doctor.again'),
                  again: _doc.running ? _doc.cancel : () => unawaited(_doc.run()),
                ),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

/// One check. The detail line is always present (pending / checking / the
/// result) so rows keep one height while results land, and the whole row
/// springs from dimmed-and-6px-low to full when the runner reaches it.
class _StepRow extends StatelessWidget {
  const _StepRow({
    super.key,
    required this.id,
    required this.result,
    required this.active,
    required this.reached,
  });

  final String id;
  final StepResult? result;
  final bool active;
  final bool reached;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final reduce = context.reduceMotion;
    final r = result;

    final String text;
    final TextStyle style;
    if (r == null) {
      text = active ? l('doctor.checking') : l('doctor.pending');
      style = t.footnote.copyWith(color: c.tertiaryLabel);
    } else if (r.detail == null) {
      text = '';
      style = t.footnote;
    } else {
      text = l(r.detail!, r.args);
      final quiet = r.status == StepStatus.skipped;
      style = r.mono
          ? t.monoSmall.copyWith(color: quiet ? c.tertiaryLabel : c.secondaryLabel)
          : t.footnote.copyWith(color: quiet ? c.tertiaryLabel : c.secondaryLabel);
    }

    final row = RowTile(
      // The desktop dialog is height-capped: tighter rows keep the verdict
      // and the actions closer to the fold.
      dense: context.isWide,
      title: l(id),
      subtitleWidget: SizedBox(
        height: 16,
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      ),
      trailing: _StatusMark(result: r, active: active),
    );

    return SpringValue(
      target: reached ? 1 : 0,
      spring: Springs.of(0.4, 1.0),
      child: row,
      builder: (context, v, child) {
        final p = v.clamp(0.0, 1.0);
        final faded = Opacity(opacity: 0.3 + 0.7 * p, child: child);
        if (reduce) return faded;
        return Transform.translate(offset: Offset(0, 6 * (1 - p)), child: faded);
      },
    );
  }
}

/// Spinner while the step runs, then the status glyph springs in.
class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.result, required this.active});
  final StepResult? result;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    final reduce = context.reduceMotion;
    final r = result;
    final Widget glyph = switch (r?.status) {
      StepStatus.ok => Icon(Icons.check_rounded, size: 16, color: c.success, semanticLabel: l('doctor.st.ok')),
      StepStatus.warn =>
        Icon(Icons.warning_amber_rounded, size: 16, color: c.warning, semanticLabel: l('doctor.st.warn')),
      StepStatus.fail => Icon(Icons.close_rounded, size: 16, color: c.danger, semanticLabel: l('doctor.st.fail')),
      // The same muted dash every unknown value in the app uses.
      StepStatus.skipped => Text('—',
          semanticsLabel: l('doctor.st.skipped'),
          style: context.t.mono.copyWith(color: c.tertiaryLabel)),
      null => const SizedBox.shrink(),
    };
    return SizedBox(
      width: 22,
      height: 22,
      child: Stack(alignment: Alignment.center, children: [
        if (active && r == null) const CupertinoActivityIndicator(radius: 7),
        SpringValue(
          target: r == null ? 0 : 1,
          spring: Springs.momentum,
          child: glyph,
          builder: (context, v, child) {
            final p = v.clamp(0.0, 1.2);
            final shown = Opacity(opacity: p.clamp(0.0, 1.0), child: child);
            if (reduce) return shown;
            return Transform.scale(scale: p, child: shown);
          },
        ),
      ]),
    );
  }
}

/// Headline + up to two fix chips. Colour lives in the small dot; the text
/// stays ink.
class _VerdictPanel extends StatelessWidget {
  const _VerdictPanel({
    required this.verdict,
    required this.running,
    required this.fixes,
    required this.onFix,
  });

  final Verdict? verdict;
  final bool running;
  final List<DoctorFix> fixes;
  final void Function(DoctorFix fix) onFix;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final t = context.t;
    final v = verdict;
    final headline = running ? l('doctor.running') : l((v ?? Verdict.partial).key);
    final dot = running
        ? c.tertiaryLabel
        : switch (v) {
            null || Verdict(key: 'doctor.v.partial') || Verdict(key: 'doctor.v.warn') => c.warning,
            Verdict(healthy: true) => c.success,
            _ => c.danger,
          };
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Overline(l('doctor.verdict')),
        const SizedBox(height: Space.s),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (w, a) => FadeTransition(opacity: a, child: w),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [...previous, ?current],
          ),
          child: Row(
            key: ValueKey(headline),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7),
                child: StatusDot(dot, hollow: running),
              ),
              const SizedBox(width: Space.s + 2),
              Expanded(
                child: Text(headline,
                    style: t.headline.copyWith(color: running ? c.secondaryLabel : c.label)),
              ),
            ],
          ),
        ),
        if (fixes.isNotEmpty) ...[
          const SizedBox(height: Space.m),
          Wrap(spacing: Space.s, runSpacing: Space.s, children: [
            for (final f in fixes)
              SecondaryButton(
                label: l(switch (f) {
                  DoctorFix.antiDpi => 'doctor.fix.antiDpi',
                  DoctorFix.switchServer => 'doctor.fix.switch',
                }),
                icon: switch (f) {
                  DoctorFix.antiDpi => Icons.shield_outlined,
                  DoctorFix.switchServer => Icons.swap_horiz_rounded,
                },
                onTap: () => onFix(f),
              ),
          ]),
        ],
      ]),
    );
  }
}

/// Copy report (primary) and run again / cancel. Side by side when there is
/// room; stacked on 360px phones so neither label truncates.
class _Actions extends StatelessWidget {
  const _Actions({required this.copy, required this.againLabel, required this.again});
  final VoidCallback? copy;
  final String againLabel;
  final VoidCallback again;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final copyBtn = PrimaryButton(
      key: const ValueKey('doctor-copy'),
      label: l('doctor.copy'),
      icon: Icons.copy_rounded,
      onTap: copy,
      expand: true,
    );
    final againBtn = SecondaryButton(
      key: const ValueKey('doctor-again'),
      label: againLabel,
      onTap: again,
      expand: true,
    );
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 420) {
        return Row(children: [
          Expanded(child: copyBtn),
          const SizedBox(width: Space.s),
          Expanded(child: againBtn),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        copyBtn,
        const SizedBox(height: Space.s),
        againBtn,
      ]);
    });
  }
}
