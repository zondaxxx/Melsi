import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/core/subscription_fetcher.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/store.dart';

import '../ui/fakes.dart';

class PendingFetcher extends SubscriptionFetcher {
  final requests = <Completer<SubscriptionFetchResult>>[];

  @override
  Future<SubscriptionFetchResult> fetch(
    String url, {
    String? userAgent,
    String? subscriptionId,
  }) {
    final request = Completer<SubscriptionFetchResult>();
    requests.add(request);
    return request.future;
  }

  void succeed(int index, String id) => requests[index].complete(
    SubscriptionFetcher.parseResponse(
      kSampleVless,
      const {},
      subscriptionId: id,
    ),
  );
}

void main() {
  AppState makeState(PendingFetcher fetcher, {MemoryStateStore? store}) {
    final app = AppState(
      store: store ?? MemoryStateStore(),
      vpn: FakeVpn(),
      fetcher: fetcher,
      enableNetwork: false,
    );
    app.subscriptions.add(
      Subscription(
        id: 's1',
        name: 'Subscription',
        url: 'https://sub.example/one',
      ),
    );
    return app;
  }

  test(
    'deleted subscription cannot return through a pending download',
    () async {
      final fetcher = PendingFetcher();
      final app = makeState(fetcher);
      addTearDown(app.dispose);
      final pending = app.updateSubscription('s1');
      app.removeSubscription('s1');
      fetcher.succeed(0, 's1');
      expect(await pending, isFalse);
      expect(app.subscriptions, isEmpty);
      expect(app.nodes, isEmpty);
      expect(app.updating, isEmpty);
    },
  );

  test(
    'backup replacement invalidates download without clearing the new request',
    () async {
      final fetcher = PendingFetcher();
      final app = makeState(fetcher);
      addTearDown(app.dispose);
      final old = app.updateSubscription('s1');
      final replacement = app.toJson();
      app.replaceFromJson(replacement);
      final fresh = app.updateSubscription('s1');
      expect(fetcher.requests, hasLength(2));
      fetcher.succeed(0, 's1');
      expect(await old, isFalse);
      expect(app.nodes, isEmpty);
      expect(app.updating, {'s1'});
      fetcher.succeed(1, 's1');
      expect(await fresh, isTrue);
      expect(app.nodes, hasLength(1));
      expect(app.updating, isEmpty);
    },
  );

  test(
    'late success or failure after disposal cannot save or notify',
    () async {
      for (final fail in [false, true]) {
        final fetcher = PendingFetcher();
        final store = MemoryStateStore();
        final app = makeState(fetcher, store: store);
        final pending = app.updateSubscription('s1');
        app.dispose();
        if (fail) {
          fetcher.requests.single.completeError(StateError('offline'));
        } else {
          fetcher.succeed(0, 's1');
        }
        expect(await pending, isFalse);
        expect(store.data, isNull);
        expect(app.nodes, isEmpty);
      }
    },
  );

  test('bulk refresh waits for an existing download instead of reporting success early', () async {
    final fetcher = PendingFetcher();
    final app = makeState(fetcher);
    addTearDown(app.dispose);
    final notices = <Notice>[];
    final listener = app.notices.listen(notices.add);
    addTearDown(listener.cancel);
    final pending = app.updateSubscription('s1', quiet: true);
    final bulk = app.updateAllSubscriptions();
    await Future<void>.delayed(Duration.zero);
    expect(fetcher.requests, hasLength(1));
    expect(notices, isEmpty);
    fetcher.succeed(0, 's1');
    expect(await pending, isTrue);
    await bulk;
    await Future<void>.delayed(Duration.zero);
    expect(notices.single.key, 'notice.allUpdated');
  });

  test(
    'bulk refresh reports partial failure and keeps existing servers',
    () async {
      final fetcher = PendingFetcher();
      final app = makeState(fetcher);
      addTearDown(app.dispose);
      app.subscriptions.add(
        Subscription(id: 's2', name: 'Second', url: 'https://sub.example/two'),
      );
      app.nodes.addAll(
        SubscriptionFetcher.parseResponse(
          kSampleVless,
          const {},
          subscriptionId: 's2',
        ).nodes,
      );
      final notices = <Notice>[];
      final listener = app.notices.listen(notices.add);
      addTearDown(listener.cancel);
      final bulk = app.updateAllSubscriptions();
      fetcher.succeed(0, 's1');
      fetcher.requests[1].completeError(StateError('offline'));
      await bulk;
      await Future<void>.delayed(Duration.zero);
      expect(notices.single.key, 'notice.subsUpdateFailed');
      expect(notices.single.kind, NoticeKind.error);
      expect(notices.single.args, {'ok': '1', 'total': '2'});
      expect(app.nodesOf('s2'), hasLength(1));
      expect(app.updating, isEmpty);
    },
  );
}
