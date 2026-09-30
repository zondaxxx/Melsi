import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/features/backup/backup_service.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/ui/screens/settings_screen.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

ProxyNode _node(String host, {String? sub}) => ProxyNode(
      id: ProxyNode.computeId({'type': 'vless', 'server': host, 'server_port': 443}),
      name: host,
      outbound: {'type': 'vless', 'server': host, 'server_port': 443, 'uuid': 'secret-$host'},
      subscriptionId: sub,
    );

/// A state with one subscription (two nodes), one manual node and a
/// favourite — the shape a real backup has.
Future<AppState> _populated() async {
  final s = testState();
  s.subscriptions.add(Subscription(
    id: 'sub1',
    name: 'Prime',
    url: 'https://p.example/sub',
    updatedAt: DateTime(2026, 9, 1),
    expire: DateTime(2027, 1, 1),
    total: 100,
    download: 10,
  ));
  s.nodes.addAll([_node('a.prime', sub: 'sub1'), _node('b.prime', sub: 'sub1')]);
  await s.importText(kSampleVless);
  s.toggleFavourite(s.nodes.last.id);
  s.updateRouting((r) => r.proxyDomains.add('example.org'));
  return s;
}

void main() {
  group('BackupService', () {
    test('export wraps the state and drops the runtime secret', () async {
      final src = await _populated();
      final f = testFeatures(src, clock: FakeClock().call);
      final json = f.backup.export();
      final doc = jsonDecode(json) as Map<String, dynamic>;
      expect(doc['melsi_backup'], 1);
      expect(doc['app'], SettingsScreen.appVersion);
      expect(doc['platform'], isNotEmpty);
      expect(DateTime.tryParse(doc['createdAt'] as String), FakeClock().now);
      final state = doc['state'] as Map<String, dynamic>;
      expect(state.containsKey('lastSecret'), isFalse);
      expect(json, isNot(contains('lastSecret')));
      expect((state['subscriptions'] as List).length, 1);
      expect((state['nodes'] as List).length, 3);
      expect((state['favourites'] as List).length, 1);
      expect(f.backup.suggestedFileName(), 'melsi-backup-2026-10-01.json');
      f.dispose();
    });

    test('inspect counts; anything else is a FormatException', () async {
      final src = await _populated();
      final f = testFeatures(src);
      final s = f.backup.inspect(f.backup.export());
      expect((s.subscriptions, s.nodes, s.favourites), (1, 3, 1));
      expect(s.app, SettingsScreen.appVersion);
      for (final bad in ['', 'not json', '[]', '{"a":1}', '{"melsi_backup":1}', jsonEncode(src.toJson())]) {
        expect(() => f.backup.inspect(bad), throwsFormatException, reason: bad);
      }
      f.dispose();
    });

    test('restore (replace) into a fresh state reproduces everything', () async {
      final src = await _populated();
      final json = testFeatures(src).backup.export();

      final dst = testState();
      final f = testFeatures(dst);
      final notices = <Notice>[];
      dst.notices.listen(notices.add);
      await f.backup.restore(json, merge: false);
      await Future<void>.delayed(Duration.zero);

      expect(dst.subscriptions.single.name, 'Prime');
      expect(dst.subscriptions.single.expire, DateTime(2027, 1, 1));
      expect(dst.nodes.map((n) => n.name), src.nodes.map((n) => n.name));
      expect(dst.nodesOf('sub1').length, 2);
      expect(dst.favouriteIds, src.favouriteIds);
      expect(dst.selectedNodeId, src.selectedNodeId);
      expect(dst.routing.proxyDomains, ['example.org']);
      expect(notices.map((n) => n.key), ['backup.done']);
      f.dispose();
    });

    test('restore (replace) wipes what was there', () async {
      final src = await _populated();
      final json = testFeatures(src).backup.export();
      final dst = testState();
      await dst.importText(kSampleVless.replaceAll('nl1.example.com', 'zz.example.com'));
      dst.toggleFavourite(dst.nodes.single.id);
      final f = testFeatures(dst);
      await f.backup.restore(json, merge: false);
      expect(dst.nodes.any((n) => n.server == 'zz.example.com'), isFalse);
      expect(dst.favouriteIds, src.favouriteIds);
      f.dispose();
    });

    test('malformed input → FormatException and the invalid notice', () async {
      final dst = testState();
      final f = testFeatures(dst);
      final notices = <Notice>[];
      dst.notices.listen(notices.add);
      await expectLater(f.backup.restore('{oops', merge: true), throwsFormatException);
      await expectLater(f.backup.restore('{"hello":1}', merge: false), throwsFormatException);
      await Future<void>.delayed(Duration.zero);
      expect(notices.map((n) => n.key), ['backup.invalid', 'backup.invalid']);
      expect(notices.first.kind, NoticeKind.error);
      f.dispose();
    });

    test('merge keeps existing favourites and settings, adds the new servers', () async {
      final src = await _populated();
      final json = testFeatures(src).backup.export();

      final dst = testState();
      await dst.importText(kSampleVless.replaceAll('nl1.example.com', 'zz.example.com'));
      final mine = dst.nodes.single.id;
      dst.toggleFavourite(mine);
      dst.updateSettings((s) => s.locale = 'en', affectsConfig: false);
      dst.updateRouting((r) => r.proxyDomains.add('mine.org'));
      final f = testFeatures(dst);
      await f.backup.restore(json, merge: true);

      expect(dst.favouriteIds.first, mine, reason: 'existing favourites survive');
      expect(dst.favouriteIds, containsAll(src.favouriteIds));
      expect(dst.nodes.length, 4, reason: 'my manual node + 3 from the backup');
      expect(dst.subscriptions.single.url, 'https://p.example/sub');
      expect(dst.settings.locale, 'en', reason: 'settings untouched');
      expect(dst.routing.proxyDomains, ['mine.org', 'example.org']);
      expect(dst.selectedNodeId, mine);
      f.dispose();
    });

    test('merge matches subscriptions by url and keeps the newer copy', () {
      Map<String, dynamic> doc(String subId, DateTime at, List<String> hosts) => {
            'subscriptions': [
              {'id': subId, 'name': 'Prime', 'url': 'https://p.example/sub', 'updatedAt': at.toIso8601String()},
            ],
            'nodes': [for (final h in hosts) _node(h, sub: subId).toJson()],
            'favourites': const [],
            'recents': const [],
            'routing': RoutingSettings().toJson(),
          };
      final older = doc('old', DateTime(2026, 1, 1), ['a', 'b']);
      final newer = doc('new', DateTime(2026, 6, 1), ['b', 'c']);

      var m = BackupService.merge(older, newer);
      expect((m['subscriptions'] as List).single['id'], 'new');
      expect((m['nodes'] as List).map((n) => n['name']), ['b', 'c']);

      m = BackupService.merge(newer, older);
      expect((m['subscriptions'] as List).single['id'], 'new');
      expect((m['nodes'] as List).map((n) => n['name']), ['b', 'c']);

      // Two different subscriptions simply coexist.
      final other = doc('x', DateTime(2026, 2, 1), ['q']);
      (other['subscriptions'] as List).single['url'] = 'https://q.example/sub';
      m = BackupService.merge(older, other);
      expect((m['subscriptions'] as List).length, 2);
      expect((m['nodes'] as List).length, 3);
    });
  });

  group('restore sheet', () {
    testWidgets('paste from text → summary → replace restores the state', (tester) async {
      stubPlatformChannels(tester);
      final src = await _populated();
      final json = testFeatures(src).backup.export();

      final (state, f) = await bootApp(tester);
      expect(state.nodes, isEmpty);
      await tester.tap(find.text('Настройки'));
      await settle(tester);
      final settingsScroll = find
          .descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('backup-paste')), 240,
          scrollable: settingsScroll);
      await settle(tester);
      expect(find.text('Сохранить резервную копию'), findsOneWidget);
      expect(find.text('Восстановить из файла'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('backup-paste')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, json);
      await tester.tap(find.text('OK'));
      await settle(tester);

      expect(find.text('Восстановление'), findsOneWidget);
      expect(find.text('1 подписок · 3 серверов · 1 избранных'), findsOneWidget);
      expect(find.text('Текущие данные будут удалены'), findsOneWidget);
      await tester.tap(find.text('Объединить'));
      await settle(tester);
      expect(find.text('Текущие данные будут удалены'), findsNothing);
      await tester.tap(find.text('Заменить'));
      await settle(tester);

      await tester.tap(find.text('Восстановить'));
      await settle(tester);
      expect(find.text('Восстановление'), findsNothing);
      expect(state.nodes.length, 3);
      expect(state.subscriptions.single.name, 'Prime');
      expect(state.favouriteIds, src.favouriteIds);
      expect(find.text('Восстановлено'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('pasting junk posts the invalid notice and opens no sheet', (tester) async {
      stubPlatformChannels(tester);
      final (state, f) = await bootApp(tester);
      await tester.tap(find.text('Настройки'));
      await settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('backup-paste')),
        240,
        scrollable: find
            .descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
            .first,
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('backup-paste')));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'vless://not-a-backup');
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.text('Восстановление'), findsNothing);
      expect(find.text('Это не резервная копия Melsi'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('restoring while connected re-applies through the apply flow', (tester) async {
      stubPlatformChannels(tester);
      final src = await _populated();
      final json = testFeatures(src).backup.export();
      final vpn = FakeVpn();
      final (state, f) = await bootApp(tester, vpn: vpn);
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.connected, isTrue);
      expect(vpn.starts, 1);

      await f.backup.restore(json, merge: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.applyPhase, ApplyPhase.pending);
      await tester.pump(const Duration(milliseconds: 1300));
      await settle(tester);
      expect(vpn.starts, 2, reason: 'one restart for the restore');
      expect(state.connected, isTrue);
      expect(state.nodes.length, 3);
      await tester.pump(const Duration(seconds: 2));
      await shutdownApp(tester, state, features: f);
    });
  });
}
