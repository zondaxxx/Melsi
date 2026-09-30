import 'package:flutter/widgets.dart';

/// Cold-start brand moment layered over the app (stub: passes the child
/// through; the onboarding feature implements it).
class LaunchVeil extends StatelessWidget {
  const LaunchVeil({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => child;
}
