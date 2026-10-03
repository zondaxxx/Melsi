// Extension points of the Home screen. The screen calls these at fixed
// places; feature modules fill the widgets behind them. Nobody edits
// home_screen.dart to add a feature.

import 'package:flutter/widgets.dart';

import '../../features/chain/chain_widgets.dart';
import '../../features/motion/route_line.dart';
import '../../features/motion/session_summary.dart';
import '../../features/netcheck/ip_geo_panel.dart';
import '../../features/netcheck/speed_test_widgets.dart';
import '../../features/stats/stats_widgets.dart';
import '../../features/updates/alert_widgets.dart';
import '../../state/app_state.dart';

abstract final class HomeSlots {
  /// Between the connect button and the "Сервер" header (fixed 20px tall).
  static Widget underButton(BuildContext context, AppState app) =>
      RouteLine(status: app.displayStatus);

  /// Right after the server card.
  static Widget afterNodePanel(BuildContext context, AppState app) => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [IpGeoPanel()],
      );

  static Widget connectionRoute(BuildContext context, AppState app) => const ChainLine();

  /// After the traffic card (inside the session-only block).
  static Widget afterTraffic(BuildContext context, AppState app) => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [SpeedTestPanel(), TodayStatsCard()],
      );

  /// Top of the quick-settings rail.
  static Widget railTop(BuildContext context, AppState app) => const AlertRows();

  /// Under the status headline when it has no note of its own.
  static Widget statusNote(BuildContext context, AppState app) => const SessionSummaryNote();
}
