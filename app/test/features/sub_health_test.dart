import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/features/updates/alerts.dart';
import 'package:melsi/features/updates/sub_health.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

final _now = DateTime(2026, 10, 1, 12);

Subscription _sub({
  String id = 's1',
  String name = 'Prime',
  DateTime? expire,
  int? total,
  int upload = 0,
  int download = 0,
  String? url = 'https://p.example/sub',
  String? webPageUrl,
}) =>
    Subscription(
      id: id,
      name: name,
      url: url,
      expire: expire,
      total: total,
      upload: upload,
      download: download,
      webPageUrl: webPageUrl,
    );

void main() {
  group('health', () {
    test('no metadata → ok', () {
      expect(health(_sub(), _now), SubscriptionHealth.ok);
    });

    test('expiry threshold is 3 days', () {
      expect(health(_sub(expire: _now.add(const Duration(days: 3, hours: 2))), _now),
          SubscriptionHealth.expiresSoon);
      expect(health(_sub(expire: _now.add(const Duration(hours: 5))), _now),
          SubscriptionHealth.expiresSoon);
      expect(health(_sub(expire: _now.add(const Duration(days: 4))), _now),
          SubscriptionHealth.ok);
    });

    test('expired', () {
      expect(health(_sub(expire: _now.subtract(const Duration(hours: 1))), _now),
          SubscriptionHealth.expired);
      expect(health(_sub(expire: _now), _now), SubscriptionHealth.expired);
    });

    test('quota threshold is 90%', () {
      expect(health(_sub(total: 1000, download: 900), _now), SubscriptionHealth.quotaLow);
      expect(health(_sub(total: 1000, download: 500, upload: 399), _now), SubscriptionHealth.ok);
      expect(health(_sub(total: 1000, download: 1000), _now), SubscriptionHealth.exhausted);
      expect(health(_sub(total: 1000, download: 1200), _now), SubscriptionHealth.exhausted);
    });

    test('no total → quota never fires', () {
      expect(health(_sub(download: 5 << 30, upload: 1 << 30), _now), SubscriptionHealth.ok);
      expect(health(_sub(total: 0, download: 10), _now), SubscriptionHealth.ok);
    });

    test('expired outranks exhausted, exhausted outranks expiring', () {
      expect(
          health(_sub(expire: _now.subtract(const Duration(days: 1)), total: 10, download: 10), _now),
          SubscriptionHealth.expired);
      expect(
          health(_sub(expire: _now.add(const Duration(days: 1)), total: 10, download: 10), _now),
          SubscriptionHealth.exhausted);
    });

    test('daysLeft truncates towards fewer days and is negative once expired', () {
      expect(daysLeft(_sub(expire: _now.add(const Duration(days: 2, hours: 20))), _now), 2);
      expect(daysLeft(_sub(expire: _now.add(const Duration(hours: 3))), _now), 0);
      expect(daysLeft(_sub(expire: _now.subtract(const Duration(hours: 3))), _now), -1);
      expect(daysLeft(_sub(), _now), isNull);
    });
  });

  group('alerts', () {
    test('danger first, then warnings, update last; dismissals and skips hide', () {
      final state = testState();
      final clock = FakeClock(_now);
      final f = testFeatures(state, clock: clock.call);
      state.subscriptions.addAll([
        _sub(id: 'a', name: 'A', expire: _now.add(const Duration(days: 2))),
        _sub(id: 'b', name: 'B', total: 100, download: 95),
        _sub(id: 'c', name: 'C', expire: _now.subtract(const Duration(days: 1))),
        _sub(id: 'd', name: 'D', total: 100, download: 100),
        _sub(id: 'e', name: 'E'),
      ]);
      state.sections['updates'] = {'latestTag': '9.9.9', 'latestUrl': 'https://r.example/9.9.9'};
      f.updates.load();

      var list = alerts(state, f.updates);
      expect(list.map((a) => a.kind), [
        AlertKind.subExpired,
        AlertKind.subExhausted,
        AlertKind.subExpiring,
        AlertKind.subQuota,
        AlertKind.updateAvailable,
      ]);
      expect(list[0].subscription?.name, 'C');
      expect(list[2].args, {'name': 'A', 'n': '2'});
      expect(list[3].args, {'name': 'B', 'p': '95'});
      expect(list[4].args, {'v': '9.9.9'});
      expect(list[4].url, 'https://r.example/9.9.9');

      f.updates.dismiss(list[0].id);
      list = alerts(state, f.updates);
      expect(list.first.kind, AlertKind.subExhausted);
      expect(list.length, 4);

      f.updates.skipLatest();
      expect(state.settings.skippedVersion, '9.9.9');
      list = alerts(state, f.updates);
      expect(list.any((a) => a.isUpdate), isFalse);
      f.dispose();
    });

    test('expiring today uses its own key', () {
      final state = testState();
      final f = testFeatures(state, clock: FakeClock(_now).call);
      state.subscriptions.add(_sub(expire: _now.add(const Duration(hours: 4))));
      final list = alerts(state, f.updates);
      expect(list.single.textKey, 'alert.subExpiringToday');
      f.dispose();
    });
  });

  group('AlertRows', () {
    Map<String, dynamic> data({int days = 2, bool second = false}) => {
          'subscriptions': [
            _sub(name: 'Prime', expire: _now.add(Duration(days: days, hours: 2))).toJson(),
            if (second)
              _sub(id: 's2', name: 'Old', url: 'https://o.example/sub',
                      expire: _now.subtract(const Duration(days: 1)))
                  .toJson(),
          ],
        };

    testWidgets('a subscription expiring in 2 days shows one attention row on Home',
        (tester) async {
      final (state, f) = await bootApp(tester, data: data());
      await settle(tester);
      expect(find.textContaining('истекает через 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-row')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1)); // the dot's one breath
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('several alerts: one row, +N tag, the sheet lists all and dismisses',
        (tester) async {
      stubPlatformChannels(tester);
      final (state, f) = await bootApp(tester, data: data(second: true));
      await settle(tester);
      // Danger first: the expired one leads, the expiring one is "+1".
      expect(find.byKey(const ValueKey('alert-row')), findsOneWidget);
      expect(find.textContaining('«Old» истекла'), findsOneWidget);
      expect(find.textContaining('истекает через 2'), findsNothing);
      expect(find.text('+1'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('alert-row')));
      await settle(tester);
      expect(find.text('Внимание'), findsOneWidget);
      expect(find.textContaining('истекает через 2'), findsOneWidget);

      // Dismiss the expired one from its menu: the expiring one takes over.
      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await settle(tester);
      await tester.tap(find.text('Скрыть'));
      await settle(tester);
      expect(f.updates.dismissedAlerts, contains('sub.expired:s2'));
      await tester.tap(find.byIcon(Icons.close_rounded));
      await settle(tester);
      expect(find.text('Внимание'), findsNothing);
      expect(find.textContaining('истекает через 2'), findsOneWidget);
      expect(find.text('+1'), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('no alerts → nothing rendered', (tester) async {
      final (state, f) = await bootApp(tester, data: data(days: 30));
      await settle(tester);
      expect(find.byKey(const ValueKey('alert-row')), findsNothing);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('reduced motion: row appears without a leaked animation', (tester) async {
      reducedMotion(tester);
      final (state, f) = await bootApp(tester, data: data());
      await settle(tester);
      expect(find.textContaining('истекает через 2'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('desktop: the row sits at the top of the rail', (tester) async {
      final (state, f) = await bootApp(tester, size: const Size(1280, 800), data: data());
      await settle(tester);
      expect(find.textContaining('истекает через 2'), findsOneWidget);
      final row = tester.getTopLeft(find.byKey(const ValueKey('alert-row')));
      final quick = tester.getTopLeft(find.text('БЫСТРЫЕ НАСТРОЙКИ'));
      expect(row.dy, lessThan(quick.dy));
      expect(row.dx, greaterThan(600));
      await shutdownApp(tester, state, features: f);
    });
  });
}
