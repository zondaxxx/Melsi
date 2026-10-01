// Extension points of the Settings screen (see home_slots.dart).

import 'package:flutter/widgets.dart';

import '../../features/backup/backup_widgets.dart';
import '../../features/chain/chain_widgets.dart';
import '../../features/clipboard/clipboard_offer.dart';
import '../../features/doctor/doctor_widgets.dart';
import '../../features/netcheck/ip_geo_panel.dart';
import '../../features/onboarding/onboarding_gate.dart';
import '../../features/stats/stats_widgets.dart';
import '../../features/updates/alert_widgets.dart';
import '../../state/app_state.dart';

abstract final class SettingsSlots {
  /// Slivers after the "Проверка сервера" group.
  static List<Widget> afterSmart(BuildContext context, AppState app) =>
      chainSettingsSlivers(context, app);

  /// Rows appended to the "Приложение" group.
  static List<Widget> appRows(BuildContext context, AppState app) => [
        ...clipboardSettingsRows(context, app),
        ...ipCheckRows(context, app),
        ...updateSettingsRows(context, app),
        ...onboardingReplayRows(context, app),
      ];

  /// Rows appended to the "Инструменты" group.
  static List<Widget> toolsRows(BuildContext context, AppState app) => [
        ...statsRows(context, app),
        ...backupRows(context, app),
        ...doctorRows(context, app),
      ];

  /// Rows appended to the "О программе" group.
  static List<Widget> aboutRows(BuildContext context, AppState app) =>
      updateCheckRows(context, app);
}
