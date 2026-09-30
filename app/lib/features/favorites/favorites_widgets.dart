import 'package:flutter/widgets.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';

/// Servers page: favourites / recents block (slivers) above the groups
/// (stub: none).
List<Widget> favoritesSlivers(BuildContext context, AppState app) => const [];

/// Node row trailing: the pin star (stub: nothing).
class FavoriteStar extends StatelessWidget {
  const FavoriteStar({super.key, required this.node});
  final ProxyNode node;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Node actions sheet: "В избранное" / "Убрать из избранного" (stub: none).
List<Widget> favoriteActionRows(BuildContext context, ProxyNode node, VoidCallback close) =>
    const [];

/// Quick switcher: favourites + recents block and the best-by-country strip
/// at the top of the list (stub: none).
List<Widget> switcherTopBlocks(BuildContext context, AppState app) => const [];
