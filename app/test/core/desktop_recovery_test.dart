import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/services/desktop_vpn_controller.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/services/vpn_controller.dart';

import 'support/desktop_test_harness.dart';

Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _LateHealthApi extends EngineApi {
  _LateHealthApi(String endpoint, String secret)
    : super(endpoint: endpoint, secret: secret);
  Completer<EngineHealth>? nextHealth;
  bool waiting = false;
  @override
  Future<EngineHealth> health({Duration timeout = const Duration(seconds: 2)}) {
    final pending = nextHealth;
    nextHealth = null;
    if (pending != null) {
      waiting = true;
      return pending.future;
    }
    return super.health(timeout: timeout);
  }
}

class _ObservedTimer implements Timer {
  _ObservedTimer(this.inner);
  final Timer inner;
  @override
  bool get isActive => inner.isActive;
  @override
  int get tick => inner.tick;
  @override
  void cancel() => inner.cancel();
}

void main() {
  Future<DesktopTestHarness> harness({
    List<Duration> backoff = const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 20),
      Duration(milliseconds: 40),
    ],
  }) async {
    final h = DesktopTestHarness();
    await h.open(
      healthInterval: const Duration(milliseconds: 10),
      healthTimeout: const Duration(milliseconds: 100),
      startupTimeout: const Duration(milliseconds: 80),
      recoveryBackoff: backoff,
    );
    addTearDown(h.close);
    return h;
  }

  test(
    'temporary API failures recover using a fresh client without restarting',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(), name: 'test');
      h.healthFailures = 3;
      await until(() => h.states.any((s) => s.message == 'reconnecting'));
      await until(() => h.states.last.status == VpnStatus.connected);
      expect(h.cores, hasLength(1));
      expect(h.stops, 0);
      expect(h.cores.single.signals, isEmpty);
    },
  );

  test(
    'resume and periodic checks share one pending local health request',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(), name: 'test');
      h.healthGate = Completer<void>();
      final calls = List.generate(6, (_) => h.vpn.currentState());
      await until(() => h.healthInFlight > 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.maxHealthInFlight, 1);
      h.healthGate!.complete();
      await Future.wait(calls);
      expect(h.cores, hasLength(1));
    },
  );

  test('core crash restarts the same config and API credentials', () async {
    final h = await harness();
    final config = h.config();
    await h.vpn.start(config, name: 'test');
    h.cores.single.finish(17);
    await until(
      () => h.cores.length == 2 && h.states.last.status == VpnStatus.connected,
    );
    expect(h.configurations, [config.singBox, config.singBox]);
    expect(h.states.where((s) => s.status == VpnStatus.error), isEmpty);
  });

  test(
    'recovery gets the latest manual configuration before a restart',
    () async {
      final h = await harness();
      final original = h.config();
      await h.vpn.start(original, name: 'test');
      final latest = BuiltConfig(
        singBox: jsonEncode({'inbounds': [], 'manual': 'server-B'}),
        engine: original.engine,
        nodeTags: const {},
      );
      h.vpn.setRecoveryConfigProvider(() async => latest);
      h.cores.single.finish(17);
      await until(
        () =>
            h.cores.length == 2 && h.states.last.status == VpnStatus.connected,
      );
      expect(h.configurations.last, latest.singBox);
    },
  );

  test(
    'successful short recoveries do not replenish the restart budget',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(), name: 'test');
      for (var restart = 1; restart <= 3; restart++) {
        h.cores.last.finish(17);
        await until(
          () =>
              h.cores.length == restart + 1 &&
              h.states.last.status == VpnStatus.connected,
        );
      }
      h.cores.last.finish(17);
      await until(() => h.states.last.status == VpnStatus.error);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(h.cores, hasLength(4));
      expect(h.states.last.message, contains('after 3 attempts'));
      await h.vpn.start(h.config(), name: 'manual retry');
      h.cores.last.finish(17);
      await until(
        () =>
            h.cores.length == 6 && h.states.last.status == VpnStatus.connected,
      );
    },
  );

  test(
    'failed restart is bounded and leaves no checking process alive',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(), name: 'test');
      h.checkCode = 1;
      h.cores.single.finish(17);
      await until(() => h.states.last.status == VpnStatus.error);
      expect(h.checks, hasLength(4));
      expect(h.checks.every((p) => p.exited.isCompleted), isTrue);
      expect(h.cores, hasLength(1));
      expect(h.states.last.message, contains('Config check failed'));
    },
  );

  test(
    'explicit stop cancels pending backoff and cannot resurrect the tunnel',
    () async {
      final h = await harness(backoff: [const Duration(milliseconds: 150)]);
      await h.vpn.start(h.config(), name: 'test');
      h.healthFailures = 3;
      await until(() => h.states.any((s) => s.message == 'reconnecting'));
      await h.vpn.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(h.cores, hasLength(1));
      expect(h.states.last.status, VpnStatus.stopped);
    },
  );

  test('closing the UI during backoff preserves the existing daemon', () async {
    final h = await harness(backoff: [const Duration(milliseconds: 150)]);
    await h.vpn.start(h.config(), name: 'test');
    h.healthFailures = 3;
    await until(() => h.states.any((s) => s.message == 'reconnecting'));
    h.vpn.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(h.cores, hasLength(1));
    expect(h.cores.single.signals, isEmpty);
    expect(h.alive, isTrue);
    expect(h.stops, 0);
  });

  test('stop wins over an in-flight recovery configuration rebuild', () async {
    final h = await harness();
    final config = h.config();
    await h.vpn.start(config, name: 'test');
    final provider = Completer<BuiltConfig>();
    var rebuilding = false;
    h.vpn.setRecoveryConfigProvider(() {
      rebuilding = true;
      return provider.future;
    });
    h.cores.single.finish(17);
    await until(() => rebuilding);
    final stop = h.vpn.stop();
    provider.complete(config);
    await stop;
    expect(h.cores, hasLength(1));
    expect((await h.vpn.currentState()).status, VpnStatus.stopped);
  });

  test(
    'closing UI while a recovery launch is pending cleans up that late launch',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(), name: 'test');
      h.launchGate = Completer<void>();
      h.cores.single.finish(17);
      await until(() => h.coreRequests == 2);
      h.vpn.dispose();
      h.launchGate!.complete();
      await until(() => h.cores.length == 2 && h.cores.last.exited.isCompleted);
      expect(h.cores.last.signals, isNotEmpty);
      expect(h.alive, isFalse);
    },
  );

  test(
    'Xray crash recovers both processes using the shared retry budget',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(xray: true), name: 'test');
      h.xrays.single.finish(23, error: 'companion crashed');
      await until(
        () =>
            h.xrays.length == 2 && h.states.last.status == VpnStatus.connected,
      );
      expect(h.cores, hasLength(2));
      expect(h.cores.first.exited.isCompleted, isTrue);
      expect(h.stops, 1);
    },
  );

  test(
    'an immediate second Xray crash cannot hide behind healthy main API',
    () async {
      final h = await harness();
      var connections = 0;
      final subscription = h.vpn.states.listen((state) {
        if (state.status == VpnStatus.connected && ++connections == 2) {
          h.xrays.last.finish(24, error: 'crashed just after recovery');
        }
      });
      addTearDown(subscription.cancel);
      await h.vpn.start(h.config(xray: true), name: 'test');
      h.xrays.single.finish(23);
      await until(
        () =>
            h.xrays.length == 3 && h.states.last.status == VpnStatus.connected,
      );
      expect(h.cores, hasLength(3));
      expect(h.xrays.last.exited.isCompleted, isFalse);
      expect(h.stops, 2);
    },
  );

  test(
    'reopened UI reattaches and can recover a daemon with its saved config',
    () async {
      final h = await harness();
      final config = h.config();
      await h.vpn.start(config, name: 'test');
      h.vpn.dispose();
      h.vpn = DesktopVpnController(
        supportDir: () async => h.directory,
        coreLocator: () => 'test-core',
        startProcess: h.launch,
        healthInterval: const Duration(milliseconds: 10),
        healthTimeout: const Duration(milliseconds: 100),
        recoveryBackoff: const [Duration(milliseconds: 10)],
      );
      h.states.clear();
      h.vpn.states.listen(h.states.add);
      expect((await h.vpn.currentState()).status, VpnStatus.connected);
      expect(h.cores, hasLength(1));
      h.cores.single.finish(17);
      await until(
        () =>
            h.cores.length == 2 && h.states.last.status == VpnStatus.connected,
      );
      expect(h.configurations.last, config.singBox);
      expect(await h.vpn.attachedSecret(), 'local-test');
    },
  );

  test(
    'an attached Xray death is detected even while the main API is healthy',
    () async {
      final h = await harness();
      final config = h.config(xray: true);
      await h.vpn.start(config, name: 'test');
      h.vpn.dispose();
      h.vpn = DesktopVpnController(
        supportDir: () async => h.directory,
        coreLocator: () => 'test-core',
        xrayLocator: () => 'test-xray',
        startProcess: h.launch,
        healthInterval: const Duration(milliseconds: 10),
        recoveryBackoff: const [Duration(milliseconds: 10)],
        processProbe: (pid, executable) async {
          expect(executable, 'test-xray');
          return h.xrays.any((p) => p.pid == pid && !p.exited.isCompleted);
        },
      );
      await Future<void>.delayed(Duration.zero);
      h.states.clear();
      h.vpn.states.listen(h.states.add);
      expect((await h.vpn.currentState()).status, VpnStatus.connected);
      h.xrays.single.finish(23);
      expect(h.alive, isTrue);
      await until(
        () =>
            h.xrays.length == 2 && h.states.last.status == VpnStatus.connected,
      );
      expect(h.cores, hasLength(2));
      expect(h.configurations.last, config.singBox);
    },
  );

  test(
    'an unknown attached Xray identity does not restart or kill a live tunnel',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(xray: true), name: 'test');
      h.vpn.dispose();
      var probes = 0;
      h.vpn = DesktopVpnController(
        supportDir: () async => h.directory,
        xrayLocator: () => 'test-xray',
        healthInterval: const Duration(milliseconds: 10),
        processProbe: (_, _) async {
          probes++;
          return null;
        },
      );
      expect((await h.vpn.currentState()).status, VpnStatus.connected);
      await until(() => probes >= 3);
      expect((await h.vpn.currentState()).status, VpnStatus.connected);
      expect(h.cores.single.signals, isEmpty);
      expect(h.xrays.single.signals, isEmpty);
      expect(h.stops, 0);
    },
  );

  test(
    'late old health response cannot create a second monitor timer chain',
    () async {
      const interval = Duration(milliseconds: 47);
      final timers = <_ObservedTimer>[];
      await runZoned(
        () async {
          final h = DesktopTestHarness();
          final apis = <_LateHealthApi>[];
          await h.open(
            healthInterval: interval,
            recoveryBackoff: const [Duration(milliseconds: 3)],
            apiFactory: (endpoint, secret) {
              final api = _LateHealthApi(endpoint, secret);
              apis.add(api);
              return api;
            },
          );
          try {
            await h.vpn.start(h.config(xray: true), name: 'test');
            final original = apis.first;
            final lateHealth = original.nextHealth = Completer<EngineHealth>();
            await until(() => original.waiting);
            h.xrays.single.finish(23);
            await until(
              () =>
                  h.xrays.length == 2 &&
                  h.states.last.status == VpnStatus.connected,
            );
            // The new monitor joins the same in-flight request before it completes.
            await Future<void>.delayed(interval * 2);
            lateHealth.complete(EngineHealth(ok: true));
            await until(() => timers.any((timer) => timer.isActive));
            expect(timers.where((timer) => timer.isActive), hasLength(1));
          } finally {
            await h.close();
          }
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration != interval) return timer;
            final observed = _ObservedTimer(timer);
            timers.add(observed);
            return observed;
          },
        ),
      );
    },
  );

  for (final identity in <bool?>[true, null]) {
    test(
      'unresponsive attached core with identity $identity cannot be bypassed by retry',
      () async {
        final h = await harness();
        final config = h.config();
        await h.vpn.start(config, name: 'test');
        h.vpn.dispose();
        h.vpn = DesktopVpnController(
          supportDir: () async => h.directory,
          coreLocator: () => 'test-core',
          startProcess: h.launch,
          healthInterval: const Duration(milliseconds: 10),
          recoveryBackoff: const [
            Duration(milliseconds: 10),
            Duration(milliseconds: 20),
          ],
          processProbe: (pid, executable) async {
            expect(pid, h.cores.first.pid);
            expect(executable, 'test-core');
            return identity;
          },
        );
        await Future<void>.delayed(Duration.zero);
        h.states.clear();
        h.vpn.states.listen(h.states.add);
        expect((await h.vpn.currentState()).status, VpnStatus.connected);
        // The control server is unreachable while the daemon itself still lives.
        h.alive = false;
        await until(() => h.states.any((s) => s.status == VpnStatus.error));
        expect(h.states.last.message, contains('shutdown cannot be confirmed'));
        expect(h.cores, hasLength(1));
        expect(h.cores.single.signals, isEmpty);
        await expectLater(
          h.vpn.start(config, name: 'manual retry'),
          throwsA(isA<DesktopVpnException>()),
        );
        expect(h.cores, hasLength(1));
        expect((await h.vpn.currentState()).status, VpnStatus.error);
        await expectLater(h.vpn.stop(), throwsA(isA<DesktopVpnException>()));
        expect((await h.vpn.currentState()).status, VpnStatus.error);
        // Once the old API returns, a graceful stop removes the owner and a
        // fresh launch is allowed without killing the attached process.
        h.alive = true;
        await h.vpn.start(config, name: 'API restored');
        expect((await h.vpn.currentState()).status, VpnStatus.connected);
        expect(h.cores, hasLength(2));
        expect(h.cores.first.signals, isEmpty);
      },
    );
  }

  test(
    'late attach health response cannot overwrite an explicit stop',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(), name: 'test');
      h.vpn.dispose();
      h.vpn = DesktopVpnController(supportDir: () async => h.directory);
      await Future<void>.delayed(Duration.zero);
      h.states.clear();
      h.vpn.states.listen(h.states.add);
      h.healthGate = Completer<void>();
      final attaching = h.vpn.currentState();
      await until(() => h.healthInFlight > 0);
      await h.vpn.stop();
      h.healthGate!.complete();
      expect((await attaching).status, VpnStatus.stopped);
      expect((await h.vpn.currentState()).status, VpnStatus.stopped);
      expect(h.states.where((s) => s.status == VpnStatus.connected), isEmpty);
    },
  );
}
