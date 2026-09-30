import 'package:flutter/widgets.dart';

import '../../state/app_state.dart';

/// Home: "Где я" — real IP vs tunnel exit with a leak verdict (stub:
/// nothing; the netcheck feature implements it).
class IpGeoPanel extends StatelessWidget {
  const IpGeoPanel({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Settings › App rows: the IP-check switch (stub: none).
List<Widget> ipCheckRows(BuildContext context, AppState app) => const [];
