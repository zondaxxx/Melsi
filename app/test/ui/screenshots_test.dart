// Renders the main screens to PNGs with real fonts for visual review.
// Skipped unless MELSI_SHOTS=<output dir> is set:
//   MELSI_SHOTS=/tmp/shots flutter test test/ui/screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/main.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/state/app_state.dart';

import 'fakes.dart';

final _out = Platform.environment['MELSI_SHOTS'];

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      if (File(f).existsSync()) {
        loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
      }
    }
    await loader.load();
  }

  const inter = '/usr/share/fonts/opentype/inter';
  final text = [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) '$inter/Inter-$w.otf',
  ];
  await family('Roboto', text);
  await family('monospace', ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  await family('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  final home = Platform.environment['HOME'];
  final cup = Directory('$home/.pub-cache/hosted/pub.dev')
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('cupertino_icons-'))
      .firstOrNull;
  if (cup != null) {
    await family('packages/cupertino_icons/CupertinoIcons', ['${cup.path}/assets/CupertinoIcons.ttf']);
  }
}

Map<String, dynamic> _demo(String theme) {
  Map<String, dynamic> node(int i, String name, String type, String cc, String sub) => {
        'id': 'n$i',
        'name': name,
        'outbound': {'type': type, 'server': '$cc$i.example.net'.toLowerCase(), 'server_port': 443, 'uuid': 'x', 'password': 'x'},
        'subscriptionId': sub,
        'countryCode': cc,
        'rawLink': 'vless://x@$cc.example.net:443#$name',
      };
  return {
    'subscriptions': [
      {
        'id': 's1',
        'name': 'Melsi Premium',
        'url': 'https://sub.example.net/api/sub/abc',
        'updatedAt': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
        'upload': 2400000000,
        'download': 41000000000,
        'total': 107374182400,
        'expire': DateTime.now().add(const Duration(days: 92)).toIso8601String(),
      },
      {'id': 's2', 'name': 'Друзья', 'updatedAt': DateTime.now().toIso8601String()},
    ],
    'nodes': [
      node(1, '🇩🇪 Frankfurt · Reality', 'vless', 'DE', 's1'),
      node(2, '🇳🇱 Amsterdam · Hysteria2', 'hysteria2', 'NL', 's1'),
      node(3, '🇫🇮 Helsinki · TUIC', 'tuic', 'FI', 's1'),
      node(4, '🇺🇸 New York · Trojan', 'trojan', 'US', 's1'),
      node(5, '🇯🇵 Tokyo · VMess', 'vmess', 'JP', 's1'),
      node(6, '🇹🇷 Istanbul · Shadowsocks', 'shadowsocks', 'TR', 's2'),
      node(7, '🇰🇿 Almaty · AnyTLS', 'anytls', 'KZ', 's2'),
    ],
    'selectedNodeId': 'n1',
    'game': {'enabled': true, 'gameIds': ['cs2', 'valorant', 'dota2', 'pubg_mobile']},
    'settings': {'themeMode': theme, 'locale': 'ru'},
  };
}

void main() {
  final key = GlobalKey();

  Future<void> shoot(WidgetTester tester, String name) async {
    final out = _out;
    if (out == null) return;
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(out).createSync(recursive: true);
      File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<void> pumpFrames(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final theme in ['dark', 'light']) {
    for (final size in [const Size(390, 844), const Size(1280, 820)]) {
      final tag = '${size.width < 600 ? 'phone' : 'desktop'}_$theme';
      testWidgets('screens $tag', (tester) async {
        await _loadFonts();
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final vpn = FakeVpn();
        final state = testState(data: _demo(theme), vpn: vpn);
        await state.load();
        await tester.pumpWidget(RepaintBoundary(key: key, child: MelsiApp(state: state)));
        await pumpFrames(tester);
        await shoot(tester, '${tag}_home');

        // Connected, with live data.
        state.connect();
        await pumpFrames(tester, 3);
        state.latencies['n1'] = Latency(48, viaUrl: true, at: DateTime.now());
        state.engineGroups['proxy'] = GroupStatus(
          selector: 'proxy',
          auto: true,
          current: state.tagOf('n1'),
          lastSwitch: LastSwitch(reason: 'джиттер 3 мс против 21 мс', at: DateTime.now().subtract(const Duration(minutes: 4))),
          nodes: [NodeStat(tag: state.tagOf('n1') ?? '', latencyMs: 48, jitterMs: 3, loss: 0.0, alive: true)],
        );
        state.engineGroups['game'] = GroupStatus(
          selector: 'game',
          auto: true,
          current: state.tagOf('n2'),
          nodes: [NodeStat(tag: state.tagOf('n2') ?? '', latencyMs: 37, jitterMs: 2, loss: 0.004, score: 41.2, alive: true)],
        );
        for (var i = 0; i < 60; i++) {
          state.gameLatencyHistory.add(34 + (i * 7 % 11) + (i % 13 == 0 ? 20 : 0));
          state.traffic.push(20000 + (i * 3731 % 90000), 400000 + (i * 91331 % 2600000));
        }
        state.traffic.upTotal = 38 * 1024 * 1024;
        state.traffic.downTotal = 1843 * 1024 * 1024;
        state.traffic.connections = 27;
        state.connectedAt = DateTime.now().subtract(const Duration(minutes: 12, seconds: 34));
        state.updateSettings((s) => s.killSwitch = true);
        await pumpFrames(tester);
        await shoot(tester, '${tag}_home_connected');

        for (final (tab, label) in [('servers', 'Серверы'), ('routing', 'Маршруты'), ('game', 'Игры'), ('settings', 'Настройки')]) {
          await tester.tap(find.text(label).last);
          await pumpFrames(tester);
          await shoot(tester, '${tag}_$tab');
        }

        state.disconnect();
        await pumpFrames(tester, 3);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      }, skip: _out == null);
    }
  }

  // Keep the RoutingPreset import used even when skipped.
  test('demo data is valid', () {
    expect(AppSettings.fromJson(_demo('dark')['settings'] as Map<String, dynamic>).locale, 'ru');
  });
}
