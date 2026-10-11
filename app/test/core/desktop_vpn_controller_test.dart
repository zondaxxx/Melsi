import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/desktop_vpn_controller.dart';
import 'package:melsi/services/vpn_controller.dart';

import 'support/desktop_test_harness.dart';

void main() {
  Future<DesktopTestHarness> harness({
    Duration? timeout,
    Duration? cleanupTimeout,
  }) async {
    final h = DesktopTestHarness();
    await h.open(
      timeout: timeout ?? const Duration(seconds: 2),
      cleanupTimeout: cleanupTimeout ?? const Duration(seconds: 2),
    );
    addTearDown(h.close);
    return h;
  }

  test('hung config check is killed and cannot launch the tunnel', () async {
    final h = await harness(timeout: const Duration(milliseconds: 30));
    h.holdCheck = true;
    await expectLater(
      h.vpn.start(h.config(xray: true), name: 'test'),
      throwsA(
        isA<DesktopVpnException>().having(
          (e) => e.message,
          'message',
          contains('Config check timed out'),
        ),
      ),
    );
    expect(h.checks.single.signals, [ProcessSignal.sigkill]);
    expect(h.cores, isEmpty);
    expect(h.xrays, isEmpty);
    expect((await h.vpn.currentState()).status, VpnStatus.error);
  });

  test('failed check reports stderr without launching either core', () async {
    final h = await harness();
    h.checkCode = 1;
    await expectLater(
      h.vpn.start(h.config(xray: true), name: 'test'),
      throwsA(
        isA<DesktopVpnException>().having(
          (e) => e.message,
          'message',
          contains('config diagnostic'),
        ),
      ),
    );
    expect(h.cores, isEmpty);
    expect(h.xrays, isEmpty);
  });

  test('stop while checking cancels before any daemon can start', () async {
    final h = await harness();
    h.holdCheck = true;
    final start = h.vpn.start(h.config(xray: true), name: 'test');
    await h.checkStarted.future;
    await Future.wait([start, h.vpn.stop()]);
    expect(h.checks.single.signals, [ProcessSignal.sigkill]);
    expect(h.cores, isEmpty);
    expect(h.xrays, isEmpty);
    expect((await h.vpn.currentState()).status, VpnStatus.stopped);
    expect(h.states.where((s) => s.status == VpnStatus.error), isEmpty);
  });

  test(
    'a launch returning after cancellation is stopped before completion',
    () async {
      final h = await harness();
      h.launchGate = Completer<void>();
      h.coreReady = false;
      final start = h.vpn.start(h.config(), name: 'test');
      await h.coreRequested.future;
      final stop = h.vpn.stop();
      h.launchGate!.complete();
      await Future.wait([start, stop]);
      expect(h.alive, isFalse);
      expect(h.cores.single.signals, [ProcessSignal.sigkill]);
      expect(h.states.where((s) => s.status == VpnStatus.connected), isEmpty);
      expect((await h.vpn.currentState()).status, VpnStatus.stopped);
    },
  );

  test(
    'late Xray death stops a healthy daemon and reports its diagnostic',
    () async {
      final h = await harness();
      h.cleanupGate = Completer<void>();
      await h.vpn.start(h.config(xray: true), name: 'test');
      expect((await h.vpn.currentState()).status, VpnStatus.connected);
      final error = h.vpn.states.firstWhere((s) => s.status == VpnStatus.error);
      h.xrays.single.finish(23, error: 'REALITY connection failed\n');
      final state = await error.timeout(const Duration(seconds: 3));
      expect(state.message, contains('exit 23'));
      expect(state.message, contains('REALITY connection failed'));
      expect(h.states.any((s) => s.message == 'reconnecting'), isTrue);
      expect(h.stops, 1);
      expect(h.alive, isFalse);
      expect(h.cores.single.signals, isEmpty);
      expect(h.cores.single.exited.isCompleted, isFalse);
      h.cleanupGate!.complete();
      await h.cores.single.exitCode;
      expect(h.cores.single.signals, isEmpty);
      expect(await h.vpn.readLog(), contains('REALITY connection failed'));
    },
  );

  test('intentional stop does not report Xray death as an error', () async {
    final h = await harness();
    await h.vpn.start(h.config(xray: true), name: 'test');
    await h.vpn.stop();
    await Future<void>.delayed(Duration.zero);
    expect(h.states.where((s) => s.status == VpnStatus.error), isEmpty);
    expect((await h.vpn.currentState()).status, VpnStatus.stopped);
  });

  test(
    'graceful stop lets core restore networking after its API closes',
    () async {
      final h = await harness();
      h.cleanupGate = Completer<void>();
      await h.vpn.start(h.config(), name: 'test');
      await h.vpn.stop();
      expect(h.alive, isFalse);
      expect(h.cores.single.exited.isCompleted, isFalse);
      expect(h.cores.single.signals, isEmpty);
      h.cleanupGate!.complete();
      await h.cores.single.exitCode;
      expect(h.cores.single.signals, isEmpty);
    },
  );

  test('old Xray exit cannot stop a replacement session', () async {
    final h = await harness();
    await h.vpn.start(h.config(xray: true), name: 'first');
    final oldXray = h.xrays.single..exitOnKill = false;
    await h.vpn.start(h.config(xray: true), name: 'second');
    oldXray.finish(9, error: 'old session ended');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect((await h.vpn.currentState()).status, VpnStatus.connected);
    expect(h.cores.last.signals, isEmpty);
    expect(h.xrays.last.signals, isEmpty);
    expect(h.alive, isTrue);
    expect(h.states.where((s) => s.status == VpnStatus.error), isEmpty);
  });

  test(
    'replacement waits for old PID removal after the control API closes',
    () async {
      final h = await harness();
      await h.vpn.start(h.config(), name: 'first');
      h.cleanupGate = Completer<void>();
      final replacement = h.vpn.start(h.config(), name: 'second');
      while (h.stops == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.cores, hasLength(1));
      expect(h.cores.single.signals, isEmpty);
      expect(h.cores.single.exited.isCompleted, isFalse);
      h.cleanupGate!.complete();
      await replacement;
      expect(h.cores, hasLength(2));
      expect(h.cores.first.exited.isCompleted, isTrue);
      expect((await h.vpn.currentState()).status, VpnStatus.connected);
    },
  );

  test(
    'cleanup timeout and retry cannot bypass the previous PID owner',
    () async {
      final h = await harness(cleanupTimeout: const Duration(milliseconds: 40));
      await h.vpn.start(h.config(), name: 'first');
      h.cleanupGate = Completer<void>();
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          h.vpn.start(h.config(), name: 'replacement'),
          throwsA(
            isA<DesktopVpnException>().having(
              (e) => e.message,
              'message',
              contains('still shutting down'),
            ),
          ),
        );
        expect(h.cores, hasLength(1));
        expect(h.cores.single.signals, isEmpty);
      }
      h.cleanupGate!.complete();
      await h.cores.single.exitCode;
      await h.vpn.start(h.config(), name: 'replacement');
      expect(h.cores, hasLength(2));
      expect((await h.vpn.currentState()).status, VpnStatus.connected);
    },
  );

  test('disposing the UI does not stop its running daemon or Xray', () async {
    final h = await harness();
    await h.vpn.start(h.config(xray: true), name: 'test');
    h.vpn.dispose();
    expect(h.cores.single.signals, isEmpty);
    expect(h.xrays.single.signals, isEmpty);
    expect(h.stops, 0);
    h.xrays.single.finish(3);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.alive, isTrue);
    expect(h.cores.single.signals, isEmpty);
  });

  test(
    'saved diagnostics retain both sources within the line and byte bounds',
    () async {
      final h = await harness();
      await File('${h.directory.path}/melsi-core.log').writeAsString(
        '${'old core line\n' * 10000}core last one\ncore last two\n',
      );
      await File('${h.directory.path}/xray.log').writeAsString(
        '${'old Xray line\n' * 10000}Xray last one\nXray last two\n',
      );
      final log = (await h.vpn.readLog(maxLines: 6))!;
      expect(const LineSplitter().convert(log), hasLength(6));
      expect(log, contains('[melsi-core.log]'));
      expect(log, contains('core last two'));
      expect(log, contains('[xray.log]'));
      expect(log, contains('Xray last two'));
      expect(
        const LineSplitter().convert((await h.vpn.readLog(maxLines: 9999))!),
        hasLength(400),
      );
      expect(await h.vpn.readLog(maxLines: 0), 'Xray last two');
    },
  );
}
