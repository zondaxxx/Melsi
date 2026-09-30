import 'package:flutter/widgets.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';

/// Home: the "entry → exit" line under the server card when the double VPN
/// is active (stub: nothing).
class ChainLine extends StatelessWidget {
  const ChainLine({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Settings: the "Double VPN" section (slivers) after the probe section
/// (stub: none).
List<Widget> chainSettingsSlivers(BuildContext context, AppState app) => const [];

/// Node actions sheet: "Сделать входным сервером" rows (stub: none).
/// [close] pops the sheet.
List<Widget> chainActionRows(BuildContext context, ProxyNode node, VoidCallback close) =>
    const [];
