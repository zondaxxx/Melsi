import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/format.dart';
import 'rolling_number.dart';

/// "Сессия 12:34 · ↓ 1.8 ГБ · ↑ 38 МБ" under the status headline for a few
/// seconds after a session ends — the one glance back before the numbers
/// are gone. Rendered in the headline's note slot only when the headline
/// has no note of its own, so an error message always wins.
///
/// Sessions shorter than [minSession] say nothing: there is nothing to sum
/// up, and a failed attempt should not be congratulated. Shown for
/// [showFor]; a new connect hides it at once.
class SessionSummaryNote extends StatefulWidget {
  const SessionSummaryNote({super.key});

  static const Duration minSession = Duration(seconds: 30);
  static const Duration showFor = Duration(seconds: 6);

  /// Screens narrower than this drop the totals ("Сессия 12:34").
  static const double shortBelow = 340;

  @override
  State<SessionSummaryNote> createState() => SessionSummaryNoteState();
}

class SessionSummaryNoteState extends State<SessionSummaryNote> {
  late final AppState _app = context.appRead;

  /// Start of the session in progress, captured on connect (and refreshed
  /// on the way out, while the state still knows it).
  DateTime? _since;
  Timer? _hide;
  ({Duration length, int down, int up})? _summary;

  /// What is on screen (tests).
  ({Duration length, int down, int up})? get debugSummary => _summary;

  @override
  void initState() {
    super.initState();
    _app.statusHooks.add(_onStatus);
    // Mounted mid-session (Home is built once, at launch): remember it.
    if (_app.displayStatus == VpnStatus.connected) _since = _app.connectedAt;
  }

  @override
  void dispose() {
    _app.statusHooks.remove(_onStatus);
    _hide?.cancel();
    super.dispose();
  }

  void _onStatus(VpnStatus prev, VpnStatus next) {
    if (!mounted) return;
    // A seamless re-apply restarts the tunnel underneath a "connected" UI:
    // not a session end, and not a new session either.
    if (_app.applying) return;
    switch (next) {
      case VpnStatus.connecting:
        _since = null;
        _dismiss();
      case VpnStatus.connected:
        _since = _app.connectedAt ?? DateTime.now();
      case VpnStatus.stopping:
        // Still known here; gone by the time `stopped` arrives.
        if (prev == VpnStatus.connected) _since = _app.connectedAt ?? _since;
      case VpnStatus.stopped:
        final since = _since;
        _since = null;
        if (since == null) return;
        final t = _app.traffic;
        final ended = t.lastStoppedAt ?? DateTime.now();
        final length = ended.difference(since);
        if (length < SessionSummaryNote.minSession) return;
        _show((length: length, down: t.lastDownTotal, up: t.lastUpTotal));
      case VpnStatus.error:
        _since = null;
        _dismiss();
    }
  }

  void _show(({Duration length, int down, int up}) s) {
    _hide?.cancel();
    setState(() => _summary = s);
    _hide = Timer(SessionSummaryNote.showFor, _dismiss);
  }

  void _dismiss() {
    _hide?.cancel();
    _hide = null;
    if (_summary != null && mounted) setState(() => _summary = null);
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    if (s == null) return const SizedBox.shrink();
    final l = context.l;
    final t = formatDuration(s.length);
    final style = context.t.footnote;
    final full = l('motion.summary', {
      't': t,
      'down': formatBytes(s.down, l: l),
      'up': formatBytes(s.up, l: l),
    });
    final short = l('motion.summary.short', {'t': t});
    return LayoutBuilder(builder: (context, box) {
      // Narrow screens — and large accessibility text — drop the totals
      // rather than squeeze them: measured, not guessed.
      final screen = MediaQuery.sizeOf(context).width;
      final text = screen < SessionSummaryNote.shortBelow || !_fits(context, full, style, box.maxWidth)
          ? short
          : full;
      // The slot's AnimatedSize opens the row; this fades the text into it.
      return _FadeIn(
        child: Padding(
          padding: const EdgeInsets.only(top: Space.xs),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: MonoNumber(text, style: style, semanticsLabel: text),
          ),
        ),
      );
    });
  }

  static bool _fits(BuildContext context, String text, TextStyle style, double width) {
    if (!width.isFinite) return true;
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final fits = p.width <= width;
    p.dispose();
    return fits;
  }
}

/// One-shot fade on mount. Under reduced motion it is the 160 ms cross-fade
/// every other state change uses.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: context.reduceMotion ? 160 : 220),
        curve: Curves.easeOut,
        child: child,
        builder: (context, v, child) => Opacity(opacity: v, child: child),
      );
}
