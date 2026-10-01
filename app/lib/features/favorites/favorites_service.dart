import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;

import '../../core/models.dart';
import '../../state/app_state.dart';
import '../../state/commands.dart';
import '../../state/feature_service.dart';
import '../../ui/widgets/common.dart' show nodeTitle;

/// Palette group the server commands live in (owned by the palette table).
const String kServersCommandGroup = 'palette.g.servers';

/// Keeps the command palette in sync with the pinned servers: one
/// "pin / unpin current" toggle and one "switch to …" command per
/// favourite. The data itself lives in [AppState.favouriteIds]; this
/// service only mirrors it into the [CommandRegistry].
///
/// [Features] has no slot for a favourites service, so [ClipboardWatcher]
/// (the other half of this package) owns one instance and forwards its
/// lifecycle — see `features.clipboard.favorites`.
class FavoritesService extends FeatureService {
  FavoritesService(super.app, super.features);

  /// Prefix of every per-favourite command id.
  static const pickPrefix = 'fav.pick.';

  /// Id of the "pin / unpin the current server" command.
  static const toggleId = 'fav.toggleCurrent';

  List<String> _registered = const [];
  bool _listening = false;

  @override
  Future<void> load() async {
    if (!_listening) {
      app.addListener(_sync);
      _listening = true;
    }
    features.commands.register(AppCommand(
      id: toggleId,
      titleKey: 'fav.toggleCmd',
      group: kServersCommandGroup,
      icon: Icons.star_outline_rounded,
      keywords: const ['favourite', 'favorite', 'pin', 'избранное', 'закрепить'],
      isOn: () {
        final n = app.selectedNode;
        return n != null && app.isFavourite(n.id);
      },
      run: (_) async => toggleCurrent(),
    ));
    _registered = const [];
    _sync();
  }

  /// Pins or unpins the currently selected server.
  void toggleCurrent() {
    final n = app.selectedNode;
    if (n != null) app.toggleFavourite(n.id);
  }

  /// Re-registers the per-favourite commands when the pinned set (or the
  /// order) changed. Cheap enough to run on every app notification.
  void _sync() {
    final ids = app.favouriteIds;
    if (listEquals(ids, _registered)) return;
    features.commands.unregisterPrefix(pickPrefix);
    features.commands.registerAll([
      for (final n in app.favouriteNodes) _pick(n),
    ]);
    _registered = List.of(ids);
    notifyListeners();
  }

  AppCommand _pick(ProxyNode n) => AppCommand(
        id: '$pickPrefix${n.id}',
        // No l10n key carries a server name: [L10n] returns an unknown key
        // verbatim, so the node title doubles as the (untranslatable) key.
        titleKey: nodeTitle(n),
        subtitle: '${n.protocol.label} · ${n.server}',
        group: kServersCommandGroup,
        icon: Icons.star_rounded,
        keywords: [n.name, n.server, n.protocol.label, 'favourite', 'избранное'],
        run: (_) => app.selectNode(n.id),
      );

  @override
  void dispose() {
    if (_listening) app.removeListener(_sync);
    _listening = false;
    features.commands.unregisterPrefix(pickPrefix);
    features.commands.unregister(toggleId);
    super.dispose();
  }
}
