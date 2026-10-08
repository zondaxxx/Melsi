import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:melsi/features/netcheck/speed_test.dart';

class _DelayedClient extends http.BaseClient {
  final response = Completer<http.StreamedResponse>();
  late Stream<List<int>> body;
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    body = request.finalize();
    return response.future;
  }

  @override
  void close() => closes++;
}

void main() {
  for (final end in [
    'timeout',
    'paused timeout',
    'subscription cancellation',
  ]) {
    testWidgets('late upload body stays closed after $end', (tester) async {
      final client = _DelayedClient();
      final speed = SpeedTest(
        client: () => client,
        requestTimeout: const Duration(milliseconds: 20),
        uploadCap: const Duration(milliseconds: 10),
      );
      final errors = <Object>[];
      final samples = <SpeedSample>[];
      final subscription = speed.upload().listen(
        samples.add,
        onError: errors.add,
      );
      if (end == 'paused timeout') subscription.pause();
      if (end == 'subscription cancellation') {
        unawaited(subscription.cancel());
        await tester.pump();
      } else {
        await tester.pump(const Duration(milliseconds: 31));
      }
      expect(client.closes, 1);

      // A delayed transport can start listening even after close(). A paused
      // progress consumer also proves cleanup does not depend on onDone.
      List<List<int>>? lateChunks;
      unawaited(client.body.toList().then((chunks) => lateChunks = chunks));
      await tester.pump();
      expect(lateChunks, isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      expect(samples, isEmpty);

      client.response.complete(
        http.StreamedResponse(const Stream.empty(), 200),
      );
      if (end == 'paused timeout') subscription.resume();
      await tester.pump();
      expect(
        errors,
        end == 'subscription cancellation'
            ? isEmpty
            : [
                isA<SpeedTestException>().having(
                  (error) => error.failure,
                  'failure',
                  SpeedFailure.timeout,
                ),
              ],
      );
      expect(client.closes, 1);
      // testWidgets also verifies that no periodic sampler survives teardown.
    });
  }
}
