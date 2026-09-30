import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../features/backup/backup_service.dart';
import '../features/clipboard/clipboard_watcher.dart';
import '../features/doctor/diagnostics.dart';
import '../features/netcheck/netcheck_service.dart';
import '../features/palette/palette_service.dart';
import '../features/stats/stats_service.dart';
import '../features/updates/update_checker.dart';
import '../services/vpn_controller.dart';
import 'app_state.dart';
import 'commands.dart';
import 'feature_service.dart';

export '../features/backup/backup_service.dart';
export '../features/clipboard/clipboard_watcher.dart';
export '../features/doctor/diagnostics.dart';
export '../features/netcheck/netcheck_service.dart';
export '../features/palette/palette_service.dart';
export '../features/stats/stats_service.dart';
export '../features/updates/update_checker.dart';
export 'commands.dart';
export 'feature_service.dart';

/// The feature modules, wired to one [AppState]. Everything a feature needs
/// from the outside world (HTTP, clock, clipboard) is injectable so tests
/// run offline and deterministically.
class Features {
  Features(
    this.app, {
    http.Client Function()? httpClient,
    DateTime Function()? clock,
    this.readClipboard,
  })  : httpClient = httpClient ?? http.Client.new,
        clock = clock ?? DateTime.now;

  final AppState app;

  /// Factory for short-lived HTTP clients (close them when done).
  final http.Client Function() httpClient;
  final DateTime Function() clock;

  /// null = platform clipboard (`Clipboard.getData`).
  final Future<String?> Function()? readClipboard;

  final CommandRegistry commands = CommandRegistry();

  late final NetCheckService netcheck = NetCheckService(app, this);
  late final StatsService stats = StatsService(app, this);
  late final ClipboardWatcher clipboard = ClipboardWatcher(app, this);
  late final UpdateChecker updates = UpdateChecker(app, this);
  late final BackupService backup = BackupService(app, this);
  late final Diagnostics doctor = Diagnostics(app, this);
  late final PaletteService palette = PaletteService(app, this);

  List<FeatureService> get all => [netcheck, stats, clipboard, updates, backup, doctor, palette];

  bool _inited = false;

  /// Hooks into [AppState] and loads every service once.
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    app.statusHooks.add(_fanOut);
    app.resumeHooks.add(onResume);
    await Future.wait(all.map((s) => s.load()));
  }

  /// Re-runs every service's [FeatureService.load] (after a restore).
  Future<void> reloadAll() => Future.wait(all.map((s) => s.load()));

  void _fanOut(VpnStatus prev, VpnStatus next) {
    for (final s in all) {
      s.onVpn(prev, next);
    }
  }

  void onResume() {
    for (final s in all) {
      s.onResume();
    }
  }

  void dispose() {
    app.statusHooks.remove(_fanOut);
    app.resumeHooks.remove(onResume);
    for (final s in all) {
      s.dispose();
    }
    commands.dispose();
  }
}

/// Exposes [Features] to the tree (never rebuilds: services are
/// [ChangeNotifier]s the widgets listen to individually).
class FeaturesScope extends InheritedWidget {
  const FeaturesScope({super.key, required this.features, required super.child});
  final Features features;

  static Features of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FeaturesScope>()!.features;

  static Features? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<FeaturesScope>()?.features;

  @override
  bool updateShouldNotify(FeaturesScope old) => old.features != features;
}

extension FeaturesX on BuildContext {
  Features get features => FeaturesScope.of(this);
}
