import 'dart:io';

import 'package:flutter/services.dart';

/// An app the user can pick for per-app routing / Game Mode.
class InstalledApp {
  InstalledApp({required this.id, required this.label, this.system = false});

  /// Android package name, or desktop process name.
  final String id;
  final String label;
  final bool system;
}

/// Lists apps: Android installed packages (MethodChannel), desktop running
/// processes. iOS has no per-app routing — returns empty.
class PlatformApps {
  PlatformApps({MethodChannel? channel})
      : _ch = channel ?? const MethodChannel('app.melsi/vpn');

  final MethodChannel _ch;
  final Map<String, Uint8List?> _icons = {};

  bool get supported => !Platform.isIOS;
  bool get isAndroid => Platform.isAndroid;

  Future<List<InstalledApp>> list() async {
    if (Platform.isIOS) return const [];
    if (Platform.isAndroid) {
      try {
        final raw = await _ch.invokeListMethod<Map>('installedApps') ?? const [];
        final apps = raw
            .map((m) => InstalledApp(
                  id: m['package'] as String? ?? '',
                  label: m['label'] as String? ?? m['package'] as String? ?? '',
                  system: m['system'] == true,
                ))
            .where((a) => a.id.isNotEmpty)
            .toList()
          ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
        return apps;
      } catch (_) {
        return const [];
      }
    }
    return _processes();
  }

  Future<Uint8List?> icon(String package) async {
    if (!Platform.isAndroid) return null;
    if (_icons.containsKey(package)) return _icons[package];
    try {
      final bytes =
          await _ch.invokeMethod<Uint8List>('appIcon', {'package': package});
      return _icons[package] = bytes;
    } catch (_) {
      return _icons[package] = null;
    }
  }

  Future<List<InstalledApp>> _processes() async {
    final names = <String>{};
    try {
      if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/fo', 'csv', '/nh']);
        for (final line in '${r.stdout}'.split('\n')) {
          final m = RegExp(r'^"([^"]+)"').firstMatch(line.trim());
          if (m != null) names.add(m.group(1)!);
        }
      } else {
        final r = await Process.run('ps', ['-axco', 'comm']);
        for (final line in '${r.stdout}'.split('\n').skip(1)) {
          final n = line.trim();
          if (n.isNotEmpty) names.add(n);
        }
      }
    } catch (_) {}
    const noise = {
      'svchost.exe', 'System', 'Idle', 'Registry', 'smss.exe', 'csrss.exe',
      'wininit.exe', 'services.exe', 'lsass.exe', 'conhost.exe', 'dwm.exe',
      'kworker', 'ps', 'bash', 'zsh', 'sh', 'launchd', 'kernel_task',
      'melsi-core', 'melsi-core.exe', 'tasklist.exe',
    };
    final list = names
        .where((n) => !noise.contains(n) && !n.startsWith('kworker'))
        .map((n) => InstalledApp(id: n, label: n))
        .toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }
}
