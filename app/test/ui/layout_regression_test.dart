import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/ui/theme/theme.dart';
import 'package:melsi/ui/widgets/page.dart';

import 'harness.dart';

void main() {
  testWidgets('large page titles have room above the first content row', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: const Scaffold(
          body: PageScaffold(
            title: 'Title',
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(key: ValueKey('content'), height: 40),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('content'))).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.text('Title').last).dy + 8,
      ),
      reason:
          'the enlarged title must not be clipped by its fixed-height header',
    );
  });

  testWidgets('dashboard tool cards keep equal heights with enlarged text', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final (state, features) = await bootApp(tester, size: const Size(320, 568));
    final heights = [
      for (final action in ['speed', 'doctor', 'timer'])
        tester.getSize(find.byKey(ValueKey('dashboard-$action'))).height,
    ];
    expect(
      heights.toSet(),
      hasLength(1),
      reason: 'wrapped labels must not make staggered card edges',
    );
    await shutdownApp(tester, state, features: features);
  });
}
