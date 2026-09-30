import 'package:flutter/widgets.dart';

/// "Сессия 12:34 · ↓ 1.8 ГБ · ↑ 38 МБ" shown under the status headline for
/// a few seconds after a session ends (stub: nothing; the motion feature
/// implements it). Rendered in the headline's note slot only when the
/// headline has no note of its own.
class SessionSummaryNote extends StatelessWidget {
  const SessionSummaryNote({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
