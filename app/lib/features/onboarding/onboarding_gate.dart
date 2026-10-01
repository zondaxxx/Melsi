import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/l10n.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import 'onboarding_screen.dart';

/// Shows the first-run onboarding instead of [child] until it is finished.
///
/// The decision is made once, when the gate mounts: onboarding is shown to
/// a fresh install only (`onboardingDone` false *and* no servers). Someone
/// upgrading with servers already in place is marked done silently and lands
/// in the app. A deep link that arrives at launch is handled the same way by
/// `main.dart`. The gate keeps its own flag rather than watching the setting
/// because importing a server on step 2 flips `onboardingDone` in the state
/// (anyone with servers counts as onboarded) — the flow must still finish.
/// [replay] re-shows it on request even when servers exist.
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key, required this.child});
  final Widget child;

  /// Re-runs the onboarding from Settings ("Показать приветствие").
  static void replay(BuildContext context) =>
      context.findAncestorStateOfType<_OnboardingGateState>()?._replay();

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  late bool _onboarding;
  late final AppState _app;
  late int _revision;

  @override
  void initState() {
    super.initState();
    final app = context.appRead;
    _app = app;
    _revision = app.onboardingRevision;
    app.addListener(_onAppChanged);
    final done = app.settings.onboardingDone;
    _onboarding = !done && app.nodes.isEmpty;
    if (!done && !_onboarding) {
      // Upgrade: servers exist, nothing to onboard about. Persist after the
      // first frame — the state must not notify while the tree is building.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _markDone(app);
      });
    }
  }

  void _onAppChanged() {
    if (_revision == _app.onboardingRevision) return;
    _revision = _app.onboardingRevision;
    if (_onboarding) setState(() => _onboarding = false);
  }

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    super.dispose();
  }

  void _markDone(AppState app) {
    if (app.settings.onboardingDone) return;
    app.updateSettings((s) => s.onboardingDone = true, affectsConfig: false);
  }

  void _finish() {
    _markDone(context.appRead);
    setState(() => _onboarding = false);
  }

  void _replay() {
    if (_onboarding) return;
    // With servers present the state flips this straight back to true (see
    // AppState._changed); the gate's own flag is what re-shows the flow.
    context.appRead.updateSettings((s) => s.onboardingDone = false, affectsConfig: false);
    setState(() => _onboarding = true);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = context.reduceMotion;
    return AnimatedSwitcher(
      duration: Duration(milliseconds: reduce ? 160 : 300),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
      child: _onboarding
          ? OnboardingScreen(key: const ValueKey('onboarding'), onDone: _finish)
          : KeyedSubtree(key: const ValueKey('shell'), child: widget.child),
    );
  }
}

/// Settings › App rows: "Показать приветствие" — replays the onboarding.
List<Widget> onboardingReplayRows(BuildContext context, AppState app) {
  final L10n l = context.l;
  return [
    RowTile(
      key: const ValueKey('onboarding-replay'),
      title: l('onboard.replay'),
      chevron: true,
      onTap: () => OnboardingGate.replay(context),
    ),
  ];
}
