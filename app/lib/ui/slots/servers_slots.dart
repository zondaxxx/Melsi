// Extension points of the Servers screen and the quick switcher.

import 'package:flutter/widgets.dart';

import '../../core/models.dart';
import '../../features/chain/chain_widgets.dart';
import '../../features/clipboard/clipboard_offer.dart';
import '../../features/favorites/favorites_widgets.dart';
import '../../state/app_state.dart';

abstract final class ServersSlots {
  /// Slivers right after the search bar, before the subscription groups.
  /// [filtering]: the user is searching / filtering, so pinned blocks hide.
  static List<Widget> beforeGroups(BuildContext context, AppState app, {bool filtering = false}) =>
      favoritesSlivers(context, app, filtering: filtering);

  /// Trailing widget in a node row, before the latency chip.
  static Widget nodeTrailing(BuildContext context, ProxyNode node) => FavoriteStar(node: node);

  /// Extra rows in the node actions sheet, after "Переименовать".
  static List<Widget> nodeActions(BuildContext context, ProxyNode node, VoidCallback close) => [
        ...favoriteActionRows(context, node, close),
        ...chainActionRows(context, node, close),
      ];

  /// Under the buttons of the empty state.
  static Widget emptyHint(BuildContext context) => const ClipboardEmptyHint();
}

abstract final class SwitcherSlots {
  /// Blocks at the top of the switcher list (after the smart-select card).
  static List<Widget> top(BuildContext context, AppState app) => switcherTopBlocks(context, app);
}
