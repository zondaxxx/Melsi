import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import 'engine_api.dart';
import 'process_identity.dart';
import 'vpn_controller.dart';

typedef DesktopProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  ProcessStartMode mode,
});

/// Runs the `melsi-core` daemon (CONTRACT §4).
///
/// The daemon is launched elevated when the config has a TUN inbound
/// (Windows: the app itself is admin via its manifest; macOS: osascript with
/// administrator privileges; Linux: pkexec). System-proxy mode needs no
/// elevation. The daemon outlives the UI, so on relaunch we re-attach to it
/// via the engine `/health` endpoint using the secret in `engine.json`.
class DesktopVpnController extends VpnController {
  DesktopVpnController({
    Future<Directory> Function()? supportDir,
    String? Function()? coreLocator,
    String? Function()? xrayLocator,
    DesktopProcessStarter? startProcess,
    DesktopProcessProbe? processProbe,
    EngineApi Function(String, String)? apiFactory,
    this.configCheckTimeout = const Duration(seconds: 20),
    this.cleanupTimeout = const Duration(seconds: 12),
    this.healthInterval = const Duration(seconds: 2),
    this.healthTimeout = const Duration(seconds: 2),
    this.startupTimeout = const Duration(seconds: 25),
    this.recoveryBackoff = const [
      Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4),
    ],
  }) : _supportDirFn = supportDir ?? getApplicationSupportDirectory,
       _coreLocator = coreLocator ?? locateCore,
       _xrayLocator = xrayLocator ?? locateXray,
       _processProbe = processProbe ?? desktopProcessMatches,
       _apiFactory = apiFactory ?? _newApi,
       _startProcess = startProcess ?? Process.start;

  final Future<Directory> Function() _supportDirFn;
  final String? Function() _coreLocator;
  final String? Function() _xrayLocator;
  final DesktopProcessStarter _startProcess;
  final DesktopProcessProbe _processProbe;
  final EngineApi Function(String, String) _apiFactory;
  static EngineApi _newApi(String endpoint, String secret) => EngineApi(endpoint: endpoint, secret: secret);
  final Duration configCheckTimeout;
  final Duration cleanupTimeout;
  final Duration healthInterval;
  final Duration healthTimeout;
  final Duration startupTimeout;
  final List<Duration> recoveryBackoff;
  final _ctrl = StreamController<VpnState>.broadcast();
  VpnState _state = VpnState.stopped;
  EngineApi? _api;
  Timer? _monitor;
  int _failures = 0;
  bool _stopping = false;
  bool _elevated = false;
  Directory? _dir;
  Process? _xray;
  Process? _coreProcess;
  Process? _checking;
  int? _pendingCleanupPid;
  int? _unconfirmedCorePid;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _operation = Future<void>.value();
  Future<void>? _healthCheck;
  int? _healthGeneration;
  bool _desiredRunning = false;
  bool _recovering = false;
  int _restarts = 0;
  Timer? _retryTimer;
  Completer<void>? _retryWait;
  BuiltConfig? _lastConfig;
  Future<BuiltConfig> Function()? _recoveryConfig;
  String? _xrayFailure;
  int? _attachedXrayPid;
  String? _attachedXrayExecutable;

  @override
  void setRecoveryConfigProvider(Future<BuiltConfig> Function() provider) {
    _recoveryConfig = provider;
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final wait = _retryWait;
    _retryWait = null;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _operation.then((_) => action());
    _operation = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _ensureCurrent(int generation) {
    if (generation != _generation || _stopping || _disposed) {
      throw const _CancelledStart();
    }
  }

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
  Future<void> start(BuiltConfig cfg, {required String name}) {
    if (_disposed) return Future<void>.value();
    final generation = ++_generation;
    _cancelRetry();
    _desiredRunning = true;
    _recovering = false;
    _restarts = 0;
    _lastConfig = cfg;
    _stopping = false;
    _monitor?.cancel();
    _emit(const VpnState(VpnStatus.connecting));
    return _serialize(() async {
      if (generation != _generation) return;
      try {
        await _start(cfg, generation);
      } on _CancelledStart {
        // The queued stop/new start owns cleanup, before it can launch again.
        if (_disposed) await _stopSession();
      } catch (e) {
        if (generation != _generation) return;
        _desiredRunning = false;
        Object failure = e;
        try {
          await _stopSession();
        } catch (cleanupError) {
          failure = cleanupError;
        }
        if (generation != _generation) return;
        _emit(VpnState(VpnStatus.error, failure.toString()));
        throw failure;
      }
    });
  }

  Future<void> _start(BuiltConfig cfg, int generation) async {
    _ensureCurrent(generation);
    final core = _coreLocator();
    if (core == null) {
      throw const DesktopVpnException(
        'melsi-core not found. Put it next to the app or set MELSI_CORE.',
      );
    }

    // Stop a daemon left over from a previous session (it holds the ports).
    // A previously unreachable attached daemon may have regained its API.
    if (_unconfirmedCorePid != null || (_api == null && _coreProcess == null)) {
      // A reopened UI may not have attached before Connect is pressed. Verify
      // the old owner before touching its Xray companion or configuration.
      await _stopStale();
    }
    await _stopSession();
    await _stopStale();
    await _waitForCleanup(generation);
    _ensureCurrent(generation);
    _xrayFailure = null;

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
    _ensureCurrent(generation);
    await _checkConfig(core, configPath, generation);
    _ensureCurrent(generation);

    final engine = (jsonDecode(cfg.engine) as Map).cast<String, dynamic>();
    _api?.close();
    _api = _apiFactory(
      engine['control_listen'] as String? ?? '127.0.0.1:9791',
      engine['secret'] as String? ?? '',
    );

    if (cfg.xray != null) {
      await _startXray(cfg.xray!, generation);
    }
    _ensureCurrent(generation);

    final needsElevation = _hasTun(cfg.singBox);
    final args = [
      'run',
      '--config',
      configPath,
      '--engine',
      enginePath,
      '--log',
      logPath,
    ];
    _elevated = false;

    if (Platform.isWindows || !needsElevation || await _isRoot()) {
      // Windows: the app already runs as admin (manifest).
      _coreProcess = await _startProcess(
        core,
        args,
        mode: ProcessStartMode.detached,
      );
    } else if (Platform.isMacOS) {
      _elevated = true;
      final cmd =
          '${_q(core)} ${args.map(_q).join(' ')} > ${_q(outPath)} 2>&1 &';
      final script =
          'do shell script "${_as(cmd)}" with administrator privileges';
      final r = await Process.run('osascript', ['-e', script]);
      if (r.exitCode != 0) {
        final err = '${r.stderr}';
        throw DesktopVpnException(
          err.contains('-128')
              ? 'Authorization cancelled'
              : 'Could not start melsi-core: ${err.trim()}',
        );
      }
    } else {
      _elevated = true;
      final cmd =
          'exec ${_q(core)} ${args.map(_q).join(' ')} > ${_q(outPath)} 2>&1 &';
      ProcessResult r;
      try {
        r = await Process.run('pkexec', ['/bin/sh', '-c', cmd]);
      } on ProcessException {
        throw const DesktopVpnException(
          'pkexec is not available — install polkit or use System proxy mode.',
        );
      }
      if (r.exitCode == 126 || r.exitCode == 127) {
        throw const DesktopVpnException('Authorization cancelled');
      }
      if (r.exitCode != 0) {
        throw DesktopVpnException('pkexec failed: ${'${r.stderr}'.trim()}');
      }
    }
    _ensureCurrent(generation);

    // Wait for the engine to answer.
    final deadline = DateTime.now().add(startupTimeout);
    while (true) {
      _ensureCurrent(generation);
      try {
        final h = await _api!.health(
          timeout: const Duration(milliseconds: 800),
        );
        _ensureCurrent(generation);
        if (h.ok) break;
      } on _CancelledStart {
        rethrow;
      } catch (_) {}
      if (DateTime.now().isAfter(deadline)) {
        final tail = await _logTail(12);
        throw DesktopVpnException(
          'melsi-core did not start${tail.isEmpty ? '' : ':\n$tail'}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (_xrayFailure != null) throw DesktopVpnException(_xrayFailure!);
    _lastConfig = cfg;
    _emit(const VpnState(VpnStatus.connected));
    _startMonitor(generation);
  }

  Future<void> _checkConfig(
    String core,
    String configPath,
    int generation,
  ) async {
    final proc = await _startProcess(core, ['check', '--config', configPath]);
    _checking = proc;
    final stdout = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    var exited = false;
    try {
      _ensureCurrent(generation);
      final code = await proc.exitCode.timeout(configCheckTimeout);
      exited = true;
      _ensureCurrent(generation);
      final output = await Future.wait([stderr, stdout])
          .timeout(const Duration(seconds: 2), onTimeout: () => ['', '']);
      if (code != 0) {
        throw DesktopVpnException(
          'Config check failed: ${_lastLines(output.join(), 8)}',
        );
      }
    } on TimeoutException {
      throw DesktopVpnException(
        'Config check timed out after ${configCheckTimeout.inSeconds} seconds.',
      );
    } finally {
      if (!exited) _killProcess(proc);
      if (identical(_checking, proc)) _checking = null;
    }
  }

  static void _killProcess(Process? proc) {
    if (proc == null) return;
    try {
      proc.kill(ProcessSignal.sigkill);
    } catch (_) {}
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

  void _startMonitor(int generation) {
    _monitor?.cancel();
    _failures = 0;
    _scheduleHealth(generation);
  }

  bool _canRecover(int generation) =>
      !_disposed && !_stopping && _desiredRunning && generation == _generation;

  void _scheduleHealth(int generation) {
    late final Timer monitor;
    monitor = Timer(healthInterval, () async {
      await _checkHealth(generation);
      if (identical(_monitor, monitor) && _canRecover(generation) && _state.status == VpnStatus.connected) {
        _scheduleHealth(generation);
      }
    });
    _monitor = monitor;
  }

  Future<void> _checkHealth(int generation) {
    if (!_canRecover(generation) || _state.status != VpnStatus.connected) {
      return Future<void>.value();
    }
    if (_healthGeneration == generation && _healthCheck != null) return _healthCheck!;
    _healthGeneration = generation;
    late Future<void> check;
    check = _pollHealth(generation).whenComplete(() {
      if (identical(_healthCheck, check)) _healthCheck = null;
    });
    return _healthCheck = check;
  }

  Future<void> _pollHealth(int generation) async {
    final api = _api;
    final pid = _attachedXrayPid;
    final executable = _attachedXrayExecutable;
    if (pid != null && executable != null) {
      final alive = await _processProbe(pid, executable);
      if (!_canRecover(generation) || !identical(api, _api) || pid != _attachedXrayPid) return;
      if (alive == false) _xrayFailure = 'The attached Xray process stopped unexpectedly.';
    }
    if (_xrayFailure != null) {
      if (_canRecover(generation)) _beginRecovery(_xrayFailure!);
      return;
    }
    try {
      final health = await api?.health(timeout: healthTimeout);
      if (!_canRecover(generation) || !identical(api, _api)) return;
      if (health?.ok == true) {
        _failures = 0;
        return;
      }
    } catch (_) {}
    if (!_canRecover(generation) || !identical(api, _api)) return;
    if (++_failures >= 3) _beginRecovery('The local VPN core stopped responding.');
  }

  void _beginRecovery(String reason) {
    if (!_canRecover(_generation) || _recovering) return;
    final generation = _generation;
    _recovering = true;
    _monitor?.cancel();
    _emit(const VpnState(VpnStatus.connecting, 'reconnecting'));
    unawaited(_recover(generation, reason).whenComplete(() {
      if (generation == _generation) _recovering = false;
    }));
  }

  Future<void> _waitToRetry(Duration delay, int generation) async {
    _ensureCurrent(generation);
    final wait = _retryWait = Completer<void>();
    _retryTimer = Timer(delay, () { if (!wait.isCompleted) wait.complete(); });
    await wait.future;
    if (identical(_retryWait, wait)) _retryWait = null;
    _ensureCurrent(generation);
  }

  Future<bool> _reattachHealthyApi(int generation) async {
    final current = _api;
    if (current == null || _xrayFailure != null) return false;
    final fresh = _apiFactory(current.endpoint, current.secret);
    var adopted = false;
    try {
      final health = await fresh.health(timeout: healthTimeout);
      if (_canRecover(generation) && health.ok && _xrayFailure == null) {
        _api = fresh;
        current.close();
        adopted = true;
      }
    } catch (_) {
    } finally {
      if (!adopted) fresh.close();
    }
    return adopted;
  }

  Future<void> _recover(int generation, String reason) async {
    var lastError = reason;
    try {
      while (_canRecover(generation)) {
        if (_restarts < recoveryBackoff.length) {
          await _waitToRetry(recoveryBackoff[_restarts], generation);
        }
        if (await _reattachHealthyApi(generation)) {
          _ensureCurrent(generation);
          _emit(const VpnState(VpnStatus.connected));
          _startMonitor(generation);
          return;
        }
        _ensureCurrent(generation);
        if (_restarts >= recoveryBackoff.length) break;
        _restarts++;
        try {
          await _serialize(() async {
            _ensureCurrent(generation);
            final config = await _recoveryConfig?.call() ?? _lastConfig;
            _ensureCurrent(generation);
            if (config == null) throw const DesktopVpnException('No saved VPN configuration is available.');
            try {
              await _start(config, generation);
            } on _CancelledStart {
              if (_disposed) await _stopSession();
              rethrow;
            } catch (_) {
              if (generation == _generation && !_disposed) await _stopSession();
              rethrow;
            }
          });
          _ensureCurrent(generation);
          return;
        } on _CancelledStart {
          return;
        } catch (error) {
          lastError = error.toString();
        }
      }
      if (!_canRecover(generation)) return;
      await _serialize(() async {
        if (!_canRecover(generation)) return;
        await _stopSession();
        final tail = await readLog(maxLines: 12) ?? '';
        if (!_canRecover(generation)) return;
        _desiredRunning = false;
        _emit(VpnState(VpnStatus.error,
          'Automatic reconnect stopped after $_restarts attempts. $lastError${tail.isEmpty ? '' : '\n$tail'}'));
      });
    } on _CancelledStart {
      return;
    } catch (error) {
      if (_canRecover(generation)) {
        _desiredRunning = false;
        _emit(VpnState(VpnStatus.error, 'Automatic reconnect failed: $error'));
      }
    }
  }

  Future<String> _logTail(int n) async {
    final parts = <String>[];
    for (final name in ['melsi-core.log', 'melsi-core.out']) {
      final tail = await _fileTail(await _path(name), n);
      if (tail.isNotEmpty) parts.add(tail);
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
  Future<void> stop() {
    final generation = ++_generation;
    _desiredRunning = false;
    _recovering = false;
    _cancelRetry();
    _stopping = true;
    _monitor?.cancel();
    _killProcess(_checking);
    _emit(const VpnState(VpnStatus.stopping));
    return _serialize(() async {
      try {
        await _stopSession();
      } catch (error) {
        if (generation == _generation && !_disposed) {
          _emit(VpnState(VpnStatus.error, error.toString()));
        }
        rethrow;
      }
      if (generation == _generation) _emit(VpnState.stopped);
    });
  }

  Future<void> _stopSession() async {
    final api = _api;
    _api = null;
    var forceKill = true;
    if (api != null) {
      final pid = await _corePid();
      var stopAccepted = false;
      try {
        await api.stop();
        stopAccepted = true;
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
      forceKill = !stopAccepted || alive;
      if (stopAccepted && !alive && pid != null) _pendingCleanupPid = pid;
      if (forceKill && _coreProcess == null && pid != null) {
        _unconfirmedCorePid = pid;
      } else if (alive) {
        await _killByPid();
      }
      api.close();
    }
    // The control API closes before sing-box restores the system proxy/TUN.
    // Acknowledged shutdown must finish that cleanup without a forced kill.
    if (forceKill) _killProcess(_coreProcess);
    _coreProcess = null;
    await _checkAttachedCoreStopped();
    await _killXray();
  }

  Future<void> _checkAttachedCoreStopped() async {
    final pid = _unconfirmedCorePid;
    if (pid == null) return;
    if (await _corePid() != pid || _pendingCleanupPid == pid) {
      // An acknowledged stop is still protected by _waitForCleanup.
      _unconfirmedCorePid = null;
      return;
    }
    final core = _coreLocator() ?? (Platform.isWindows ? 'melsi-core.exe' : 'melsi-core');
    final matches = await _processProbe(pid, core);
    if (matches != false) {
      throw const DesktopVpnException(
        'The existing VPN core is not responding, and its shutdown cannot be confirmed. '
        'A second tunnel was not started. Wait for the core to stop or restart the device before reconnecting.',
      );
    }
    _unconfirmedCorePid = null;
  }

  Future<int?> _corePid() async {
    try {
      return int.tryParse((await File(await _path('melsi-core.pid')).readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  Future<void> _waitForCleanup(int generation) async {
    final pid = _pendingCleanupPid;
    if (pid == null) return;
    final deadline = DateTime.now().add(cleanupTimeout);
    while (await _corePid() == pid) {
      _ensureCurrent(generation);
      if (DateTime.now().isAfter(deadline)) {
        // Keep this owner until its PID file changes; a retry must not bypass
        // unfinished TUN/proxy cleanup and reuse the same ports/cache.
        throw const DesktopVpnException(
          'The previous VPN is still shutting down. Wait a moment before reconnecting.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (_pendingCleanupPid == pid) _pendingCleanupPid = null;
  }

  Future<void> _startXray(String config, int generation) async {
    final bin = _xrayLocator();
    if (bin == null) {
      throw const DesktopVpnException(
        'Xray core not found. Place xray next to melsi-core, set MELSI_XRAY, or install it on PATH.',
      );
    }
    final configPath = await _path('xray.json');
    final logPath = await _path('xray.log');
    await _atomicWrite(configPath, config);
    final log = File(logPath).openWrite();
    late final Process proc;
    try {
      proc = await _startProcess(bin, ['run', '-c', configPath]);
    } catch (_) {
      await log.close();
      rethrow;
    }
    _xray = proc;
    final logDone =
        Future.wait([
              proc.stdout.forEach(log.add),
              proc.stderr.forEach(log.add),
            ])
            .whenComplete(() async {
              await log.close();
            })
            .then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await File(await _path('xray.pid')).writeAsString('${proc.pid}');
    _ensureCurrent(generation);
    final exited = await proc.exitCode.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () => -1,
    );
    if (exited != -1) {
      await logDone.timeout(const Duration(seconds: 1), onTimeout: () {});
      final tail = await _fileTail(logPath, 8);
      throw DesktopVpnException(
        'Xray exited before the tunnel started${tail.isEmpty ? '' : ':\n$tail'}',
      );
    }
    unawaited(proc.exitCode.then<void>((code) async {
      if (_disposed || _stopping || generation != _generation || !identical(_xray, proc)) return;
      _xrayFailure = 'Xray stopped unexpectedly (exit $code).';
      if (_state.status == VpnStatus.connected || _recovering) {
        _beginRecovery(_xrayFailure!);
      }
    }).catchError((Object _) {}));
  }

  Future<void> _killXray() async {
    final proc = _xray;
    _xray = null;
    _killProcess(proc);
    final executable = _attachedXrayExecutable ?? _xrayLocator();
    _attachedXrayPid = null;
    _attachedXrayExecutable = null;
    int? pid;
    try {
      pid = int.tryParse(
        (await File(await _path('xray.pid')).readAsString()).trim(),
      );
    } catch (_) {}
    if (pid != null && pid > 0 && pid != proc?.pid) {
      final matches = executable == null ? null : await _processProbe(pid, executable);
      if (matches == null) {
        throw const DesktopVpnException('Cannot verify the previous Xray process. Wait a moment before reconnecting.');
      }
      if (matches) {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
        } else {
          Process.killPid(pid);
        }
      }
    }
    try {
      await File(await _path('xray.pid')).delete();
    } catch (_) {}
  }

  Future<String> _fileTail(String path, int n) async {
    try {
      final file = await File(path).open();
      try {
        final length = await file.length();
        final start = (length - (64 << 10)).clamp(0, length);
        await file.setPosition(start);
        var text = utf8.decode(
          await file.read(length - start),
          allowMalformed: true,
        );
        if (start > 0) text = text.substring(text.indexOf('\n') + 1);
        return _lastLines(text, n);
      } finally {
        await file.close();
      }
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
    final pid = await _corePid();
    var stopAccepted = false;
    EngineApi? api;
    try {
      final f = File(await _path('engine.json'));
      if (await f.exists()) {
        final j = (jsonDecode(await f.readAsString()) as Map)
            .cast<String, dynamic>();
        api = _apiFactory(
          j['control_listen'] as String? ?? '127.0.0.1:9791',
          j['secret'] as String? ?? '',
        );
        await api.health(timeout: const Duration(milliseconds: 500));
        await api.stop();
        stopAccepted = true;
      }
    } catch (_) {
    } finally {
      api?.close();
    }
    if (stopAccepted) {
      if (pid != null) {
        _pendingCleanupPid = pid;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    } else if (pid != null) {
      // An unreachable API (or unreadable settings) does not prove the old
      // daemon is gone. Reuse the same guard as recovery of an attached core.
      _unconfirmedCorePid = pid;
      await _checkAttachedCoreStopped();
    }
  }

  // ------------------------------------------------------------ state

  @override
  Future<VpnState> currentState() async {
    if (_disposed) return _state;
    if (_state.status == VpnStatus.connected) {
      await _checkHealth(_generation);
      return _state;
    }
    if (_state.status != VpnStatus.stopped || _stopping) return _state;
    final generation = _generation;
    // Re-attach to a daemon that survived an app restart.
    EngineApi? candidate;
    try {
      final f = File(await _path('engine.json'));
      if (!await f.exists()) return _state;
      final j = (jsonDecode(await f.readAsString()) as Map)
          .cast<String, dynamic>();
      final api = candidate = _apiFactory(
        j['control_listen'] as String? ?? '127.0.0.1:9791',
        j['secret'] as String? ?? '',
      );
      final h = await api.health(timeout: const Duration(milliseconds: 700));
      if (generation != _generation || _stopping || _disposed) {
        api.close();
        return _state;
      }
      if (h.ok) {
        BuiltConfig? config;
        int? xrayPid;
        try {
          final singBox = await File(await _path('config.json')).readAsString();
          final hasXray = await File(await _path('xray.pid')).exists();
          if (hasXray) xrayPid = int.tryParse((await File(await _path('xray.pid')).readAsString()).trim());
          config = BuiltConfig(singBox: singBox, engine: jsonEncode(j), nodeTags: const {},
            xray: hasXray ? await File(await _path('xray.json')).readAsString() : null);
        } catch (_) {}
        if (generation != _generation || _disposed || _stopping || _state.status != VpnStatus.stopped) return _state;
        _api = api;
        candidate = null;
        _lastConfig = config;
        _attachedXrayPid = xrayPid != null && xrayPid > 0 ? xrayPid : null;
        _attachedXrayExecutable = _attachedXrayPid == null ? null : _xrayLocator();
        _elevated = !Platform.isWindows;
        _desiredRunning = true;
        _restarts = 0;
        _emit(const VpnState(VpnStatus.connected));
        _startMonitor(_generation);
      } else {
        api.close();
      }
    } catch (_) {
    } finally {
      candidate?.close();
    }
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
    final core = _coreLocator();
    if (core == null) return null;
    try {
      final r = await Process.run(core, [
        'version',
      ]).timeout(const Duration(seconds: 5));
      final j = jsonDecode('${r.stdout}') as Map;
      return 'melsi ${j['melsi']} · sing-box ${j['sing_box']}';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> readLog({int maxLines = 400}) async {
    try {
      final limit = maxLines.clamp(1, 400);
      final logs = <String, String>{};
      for (final name in ['melsi-core.log', 'xray.log']) {
        final tail = await _fileTail(await _path(name), limit);
        if (tail.isNotEmpty) logs[name] = tail;
      }
      if (logs.isEmpty) return '';
      final perFile = ((limit ~/ logs.length) - 1).clamp(1, 400);
      return _lastLines(
        logs.entries
            .map((e) => '[${e.key}]\n${_lastLines(e.value, perFile)}')
            .join('\n'),
        limit,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _desiredRunning = false;
    _recoveryConfig = null;
    _generation++;
    _cancelRetry();
    _killProcess(_checking);
    _monitor?.cancel();
    _api?.close();
    _ctrl.close();
  }
}

class _CancelledStart implements Exception {
  const _CancelledStart();
}

class DesktopVpnException implements Exception {
  const DesktopVpnException(this.message);
  final String message;
  @override
  String toString() => message;
}
