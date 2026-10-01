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
import 'package:melsi/features/chain/chain_picker.dart';
import 'package:melsi/features/doctor/doctor_widgets.dart';
import 'package:melsi/features/netcheck/speed_test_sheet.dart';
import 'package:melsi/features/palette/palette_shell.dart';
import 'package:melsi/features/stats/stats_screen.dart';
import 'package:melsi/main.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/ui/screens/home_screen.dart';

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
  const mac = '/System/Library/Fonts/Supplemental';
  final text = [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) '$inter/Inter-$w.otf',
    // macOS fallbacks (Linux paths above do not exist there).
    '$mac/Arial.ttf',
    '$mac/Arial Bold.ttf',
  ];
  await family('Roboto', text);
  await family('monospace', [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/System/Library/Fonts/Monaco.ttf',
  ]);
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
      {
        'id': 's3',
        'name': 'Старый тариф',
        'url': 'https://old.example.net/sub/xyz',
        'updatedAt': DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
        'upload': 900000000,
        'download': 48000000000,
        'total': 53687091200,
        'expire': DateTime.now().add(const Duration(days: 2)).toIso8601String(),
      },
    ],
    'nodes': [
      node(1, '🇩🇪 Frankfurt · Reality', 'vless', 'DE', 's1'),
      node(2, '🇳🇱 Amsterdam · Hysteria2', 'hysteria2', 'NL', 's1'),
      node(3, '🇫🇮 Helsinki · TUIC', 'tuic', 'FI', 's1'),
      node(4, '🇺🇸 New York · Trojan', 'trojan', 'US', 's1'),
      node(5, '🇯🇵 Tokyo · VMess', 'vmess', 'JP', 's1'),
      node(6, '🇹🇷 Istanbul · Shadowsocks', 'shadowsocks', 'TR', 's2'),
      node(7, '🇰🇿 Almaty · AnyTLS', 'anytls', 'KZ', 's2'),
      node(8, '🇸🇪 Stockholm · VLESS', 'vless', 'SE', 's3'),
    ],
    'selectedNodeId': 'n1',
    'game': {'enabled': true, 'gameIds': ['cs2', 'valorant', 'dota2', 'pubg_mobile']},
    'settings': {'themeMode': theme, 'locale': 'ru'},
    'favourites': ['n2', 'n3'],
    'recents': ['n3', 'n1'],
    'chain': {'enabled': true, 'entryNodeId': 'n2'},
    'sections': {
      'netcheck': {
        'realIp': {
          'ip': '95.24.118.7',
          'countryCode': 'RU',
          'city': 'Москва',
          'org': 'PJSC MTS',
          'at': DateTime.now().subtract(const Duration(minutes: 20)).toIso8601String(),
        },
        'exitIp': {
          'ip': '185.199.110.42',
          'countryCode': 'DE',
          'city': 'Frankfurt am Main',
          'org': 'Hetzner Online',
          'at': DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String(),
        },
      },
    },
  };
}

void main() {
  final key = GlobalKey();

  setUpAll(() async {
    if (_out != null) await _loadFonts();
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    final out = _out;
    if (out == null) return;
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(out).createSync(recursive: true);
      File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> pumpFrames(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The visible page's vertical scroll position.
  ScrollPosition pagePosition(WidgetTester tester) {
    final page = find.byType(CustomScrollView).hitTestable().first;
    return tester
        .state<ScrollableState>(find.descendant(of: page, matching: find.byType(Scrollable)).first)
        .position;
  }

  Future<void> shootBottom(WidgetTester tester, String name) async {
    final pos = pagePosition(tester);
    pos.jumpTo(pos.maxScrollExtent);
    await pumpFrames(tester, 4);
    await shoot(tester, name);
    pagePosition(tester).jumpTo(0);
    await pumpFrames(tester, 2);
  }

  Future<void> closeSheet(WidgetTester tester) async {
    await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await pumpFrames(tester, 6);
  }

  const sizes = {
    'phone': Size(390, 844),
    'small': Size(360, 740),
    'desktop': Size(1280, 820),
  };

  for (final theme in ['dark', 'light']) {
    for (final MapEntry(key: kind, value: size) in sizes.entries) {
      final tag = '${kind}_$theme';
      final phone = kind != 'desktop';
      testWidgets('screens $tag', (tester) async {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final vpn = FakeVpn();
        final state = testState(data: _demo(theme), vpn: vpn);
        await state.load();
        final features = testFeatures(state);
        await features.init();
        addTearDown(features.dispose);
        await tester.pumpWidget(RepaintBoundary(
            key: key, child: MelsiApp(state: state, features: features, launchMoment: false)));
        await pumpFrames(tester);
        await shoot(tester, '${tag}_home');
        if (phone) await shootBottom(tester, '${tag}_home_bottom');

        // Connecting: the route line is mid-sweep.
        vpn.delay = const Duration(milliseconds: 900);
        state.connect();
        await tester.pump(const Duration(milliseconds: 350));
        await shoot(tester, '${tag}_home_connecting');
        await pumpFrames(tester, 8);
        vpn.delay = const Duration(milliseconds: 10);

        // Connected, with live data.
        await pumpFrames(tester, 3);
        state.latencies['n1'] = Latency(48, viaUrl: true, at: DateTime.now());
        state.latencies['n2'] = Latency(37, viaUrl: true, at: DateTime.now());
        state.latencies['n3'] = Latency(142, viaUrl: true, at: DateTime.now());
        state.latencies['n4'] = Latency(null, viaUrl: true, at: DateTime.now());
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
          current: state.tagOf('n3'),
          nodes: [NodeStat(tag: state.tagOf('n3') ?? '', latencyMs: 37, jitterMs: 2, loss: 0.004, score: 41.2, alive: true)],
        );
        for (var i = 0; i < 60; i++) {
          state.gameLatencyHistory.add(34 + (i * 7 % 11) + (i % 13 == 0 ? 20 : 0));
          state.traffic.push(20000 + (i * 3731 % 90000), 400000 + (i * 91331 % 2600000));
        }
        state.traffic.upTotal = 38 * 1024 * 1024;
        state.traffic.downTotal = 1843 * 1024 * 1024;
        state.traffic.connections = 27;
        state.connectedAt = DateTime.now().subtract(const Duration(minutes: 12, seconds: 34));
        // Not a config change for the shots (would trigger an auto-apply).
        state.updateSettings((s) => s.killSwitch = true, affectsConfig: false);
        await pumpFrames(tester);
        await shoot(tester, '${tag}_home_connected');
        if (phone) await shootBottom(tester, '${tag}_home_connected_bottom');

        // Feature sheets and screens, opened from Home's context.
        final home = tester.element(find.byType(HomeScreen));
        openStatsScreen(home);
        await pumpFrames(tester, 8);
        await shoot(tester, '${tag}_stats');
        await closeSheet(tester);

        showDoctorSheet(home);
        await pumpFrames(tester, 12);
        await shoot(tester, '${tag}_doctor');
        await closeSheet(tester);

        showChainPicker(home);
        await pumpFrames(tester, 8);
        await shoot(tester, '${tag}_chain_picker');
        await closeSheet(tester);

        showSpeedTestSheet(home);
        await pumpFrames(tester, 8);
        await shoot(tester, '${tag}_speedtest');
        await closeSheet(tester);

        if (!phone) {
          showCommandPalette(home);
          await pumpFrames(tester, 6);
          await tester.enterText(find.byType(TextField).last, 'kill');
          await pumpFrames(tester, 3);
          await shoot(tester, '${tag}_palette');
          await closeSheet(tester);
        }

        // Quick server switcher.
        await tester.tap(find.descendant(of: find.byType(HomeScreen), matching: find.text('Frankfurt · Reality')).first);
        await pumpFrames(tester, 8);
        await shoot(tester, '${tag}_switcher');
        await closeSheet(tester);

        for (final (tab, label) in [('servers', 'Серверы'), ('routing', 'Маршруты'), ('game', 'Игры'), ('settings', 'Настройки')]) {
          await tester.tap(find.text(label).last);
          await pumpFrames(tester);
          await shoot(tester, '${tag}_$tab');
          if (phone) await shootBottom(tester, '${tag}_${tab}_bottom');
        }

        // Change a setting while connected: it applies itself.
        vpn.delay = const Duration(milliseconds: 700);
        state.updateSettings((s) => s.ipv6 = !s.ipv6);
        await pumpFrames(tester, 17);
        await shoot(tester, '${tag}_apply_applying');
        await pumpFrames(tester, 14);
        await shoot(tester, '${tag}_apply_done');
        await pumpFrames(tester, 20);
        vpn.delay = const Duration(milliseconds: 10);

        state.disconnect();
        await pumpFrames(tester, 3);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      }, skip: _out == null);
    }

    for (final (kind, size) in [('phone', const Size(390, 844)), ('desktop', const Size(1280, 820))]) {
      testWidgets('onboarding $kind $theme', (tester) async {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final state = testState(
            data: {'settings': {'themeMode': theme, 'locale': 'ru', 'onboardingDone': false}});
        await state.load();
        final features = testFeatures(state);
        await features.init();
        addTearDown(features.dispose);
        await tester.pumpWidget(RepaintBoundary(
            key: key, child: MelsiApp(state: state, features: features, launchMoment: true)));
        await tester.pump(const Duration(milliseconds: 200));
        await shoot(tester, '${kind}_${theme}_launch');
        await pumpFrames(tester, 16);
        await shoot(tester, '${kind}_${theme}_onboarding_1');
        await tester.tap(find.byKey(const ValueKey('onboarding-next')));
        await pumpFrames(tester, 8);
        await shoot(tester, '${kind}_${theme}_onboarding_2');
        await tester.enterText(find.byKey(const ValueKey('onboarding-link-field')), kSampleVless);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('onboarding-submit')));
        await pumpFrames(tester, 8);
        await shoot(tester, '${kind}_${theme}_onboarding_2_added');
        await tester.tap(find.byKey(const ValueKey('onboarding-next-2')));
        await pumpFrames(tester, 8);
        await shoot(tester, '${kind}_${theme}_onboarding_3');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      }, skip: _out == null);
    }

    testWidgets('empty $theme', (tester) async {
      tester.view.physicalSize = const Size(390, 844) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final state = testState(data: {'settings': {'themeMode': theme, 'locale': 'ru'}});
      await state.load();
      final features = testFeatures(state);
      await features.init();
      addTearDown(features.dispose);
      await tester.pumpWidget(RepaintBoundary(
            key: key, child: MelsiApp(state: state, features: features, launchMoment: false)));
      await pumpFrames(tester);
      await shoot(tester, 'phone_${theme}_home_empty');
      await tester.tap(find.text('Серверы').last);
      await pumpFrames(tester);
      await shoot(tester, 'phone_${theme}_servers_empty');
      await tester.tap(find.text('Добавить подписку').first);
      await pumpFrames(tester, 8);
      await shoot(tester, 'phone_${theme}_add_sheet');
      await closeSheet(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }, skip: _out == null);
  }

  // Keep the RoutingPreset import used even when skipped.
  test('demo data is valid', () {
    expect(AppSettings.fromJson(_demo('dark')['settings'] as Map<String, dynamic>).locale, 'ru');
  });
}
