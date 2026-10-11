import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/services/desktop_vpn_controller.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/services/process_identity.dart';
import 'package:melsi/services/vpn_controller.dart';

class DesktopTestProcess extends Fake implements Process {
  DesktopTestProcess(this.pid);
  @override
  final int pid;
  bool exitOnKill = true;
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  final signals = <ProcessSignal>[];

  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;

  void finish(int code, {String? error}) {
    if (exited.isCompleted) return;
    if (error != null) errors.add(utf8.encode(error));
    exited.complete(code);
    unawaited(output.close());
    unawaited(errors.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (exited.isCompleted) return false;
    signals.add(signal);
    if (exitOnKill) finish(-1);
    return true;
  }
}

/// No installed core, elevated shell, TUN, system proxy, or remote server.
/// Processes are controllable fakes; the control API uses a real local socket.
class DesktopTestHarness {
  late Directory directory;
  late HttpServer server;
  late DesktopVpnController vpn;
  final states = <VpnState>[];
  final checks = <DesktopTestProcess>[];
  final cores = <DesktopTestProcess>[];
  final xrays = <DesktopTestProcess>[];
  final checkStarted = Completer<void>();
  final coreRequested = Completer<void>();
  Completer<void>? launchGate;
  Completer<void>? cleanupGate;
  bool holdCheck = false;
  bool coreReady = true;
  bool alive = false;
  int checkCode = 0;
  int stops = 0;
  int healthFailures = 0;
  int healthRequests = 0;
  int healthInFlight = 0;
  int maxHealthInFlight = 0;
  Completer<void>? healthGate;
  int coreRequests = 0;
  final configurations = <String>[];
  int _pid = 100000000;

  Future<void> open({
    Duration timeout = const Duration(seconds: 2),
    Duration cleanupTimeout = const Duration(seconds: 2),
    Duration healthInterval = const Duration(seconds: 2),
    Duration healthTimeout = const Duration(seconds: 2),
    Duration startupTimeout = const Duration(seconds: 25),
    List<Duration> recoveryBackoff = const [],
    DesktopProcessProbe? processProbe,
    EngineApi Function(String, String)? apiFactory,
  }) async {
    directory = await Directory.systemTemp.createTemp('melsi-desktop-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final health = request.uri.path == '/health';
      if (health) {
        healthRequests++;
        healthInFlight++;
        if (healthInFlight > maxHealthInFlight) {
          maxHealthInFlight = healthInFlight;
        }
        await healthGate?.future;
      }
      if (request.uri.path == '/stop' && alive) {
        stops++;
        alive = false;
        final process = cores.last;
        if (cleanupGate == null) {
          await finishCleanup(process);
        } else {
          unawaited(cleanupGate!.future.then((_) => finishCleanup(process)));
        }
        request.response.write('{"ok":true}');
      } else if (health && healthFailures > 0) {
        healthFailures--;
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.write('{"ok":false}');
      } else if (alive) {
        request.response.write('{"ok":true}');
      } else {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.write('{"ok":false}');
      }
      await request.response.close();
      if (health) healthInFlight--;
    });
    vpn = DesktopVpnController(
      supportDir: () async => directory,
      coreLocator: () => 'test-core',
      xrayLocator: () => 'test-xray',
      startProcess: launch,
      configCheckTimeout: timeout,
      cleanupTimeout: cleanupTimeout,
      healthInterval: healthInterval,
      healthTimeout: healthTimeout,
      startupTimeout: startupTimeout,
      recoveryBackoff: recoveryBackoff,
      processProbe: processProbe,
      apiFactory: apiFactory,
    );
    vpn.states.listen(states.add);
  }

  BuiltConfig config({bool xray = false}) => BuiltConfig(
    singBox: '{"inbounds":[]}',
    engine: jsonEncode({
      'control_listen': '127.0.0.1:${server.port}',
      'secret': 'local-test',
    }),
    nodeTags: const {},
    xray: xray ? '{}' : null,
  );

  Future<Process> launch(
    String executable,
    List<String> args, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final process = DesktopTestProcess(++_pid);
    if (args.first == 'check') {
      checks.add(process);
      if (!checkStarted.isCompleted) checkStarted.complete();
      if (!holdCheck) process.finish(checkCode, error: 'config diagnostic');
    } else if (executable == 'test-xray') {
      xrays.add(process);
    } else {
      expect(mode, ProcessStartMode.detached);
      coreRequests++;
      if (!coreRequested.isCompleted) coreRequested.complete();
      await launchGate?.future;
      cores.add(process);
      configurations.add(
        await File(args[args.indexOf('--config') + 1]).readAsString(),
      );
      unawaited(
        process.exitCode.then((_) {
          if (identical(cores.last, process)) alive = false;
        }),
      );
      await File('${directory.path}/melsi-core.pid')
          .writeAsString('${process.pid}');
      alive = coreReady;
    }
    return process;
  }

  Future<void> finishCleanup(DesktopTestProcess process) async {
    final file = File('${directory.path}/melsi-core.pid');
    if (await file.exists() && await file.readAsString() == '${process.pid}') {
      await file.delete();
    }
    process.finish(0);
  }

  Future<void> close() async {
    vpn.dispose();
    if (healthGate != null && !healthGate!.isCompleted) healthGate!.complete();
    for (final process in [...checks, ...cores, ...xrays]) {
      process.finish(0);
    }
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}
