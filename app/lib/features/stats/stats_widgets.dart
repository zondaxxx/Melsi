import 'package:flutter/widgets.dart';

import '../../state/app_state.dart';

/// Home: today's traffic and sessions (stub: nothing; the stats feature
/// implements it).
class TodayStatsCard extends StatelessWidget {
  const TodayStatsCard({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Settings › Tools rows: "Статистика" (stub: none).
List<Widget> statsRows(BuildContext context, AppState app) => const [];
