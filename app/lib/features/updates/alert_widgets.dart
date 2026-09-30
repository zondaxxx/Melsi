import 'package:flutter/widgets.dart';

import '../../state/app_state.dart';

/// Home rail: the "Внимание" rows (subscription expiring / exhausted, update
/// available). Stub: nothing.
class AlertRows extends StatelessWidget {
  const AlertRows({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Settings › App rows: the update-check switch (stub: none).
List<Widget> updateSettingsRows(BuildContext context, AppState app) => const [];

/// Settings › About rows: "Проверить обновления" (stub: none).
List<Widget> updateCheckRows(BuildContext context, AppState app) => const [];
