import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import 'strings.dart';

/// Map-based localisation. Russian is the default; English is complete.
/// Usage: `context.l('home.connect')`, `context.l('n.nodes', {'n': '3'})`.
class L10n {
  const L10n(this.locale);
  final String locale;

  static const supported = ['ru', 'en'];

  /// null setting → system language if supported, else Russian.
  static String resolve(String? setting) {
    if (setting != null && supported.contains(setting)) return setting;
    final sys = PlatformDispatcher.instance.locale.languageCode;
    return supported.contains(sys) ? sys : 'ru';
  }

  String call(String key, [Map<String, String>? args]) {
    var s = kStrings[locale]?[key] ?? kStrings['ru']![key] ?? key;
    if (args != null) {
      args.forEach((k, v) => s = s.replaceAll('{$k}', v));
    }
    return s;
  }

  /// Russian-style plural picker: one / few / many.
  String plural(int n, String key) {
    final forms = (this('$key.plural')).split('|');
    if (forms.length < 3) return '$n ${forms.first}';
    int i;
    if (locale == 'ru') {
      final m10 = n % 10, m100 = n % 100;
      i = m10 == 1 && m100 != 11
          ? 0
          : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
              ? 1
              : 2;
    } else {
      i = n == 1 ? 0 : 2;
    }
    return '$n ${forms[i]}';
  }
}

class L10nScope extends InheritedWidget {
  const L10nScope({super.key, required this.l10n, required super.child});
  final L10n l10n;

  @override
  bool updateShouldNotify(L10nScope old) => old.l10n.locale != l10n.locale;
}

extension L10nX on BuildContext {
  L10n get l =>
      dependOnInheritedWidgetOfExactType<L10nScope>()?.l10n ?? const L10n('ru');
}
