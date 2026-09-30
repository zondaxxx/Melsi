import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';

/// Shows the first-run onboarding instead of [child] until
/// `settings.onboardingDone` (stub: passes the child through; the
/// onboarding feature implements it).
class OnboardingGate extends StatelessWidget {
  const OnboardingGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Settings › App rows: "Показать вступление снова" (stub: none).
List<Widget> onboardingReplayRows(BuildContext context, AppState app) {
  // ignore: unused_local_variable
  final L10n l = context.l;
  return const [];
}
