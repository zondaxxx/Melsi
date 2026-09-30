import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:melsi/features/updates/semver.dart';
import 'package:melsi/features/updates/update_checker.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';
import 'package:melsi/state/store.dart';
import 'package:melsi/ui/screens/settings_screen.dart';

import '../ui/fakes.dart';
import '../ui/harness.dart';

/// App state with networking on (the checker gates on it) but nothing
/// loaded, so no timers or subscriptions start.
AppState _onlineState() => AppState(
      store: MemoryStateStore({}),
      vpn: FakeVpn(),
      apps: FakeApps(),
      enableNetwork: true,
    );

/// GitHub stand-in: answers the releases URL with [status] and [tag]; counts
/// the calls.
class _GitHub {
  _GitHub({this.tag = 'v9.9.9', this.status = 200, this.offline = false});
  String tag;
  int status;
  bool offline;
  int calls = 0;

  late final http.Client client = MockClient((req) async {
    if (req.url.toString() != UpdateChecker.releasesUrl) return http.Response('', 404);
    calls++;
    expect(req.headers['Accept'], 'application/vnd.github+json');
    if (offline) throw http.ClientException('offline');
    if (status != 200) return http.Response('rate limited', status);
    return http.Response(
      jsonEncode({'tag_name': tag, 'html_url': 'https://github.com/zondaxxx/melsi/releases/tag/$tag'}),
      200,
    );
  });
}

void main() {
  group('Semver', () {
    test('parses tags', () {
      expect(parseSemver('v1.2.3'), const Semver(1, 2, 3));
      expect(parseSemver('1.2'), const Semver(1, 2, 0));
      expect(parseSemver('1.2.3+7'), const Semver(1, 2, 3));
      expect(parseSemver('1.2.3-beta.1')?.preRelease, ['beta', '1']);
      expect(parseSemver('nightly'), isNull);
      expect(parseSemver(''), isNull);
    });

    test('orders releases and pre-releases', () {
      expect(const Semver(1, 0, 1) > const Semver(1, 0, 0), isTrue);
      expect(const Semver(2, 0, 0) > const Semver(1, 9, 9), isTrue);
      expect(parseSemver('1.0.0')! > parseSemver('1.0.0-rc.1')!, isTrue);
      expect(parseSemver('1.0.0-rc.2')! > parseSemver('1.0.0-rc.1')!, isTrue);
      expect(parseSemver('1.0.0-rc.10')! > parseSemver('1.0.0-rc.9')!, isTrue);
      expect(parseSemver('1.0.0-beta')! < parseSemver('1.0.0-beta.1')!, isTrue);
      expect(isNewerVersion('v1.0.1', '1.0.0'), isTrue);
      expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
      expect(isNewerVersion('garbage', '1.0.0'), isFalse);
    });
  });

  group('UpdateChecker', () {
    test('a newer tag makes an update available and is persisted', () async {
      final state = _onlineState();
      final gh = _GitHub();
      final clock = FakeClock();
      final f = testFeatures(state, client: gh.client, clock: clock.call);
      await f.updates.load();
      await pumpEventQueue();
      expect(gh.calls, 1);
      expect(f.updates.latestTag, '9.9.9');
      expect(f.updates.available, isTrue);
      expect(f.updates.latestUrl, contains('v9.9.9'));
      expect(state.sectionOf('updates')?['latestTag'], '9.9.9');
      expect(state.settings.lastUpdateCheck, clock.now);
      expect(f.commands.byId('update.check'), isNotNull);
      f.dispose();
    });

    test('equal or older tags are not an update', () async {
      for (final tag in ['v${SettingsScreen.appVersion}', 'v0.0.1', 'nightly']) {
        final state = _onlineState();
        final gh = _GitHub(tag: tag);
        final f = testFeatures(state, client: gh.client);
        await f.updates.load();
        await pumpEventQueue();
        expect(f.updates.available, isFalse, reason: tag);
        f.dispose();
      }
    });

    test('a skipped version stays quiet', () async {
      final state = _onlineState();
      final gh = _GitHub();
      final f = testFeatures(state, client: gh.client);
      await f.updates.load();
      await pumpEventQueue();
      expect(f.updates.available, isTrue);
      f.updates.skipLatest();
      expect(state.settings.skippedVersion, '9.9.9');
      expect(f.updates.available, isFalse);
      // A newer release than the skipped one shows again.
      gh.tag = 'v10.0.0';
      await f.updates.checkNow();
      expect(f.updates.available, isTrue);
      f.dispose();
    });

    test('checks at most once a day', () async {
      final state = _onlineState();
      final gh = _GitHub();
      final clock = FakeClock();
      final f = testFeatures(state, client: gh.client, clock: clock.call);
      await f.updates.load();
      await pumpEventQueue();
      expect(gh.calls, 1);

      clock.advance(const Duration(hours: 23));
      f.updates.onResume();
      await pumpEventQueue();
      expect(gh.calls, 1, reason: 'throttled');

      clock.advance(const Duration(hours: 2));
      f.updates.onResume();
      await pumpEventQueue();
      expect(gh.calls, 2);

      // Manual check ignores the throttle.
      await f.updates.checkNow();
      expect(gh.calls, 3);
      f.dispose();
    });

    test('the setting turns the daily check off', () async {
      final state = _onlineState();
      state.settings.checkUpdates = false;
      final gh = _GitHub();
      final f = testFeatures(state, client: gh.client);
      await f.updates.load();
      await pumpEventQueue();
      expect(gh.calls, 0);
      f.dispose();
    });

    test('403 is silent and keeps the previous result', () async {
      final state = _onlineState();
      state.sections['updates'] = {
        'latestTag': '9.9.9',
        'latestUrl': 'https://r.example/9.9.9',
        'checkedAt': '2026-09-30T12:00:00.000',
      };
      final gh = _GitHub(status: 403);
      final clock = FakeClock();
      final f = testFeatures(state, client: gh.client, clock: clock.call);
      await f.updates.load();
      await pumpEventQueue();
      expect(gh.calls, 1);
      expect(f.updates.latestTag, '9.9.9');
      expect(f.updates.available, isTrue);
      expect(f.updates.checking, isFalse);
      // Rate limited: do not hammer GitHub for the rest of the day.
      expect(state.settings.lastUpdateCheck, clock.now);
      f.dispose();
    });

    test('offline is silent and retries next time', () async {
      final state = _onlineState();
      final gh = _GitHub(offline: true);
      final f = testFeatures(state, client: gh.client);
      await f.updates.load();
      await pumpEventQueue();
      expect(gh.calls, 1);
      expect(f.updates.latestTag, isNull);
      expect(f.updates.available, isFalse);
      expect(state.settings.lastUpdateCheck, isNull);
      f.updates.onResume();
      await pumpEventQueue();
      expect(gh.calls, 2);
      f.dispose();
    });

    test('no network → no request at all', () async {
      final state = testState();
      final gh = _GitHub();
      final f = testFeatures(state, client: gh.client);
      await f.updates.load();
      await f.updates.checkNow();
      expect(gh.calls, 0);
      f.dispose();
    });
  });

  group('Settings rows', () {
    Future<void> openSettings(WidgetTester tester, Finder target) async {
      await tester.tap(find.text('Настройки'));
      await settle(tester);
      await tester.scrollUntilVisible(
        target,
        240,
        scrollable: find
            .descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
            .first,
      );
      await settle(tester);
    }

    testWidgets('About shows the available version', (tester) async {
      final (state, f) = await bootApp(tester, data: {
        'sections': {
          'updates': {
            'latestTag': '9.9.9',
            'latestUrl': 'https://github.com/zondaxxx/melsi/releases/tag/v9.9.9',
            'checkedAt': '2026-10-01T10:00:00.000',
          },
        },
      });
      await openSettings(tester, find.byKey(const ValueKey('update-check')));
      expect(find.text('9.9.9 доступна'), findsOneWidget);
      expect(find.text('Проверить обновления'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('About says up to date after a check, and the App switch persists',
        (tester) async {
      final (state, f) = await bootApp(tester, data: {
        'sections': {
          'updates': {
            'latestTag': SettingsScreen.appVersion,
            'latestUrl': 'https://github.com/zondaxxx/melsi/releases/latest',
            'checkedAt': '2026-10-01T10:00:00.000',
          },
        },
      });
      await openSettings(tester, find.byKey(const ValueKey('update-setting')));
      expect(find.text('Проверять обновления'), findsOneWidget);
      expect(state.settings.checkUpdates, isTrue);
      await tester.tap(find.byKey(const ValueKey('update-setting')));
      await settle(tester);
      expect(state.settings.checkUpdates, isFalse);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('update-check')),
        240,
        scrollable: find
            .descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
            .first,
      );
      await settle(tester);
      expect(find.text('Актуальная версия'), findsOneWidget);
      await shutdownApp(tester, state, features: f);
    });
  });
}
