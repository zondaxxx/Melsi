import 'package:flutter/widgets.dart';

import '../../ui/widgets/common.dart';

/// Status dot that breathes softly while [active] (stub: a plain
/// [StatusDot]; the motion feature implements the pulse).
class StatusPulse extends StatelessWidget {
  const StatusPulse({
    super.key,
    required this.color,
    this.size = 8,
    this.hollow = false,
    this.active = false,
  });
  final Color color;
  final double size;
  final bool hollow;
  final bool active;

  @override
  Widget build(BuildContext context) => StatusDot(color, size: size, hollow: hollow);
}
