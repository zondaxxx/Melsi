import 'package:flutter/widgets.dart';

import '../../services/vpn_controller.dart';
import '../../ui/theme/tokens.dart';

/// The route line under the connect button: draws itself while connecting,
/// completes on connected. Stub: the 20px gap the layout always had; the
/// motion feature implements the line inside the same 20px box.
class RouteLine extends StatelessWidget {
  const RouteLine({super.key, required this.status});
  final VpnStatus status;

  /// Total height, so Home's layout never jumps.
  static const double height = Space.xl;

  @override
  Widget build(BuildContext context) => const SizedBox(height: height);
}
