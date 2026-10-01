import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists the app state as one JSON document.
abstract class StateStore {
  Future<Map<String, dynamic>?> load();

  /// Debounced save; [snapshot] is called when the write actually happens.
  void scheduleSave(Map<String, dynamic> Function() snapshot);

  /// Write any pending save now.
  Future<void> flush();

  /// Directory for runtime files (sing-box cache, logs).
  Future<String> cacheDir();
}

/// `getApplicationSupportDirectory()/melsi_state.json`, atomic writes
/// (write `.tmp`, then rename) debounced by [debounce].
class FileStateStore implements StateStore {
  FileStateStore({this.debounce = const Duration(milliseconds: 400), Future<Directory> Function()? dir})
      : _dirFn = dir ?? getApplicationSupportDirectory;

  final Duration debounce;
  final Future<Directory> Function() _dirFn;
  Timer? _timer;
  Map<String, dynamic> Function()? _pending;
  Future<void> _writing = Future.value();
  Directory? _dir;

  Future<Directory> _root() async {
    final d = _dir ??= await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _file() async =>
      File('${(await _root()).path}${Platform.pathSeparator}melsi_state.json');

  @override
  Future<String> cacheDir() async => (await _root()).path;

  @override
  Future<Map<String, dynamic>?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      return (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  @override
  void scheduleSave(Map<String, dynamic> Function() snapshot) {
    _pending = snapshot;
    _timer?.cancel();
    _timer = Timer(debounce, flush);
  }

  @override
  Future<void> flush() {
    _timer?.cancel();
    final snap = _pending;
    _pending = null;
    if (snap == null) return _writing;
    return _writing = _writing.then((_) async {
      try {
        final f = await _file();
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(snap()), flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }
}

/// In-memory store for tests.
class MemoryStateStore implements StateStore {
  MemoryStateStore([this.data]);
  Map<String, dynamic>? data;

  @override
  Future<Map<String, dynamic>?> load() async => data;

  @override
  void scheduleSave(Map<String, dynamic> Function() snapshot) {
    data = jsonDecode(jsonEncode(snapshot())) as Map<String, dynamic>;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<String> cacheDir() async => Directory.systemTemp.path;
}
