import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/l10n.dart';
import 'services/deep_links.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';
import 'ui/shell.dart';
import 'ui/theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final state = AppState();
  await state.load();
  final links = DeepLinks((url, name) => state.addSubscription(url, name: name));
  await links.start();
  runApp(MelsiApp(state: state));
}

class MelsiApp extends StatelessWidget {
  const MelsiApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: Builder(builder: (context) {
        final s = context.app.settings;
        final locale = L10n.resolve(s.locale);
        final mode = switch (s.themeMode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
        return L10nScope(
          l10n: L10n(locale),
          child: MaterialApp(
            title: 'Melsi',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            themeMode: mode,
            themeAnimationDuration: const Duration(milliseconds: 350),
            locale: Locale(locale),
            supportedLocales: const [Locale('ru'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) {
              final dark = Theme.of(context).brightness == Brightness.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
                  statusBarColor: Colors.transparent,
                  systemNavigationBarColor: Colors.transparent,
                ),
                child: child!,
              );
            },
            home: const Shell(),
          ),
        );
      }),
    );
  }
}
