import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../ui/theme/pressable.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';

/// Height of the shell's tab bar (`_ShellState._barHeight`, private). The
/// host wraps the shell's scaffold, so [ShellInsets] is not an ancestor
/// here and the bar has to be measured the same way the shell does.
const double _kTabBarHeight = 54;

/// How long an offer stays on screen before it dismisses itself.
const Duration kClipboardOfferTimeout = Duration(seconds: 8);

/// Wraps the shell with the "import from clipboard?" toast. It floats over
/// the page — bottom on phones (clear of the tab bar), top-right on wide
/// layouts — and never takes focus or blocks the rest of the screen.
class ClipboardOfferHost extends StatefulWidget {
  const ClipboardOfferHost({super.key, required this.child});
  final Widget child;

  @override
  State<ClipboardOfferHost> createState() => _ClipboardOfferHostState();
}

class _ClipboardOfferHostState extends State<ClipboardOfferHost> {
  ClipboardWatcher? _watcher;
  ClipboardOffer? _shown;
  bool _visible = false;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final w = FeaturesScope.maybeOf(context)?.clipboard;
    if (identical(w, _watcher)) return;
    _watcher?.removeListener(_changed);
    _watcher = w?..addListener(_changed);
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _watcher?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(_sync);
  }

  /// Mirrors the watcher's offer: (re)arms the auto-dismiss on a new
  /// offer, keeps the last content while the toast springs out.
  void _sync() {
    final o = _watcher?.offer;
    if (!identical(o, _shown) || (o == null) == _visible) {
      _timer?.cancel();
      _timer = o == null ? null : Timer(kClipboardOfferTimeout, () => _watcher?.dismiss());
    }
    if (o != null) _shown = o;
    _visible = o != null;
  }

  @override
  Widget build(BuildContext context) {
    final w = _watcher;
    if (w == null) return widget.child;
    final wide = context.isWide;
    final pad = MediaQuery.paddingOf(context);
    final toast = _OfferToast(
      offer: _shown,
      visible: _visible,
      onAdd: () {
        HapticFeedback.mediumImpact();
        w.accept();
      },
      onClose: w.dismiss,
    );
    return Stack(children: [
      widget.child,
      if (wide)
        Positioned(
          top: pad.top + Space.l,
          right: pad.right + Space.l,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: toast),
        )
      else
        Positioned(
          left: pad.left + Space.l,
          right: pad.right + Space.l,
          bottom: pad.bottom + _kTabBarHeight + Space.xl,
          child: toast,
        ),
    ]);
  }
}

/// The toast: raised surface, hairline, paste glyph, one line of copy, the
/// accent "Добавить" and a quiet close. Springs 14px up while fading in;
/// reduced motion fades only.
class _OfferToast extends StatelessWidget {
  const _OfferToast({
    required this.offer,
    required this.visible,
    required this.onAdd,
    required this.onClose,
  });
  final ClipboardOffer? offer;
  final bool visible;
  final VoidCallback onAdd;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final o = offer;
    if (o == null) return const SizedBox.shrink();
    final reduce = context.reduceMotion;
    return IgnorePointer(
      ignoring: !visible,
      child: SpringValue(
        target: visible ? 1 : 0,
        spring: Springs.of(0.42, 0.82),
        builder: (context, v, child) {
          final t = v.clamp(0.0, 1.0);
          if (t <= 0.001) return const SizedBox.shrink();
          return Opacity(
            opacity: (t * 1.6).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, reduce ? 0 : (1 - v) * 14),
              child: child,
            ),
          );
        },
        child: Semantics(
          liveRegion: true,
          child: _OfferCard(offer: o, onAdd: onAdd, onClose: onClose),
        ),
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.offer, required this.onAdd, required this.onClose});
  final ClipboardOffer offer;
  final VoidCallback onAdd;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    return DecoratedBox(
      key: const ValueKey('clipboard-offer'),
      decoration: ShapeDecoration(
        color: c.surfaceRaised,
        shape: Radii.shape(Radii.m, side: BorderSide(color: c.separator, width: kHairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, Space.s),
        child: Row(children: [
          Icon(Icons.content_paste_rounded, size: 18, color: c.secondaryLabel),
          const SizedBox(width: Space.m),
          Expanded(
            child: Text(
              offerText(l, offer),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.t.subhead.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: Space.m),
          _AddButton(label: l('clip.add'), onTap: onAdd),
          const SizedBox(width: Space.xs),
          PressableScale(
            scale: 0.85,
            semanticLabel: l('clip.close'),
            onTap: onClose,
            child: SizedBox.square(
              dimension: 32,
              child: Icon(Icons.close_rounded, size: 18, color: c.secondaryLabel),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The toast's one accent action. A [PrimaryButton] is 44px with a 20px
/// gutter — too much for a one-line toast — so this is the same solid
/// accent pill at toast scale.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return PressableScale(
      key: const ValueKey('clipboard-offer-add'),
      onTap: onTap,
      haptic: true,
      scale: 0.96,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: Space.l),
        alignment: Alignment.center,
        decoration: ShapeDecoration(color: c.accent, shape: Radii.shape(Radii.m - 2)),
        child: Text(label,
            style: context.t.subhead.copyWith(color: c.onAccent, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// Copy for an offer: what was found, not what to do.
String offerText(L10n l, ClipboardOffer o) => switch (o.kind) {
      ClipboardOfferKind.link => l('clip.link'),
      ClipboardOfferKind.subscription => l('clip.sub', {'host': o.host ?? '…'}),
      ClipboardOfferKind.many => l('clip.many', {'n': l.plural(o.count, 'clip.many')}),
    };

/// Servers empty state: a footnote under the buttons while an offer is
/// pending — "Нашли ссылку в буфере — Добавить".
class ClipboardEmptyHint extends StatefulWidget {
  const ClipboardEmptyHint({super.key});

  @override
  State<ClipboardEmptyHint> createState() => _ClipboardEmptyHintState();
}

class _ClipboardEmptyHintState extends State<ClipboardEmptyHint> {
  late final _tap = TapGestureRecognizer()..onTap = _add;

  void _add() {
    final w = FeaturesScope.maybeOf(context)?.clipboard;
    if (w == null) return;
    HapticFeedback.mediumImpact();
    w.accept();
  }

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = FeaturesScope.maybeOf(context)?.clipboard;
    if (w == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) {
        final o = w.offer;
        final l = context.l;
        return AnimatedSwitcher(
          duration: context.reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
          child: o == null
              ? const SizedBox.shrink()
              : Padding(
                  key: const ValueKey('clipboard-hint'),
                  padding: const EdgeInsets.only(top: Space.l),
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: l('clip.hint')),
                      TextSpan(
                        text: l('clip.add'),
                        recognizer: _tap,
                        style: TextStyle(color: context.c.label, fontWeight: FontWeight.w600),
                      ),
                    ]),
                    textAlign: TextAlign.center,
                    style: context.t.footnote,
                  ),
                ),
        );
      },
    );
  }
}

/// Settings › App rows: the clipboard watch switch.
List<Widget> clipboardSettingsRows(BuildContext context, AppState app) {
  final l = context.l;
  final w = FeaturesScope.maybeOf(context)?.clipboard;
  final on = w?.enabled ?? (app.settings.clipboardWatch ?? !app.isIOS);
  return [
    SwitchRow(
      title: l('clip.setting'),
      subtitle: l('clip.settingHint'),
      value: on,
      onChanged: (v) => app.updateSettings((s) => s.clipboardWatch = v, affectsConfig: false),
    ),
  ];
}
