// Optional visual review of the real map painter. No network or mock geometry.
// MELSI_MAP_SHOTS=/tmp/melsi-map flutter test test/ui/route_field_preview_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/ui/theme/theme.dart';
import 'package:melsi/ui/widgets/route_field.dart';

void main() {
  final output = Platform.environment['MELSI_MAP_SHOTS'];
  testWidgets('render map states and a complete connection sequence', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await WorldMapData.load();
      await (FontLoader('Liberation Mono')
            ..addFont(
              rootBundle.load('assets/fonts/LiberationMono-Regular.ttf'),
            )
            ..addFont(rootBundle.load('assets/fonts/LiberationMono-Bold.ttf')))
          .load();
    });
    final key = GlobalKey();
    Future<void> show(
      VpnStatus status, {
      bool ready = false,
      bool light = false,
      double width = 358,
      bool reduced = false,
      String exitCode = 'JP',
      double exitLat = 35.68,
      double exitLon = 139.69,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(light ? Brightness.light : Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: key,
                  child: SizedBox(
                    width: width,
                    child: RouteField(
                      status: status,
                      originCode: 'RU',
                      originLat: 55.75,
                      originLon: 37.62,
                      exitCode: ready ? exitCode : null,
                      exitLat: ready ? exitLat : null,
                      exitLon: ready ? exitLon : null,
                      exitReady: ready,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> shot(String name) async {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(output!).createSync(recursive: true);
        File('$output/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    var frame = 0;
    Future<void> nextFrame() async {
      await tester.pump(const Duration(milliseconds: 50));
      await shot('frame-${(frame++).toString().padLeft(3, '0')}');
    }

    await show(VpnStatus.stopped);
    await shot('01-idle');
    await show(VpnStatus.connecting);
    for (var i = 0; i < 24; i++) {
      await nextFrame();
    }
    await shot('02-waiting');
    await show(VpnStatus.connected, ready: true);
    // Ten seconds at 20 fps: approach, travel, arrival, and multiple
    // settled wave cycles. This also exposes any jump between the phases.
    for (var i = 0; i < 176; i++) {
      await nextFrame();
      if (i == 12) await shot('03-travel');
      if (i == 26) await shot('04-arrival');
      if (i == 80) await shot('09-settled-wave-a');
      if (i == 104) await shot('10-settled-wave-b');
      if (i == 144) await shot('11-settled-wave-c');
    }
    await shot('05-connected-dark');
    await show(VpnStatus.connected, ready: true, light: true);
    await tester.pump(const Duration(milliseconds: 400));
    await shot('06-connected-light');
    await show(VpnStatus.connected, ready: true, width: 288);
    await tester.pump(const Duration(milliseconds: 400));
    await shot('07-small-screen');
    await show(VpnStatus.connected, ready: true, reduced: true);
    await shot('08-reduced-motion');
    await show(VpnStatus.stopped);
    await show(
      VpnStatus.connected,
      ready: true,
      exitCode: 'NL',
      exitLat: 52.37,
      exitLon: 4.9,
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await shot('12-connected-netherlands');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, skip: output == null);
}
