import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/features/netcheck/speed_test.dart';
import 'package:melsi/services/clash_api.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';
import 'package:melsi/state/store.dart';

import '../ui/fakes.dart';

class _State extends AppState {
  _State({PlatformKind platform = PlatformKind.windows, bool network = false})
    : super(
        store: MemoryStateStore(),
        vpn: FakeVpn(),
        platform: platform,
        enableNetwork: network,
      ) {
    settings.ipCheck = false;
    settings.autoSelect = false;
    nodes.addAll([
      LinkParser.parseLink(kSampleVless)!,
      LinkParser.parseLink(
        kSampleVless.replaceAll('nl1.example.com', 'nl2.example.com'),
      )!,
    ]);
    selectedNodeId = nodes.first.id;
    vpnState = const VpnState(VpnStatus.connected);
    connectedAt = DateTime(2026, 10, 11);
    lastBuilt = BuiltConfig(
      singBox: '{}',
      engine: '{}',
      nodeTags: {for (final node in nodes) node.id: node.server},
    );
  }

  void changed() => notifyListeners();
}

class _Client extends http.BaseClient {
  _Client(this.handle);
  final Future<http.StreamedResponse> Function(
    http.BaseRequest,
    Stream<List<int>>,
  )
  handle;
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request, request.finalize());

  @override
  void close() => closes++;
}

// Keep the real HttpClient's proxy selection, but inject the socket failure:
// a closed loopback port does not have a portable connection-refusal deadline.
class _MissingProxyHttp extends HttpOverrides {
  final attempts = <(Uri, String?, int?)>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = (url, proxyHost, proxyPort) async {
          attempts.add((url, proxyHost, proxyPort));
          throw SocketException(
            'Connection refused',
            address: InternetAddress.loopbackIPv4,
            port: proxyPort,
          );
        };
}

Future<http.StreamedResponse> _success(
  http.BaseRequest request,
  Stream<List<int>> body,
) async {
  if (request.method == 'POST') {
    await body.drain<void>();
    return http.StreamedResponse(const Stream.empty(), 200);
  }
  return http.StreamedResponse(Stream.value(List.filled(4096, 1)), 200);
}

Features _features(_State state, http.Client Function() client) {
  final features = Features(state, httpClient: client);
  addTearDown(state.dispose);
  addTearDown(features.netcheck.dispose);
  return features;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'switching nodes clears the live result and preserves only keyed history',
    () async {
      final state = _State();
      final net = _features(state, () => _Client(_success)).netcheck;
      await net.load();
      await net.runSpeedTest();
      final first = state.selectedNodeId!;
      expect(net.phase, SpeedPhase.done);
      expect(net.resultsFor(first), hasLength(1));
      state.selectedNodeId = state.nodes.last.id;
      state.changed();
      expect(net.phase, SpeedPhase.idle);
      expect(net.result, isNull);
      expect(net.liveDown, isNull);
      expect(net.samples, isEmpty);
      expect(net.resultsFor(state.selectedNodeId), isEmpty);
      expect(net.resultsFor(first), hasLength(1));
    },
  );

  test('a same-node reconnect clears the completed result', () async {
    final state = _State();
    final net = _features(state, () => _Client(_success)).netcheck;
    await net.runSpeedTest();
    state.connectedAt = state.connectedAt!.add(const Duration(minutes: 1));
    state.changed();
    expect(net.result, isNull);
    expect(net.phase, SpeedPhase.idle);
    expect(net.resultsFor(state.selectedNodeId), hasLength(1));
  });

  test('a failed run does not follow the user to another node', () async {
    final state = _State();
    final net = _features(
      state,
      () => _Client(
        (_, _) async => http.StreamedResponse(const Stream.empty(), 503),
      ),
    ).netcheck;
    await net.runSpeedTest();
    expect(net.speedFailed, isTrue);
    state.selectedNodeId = state.nodes.last.id;
    state.changed();
    expect(net.speedFailed, isFalse);
    expect(net.speedFailure, isNull);
    expect(net.failedPhase, isNull);
  });

  test(
    'node change cancels pending headers and ignores a late failure',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final started = Completer<void>();
      final client = _Client((_, _) {
        started.complete();
        return pending.future;
      });
      final state = _State();
      final net = _features(state, () => client).netcheck;
      final run = net.runSpeedTest();
      await started.future;
      state.selectedNodeId = state.nodes.last.id;
      state.changed();
      await run.timeout(const Duration(milliseconds: 200));
      expect(client.closes, 1);
      expect(net.speedInterruptedKey, 'speed.interrupted.connection');
      pending.completeError(http.ClientException('late old-session failure'));
      await Future<void>.delayed(Duration.zero);
      expect(net.speedFailed, isFalse);
      expect(net.result, isNull);
      expect(net.resultsFor(state.nodes.first.id), isEmpty);
    },
  );

  test(
    'restoring during an upload cannot save the old run afterward',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final uploading = Completer<void>();
      final state = _State();
      final net = _features(
        state,
        () => _Client((request, body) async {
          if (request.method == 'POST') {
            await body.drain<void>();
            uploading.complete();
            return pending.future;
          }
          return _success(request, body);
        }),
      ).netcheck;
      final run = net.runSpeedTest();
      await uploading.future;
      final historical = SpeedResult(down: 12, up: 3, at: DateTime(2026, 1, 1));
      state.setSection('netcheck', {
        'lastSpeed': historical.toJson(),
        'speedResults': {
          state.nodes.last.id: [historical.toJson()],
        },
      });
      await net.load();
      await run.timeout(const Duration(milliseconds: 200));
      pending.complete(http.StreamedResponse(const Stream.empty(), 200));
      await Future<void>.delayed(Duration.zero);
      expect(
        net.result,
        isNull,
        reason: 'legacy lastSpeed has no node/session identity',
      );
      expect(net.phase, SpeedPhase.idle);
      expect(net.resultsFor(state.nodes.first.id), isEmpty);
      expect(net.resultsFor(state.nodes.last.id).single.down, 12);
    },
  );

  for (final platform in [
    PlatformKind.ios,
    PlatformKind.android,
    PlatformKind.windows,
  ]) {
    test(
      '$platform background follows mobile-only cancellation policy',
      () async {
        final pending = Completer<http.StreamedResponse>();
        final started = Completer<void>();
        final client = _Client((_, _) {
          started.complete();
          return pending.future;
        });
        final state = _State(platform: platform);
        final net = _features(state, () => client).netcheck;
        final run = net.runSpeedTest();
        await started.future;
        net.didChangeAppLifecycleState(AppLifecycleState.hidden);
        if (platform == PlatformKind.windows) {
          expect(net.speedRunning, isTrue);
          expect(client.closes, 0);
          net.cancelSpeedTest();
        } else {
          expect(net.speedInterruptedKey, 'speed.interrupted.background');
          expect(net.speedRunning, isFalse);
        }
        await run.timeout(const Duration(milliseconds: 200));
        expect(client.closes, 1);
        pending.complete(http.StreamedResponse(const Stream.empty(), 200));
        expect(net.result, isNull);
      },
    );
  }

  test(
    'cancelling latency closes only its owned request and completes promptly',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final started = Completer<void>();
      final client = _Client((request, _) {
        expect(request.url.path, contains('/delay'));
        started.complete();
        return pending.future;
      });
      final shared = _Client(
        (_, _) async => throw StateError('Shared API is not the test client'),
      );
      final state = _State(network: true);
      state.clash = ClashApi(
        endpoint: '127.0.0.1:1',
        secret: 'test',
        client: shared,
      );
      final net = _features(state, () => client).netcheck;
      final run = net.runSpeedTest();
      await started.future;
      net.cancelSpeedTest();
      await run.timeout(const Duration(milliseconds: 200));
      expect(net.phase, SpeedPhase.idle);
      expect(client.closes, 1);
      expect(shared.closes, 0);
      pending.complete(
        http.StreamedResponse(Stream.value('{}'.codeUnits), 200),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.closes, 1);
      expect(net.result, isNull);
    },
  );

  test('connection in progress does not start a direct speed test', () async {
    var opened = 0;
    final state = _State()..vpnState = const VpnState(VpnStatus.connecting);
    final net = _features(state, () {
      opened++;
      return _Client(_success);
    }).netcheck;
    await net.runSpeedTest();
    expect(opened, 0);
    expect(net.speedErrorKey, 'speed.error.notReady');
    expect(net.speedFailed, isTrue);
  });

  test(
    'manual selection still changing cannot measure the previous server',
    () async {
      var opened = 0;
      final state = _State();
      state.engineGroups['proxy'] = GroupStatus(
        selector: 'proxy',
        current: state.tagOf(state.nodes.first.id),
      );
      state.selectedNodeId = state.nodes.last.id;
      final net = _features(state, () {
        opened++;
        return _Client(_success);
      }).netcheck;
      await net.runSpeedTest();
      expect(opened, 0);
      expect(net.speedErrorKey, 'speed.error.notReady');
    },
  );

  test(
    'missing system proxy fails without retrying through a direct client',
    () async {
      const port = 43128;
      final sockets = _MissingProxyHttp();
      var clients = 0;
      final state = _State(network: true);
      state.settings.captureMode = CaptureMode.systemProxy;
      state.settings.mixedPort = port;
      state.clash = ClashApi(endpoint: '127.0.0.1:1', secret: 'test');
      final net = _features(state, () {
        clients++;
        return _Client((request, _) async {
          expect(request.url.path, contains('/delay'));
          return http.StreamedResponse(
            Stream.value('{"delay":5}'.codeUnits),
            200,
          );
        });
      }).netcheck;
      await HttpOverrides.runWithHttpOverrides(
        net.runSpeedTest,
        sockets,
      );
      expect(net.speedErrorKey, 'speed.error.proxy');
      expect(net.result, isNull);
      expect(
        sockets.attempts,
        [(SpeedTest.defaultDownloadUrl, '127.0.0.1', port)],
        reason: 'HttpClient must select only the configured proxy, never DIRECT',
      );
      expect(
        clients,
        1,
        reason: 'only latency uses the injected client; download stays on the local proxy',
      );
    },
  );

  test('speed errors distinguish DNS, TLS and local proxy failures', () {
    expect(
      SpeedTestException.from(const SocketException('Failed host lookup'))
          .failure,
      SpeedFailure.dns,
    );
    expect(
      SpeedTestException.from(const HandshakeException('bad certificate'))
          .failure,
      SpeedFailure.tls,
    );
    final refused = SocketException(
      'Connection refused',
      address: InternetAddress.loopbackIPv4,
    );
    expect(
      SpeedTestException.from(refused, localProxy: true).failure,
      SpeedFailure.proxy,
    );
    expect(SpeedTestException.from(refused).failure, SpeedFailure.connection);
  });
}
