import 'package:flutter/widgets.dart';

/// An action the command palette (and shortcuts) can run. [titleKey] is an
/// l10n key; [subtitle] is a resolved string (e.g. a server name).
class AppCommand {
  const AppCommand({
    required this.id,
    required this.titleKey,
    required this.group,
    required this.icon,
    required this.run,
    this.subtitle,
    this.keywords = const [],
    this.isOn,
  });

  final String id;
  final String titleKey;

  /// Grouping label key ("palette.group.servers" …).
  final String group;
  final IconData icon;
  final Future<void> Function(BuildContext context) run;
  final String? subtitle;

  /// Extra search terms (server host, protocol …).
  final List<String> keywords;

  /// For toggles: current state, shown as a switch glyph.
  final bool Function()? isOn;
}

/// Registry the palette reads. Features register at load and re-register
/// when their items change (servers, favourites …).
class CommandRegistry extends ChangeNotifier {
  final Map<String, AppCommand> _items = {};

  void register(AppCommand c) {
    _items[c.id] = c;
    notifyListeners();
  }

  void registerAll(Iterable<AppCommand> cs) {
    for (final c in cs) {
      _items[c.id] = c;
    }
    notifyListeners();
  }

  void unregister(String id) {
    if (_items.remove(id) != null) notifyListeners();
  }

  /// Drops every command whose id starts with [prefix].
  void unregisterPrefix(String prefix) {
    final before = _items.length;
    _items.removeWhere((k, _) => k.startsWith(prefix));
    if (_items.length != before) notifyListeners();
  }

  List<AppCommand> get all => List.unmodifiable(_items.values);
  AppCommand? byId(String id) => _items[id];
}
