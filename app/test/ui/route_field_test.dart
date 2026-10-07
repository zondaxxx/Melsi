import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/ui/theme/theme.dart';
import 'package:melsi/ui/widgets/route_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<RouteFieldState> show(WidgetTester tester, VpnStatus status) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: RouteField(
        status: status,
        originCode: 'DE',
        originLat: 52.5,
        originLon: 13.4,
        exitCode: 'JP',
        exitLat: 35.7,
        exitLon: 139.7,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    return tester.state<RouteFieldState>(find.byType(RouteField));
  }

  testWidgets('connect travels to the server and failure spreads at home', (tester) async {
    var state = await show(tester, VpnStatus.stopped);
    expect(state.debugCue, MapCue.idle);

    state = await show(tester, VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.debugCue, anyOf(MapCue.approach, MapCue.travel));
    await tester.pump(const Duration(milliseconds: 3400));
    expect(state.debugCue, MapCue.settled);

    state = await show(tester, VpnStatus.error);
    await tester.pump(const Duration(milliseconds: 200));
    expect(state.debugCue, MapCue.retreat);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(state.debugCue, MapCue.failed);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion settles without a travelling signal', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final state = await show(tester, VpnStatus.connecting);
    expect(state.debugCue, MapCue.settled);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}