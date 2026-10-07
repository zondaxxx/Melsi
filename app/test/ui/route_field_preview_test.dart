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
                      exitCode: ready ? 'JP' : null,
                      exitLat: ready ? 35.68 : null,
                      exitLon: ready ? 139.69 : null,
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

    await show(VpnStatus.stopped);
    await shot('01-idle');
    await show(VpnStatus.connecting);
    await tester.pump(const Duration(milliseconds: 950));
    await tester.pump(const Duration(milliseconds: 350));
    await shot('02-waiting');
    await show(VpnStatus.connected, ready: true);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 75));
      await shot('frame-${i.toString().padLeft(2, '0')}');
      if (i == 7) await shot('03-travel');
      if (i == 18) await shot('04-arrival');
    }
    await shot('05-connected-dark');
    await show(VpnStatus.connected, ready: true, light: true);
    await tester.pump(const Duration(milliseconds: 400));
    await shot('06-connected-light');
    await show(VpnStatus.connected, ready: true, width: 288);
    await tester.pump(const Duration(milliseconds: 400));
    await shot('07-small-screen');
    await show(VpnStatus.stopped, reduced: true);
    await show(VpnStatus.connecting, reduced: true);
    await shot('08-reduced-motion');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, skip: output == null);
}
