import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:melsi/core/subscription_fetcher.dart';

import 'samples.dart';

void main() {
  test('fetch parses body + headers', () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      final body = base64.encode(utf8.encode(kSampleLinks.values.take(5).join('\n')));
      return http.Response.bytes(utf8.encode(body), 200, headers: {
        'subscription-userinfo':
            'upload=1024; download=2048; total=10737418240; expire=1767225600',
        'profile-title': 'base64:${base64.encode(utf8.encode('Мой VPN 🚀'))}',
        'profile-update-interval': '6',
        'support-url': 'https://t.me/support',
        'profile-web-page-url': 'https://panel.example.com/sub/abc',
        'announce': 'base64:${base64.encode(utf8.encode('Скидка 50%'))}',
      });
    });
    final r = await SubscriptionFetcher(client: client)
        .fetch('https://sub.example.com/abc', subscriptionId: 'sub1');
    expect(seen!.headers['User-Agent'], kDefaultSubscriptionUserAgent);
    expect(r.nodes, hasLength(5));
    expect(r.nodes.every((n) => n.subscriptionId == 'sub1'), isTrue);
    expect(r.title, 'Мой VPN 🚀');
    expect(r.upload, 1024);
    expect(r.download, 2048);
    expect(r.total, 10737418240);
    expect(r.expire, DateTime.utc(2026, 1, 1));
    expect(r.updateIntervalHours, 6);
    expect(r.supportUrl, 'https://t.me/support');
    expect(r.webPageUrl, 'https://panel.example.com/sub/abc');
    expect(r.announce, 'Скидка 50%');
  });

  test('custom user agent, plain title, missing headers', () async {
    final client = MockClient((req) async {
      expect(req.headers['User-Agent'], 'v2rayNG/1.9');
      return http.Response.bytes(utf8.encode(kClashYaml), 200,
          headers: {'profile-title': 'Plain Title'});
    });
    final r = await SubscriptionFetcher(client: client)
        .fetch('https://sub.example.com/clash', userAgent: 'v2rayNG/1.9');
    expect(r.title, 'Plain Title');
    expect(r.total, isNull);
    expect(r.expire, isNull);
    expect(r.nodes.length, greaterThan(10));
  });

  test('title from content-disposition', () {
    final r = SubscriptionFetcher.parseResponse('', {
      'content-disposition': "attachment; filename*=UTF-8''%D0%9C%D0%B5%D0%BB%D1%8C%D1%81%D0%B8.yaml",
    });
    expect(r.title, 'Мельси');
    expect(r.nodes, isEmpty);
  });

  test('expire=0 means no expiry', () {
    final i = SubscriptionFetcher.parseUserInfo('upload=0;download=0;total=0;expire=0');
    expect(i.expire, isNull);
    expect(i.total, 0);
  });

  test('HTTP errors throw', () async {
    final client = MockClient((req) async => http.Response('nope', 403));
    expect(
        () => SubscriptionFetcher(client: client).fetch('https://x.example.com'),
        throwsA(isA<SubscriptionFetchException>()
            .having((e) => e.statusCode, 'statusCode', 403)));
    expect(() => SubscriptionFetcher(client: client).fetch('ftp://x'),
        throwsA(isA<SubscriptionFetchException>()));
  });

  test('timeout throws', () async {
    final client = MockClient((req) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return http.Response('', 200);
    });
    expect(
        () => SubscriptionFetcher(
                client: client, timeout: const Duration(milliseconds: 100))
            .fetch('https://slow.example.com'),
        throwsA(isA<SubscriptionFetchException>()));
  });
}
