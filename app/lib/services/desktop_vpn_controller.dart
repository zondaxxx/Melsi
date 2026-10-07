import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import 'engine_api.dart';
import 'vpn_controller.dart';

/// Runs the `melsi-core` daemon (CONTRACT §4).
///
/// The daemon is launched elevated when the config has a TUN inbound
/// (Windows: the app itself is admin via its manifest; macOS: osascript with
/// administrator privileges; Linux: pkexec). System-proxy mode needs no
/// elevation. The daemon outlives the UI, so on relaunch we re-attach to it
/// via the engine `/health` endpoint using the secret in `engine.json`.
class DesktopVpnController extends VpnController {
  DesktopVpnController({Future<Directory> Function()? supportDir})
      : _supportDirFn = supportDir ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirFn;
  final _ctrl = StreamController<VpnState>.broadcast();
  VpnState _state = VpnState.stopped;
  EngineApi? _api;
  Timer? _monitor;
  int _failures = 0;
  bool _stopping = false;
  bool _elevated = false;
  Directory? _dir;
  Process? _xray;

  @override
  Stream<VpnState> get states => _ctrl.stream;

  void _emit(VpnState s) {
    _state = s;
    if (!_ctrl.isClosed) _ctrl.add(s);
  }

  Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final d = await _supportDirFn();
    await d.create(recursive: true);
    return _dir = d;
  }

  String _join(String a, String b) =>
      a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';

  Future<String> _path(String name) async => _join((await _root()).path, name);

  @override
  Future<bool> prepare() async => true;

  // ------------------------------------------------------------ locate core

  /// Finds the `melsi-core` binary: `$MELSI_CORE`, next to the executable
  /// (per-platform bundle layout), then dev fallbacks (`core/dist`).
  static String? locateCore() {
    final exe = Platform.isWindows ? 'melsi-core.exe' : 'melsi-core';
    final env = Platform.environment['MELSI_CORE'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;

    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      if (Platform.isMacOS) '$exeDir$sep..${sep}Resources$sep$exe',
      '$exeDir$sep$exe',
      '$exeDir${sep}lib$sep$exe',
    ];
    // Dev: walk up from the executable and the CWD looking for core/dist.
    for (final start in [exeDir, Directory.current.path]) {
      var dir = Directory(start);
      for (var i = 0; i < 10; i++) {
        candidates.add('${dir.path}${sep}core${sep}dist$sep$exe');
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    return null;
  }

  /// Original Xray binary: `$MELSI_XRAY`, next to `melsi-core`, then `xray`
  /// on `PATH`. Mobile builds do not ship one.
  static String? locateXray() {
    final exe = Platform.isWindows ? 'xray.exe' : 'xray';
    final env = Platform.environment['MELSI_XRAY'];
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final core = locateCore();
    if (core != null) {
      final beside = File(_sibling(core, exe));
      if (beside.existsSync()) return beside.absolute.path;
    }
    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final nextToApp = File('$exeDir$sep$exe');
    if (nextToApp.existsSync()) return nextToApp.absolute.path;
    final pathEnv = Platform.environment['PATH'];
    if (pathEnv != null) {
      for (final dir in pathEnv.split(Platform.isWindows ? ';' : ':')) {
        if (dir.isEmpty) continue;
        final candidate = File('$dir$sep$exe');
        if (candidate.existsSync()) return candidate.absolute.path;
      }
    }
    return null;
  }

  static String _sibling(String path, String name) {
    final sep = Platform.pathSeparator;
    final i = path.lastIndexOf(sep);
    if (i < 0) return name;
    return '${path.substring(0, i + 1)}$name';
  }

  // ------------------------------------------------------------ start

  @override
  Future<void> start(BuiltConfig cfg, {required String name}) async {
    _stopping = false;
    _emit(const VpnState(VpnStatus.connecting));
    try {
      await _start(cfg);
    } catch (e) {
      await _killXray();
      _emit(VpnState(VpnStatus.error, e.toString()));
      rethrow;
    }
  }

  Future<void> _start(BuiltConfig cfg) async {
    final core = locateCore();
    if (core == null) {
      throw const DesktopVpnException(
          'melsi-core not found. Put it next to the app or set MELSI_CORE.');
    }

    // Stop a daemon left over from a previous session (it holds the ports).
    await _stopStale();
    await _killXray();

    final configPath = await _path('config.json');
    final enginePath = await _path('engine.json');
    final logPath = await _path('melsi-core.log');
    final outPath = await _path('melsi-core.out');
    await _atomicWrite(configPath, cfg.singBox);
    await _atomicWrite(enginePath, cfg.engine);
    try {
      await File(logPath).writeAsString('');
      await File(outPath).writeAsString('');
    } catch (_) {}

    // Validate without elevation first: config errors surface immediately.
    final check = await Process.run(core, ['check', '--config', configPath])
        .timeout(const Duration(seconds: 20),
            onTimeout: () => ProcessResult(0, 0, '', ''));
    if (check.exitCode != 0) {
      throw DesktopVpnException(
          'Config check failed: ${_lastLines('${check.stderr}${check.stdout}', 8)}');
    }

    final engine = (jsonDecode(cfg.engine) as Map).cast<String, dynamic>();
    _api?.close();
    _api = EngineApi(
      endpoint: engine['control_listen'] as String? ?? '127.0.0.1:9791',
      secret: engine['secret'] as String? ?? '',
    );

    if (cfg.xray != null) {
      await _startXray(cfg.xray!);
    }

    final needsElevation = _hasTun(cfg.singBox);
    final args = ['run', '--config', configPath, '--engine', enginePath, '--log', logPath];
    _elevated = false;

    if (Platform.isWindows || !needsElevation || await _isRoot()) {
      // Windows: the app already runs as admin (manifest).
      await Process.start(core, args, mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      _elevated = true;
      final cmd = '${_q(core)} ${args.map(_q).join(' ')} > ${_q(outPath)} 2>&1 &';
      final script = 'do shell script "${_as(cmd)}" with administrator privileges';
      final r = await Process.run('osascript', ['-e', script]);
      if (r.exitCode != 0) {
        final err = '${r.stderr}';
        throw DesktopVpnException(err.contains('-128')
            ? 'Authorization cancelled'
            : 'Could not start melsi-core: ${err.trim()}');
      }
    } else {
      _elevated = true;
      final cmd = 'exec ${_q(core)} ${args.map(_q).join(' ')} > ${_q(outPath)} 2>&1 &';
      ProcessResult r;
      try {
        r = await Process.run('pkexec', ['/bin/sh', '-c', cmd]);
      } on ProcessException {
        throw const DesktopVpnException(
            'pkexec is not available — install polkit or use System proxy mode.');
      }
      if (r.exitCode == 126 || r.exitCode == 127) {
        throw const DesktopVpnException('Authorization cancelled');
      }
      if (r.exitCode != 0) {
        throw DesktopVpnException('pkexec failed: ${'${r.stderr}'.trim()}');
      }
    }

    // Wait for the engine to answer.
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (true) {
      if (_stopping) return;
      try {
        final h = await _api!.health(timeout: const Duration(milliseconds: 800));
        if (h.ok) break;
      } catch (_) {}
      if (DateTime.now().isAfter(deadline)) {
        final tail = await _logTail(12);
        throw DesktopVpnException(
            'melsi-core did not start${tail.isEmpty ? '' : ':\n$tail'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _emit(const VpnState(VpnStatus.connected));
    _startMonitor();
  }

  bool _hasTun(String singBox) {
    try {
      final j = jsonDecode(singBox) as Map;
      return (j['inbounds'] as List? ?? const [])
          .any((e) => e is Map && e['type'] == 'tun');
    } catch (_) {
      return true;
    }
  }

  Future<bool> _isRoot() async {
    if (Platform.isWindows) return true;
    try {
      final r = await Process.run('id', ['-u']);
      return '${r.stdout}'.trim() == '0';
    } catch (_) {
      return false;
    }
  }

  /// POSIX single-quote.
  static String _q(String s) => "'${s.replaceAll("'", r"'\''")}'";

  /// AppleScript string literal escape.
  static String _as(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  Future<void> _atomicWrite(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(path);
  }

  // ------------------------------------------------------------ monitor

  void _startMonitor() {
    _monitor?.cancel();
    _failures = 0;
    _monitor = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_stopping || _api == null) return;
      try {
        final h = await _api!.health();
        if (h.ok) {
          _failures = 0;
          return;
        }
      } catch (_) {}
      if (++_failures >= 3 && !_stopping) {
        _monitor?.cancel();
        final tail = await _logTail(10);
        _emit(VpnState(VpnStatus.error,
            'melsi-core stopped unexpectedly${tail.isEmpty ? '' : ':\n$tail'}'));
      }
    });
  }

  Future<String> _logTail(int n) async {
    final parts = <String>[];
    for (final name in ['melsi-core.log', 'melsi-core.out']) {
      try {
        final f = File(await _path(name));
        if (await f.exists()) parts.add(await f.readAsString());
      } catch (_) {}
    }
    return _lastLines(parts.join('\n'), n);
  }

  static String _lastLines(String s, int n) {
    final lines = const LineSplitter()
        .convert(s)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    return lines.skip(lines.length > n ? lines.length - n : 0).join('\n').trim();
  }

  // ------------------------------------------------------------ stop

  @override
  Future<void> stop() async {
    _stopping = true;
    _monitor?.cancel();
    _emit(const VpnState(VpnStatus.stopping));
    final api = _api;
    if (api != null) {
      try {
        await api.stop();
      } catch (_) {}
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      var alive = true;
      while (DateTime.now().isBefore(deadline)) {
        try {
          await api.health(timeout: const Duration(milliseconds: 500));
        } catch (_) {
          alive = false;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (alive) await _killByPid();
    }
    await _killXray();
    _emit(VpnState.stopped);
  }

  Future<void> _startXray(String config) async {
    final bin = locateXray();
    if (bin == null) {
      throw const DesktopVpnException(
          'Xray core not found. Place xray next to melsi-core, set MELSI_XRAY, or install it on PATH.');
    }
    final configPath = await _path('xray.json');
    final logPath = await _path('xray.log');
    await _atomicWrite(configPath, config);
    final log = File(logPath).openWrite();
    final proc = await Process.start(bin, ['run', '-c', configPath]);
    _xray = proc;
    proc.stdout.listen(log.add, onDone: log.close);
    proc.stderr.listen(log.add);
    await File(await _path('xray.pid')).writeAsString('${proc.pid}');
    final exited = await proc.exitCode
        .timeout(const Duration(milliseconds: 300), onTimeout: () => -1);
    if (exited != -1) {
      final tail = await _fileTail(logPath, 8);
      throw DesktopVpnException(
          'Xray exited before the tunnel started${tail.isEmpty ? '' : ':\n$tail'}');
    }
  }

  Future<void> _killXray() async {
    final proc = _xray;
    _xray = null;
    if (proc != null) {
      proc.kill();
    }
    try {
      final pid = int.tryParse((await File(await _path('xray.pid')).readAsString()).trim());
      if (pid != null && pid != proc?.pid) {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
        } else {
          Process.killPid(pid);
        }
      }
    } catch (_) {}
    try {
      await File(await _path('xray.pid')).delete();
    } catch (_) {}
  }

  Future<String> _fileTail(String path, int n) async {
    try {
      return _lastLines(await File(path).readAsString(), n);
    } catch (_) {
      return '';
    }
  }

  Future<void> _killByPid() async {
    try {
      final pid = int.tryParse(
          (await File(await _path('melsi-core.pid')).readAsString()).trim());
      if (pid == null) return;
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '$pid', '/F']);
      } else if (!_elevated) {
        Process.killPid(pid);
      } else if (Platform.isMacOS) {
        await Process.run('osascript', [
          '-e',
          'do shell script "kill $pid" with administrator privileges'
        ]);
      } else {
        await Process.run('pkexec', ['kill', '$pid']);
      }
    } catch (_) {}
  }

  Future<void> _stopStale() async {
    try {
      final f = File(await _path('engine.json'));
      if (!await f.exists()) return;
      final j = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
      final api = EngineApi(
          endpoint: j['control_listen'] as String? ?? '127.0.0.1:9791',
          secret: j['secret'] as String? ?? '');
      try {
        await api.health(timeout: const Duration(milliseconds: 500));
        await api.stop();
        await Future<void>.delayed(const Duration(milliseconds: 800));
      } catch (_) {
      } finally {
        api.close();
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ state

  @override
  Future<VpnState> currentState() async {
    if (_state.status != VpnStatus.stopped) return _state;
    // Re-attach to a daemon that survived an app restart.
    try {
      final f = File(await _path('engine.json'));
      if (!await f.exists()) return _state;
      final j = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
      final api = EngineApi(
          endpoint: j['control_listen'] as String? ?? '127.0.0.1:9791',
          secret: j['secret'] as String? ?? '');
      final h = await api.health(timeout: const Duration(milliseconds: 700));
      if (h.ok) {
        _api = api;
        _elevated = !Platform.isWindows;
        _emit(const VpnState(VpnStatus.connected));
        _startMonitor();
      } else {
        api.close();
      }
    } catch (_) {}
    return _state;
  }

  /// Secret of the running (re-attached) session, if any.
  Future<String?> attachedSecret() async {
    try {
      final j = jsonDecode(await File(await _path('engine.json')).readAsString()) as Map;
      return j['secret'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> coreVersion() async {
    final core = locateCore();
    if (core == null) return null;
    try {
      final r = await Process.run(core, ['version'])
          .timeout(const Duration(seconds: 5));
      final j = jsonDecode('${r.stdout}') as Map;
      return 'melsi ${j['melsi']} · sing-box ${j['sing_box']}';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> readLog({int maxLines = 400}) async {
    try {
      final f = File(await _path('melsi-core.log'));
      if (!await f.exists()) return '';
      return _lastLines(await f.readAsString(), maxLines);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _monitor?.cancel();
    _api?.close();
    _ctrl.close();
  }
}

class DesktopVpnException implements Exception {
  const DesktopVpnException(this.message);
  final String message;
  @override
  String toString() => message;
}
