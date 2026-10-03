import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';

import 'harness.dart';

void main() {
  for (final platform in [PlatformKind.android, PlatformKind.ios]) {
    for (final width in [390.0, 1024.0]) {
      testWidgets('$platform at $width hides PC games and launchers', (
        tester,
      ) async {
        final (state, features) = await bootApp(
          tester,
          platform: platform,
          size: Size(width, 844),
          data: {
            'game': {
              'gameIds': ['cs2', 'valorant', 'steam', 'pubg_mobile'],
            },
          },
        );
        await tester.tap(find.text('Игры'));
        await settle(tester);
        expect(find.text('Counter-Strike 2'), findsNothing);
        expect(find.text('VALORANT'), findsNothing);
        expect(find.text('Steam'), findsNothing);
        expect(find.text('ПК'), findsNothing);
        expect(find.text('World of Tanks / Мир танков'), findsNothing);
        expect(find.text('World of Tanks Blitz'), findsOneWidget);
        expect(find.text('PUBG Mobile'), findsOneWidget);
        expect(find.textContaining('1 ВЫБРАНО'), findsOneWidget);
        expect(state.game.gameIds, contains('cs2'));
        await shutdownApp(tester, state, features: features);
      });
    }
  }

  testWidgets('a narrow desktop window keeps PC games', (tester) async {
    final (state, features) = await bootApp(
      tester,
      platform: PlatformKind.windows,
    );
    await tester.tap(find.text('Игры'));
    await settle(tester);
    expect(find.text('Counter-Strike 2'), findsOneWidget);
    expect(find.text('ПК'), findsOneWidget);
    await shutdownApp(tester, state, features: features);
  });
}
