// One-file backup of the whole persisted state, and its restore (replace or
// merge). The envelope wraps `AppState.toJson()` so a restore is just
// `replaceFromJson`; the runtime secret is stripped because it is useless on
// another machine and would only leak into shared files.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';
import '../../state/features.dart';
import '../../ui/screens/settings_screen.dart' show SettingsScreen;
import '../stats/stats_models.dart';
import 'backup_sheet.dart';

/// What a backup file holds, read without applying it.
class BackupSummary {
  const BackupSummary({
    required this.format,
    required this.createdAt,
    required this.platform,
    required this.app,
    required this.subscriptions,
    required this.nodes,
    required this.favourites,
    required this.state,
  });

  final int format;
  final DateTime? createdAt;
  final String? platform;

  /// App version that wrote the file.
  final String? app;
  final int subscriptions;
  final int nodes;
  final int favourites;

  /// The `AppState.toJson()` document inside the envelope.
  final Map<String, dynamic> state;
}

class BackupService extends FeatureService {
  BackupService(super.app, super.features);

  /// Envelope marker / format version.
  static const format = 1;

  @override
  Future<void> load() async {
    features.commands.registerAll([
      AppCommand(
        id: 'backup.create',
        titleKey: 'backup.save',
        group: 'palette.g.tools',
        icon: Icons.save_alt_rounded,
        keywords: const ['backup', 'export', 'резервная', 'копия', 'бэкап'],
        run: saveBackup,
      ),
      AppCommand(
        id: 'backup.restore',
        titleKey: 'backup.restore',
        group: 'palette.g.tools',
        icon: Icons.settings_backup_restore_rounded,
        keywords: const ['backup', 'restore', 'import', 'восстановить', 'копия'],
        run: restoreBackupFromFile,
      ),
    ]);
  }

  /// The backup document (pretty-printed: people do open these in editors).
  String export() {
    final state = Map<String, dynamic>.of(app.toJson())..remove('lastSecret');
    return const JsonEncoder.withIndent('  ').convert({
      'melsi_backup': format,
      'createdAt': now().toIso8601String(),
      'platform': Platform.operatingSystem,
      'app': SettingsScreen.appVersion,
      'state': state,
    });
  }

  /// File name for a backup written today.
  String suggestedFileName() {
    final d = now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'melsi-backup-${d.year}-${two(d.month)}-${two(d.day)}.json';
  }

  /// Validates [json] and counts what it holds. Throws [FormatException]
  /// for anything that is not a Melsi backup.
  BackupSummary inspect(String json) {
    Object? doc;
    try {
      doc = jsonDecode(json);
    } catch (_) {
      throw const FormatException('not JSON');
    }
    if (doc is! Map) throw const FormatException('not an object');
    final marker = doc['melsi_backup'];
    if (marker is! int || marker != format) throw const FormatException('unsupported backup');
    final state = doc['state'];
    if (state is! Map) throw const FormatException('no state');
    _validateState(state);
    int count(Object? v) => v is List ? v.length : 0;
    return BackupSummary(
      format: marker.toInt(),
      createdAt: DateTime.tryParse(doc['createdAt']?.toString() ?? ''),
      platform: doc['platform']?.toString(),
      app: doc['app']?.toString(),
      subscriptions: count(state['subscriptions']),
      nodes: count(state['nodes']),
      favourites: count(state['favourites']),
      state: state.cast<String, dynamic>(),
    );
  }

  static void _validateState(Map state) {
    try {
      if (state['nodes'] is! List || state['subscriptions'] is! List) {
        throw const FormatException('missing server lists');
      }
      for (final key in ['favourites', 'recents']) {
        final values = state[key];
        if (values != null && (values is! List || values.any((value) => value is! String))) {
          throw const FormatException('invalid server references');
        }
      }
      for (final key in ['routing', 'game', 'settings', 'chain', 'sections']) {
        if (state[key] != null && state[key] is! Map) {
          throw const FormatException('invalid settings');
        }
      }
      if (state['selectedNodeId'] != null && state['selectedNodeId'] is! String) {
        throw const FormatException('invalid selection');
      }
      for (final value in state['nodes'] as List) {
        final node = ProxyNode.fromJson((value as Map).cast<String, dynamic>());
        if (node.id.isEmpty || node.outbound.isEmpty) throw const FormatException('invalid node');
      }
      for (final value in state['subscriptions'] as List) {
        Subscription.fromJson((value as Map).cast<String, dynamic>());
      }
      Map<String, dynamic> section(String key) =>
          (state[key] as Map? ?? const {}).cast<String, dynamic>();
      RoutingSettings.fromJson(section('routing'));
      GameSettings.fromJson(section('game'));
      AppSettings.fromJson(section('settings'));
      ChainSettings.fromJson(section('chain'));
      for (final value in section('sections').values) {
        if (value is! Map) throw const FormatException('invalid feature section');
      }
      _validateSections(section('sections'));
    } catch (_) {
      throw const FormatException('invalid backup state');
    }
  }

  static void _validateSections(Map<String, dynamic> sections) {
    Map<String, dynamic> feature(String key) =>
        (sections[key] as Map? ?? const {}).cast<String, dynamic>();
    final netcheck = feature('netcheck');
    for (final key in ['realIp', 'exitIp']) {
      final value = netcheck[key];
      if (value != null) IpInfo.fromJson((value as Map).cast<String, dynamic>());
    }
    void speed(Object? value) {
      if (value != null) SpeedResult.fromJson(value as Map);
    }
    speed(netcheck['lastSpeed']);
    for (final results in (netcheck['speedResults'] as Map? ?? const {}).values) {
      for (final value in results as List) {
        speed(value);
      }
    }
    final stats = feature('stats');
    for (final value in stats['sessions'] as List? ?? const []) {
      final record = SessionRecord.fromJson((value as Map).cast<String, dynamic>());
      if (record == null) throw const FormatException('invalid session');
    }
    for (final value in stats['days'] as List? ?? const []) {
      final day = DayTotal.fromJson((value as Map).cast<String, dynamic>());
      if (day == null) throw const FormatException('invalid day');
    }
    final updates = feature('updates');
    for (final key in ['latestTag', 'latestUrl', 'checkedAt']) {
      if (updates[key] != null && updates[key] is! String) {
        throw const FormatException('invalid update cache');
      }
    }
  }

  /// Applies [json]. Replace swaps the whole state; merge folds the backup
  /// into what is here (see [merge]). Either way the feature services
  /// reload their sections and a running tunnel re-applies through the
  /// usual apply flow. Invalid input posts `backup.invalid` and throws.
  Future<void> restore(String json, {required bool merge}) async {
    final BackupSummary summary;
    try {
      summary = inspect(json);
    } on FormatException {
      app.notice('backup.invalid', kind: NoticeKind.error);
      rethrow;
    }
    final next = merge ? BackupService.merge(app.toJson(), summary.state) : summary.state;
    app.replaceFromJson(next);
    await features.reloadAll();
    app.notice('backup.done', kind: NoticeKind.success);
  }

  /// Folds [incoming] (a backup's state) into [current]:
  /// - subscriptions match by URL (local groups by id); the newer
  ///   `updatedAt` wins together with its nodes;
  /// - manual nodes match by id (union);
  /// - favourites, recents and the custom domain lists are unions;
  /// - routing, game, settings, chain and sections stay as they are here
  ///   (missing sections are taken from the backup).
  static Map<String, dynamic> merge(Map<String, dynamic> current, Map<String, dynamic> incoming) {
    List<Map<String, dynamic>> maps(Object? v) => [
          for (final e in (v as List? ?? const []))
            if (e is Map) e.cast<String, dynamic>(),
        ];
    List<String> strings(Object? v) => [for (final e in (v as List? ?? const [])) e.toString()];
    List<String> union(Object? a, Object? b) {
      final out = <String>[];
      for (final s in [...strings(a), ...strings(b)]) {
        if (!out.contains(s)) out.add(s);
      }
      return out;
    }

    String subKey(Map<String, dynamic> s) => (s['url'] as String?) ?? 'id:${s['id']}';
    DateTime? updatedAt(Map<String, dynamic> s) =>
        DateTime.tryParse(s['updatedAt']?.toString() ?? '');

    // key -> (subscription json, came from the backup)
    final subs = <String, (Map<String, dynamic>, bool)>{};
    for (final s in maps(current['subscriptions'])) {
      subs[subKey(s)] = (s, false);
    }
    for (final s in maps(incoming['subscriptions'])) {
      final k = subKey(s);
      final cur = subs[k];
      if (cur == null) {
        subs[k] = (s, true);
        continue;
      }
      final a = updatedAt(cur.$1);
      final b = updatedAt(s);
      final newer = a == null ? b != null : (b != null && b.isAfter(a));
      if (newer) subs[k] = (s, true);
    }
    // Subscription id -> whether its nodes come from the backup.
    final fromBackup = <String, bool>{
      for (final e in subs.values) e.$1['id'].toString(): e.$2,
    };

    final nodes = <String, Map<String, dynamic>>{};
    void take(Iterable<Map<String, dynamic>> ns, {required bool backup}) {
      for (final n in ns) {
        final sid = n['subscriptionId'] as String?;
        // A subscription's nodes travel with the winning copy; manual nodes
        // are a union keyed by id (ids are content hashes, so the same
        // server is the same id on both sides).
        if (sid != null && fromBackup[sid] != backup) continue;
        nodes.putIfAbsent(n['id'].toString(), () => n);
      }
    }

    take(maps(current['nodes']), backup: false);
    take(maps(incoming['nodes']), backup: true);

    final routing = <String, dynamic>{
      ...?(incoming['routing'] as Map?)?.cast<String, dynamic>(),
      ...?(current['routing'] as Map?)?.cast<String, dynamic>(),
    };
    for (final k in ['directDomains', 'proxyDomains', 'blockDomains']) {
      routing[k] = union((current['routing'] as Map?)?[k], (incoming['routing'] as Map?)?[k]);
    }

    final sections = <String, dynamic>{
      ...?(incoming['sections'] as Map?)?.cast<String, dynamic>(),
      ...?(current['sections'] as Map?)?.cast<String, dynamic>(),
    };

    return {
      ...current,
      'version': current['version'] ?? incoming['version'] ?? 1,
      'subscriptions': [for (final e in subs.values) e.$1],
      'nodes': nodes.values.toList(),
      'selectedNodeId': current['selectedNodeId'] ?? incoming['selectedNodeId'],
      'routing': routing,
      'favourites': union(current['favourites'], incoming['favourites']),
      'recents': union(current['recents'], incoming['recents']).take(AppState.maxRecents).toList(),
      'sections': sections,
    };
  }
}
