import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../ui/shell.dart' show Wordmark;
import '../../ui/theme/surfaces.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/import_panel.dart';
import 'launch_veil.dart' show DrawnHairline, LaunchVeilScope;

/// First-run flow: a brand moment (step 0) that settles into what Melsi
/// does (step 1), then adding a server (step 2) and one launch preference
/// (step 3). Calls [onDone] when the person opens the app; the gate marks
/// onboarding done and swaps the shell in.
///
/// Steps 0 and 1 are one page — the wordmark of the brand moment lifts and
/// the copy appears beneath it, so the story is continuous rather than a
/// slide. Steps 2 and 3 slide in (24px + fade on a spring).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  /// 0 brand moment · 1 features · 2 add a server · 3 almost there.
  int _step = 0;

  final _intro = GlobalKey<_IntroStepState>();

  /// Servers added on step 2 (via the panel or a deep link meanwhile).
  int _added = 0;
  int _baseline = 0;

  StreamSubscription<Notice>? _notices;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // No shell yet, so nobody else would surface import errors.
    _notices ??= context.appRead.notices.listen(_showNotice);
  }

  @override
  void dispose() {
    _notices?.cancel();
    super.dispose();
  }

  void _go(int step) {
    if (step == _step) return;
    setState(() {
      if (step == 2) _baseline = context.appRead.nodes.length;
      _step = step;
    });
  }

  void _onImported(int n) {
    if (n <= 0) return;
    setState(() => _added += n);
  }

  /// The one notice the collapsed panel already tells; everything else
  /// (unsupported link, nothing found, empty clipboard) needs a voice.
  void _showNotice(Notice n) {
    if (!mounted || n.key == 'notice.imported') return;
    final l = context.l;
    final c = context.c;
    var text = l(n.key, n.args);
    if (n.detail != null && n.detail!.isNotEmpty) text = '$text\n${n.detail}';
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      margin: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
      duration: Duration(seconds: n.kind == NoticeKind.error ? 5 : 3),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: StatusDot(switch (n.kind) {
              NoticeKind.success => c.success,
              NoticeKind.error => c.danger,
              NoticeKind.info => c.isDark ? c.secondaryLabel : c.background.withValues(alpha: 0.6),
            }),
          ),
          const SizedBox(width: Space.m),
          Expanded(child: Text(text, maxLines: 6, overflow: TextOverflow.ellipsis)),
        ],
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = context.app;
    // A deep link during step 2 lands servers without the panel: count them.
    final added = _step == 2 ? (app.nodes.length - _baseline).clamp(_added, 1 << 30) : _added;

    final pages = <Widget>[
      _IntroStep(
        key: _intro,
        onAdvance: () => _go(1),
        onNext: () => _go(2),
        onSkip: widget.onDone,
      ),
      _AddStep(
        key: const ValueKey('onboarding-add'),
        added: added,
        onImported: _onImported,
        onNext: () => _go(3),
      ),
      _FinishStep(
        key: const ValueKey('onboarding-finish'),
        connectOnLaunch: app.settings.connectOnLaunch,
        onConnectOnLaunch: (v) =>
            app.updateSettings((s) => s.connectOnLaunch = v, affectsConfig: false),
        onOpen: widget.onDone,
      ),
    ];

    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                // Progress lives above the story; it appears with the copy.
                Padding(
                  padding: const EdgeInsets.only(top: Space.l),
                  child: AnimatedOpacity(
                    duration: Duration(milliseconds: context.reduceMotion ? 160 : 240),
                    curve: Curves.easeOut,
                    opacity: _step >= 1 ? 1 : 0,
                    child: Semantics(
                      label: '${_step.clamp(1, 3)} / 3',
                      child: _Dots(index: _step.clamp(1, 3) - 1),
                    ),
                  ),
                ),
                Expanded(
                  child: _StepSwitcher(
                    index: _step <= 1 ? 0 : _step - 1,
                    children: [for (final p in pages) _StepPage(child: p)],
                  ),
                ),
              ],
            ),
            // Step 0: the whole screen is the "skip" target, and nothing
            // underneath is interactive until the moment is over. A sibling
            // rather than a wrapper, so removing it never re-creates the
            // page (which would restart its reveal).
            if (_step == 0)
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('onboarding-skip'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _intro.currentState?.hurry(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- layout

/// One centred column (480px, 520 on wide) with 16px gutters, scrollable
/// when the keyboard or a short window squeezes it. Buttons inside keep
/// the column width on desktop rather than spanning the window.
class _StepPage extends StatelessWidget {
  const _StepPage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final maxWidth = context.isWide ? 520.0 : 480.0;
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: Space.xxl),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - 2 * Space.xxl)),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Three 4px dots; the active one springs to 14px wide.
class _Dots extends StatelessWidget {
  const _Dots({required this.index});
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: SpringValue(
              target: i == index ? 14 : 4,
              spring: Springs.momentum,
              builder: (context, v, _) => Container(
                width: v.clamp(2.0, 18.0),
                height: 4,
                decoration: BoxDecoration(
                  color: i == index ? c.label : c.fillStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Swaps pages with a 24px slide + fade on a spring (reduced motion: a
/// 160ms fade). The outgoing page is kept only while the transition runs,
/// so finders and hit tests never see two pages at rest.
class _StepSwitcher extends StatefulWidget {
  const _StepSwitcher({required this.index, required this.children});
  final int index;
  final List<Widget> children;

  @override
  State<_StepSwitcher> createState() => _StepSwitcherState();
}

class _StepSwitcherState extends State<_StepSwitcher> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: 1)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && _previous != null) setState(() => _previous = null);
    });
  late int _current = widget.index;
  int? _previous;

  @override
  void didUpdateWidget(_StepSwitcher old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    _previous = _current;
    _current = widget.index;
    _c.value = 0;
    _c.springTo(1, spring: Springs.of(0.45, 1.0), reduceMotion: context.reduceMotion);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value.clamp(0.0, 1.0);
        final prev = _previous;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (prev != null)
              IgnorePointer(
                child: ExcludeSemantics(
                  child: Opacity(
                    opacity: 1 - t,
                    child: Transform.translate(
                      offset: Offset(reduce ? 0 : -24 * t, 0),
                      child: widget.children[prev],
                    ),
                  ),
                ),
              ),
            Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(reduce ? 0 : 24 * (1 - t), 0),
                child: widget.children[_current],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Fade + 8px rise on a spring once [show] turns true, after [delay]
/// (the stagger). Reduced motion: appears in place.
class _Rise extends StatefulWidget {
  const _Rise({required this.show, required this.child, this.delay = Duration.zero});
  final bool show;
  final Duration delay;
  final Widget child;

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: 0);
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.show) _start();
  }

  @override
  void didUpdateWidget(_Rise old) {
    super.didUpdateWidget(old);
    if (widget.show && !old.show) _start();
  }

  void _start() {
    if (_started) return;
    _started = true;
    if (context.reduceMotion) {
      _c.value = 1;
      return;
    }
    if (widget.delay == Duration.zero) {
      _c.springTo(1, spring: Springs.of(0.42, 1.0));
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) _c.springTo(1, spring: Springs.of(0.42, 1.0));
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          final v = _c.value.clamp(0.0, 1.0);
          return Opacity(
            opacity: v,
            child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child),
          );
        },
      );
}

/// Scale 0→1 on a momentum spring (the check mark). Reduced: static.
class _PopIn extends StatefulWidget {
  const _PopIn({required this.child});
  final Widget child;

  @override
  State<_PopIn> createState() => _PopInState();
}

class _PopInState extends State<_PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this, value: 0);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (context.reduceMotion) {
      _c.value = 1;
    } else {
      _c.springTo(1, spring: Springs.momentum);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) =>
            Transform.scale(scale: _c.value.clamp(0.0, 1.3), child: child),
      );
}

/// Page title (steps 2 and 3).
class _StepTitle extends StatelessWidget {
  const _StepTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        child: Text(text, style: context.t.title2, textAlign: TextAlign.center),
      );
}

/// Quiet secondary action under a primary button ("Пропустить", "Позже").
class _QuietButton extends StatelessWidget {
  const _QuietButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: context.c.secondaryLabel,
          minimumSize: const Size(44, 40),
          padding: const EdgeInsets.symmetric(horizontal: Space.l),
        ),
        child: Text(label, style: context.t.subhead.copyWith(color: context.c.secondaryLabel)),
      );
}

// ------------------------------------------------------------ steps 0 + 1

const _kIntroMs = 900.0;
const _kIntroLineStartMs = 120.0;
const _kIntroLineEndMs = 540.0;
const _kIntroRevealMs = 480.0;

/// The brand moment and the feature list, one page. A 900ms timeline: the
/// hairline draws 120–540ms, at 480ms the wordmark lifts 28px on a spring
/// and the copy rises beneath it (staggered 60ms), at 900ms the page counts
/// as step 1 ([onAdvance]). Any tap before that hurries it. It waits for a
/// launch veil above it to lift so two brand moments never overlap.
class _IntroStep extends StatefulWidget {
  const _IntroStep({
    super.key,
    required this.onAdvance,
    required this.onNext,
    required this.onSkip,
  });

  final VoidCallback onAdvance;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  State<_IntroStep> createState() => _IntroStepState();
}

class _IntroStepState extends State<_IntroStep> with TickerProviderStateMixin {
  late final AnimationController _timeline =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..addListener(_onTick)
        ..addStatusListener(_onStatus);

  /// 0→1: wordmark lift (normal) or whole-page fade-in (reduced motion).
  late final AnimationController _lift = AnimationController.unbounded(vsync: this, value: 0);

  bool _started = false;
  bool _revealed = false;
  bool _reduce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || LaunchVeilScope.activeOf(context)) return;
    _started = true;
    // A tap while the veil was still lifting may have hurried it already.
    if (_timeline.isCompleted) return;
    _reduce = context.reduceMotion;
    if (_reduce) {
      // Straight to step 1 behind a short fade; no draw, no lift.
      _revealed = true;
      _lift.animateTo(1, duration: const Duration(milliseconds: 160), curve: Curves.easeOut);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onAdvance();
      });
      return;
    }
    _timeline.forward();
  }

  void _onTick() {
    if (!_revealed && _timeline.value * _kIntroMs >= _kIntroRevealMs) _reveal();
  }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) widget.onAdvance();
  }

  void _reveal() {
    if (_revealed) return;
    setState(() => _revealed = true);
    _lift.springTo(1, spring: Springs.of(0.5, 0.9));
  }

  /// Tap anywhere on step 0: finish the moment now.
  void hurry() {
    if (_timeline.isCompleted) return;
    _timeline.stop();
    _timeline.value = 1; // draws the line, reveals, fires completed → advance
  }

  @override
  void dispose() {
    _timeline.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    final narrow = MediaQuery.sizeOf(context).width < 360;

    final features = [
      (Icons.auto_awesome_outlined, l('onboard.f1'), l('onboard.f1d')),
      (Icons.sports_esports_outlined, l('onboard.f2'), l('onboard.f2d')),
      (Icons.alt_route_rounded, l('onboard.f3'), l('onboard.f3d')),
    ];

    Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wordmark + its hairline, lifted 28px once the copy is revealed.
        AnimatedBuilder(
          animation: Listenable.merge([_timeline, _lift]),
          builder: (context, child) {
            final ms = _timeline.value * _kIntroMs;
            final line = Curves.easeOutCubic
                .transform(((ms - _kIntroLineStartMs) / (_kIntroLineEndMs - _kIntroLineStartMs))
                    .clamp(0.0, 1.0));
            final lift = _reduce ? 0.0 : _lift.value;
            return Transform.translate(
              offset: Offset(0, -28 * lift),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wordmark(size: narrow ? 30 : 34),
                  const SizedBox(height: Space.m),
                  DrawnHairline(
                    progress: _reduce ? 1 : line,
                    width: 56,
                    color: c.label.withValues(alpha: 0.3),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: Space.x3),
        for (final (i, f) in features.indexed)
          _Rise(
            show: _revealed,
            delay: Duration(milliseconds: 60 * i),
            child: Padding(
              padding: EdgeInsets.only(bottom: i < features.length - 1 ? Space.xl : 0),
              child: _FeatureLine(icon: f.$1, title: f.$2, text: f.$3),
            ),
          ),
        const SizedBox(height: Space.x4),
        _Rise(
          show: _revealed,
          delay: const Duration(milliseconds: 180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PrimaryButton(
                key: const ValueKey('onboarding-next'),
                label: l('onboard.next'),
                expand: true,
                onTap: _revealed ? widget.onNext : null,
              ),
              const SizedBox(height: Space.s),
              Center(child: _QuietButton(label: l('onboard.skip'), onTap: widget.onSkip)),
            ],
          ),
        ),
      ],
    );

    if (_reduce) {
      body = AnimatedBuilder(
        animation: _lift,
        child: body,
        builder: (context, child) => Opacity(opacity: _lift.value.clamp(0.0, 1.0), child: child),
      );
    }

    return body;
  }
}

/// One feature: 20px icon, headline, two-line footnote.
class _FeatureLine extends StatelessWidget {
  const _FeatureLine({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 20, color: c.tertiaryLabel),
        ),
        const SizedBox(width: Space.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.headline, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(text, style: t.footnote, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ step 2

/// Add a server: the shared import panel, which collapses into a one-line
/// confirmation once something was added. "Позже" until then, "Далее" after.
class _AddStep extends StatelessWidget {
  const _AddStep({
    super.key,
    required this.added,
    required this.onImported,
    required this.onNext,
  });
  final int added;
  final ValueChanged<int> onImported;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepTitle(l('onboard.addTitle')),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: added > 0
              ? _AddedPanel(key: const ValueKey('onboarding-added'), n: added)
              : ImportPanel(
                  key: const ValueKey('onboarding-import'),
                  fieldKey: const ValueKey('onboarding-link-field'),
                  submitKey: const ValueKey('onboarding-submit'),
                  onImported: onImported,
                ),
        ),
        const SizedBox(height: Space.xxl),
        if (added > 0)
          PrimaryButton(
            key: const ValueKey('onboarding-next-2'),
            label: l('onboard.next'),
            expand: true,
            onTap: onNext,
          )
        else
          Center(
            child: _QuietButton(
              key: const ValueKey('onboarding-later'),
              label: l('onboard.later'),
              onTap: onNext,
            ),
          ),
      ],
    );
  }
}

/// "Добавлено: 3 сервера" with a check that pops in.
class _AddedPanel extends StatelessWidget {
  const _AddedPanel({super.key, required this.n});
  final int n;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final l = context.l;
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.m),
      child: Row(
        children: [
          _PopIn(child: Icon(Icons.check_circle_rounded, size: 20, color: c.success)),
          const SizedBox(width: Space.m),
          Expanded(
            child: Text(
              l('onboard.added', {'n': l.plural(n, 'onboard.added')}),
              style: context.t.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ step 3

/// Almost there: one launch preference and the door into the app. No VPN
/// permission is requested here — the note says the system will ask on the
/// first connect, where the request makes sense.
class _FinishStep extends StatelessWidget {
  const _FinishStep({
    super.key,
    required this.connectOnLaunch,
    required this.onConnectOnLaunch,
    required this.onOpen,
  });
  final bool connectOnLaunch;
  final ValueChanged<bool> onConnectOnLaunch;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepTitle(l('onboard.finishTitle')),
        GroupCard(children: [
          SwitchRow(
            key: ValueKey(l('settings.connectOnLaunch')),
            title: l('settings.connectOnLaunch'),
            value: connectOnLaunch,
            onChanged: onConnectOnLaunch,
          ),
        ]),
        SectionFooter(l('onboard.permNote')),
        const SizedBox(height: Space.x4),
        PrimaryButton(
          key: const ValueKey('onboarding-open'),
          label: l('onboard.open'),
          expand: true,
          onTap: onOpen,
        ),
      ],
    );
  }
}
