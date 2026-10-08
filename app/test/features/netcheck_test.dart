// P5-netcheck: IP lookup chain, speed stream, and the Home panel. No real
// sockets: every request goes through a MockClient and the app state has
// networking off.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/features/netcheck/ip_geo.dart';
import 'package:melsi/features/netcheck/speed_test.dart';
import 'package:melsi/main.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

const _ru = '91.201.10.10';
const _nl = '185.20.30.40';

Map<String, dynamic> _ipwho(String ip, String cc) =>
    {'ip': ip, 'success': true, 'country_code': cc, 'city': 'City', 'connection': {'org': 'Org $cc'}};

http.Response _json(Map<String, dynamic> j, [int status = 200]) => http.Response(
    jsonEncode(j), status,
    headers: const {'content-type': 'application/json; charset=utf-8'});

/// Geo answers switch on the fake tunnel state; speed endpoints stream
/// chunks / swallow uploads. [geoRequests] counts lookups.
class _Net {
  _Net(this.vpn, {this.sameIp = false, this.hang = false});
  final FakeVpn vpn;
  final bool sameIp;
  final bool hang;
  int geoRequests = 0;

  late final http.Client client = MockClient.streaming((req, body) async {
    if (req.url.host == 'speed.cloudflare.com') {
      if (req.method == 'POST') {
        await body.drain<void>();
        return http.StreamedResponse(Stream.value(const <int>[]), 200);
      }
      final chunk = List<int>.filled(8192, 1);
      return http.StreamedResponse(
          Stream<List<int>>.periodic(const Duration(milliseconds: 10), (_) => chunk).take(100000),
          200);
    }
    geoRequests++;
    if (hang) return Completer<http.StreamedResponse>().future;
    final connected = vpn.state.status == VpnStatus.connected;
    final j = connected && !sameIp ? _ipwho(_nl, 'NL') : _ipwho(_ru, 'RU');
    return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(j))), 200,
        headers: const {'content-type': 'application/json; charset=utf-8'});
  });
}

/// Mirrors `bootApp`, but with features bound to a client of our own
/// (the harness builds its own state, so it cannot take ours).
Future<(AppState, Features)> _boot(
  WidgetTester tester, {
  required http.Client client,
  FakeVpn? vpn,
  Map<String, dynamic>? data,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final state = testState(data: data, vpn: vpn);
  await state.load();
  state.settings.locale ??= 'ru';
  final f = testFeatures(state, client: client);
  await f.init();
  await tester.pumpWidget(MelsiApp(state: state, features: f, launchMoment: false));
  await tester.pump(const Duration(milliseconds: 500));
  return (state, f);
}

Finder _rich(String s) => find.textContaining(s, findRichText: true);

void main() {
  testWidgets('late lookup from an old session cannot replace the exit', (tester) async {
    final response = Completer<http.Response>();
    final state = testState();
    state.settings.ipCheck = false;
    state.vpnState = const VpnState(VpnStatus.connected);
    final features = testFeatures(state, client: MockClient((_) => response.future));
    final request = features.netcheck.refresh(manual: true);
    await tester.pump();
    features.netcheck.onVpn(VpnStatus.connected, VpnStatus.stopping);
    features.netcheck.onVpn(VpnStatus.stopping, VpnStatus.connected);
    response.complete(_json(_ipwho(_nl, 'NL')));
    await request;
    expect(features.netcheck.exitIp, isNull);
    expect(features.netcheck.checking, isFalse);
    features.dispose();
  });

  test('restoring a backup without IP history clears old cached values', () async {
    final state = testState();
    state.settings.ipCheck = false;
    final features = testFeatures(state);
    features.netcheck.realIp = IpInfo(ip: _ru, at: DateTime(2026));
    features.netcheck.exitIp = IpInfo(ip: _nl, at: DateTime(2026));
    await features.netcheck.load();
    expect(features.netcheck.realIp, isNull);
    expect(features.netcheck.exitIp, isNull);
    features.dispose();
  });

  group('IpGeoClient', () {
    test('falls through the providers in order and stops at the first answer', () async {
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        return switch (req.url.host) {
          'ipwho.is' => _json({'success': false, 'message': 'rate limited'}),
          'api.ip.sb' => _json({'ip': _nl, 'country_code': 'nl', 'city': 'Amsterdam', 'organization': 'Foo BV'}),
          _ => _json({'ip': '1.1.1.1', 'country': 'US'}),
        };
      });
      final info = await IpGeoClient(client: () => client).lookup(at: DateTime(2026));
      expect(hosts, ['ipwho.is', 'api.ip.sb']);
      expect(info.ip, _nl);
      expect(info.countryCode, 'NL');
      expect(info.city, 'Amsterdam');
      expect(info.org, 'Foo BV');
      expect(info.at, DateTime(2026));
    });

    test('a 5xx and a body without ip both fall through', () async {
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        return switch (req.url.host) {
          'ipwho.is' => _json({}, 503),
          'api.ip.sb' => _json({'country_code': 'NL'}),
          _ => _json({'ip': '8.8.8.8', 'country': 'US', 'city': 'MV', 'org': 'AS15169 Google LLC'}),
        };
      });
      final info = await IpGeoClient(client: () => client).lookup();
      expect(hosts, ['ipwho.is', 'api.ip.sb', 'ipinfo.io']);
      expect(info.ip, '8.8.8.8');
      expect(info.countryCode, 'US');
      expect(info.org, 'Google LLC', reason: 'ASN prefix stripped');
    });

    test('all three adapter shapes parse', () async {
      Future<void> check(Uri uri, Map<String, dynamic> body) async {
        final client = MockClient((_) async => _json(body));
        final info = await IpGeoClient(client: () => client, providers: [uri]).lookup();
        expect(info.ip, _nl, reason: uri.host);
        expect(info.countryCode, 'NL', reason: uri.host);
        expect(info.city, 'Amsterdam', reason: uri.host);
        expect(info.org, 'Foo', reason: uri.host);
      }

      await check(IpGeoClient.defaultProviders[0], _ipwho(_nl, 'NL')
        ..['city'] = 'Amsterdam'
        ..['connection'] = {'org': 'Foo'});
      await check(IpGeoClient.defaultProviders[1],
          {'ip': _nl, 'country_code': 'NL', 'city': 'Amsterdam', 'organization': 'Foo'});
      await check(IpGeoClient.defaultProviders[2],
          {'ip': _nl, 'country': 'NL', 'city': 'Amsterdam', 'org': 'AS1 Foo'});
    });

    test('every provider timing out throws', () async {
      final client = MockClient((_) => Completer<http.Response>().future);
      final geo = IpGeoClient(client: () => client, timeout: const Duration(milliseconds: 20));
      await expectLater(geo.lookup(), throwsA(isA<IpLookupException>()));
    });

    test('non-utf8 declared bodies still decode', () async {
      final client = MockClient((_) async => http.Response.bytes(
          utf8.encode(jsonEncode({'ip': _ru, 'country_code': 'RU', 'city': 'Москва'})), 200));
      final info = await IpGeoClient(client: () => client, providers: [Uri.parse('https://x.test/')]).lookup();
      expect(info.city, 'Москва');
    });
  });

  group('SpeedTest', () {
    test('download stream emits non-decreasing byte counts and completes at the cap', () async {
      final chunk = List<int>.filled(4096, 7);
      final client = MockClient.streaming((req, _) async => http.StreamedResponse(
          Stream<List<int>>.periodic(const Duration(milliseconds: 5), (_) => chunk).take(100000),
          200));
      final test = SpeedTest(
        client: () => client,
        cap: const Duration(milliseconds: 300),
        interval: const Duration(milliseconds: 50),
      );
      final sw = Stopwatch()..start();
      final samples = await test.download().toList();
      sw.stop();
      expect(samples.length, greaterThanOrEqualTo(3));
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].bytes, greaterThanOrEqualTo(samples[i - 1].bytes));
        expect(samples[i].elapsed, greaterThanOrEqualTo(samples[i - 1].elapsed));
      }
      expect(samples.last.bytes, greaterThan(0));
      expect(samples.last.averageBps, greaterThan(0));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)), reason: 'stopped at the cap');
      expect(samples.last.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 250)));
    });

    test('download completes at EOF before the cap', () async {
      final client = MockClient.streaming((req, _) async =>
          http.StreamedResponse(Stream.value(List<int>.filled(1000, 1)), 200));
      final test = SpeedTest(client: () => client, cap: const Duration(seconds: 5));
      final samples = await test.download().toList();
      expect(samples, isNotEmpty);
      expect(samples.last.bytes, 1000);
    });

    test('upload pushes 64 KB chunks until the byte budget is spent', () async {
      var received = 0;
      var chunks = 0;
      final client = MockClient.streaming((req, body) async {
        expect(req.method, 'POST');
        await for (final c in body) {
          received += c.length;
          chunks++;
        }
        return http.StreamedResponse(Stream.value(const <int>[]), 200);
      });
      final test = SpeedTest(client: () => client, interval: const Duration(milliseconds: 20));
      final samples = await test.upload(bytes: 200 << 10).toList();
      expect(received, 200 << 10);
      expect(chunks, greaterThanOrEqualTo(4));
      expect(samples.last.bytes, 200 << 10);
    });

    test('a non-2xx download surfaces as a stream error', () async {
      final client = MockClient.streaming(
          (req, _) async => http.StreamedResponse(Stream.value(const <int>[]), 503));
      final test = SpeedTest(client: () => client);
      await expectLater(test.download().toList(), throwsA(isA<SpeedTestException>().having((error) => error.failure, 'failure', SpeedFailure.server).having((error) => error.statusCode, 'status', 503)));
    });
  });

  group('NetCheckService', () {
    testWidgets('switching servers clears the old verdict before the throttled lookup', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, features) = await _boot(tester, client: net.client, vpn: vpn);
      await state.importText('$kSampleVless\n${kSampleVless.replaceAll('nl1.example.com', 'de1.example.com')}');
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump();
      expect(features.netcheck.exitIp?.ip, _nl);
      final previous = state.activeNode!.id;
      final next = state.nodes.firstWhere((node) => node.id != previous);
      await state.selectNode(next.id);
      expect(features.netcheck.exitIp, isNull);
      expect(features.netcheck.verdict, LeakVerdict.unknown);
      expect(net.geoRequests, 2);
      await tester.pump(NetCheckService.switchMinGap);
      await tester.pump();
      expect(net.geoRequests, 3);
      expect(features.netcheck.exitIp?.ip, _nl);
      await shutdownApp(tester, state, features: features);
    });

    testWidgets('lookup on load, then the exit after connect (+1.5 s); disconnect re-reads', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn);
      await state.importText(kSampleVless);
      await tester.pump(const Duration(milliseconds: 100));

      expect(net.geoRequests, 1, reason: 'one lookup on load');
      expect(f.netcheck.realIp?.ip, _ru);
      expect(find.text('ВАШ IP'), findsOneWidget);
      expect(_rich(_ru), findsOneWidget);
      expect(find.text('ВЫХОД'), findsNothing);

      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.connected, isTrue);
      expect(net.geoRequests, 1, reason: 'the exit lookup waits');
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump();
      expect(net.geoRequests, 2, reason: 'exactly one lookup for the connect');
      expect(f.netcheck.exitIp?.ip, _nl);
      expect(f.netcheck.verdict, LeakVerdict.ok);
      await settle(tester);
      expect(find.text('ВЫХОД'), findsOneWidget);
      expect(_rich(_nl), findsOneWidget);
      expect(find.text('Трафик идёт напрямую'), findsNothing);

      // Cached in the section.
      final section = state.sectionOf('netcheck')!;
      expect((section['exitIp'] as Map)['ip'], _nl);
      expect((section['realIp'] as Map)['ip'], _ru);

      state.disconnect();
      await tester.pump(const Duration(milliseconds: 100));
      expect(net.geoRequests, 3, reason: 'one lookup for the disconnect');
      await settle(tester);
      expect(find.text('ВЫХОД'), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('same ip on both sides reads as a direct leak', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn, sameIp: true);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn);
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1600));
      await settle(tester);
      expect(f.netcheck.verdict, LeakVerdict.danger);
      expect(find.text('Трафик идёт напрямую'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('exit in the real country while the server is elsewhere is a warning', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn);
      await state.importText(kSampleVless); // NL node
      f.netcheck.realIp = IpInfo(ip: _ru, countryCode: 'RU', at: DateTime(2026));
      f.netcheck.exitIp = IpInfo(ip: '5.5.5.5', countryCode: 'RU', at: DateTime(2026));
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      // The connect transition clears the exit; put the canned one back.
      f.netcheck.exitIp = IpInfo(ip: '5.5.5.5', countryCode: 'RU', at: DateTime(2026));
      expect(f.netcheck.verdict, LeakVerdict.warning);
      // ignore: invalid_use_of_protected_member
      f.netcheck.notifyListeners();
      await tester.pump();
      expect(find.text('Похоже на утечку'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('timeout degrades to a dash and a footnote, no snackbar', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn, hang: true);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn);
      expect(f.netcheck.checking, isTrue);
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(f.netcheck.checking, isFalse);
      expect(f.netcheck.error, isTrue);
      expect(f.netcheck.realIp, isNull);
      expect(_rich('—'), findsWidgets);
      expect(_rich('нет ответа'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('ipCheck off: no request, no panel', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, f) = await _boot(tester,
          client: net.client, vpn: vpn, data: {'settings': {'ipCheck': false}});
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      expect(net.geoRequests, 0);
      expect(find.text('ВАШ IP'), findsNothing);
      expect(find.text('СЕТЬ'), findsNothing);

      // Switching it on in Settings brings the panel back.
      state.updateSettings((s) => s.ipCheck = true, affectsConfig: false);
      await tester.pump();
      expect(find.text('ВАШ IP'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('iOS looks up the exit after connect and stays quiet otherwise', (tester) async {
      // Reset inside the body: the binding checks foundation debug
      // variables before tear-downs run.
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final vpn = FakeVpn();
        final net = _Net(vpn);
        final state = testState(vpn: vpn);
        await state.load();
        final f = testFeatures(state, client: net.client);
        await f.init();
        await tester.pump();
        expect(net.geoRequests, 0, reason: 'nothing on load');

        await state.importText(kSampleVless);
        state.connect();
        await tester.pump(const Duration(milliseconds: 100));
        expect(state.connected, isTrue);
        expect(net.geoRequests, 0, reason: 'waits until the tunnel is up');
        await tester.pump(const Duration(milliseconds: 1600));
        await tester.pump();
        expect(net.geoRequests, 1, reason: 'exit lookup after connect');
        expect(f.netcheck.exitIp?.ip, _nl);
        f.onResume();
        await tester.pump();
        expect(net.geoRequests, 1, reason: 'resume does not look up again');

        await f.netcheck.refresh(manual: true);
        expect(net.geoRequests, 2);

        state.disconnect();
        await tester.pump(const Duration(milliseconds: 100));
        expect(net.geoRequests, 2, reason: 'nothing on disconnect');
        f.dispose();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('resume re-reads only a stale result', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final clock = FakeClock();
      final state = testState(vpn: vpn);
      await state.load();
      final f = testFeatures(state, client: net.client, clock: clock.call);
      await f.init();
      await tester.pump();
      expect(net.geoRequests, 1);
      f.onResume();
      await tester.pump();
      expect(net.geoRequests, 1, reason: 'fresh result kept');
      clock.advance(const Duration(minutes: 11));
      f.onResume();
      await tester.pump();
      expect(net.geoRequests, 2);
      f.dispose();
    });

    testWidgets('speed test: cancel mid-run leaves no result; a full run is filed per node', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn);
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      final s = f.netcheck;

      unawaited(s.runSpeedTest());
      await tester.pump(const Duration(milliseconds: 600));
      expect(s.phase, SpeedPhase.down);
      expect(s.samples, isNotEmpty);
      expect(s.currentBps, greaterThan(0));
      s.cancelSpeedTest();
      await tester.pump(const Duration(milliseconds: 100));
      expect(s.phase, SpeedPhase.idle);
      expect(s.result, isNull);
      expect(s.samples, isEmpty);
      expect(s.resultsFor(state.activeNode!.id), isEmpty);

      unawaited(s.runSpeedTest());
      await tester.pump(const Duration(seconds: 20));
      expect(s.phase, SpeedPhase.done);
      expect(s.result, isNotNull);
      expect(s.result!.down, greaterThan(0));
      expect(s.result!.up, greaterThan(0));
      expect(s.result!.ping, isNull, reason: 'no sockets in tests');
      expect(s.resultsFor(state.activeNode!.id), hasLength(1));
      final section = state.sectionOf('netcheck')!;
      expect((section['speedResults'] as Map)[state.activeNode!.id], hasLength(1));
      await settle(tester);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('speed sheet runs from the Home panel and settles', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn);
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      final details = find.byKey(const ValueKey('dashboard-details'));
      await tester.ensureVisible(details);
      await settle(tester);
      await tester.tap(details);
      await settle(tester);
      expect(find.text('СКОРОСТЬ'), findsOneWidget);
      expect(find.text('Ещё не измеряли'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('speed-open')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('speed-open')));
      await settle(tester);
      expect(find.text('Запустить'), findsOneWidget);
      expect(find.textContaining('Netherlands'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('speed-run')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Отмена'), findsOneWidget);
      expect(find.text('ЗАГРУЗКА'), findsWidgets);
      await tester.pump(const Duration(seconds: 20));
      await settle(tester);
      expect(f.netcheck.phase, SpeedPhase.done);
      expect(find.text('Запустить'), findsOneWidget);
      expect(find.text('РЕЗУЛЬТАТ'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await settle(tester);
      expect(find.text('Запустить'), findsNothing);
      expect(find.text('только что'), findsOneWidget, reason: 'panel shows the fresh result');
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('reduced motion: the exit line still appears; desktop layout fits', (tester) async {
      reducedMotion(tester);
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn, size: const Size(1280, 800));
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1600));
      await settle(tester);
      expect(find.text('ВЫХОД'), findsOneWidget);
      expect(_rich(_nl), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('360px phone: nothing overflows', (tester) async {
      final vpn = FakeVpn();
      final net = _Net(vpn);
      final (state, f) = await _boot(tester, client: net.client, vpn: vpn, size: const Size(360, 780));
      await state.importText(kSampleVless);
      f.netcheck.realIp = IpInfo(
          ip: '2a02:6b8:0:1::1:ffff:ffff',
          countryCode: 'RU',
          city: 'Санкт-Петербург',
          org: 'A very long organisation name that keeps going',
          at: DateTime(2026));
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1600));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await shutdownApp(tester, state, features: f);
    });
  });
}
