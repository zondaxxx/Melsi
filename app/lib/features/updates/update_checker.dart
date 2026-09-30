// Once-a-day GitHub release check. Fails silently: offline, rate-limited
// (403) or a malformed answer keep whatever was known before, and the UI
// only ever says "a newer version exists", never "check failed".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/features.dart';
import '../../ui/screens/settings_screen.dart' show SettingsScreen;
import 'semver.dart';

class UpdateChecker extends FeatureService {
  UpdateChecker(super.app, super.features);

  static const releasesUrl = 'https://api.github.com/repos/zondaxxx/melsi/releases/latest';
  static const throttle = Duration(hours: 24);
  static const requestTimeout = Duration(seconds: 12);

  /// `app.sections['updates']`: the last successful answer.
  static const sectionName = 'updates';

  /// Version this build reports (the About row's number).
  static String get currentVersion => SettingsScreen.appVersion;

  /// Latest release tag without the `v` (`1.2.0`), from the last check.
  String? latestTag;
  String? latestUrl;
  DateTime? checkedAt;

  /// A request is in flight (the About row shows a spinner).
  bool checking = false;

  /// Alerts hidden for this session ([AppAlert.id]s). In memory on
  /// purpose: an expiring subscription deserves a reminder on the next
  /// launch; only a skipped version is remembered (`settings.skippedVersion`).
  final Set<String> dismissedAlerts = {};

  /// A newer release the user has not skipped.
  bool get available {
    final latest = latestTag;
    if (latest == null || latest == app.settings.skippedVersion) return false;
    return isNewerVersion(latest, currentVersion);
  }

  @override
  Future<void> load() async {
    _readSection();
    features.commands.register(AppCommand(
      id: 'update.check',
      titleKey: 'update.check',
      group: 'palette.g.actions',
      icon: Icons.system_update_alt_rounded,
      keywords: const ['update', 'release', 'version', 'обновление', 'версия'],
      run: (context) => available ? openRelease() : checkNow(),
    ));
    // Not awaited: app start must not wait for GitHub.
    unawaited(checkIfDue());
  }

  @override
  void onResume() => unawaited(checkIfDue());

  void _readSection() {
    final s = app.sectionOf(sectionName);
    latestTag = s?['latestTag'] as String?;
    latestUrl = s?['latestUrl'] as String?;
    checkedAt = DateTime.tryParse(s?['checkedAt'] as String? ?? '');
    notifyListeners();
  }

  /// Runs a check when the setting is on and the last one is older than
  /// [throttle] (or never happened).
  Future<void> checkIfDue() async {
    if (!networkAllowed || !app.settings.checkUpdates) return;
    final last = app.settings.lastUpdateCheck;
    if (last != null && now().difference(last) < throttle) return;
    await checkNow();
  }

  /// Unconditional check (the About row / the palette command). Gated only
  /// by [networkAllowed] and by a check already running.
  Future<void> checkNow() async {
    if (!networkAllowed || checking) return;
    checking = true;
    notifyListeners();
    final client = features.httpClient();
    try {
      final r = await client
          .get(Uri.parse(releasesUrl), headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'melsi/${SettingsScreen.appVersion}',
          })
          .timeout(requestTimeout);
      if (r.statusCode == 200) {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is! Map) throw const FormatException('release');
        var tag = (j['tag_name'] as String? ?? '').trim();
        if (tag.startsWith('v') || tag.startsWith('V')) tag = tag.substring(1);
        if (tag.isEmpty || Semver.parse(tag) == null) throw const FormatException('tag');
        latestTag = tag;
        latestUrl = j['html_url'] as String?;
        checkedAt = now();
        app.setSection(sectionName, {
          'latestTag': latestTag,
          'latestUrl': latestUrl,
          'checkedAt': checkedAt!.toIso8601String(),
        });
        _stamp();
      } else if (r.statusCode == 403 || r.statusCode == 429) {
        // Rate limited: back off for the full day rather than retry on
        // every resume. Anything else (5xx) is retried next time.
        _stamp();
      }
    } catch (_) {
      // Offline / timeout / bad JSON: keep the previous result, retry later.
    } finally {
      client.close();
      checking = false;
      notifyListeners();
    }
  }

  void _stamp() =>
      app.updateSettings((s) => s.lastUpdateCheck = now(), affectsConfig: false);

  /// Opens the release page of the latest version.
  Future<void> openRelease() async {
    final u = Uri.tryParse(latestUrl ?? '');
    if (u == null) return;
    try {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Never mention [latestTag] again (persisted).
  void skipLatest() {
    final tag = latestTag;
    if (tag == null) return;
    app.updateSettings((s) => s.skippedVersion = tag, affectsConfig: false);
    notifyListeners();
  }

  /// Hides one alert until the next launch.
  void dismiss(String alertId) {
    if (dismissedAlerts.add(alertId)) notifyListeners();
  }
}
