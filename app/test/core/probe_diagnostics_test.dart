import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:melsi/services/clash_api.dart';
import 'package:melsi/services/probe_diagnostics.dart';

void main() {
  test(
    'Clash error details survive as safe categories; unknown stays unknown',
    () async {
      for (final (message, kind) in [
        ('lookup private.example: no such host', ProbeFailure.dns),
        ('TLS handshake: certificate verification failed', ProbeFailure.tls),
        ('REALITY verification failed', ProbeFailure.tls),
        ('authentication failed for private-user', ProbeFailure.authentication),
        ('connect: network is unreachable', ProbeFailure.route),
        ('connect: connection refused', ProbeFailure.refused),
        ('context deadline exceeded', ProbeFailure.timeout),
        ('URL test failed', ProbeFailure.unknown),
      ('An error occurred in the delay test', ProbeFailure.unknown),
      ]) {
        final api = ClashApi(
          endpoint: '127.0.0.1:9790',
          secret: 'test',
          client: MockClient((request) async {
            expect(request.url.host, '127.0.0.1');
            expect(request.url.queryParameters['url'], 'https://example.com');
            return http.Response('{"message":"$message"}', 503);
          }),
        );
        final result = await api.probe(
          'selected node',
          url: 'https://example.com',
        );
        expect(result.failure, kind, reason: message);
        expect(result.delayMs, isNull);
        expect(probeFailureKey(result.failure!), isNot(contains('private')));
        api.close();
      }
    },
  );

  test(
    'control API rejection and connection refusal are local core failures',
    () async {
      for (final status in [401, 403, 404]) {
        final api = ClashApi(
          endpoint: '127.0.0.1:9790',
          secret: 'test',
          client: MockClient((_) async => http.Response('denied', status)),
        );
        expect(
          (await api.probe('proxy', url: 'https://example.com')).failure,
          ProbeFailure.core,
        );
        api.close();
      }
      final api = ClashApi(
        endpoint: '127.0.0.1:9790',
        secret: 'test',
        client: MockClient(
          (_) async => throw http.ClientException('Connection refused'),
        ),
      );
      expect(
        (await api.probe('proxy', url: 'https://example.com')).failure,
        ProbeFailure.core,
      );
      api.close();
    },
  );

  test(
    'latency-only callers remain compatible with success and malformed replies',
    () async {
      for (final (body, expected) in [
        ('{"delay":42}', 42),
        ('{"delay":0}', null),
        ('not json', null),
      ]) {
        final api = ClashApi(
          endpoint: '127.0.0.1:9790',
          secret: 'test',
          client: MockClient((_) async => http.Response(body, 200)),
        );
        expect(await api.delay('proxy', url: 'https://example.com'), expected);
        api.close();
      }
    },
  );
}
