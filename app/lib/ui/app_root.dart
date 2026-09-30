import 'package:flutter/widgets.dart';

import '../features/onboarding/launch_veil.dart';
import '../features/onboarding/onboarding_gate.dart';
import 'shell.dart';

/// The app's home: launch moment over the onboarding gate over the shell.
/// [launchMoment] false skips the cold-start animation (tests, screenshots).
class AppRoot extends StatelessWidget {
  const AppRoot({super.key, this.launchMoment = true});
  final bool launchMoment;

  @override
  Widget build(BuildContext context) => LaunchVeil(
        enabled: launchMoment,
        child: const OnboardingGate(child: Shell()),
      );
}
