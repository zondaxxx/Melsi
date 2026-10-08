import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:melsi/features/netcheck/speed_test.dart';
import 'package:melsi/state/features.dart';

import '../ui/fakes.dart';

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

Matcher failure(SpeedFailure kind, [int? status]) => isA<SpeedTestException>()
    .having((error) => error.failure, 'failure', kind)
    .having((error) => error.statusCode, 'HTTP status', status);

void main() {
  test('download headers have a deadline and close a hung client', () async {
    final response = Completer<http.StreamedResponse>();
    final client = _Client((_, _) => response.future);
    final speed = SpeedTest(
      client: () => client,
      requestTimeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      speed.download().toList(),
      throwsA(failure(SpeedFailure.timeout)),
    );
    expect(client.closes, 1);
    response.complete(http.StreamedResponse(const Stream.empty(), 200));
  });

  test(
    'cancel before download headers completes promptly without failure',
    () async {
      final response = Completer<http.StreamedResponse>();
      final client = _Client((_, _) => response.future);
      final speed = SpeedTest(client: () => client);
      final result = speed.download().toList();
      await Future<void>.delayed(Duration.zero);
      speed.cancel();
      expect(await result.timeout(const Duration(milliseconds: 200)), isEmpty);
      expect(client.closes, 1);
      response.complete(http.StreamedResponse(const Stream.empty(), 200));
    },
  );

  test('cancelling before listening never opens a client', () async {
    var opens = 0;
    final speed = SpeedTest(
      client: () {
        opens++;
        return _Client(
          (_, _) async => http.StreamedResponse(const Stream.empty(), 200),
        );
      },
    );
    speed.cancel();
    expect(await speed.download().toList(), isEmpty);
    expect(await speed.upload().toList(), isEmpty);
    expect(opens, 0);
  });

  test(
    'cancelling a progress subscription stops the download and its client',
    () async {
      var bodyCancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => bodyCancelled = true,
      );
      final client = _Client(
        (_, _) async => http.StreamedResponse(body.stream, 200),
      );
      final speed = SpeedTest(
        client: () => client,
        interval: const Duration(milliseconds: 10),
      );
      final first = Completer<void>();
      final sub = speed.download().listen((_) {
        if (!first.isCompleted) first.complete();
      });
      body.add(List.filled(65536, 1));
      await first.future.timeout(const Duration(seconds: 1));
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(bodyCancelled, isTrue);
      expect(client.closes, 1);
      await body.close();
    },
  );

  test(
    'download connection failure after data is not saved as success',
    () async {
      Stream<List<int>> body() async* {
        yield List.filled(65536, 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw http.ClientException('Connection closed while receiving data');
      }

      final client = _Client(
        (_, _) async => http.StreamedResponse(body(), 200),
      );
      final speed = SpeedTest(
        client: () => client,
        interval: const Duration(milliseconds: 5),
      );
      await expectLater(
        speed.download().toList(),
        throwsA(failure(SpeedFailure.connection)),
      );
      expect(client.closes, 1);
    },
  );

  test('empty download is a failed measurement', () async {
    final client = _Client(
      (_, _) async => http.StreamedResponse(const Stream.empty(), 200),
    );
    final speed = SpeedTest(client: () => client);
    await expectLater(
      speed.download().toList(),
      throwsA(failure(SpeedFailure.empty)),
    );
  });

  test(
    'upload HTTP rejection cannot become a successful speed result',
    () async {
      final client = _Client((_, body) async {
        await body.drain<void>();
        return http.StreamedResponse(const Stream.empty(), 429);
      });
      final speed = SpeedTest(client: () => client);
      await expectLater(
        speed.upload(bytes: 65536).toList(),
        throwsA(failure(SpeedFailure.server, 429)),
      );
      expect(client.closes, 1);
    },
  );

  test(
    'upload response body has a deadline and its stream is cancelled',
    () async {
      var bodyCancelled = false;
      final response = StreamController<List<int>>(
        onCancel: () => bodyCancelled = true,
      );
      final client = _Client((_, body) async {
        await body.drain<void>();
        return http.StreamedResponse(response.stream, 200);
      });
      final speed = SpeedTest(
        client: () => client,
        responseTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(
        speed.upload(bytes: 65536).toList(),
        throwsA(failure(SpeedFailure.timeout)),
      );
      expect(bodyCancelled, isTrue);
      expect(client.closes, 1);
      await response.close();
    },
  );

  test(
    'cancel upload awaiting acknowledgement does not wait for its timeout',
    () async {
      final received = Completer<void>();
      final response = Completer<http.StreamedResponse>();
      final client = _Client((_, body) async {
        await body.drain<void>();
        received.complete();
        return response.future;
      });
      final speed = SpeedTest(client: () => client);
      final result = speed.upload(bytes: 65536).toList();
      await received.future;
      speed.cancel();
      await result.timeout(const Duration(milliseconds: 200));
      expect(client.closes, 1);
      response.complete(http.StreamedResponse(const Stream.empty(), 200));
    },
  );

  test(
    'real HTTP download streams bytes and upload confirms the full body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final uploaded = Completer<int>();
      final serverErrors = <Object>[];
      server.listen((request) {
        unawaited(
          () async {
            if (request.method == 'GET') {
              expect(request.headers.value('accept-encoding'), 'identity');
              request.response.contentLength = 2 << 20;
              for (var i = 0; i < 32; i++) {
                request.response.add(List.filled(65536, i));
                await request.response.flush();
                await Future<void>.delayed(const Duration(milliseconds: 2));
              }
            } else {
              var bytes = 0;
              await for (final chunk in request) {
                bytes += chunk.length;
              }
              uploaded.complete(bytes);
              await Future<void>.delayed(const Duration(milliseconds: 30));
              request.response.write('accepted');
            }
            await request.response.close();
          }().catchError((Object error) {
            serverErrors.add(error);
          }),
        );
      });
      final url = Uri.parse('http://127.0.0.1:${server.port}/measure');
      final speed = SpeedTest(
        client: IOClient.new,
        downloadUrl: url,
        uploadUrl: url,
        interval: const Duration(milliseconds: 10),
      );
      final down = await speed.download().toList().timeout(
        const Duration(seconds: 4),
      );
      expect(down.last.bytes, 2 << 20);
      expect(down.length, greaterThan(2));
      expect(down.last.averageBps, greaterThan(0));
      final up = await speed
          .upload(bytes: 2 << 20)
          .toList()
          .timeout(const Duration(seconds: 4));
      expect(await uploaded.future, 2 << 20);
      expect(up.last.bytes, 2 << 20);
      expect(
        up.last.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 30)),
        reason: 'the result includes the server acknowledgement',
      );
      expect(up.last.averageBps, greaterThan(0));
      expect(
        speed.cancelled,
        isFalse,
        reason: 'completing download must not cancel the following upload',
      );
      expect(serverErrors, isEmpty);
    },
  );

  test('upload failure keeps its stage and download estimate without saving a result', () async {
    final state = testState();
    final features = Features(
      state,
      httpClient: () => _Client((request, body) async {
        if (request.method == 'POST') {
          await body.drain<void>();
          return http.StreamedResponse(const Stream.empty(), 503);
        }
        return http.StreamedResponse(Stream.value(List.filled(4096, 1)), 200);
      }),
    );
    final net = features.netcheck;
    addTearDown(state.dispose);
    addTearDown(net.dispose);
    await net.runSpeedTest();
    expect(net.speedFailed, isTrue);
    expect(net.failedPhase, SpeedPhase.up);
    expect(net.speedErrorKey, 'speed.error.server');
    expect(net.speedErrorArgs, {'status': '503'});
    expect(net.liveDown, greaterThan(0));
    expect(net.result, isNull);
    expect(net.resultsFor(null), isEmpty);
  });

  test(
    'cancel and restart ignores a late failure from the old download',
    () async {
      final oldResponse = Completer<http.StreamedResponse>();
      final firstStarted = Completer<void>();
      var opens = 0;
      final clients = <_Client>[];
      final state = testState();
      final features = Features(
        state,
        httpClient: () {
          final index = opens++;
          final client = _Client((request, body) async {
            if (index == 0) {
              firstStarted.complete();
              return oldResponse.future;
            }
            if (request.method == 'POST') {
              await body.drain<void>();
              return http.StreamedResponse(const Stream.empty(), 200);
            }
            return http.StreamedResponse(
              Stream.value(List.filled(4096, 1)),
              200,
            );
          });
          clients.add(client);
          return client;
        },
      );
      final net = features.netcheck;
      addTearDown(state.dispose);
      addTearDown(net.dispose);
      final firstRun = net.runSpeedTest();
      await firstStarted.future;
      net.cancelSpeedTest();
      await firstRun.timeout(const Duration(milliseconds: 200));
      expect(net.speedRunning, isFalse);
      await net.runSpeedTest();
      oldResponse.completeError(http.ClientException('late cancelled request'));
      await Future<void>.delayed(Duration.zero);
      expect(net.phase, SpeedPhase.done);
      expect(net.speedFailed, isFalse);
      expect(net.speedFailure, isNull);
      expect(net.result, isNotNull);
      expect(net.resultsFor(null), hasLength(1));
      expect(clients.every((client) => client.closes == 1), isTrue);
    },
  );
}
