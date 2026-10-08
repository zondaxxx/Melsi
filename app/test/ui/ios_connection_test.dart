import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/services/mobile_vpn_controller.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';

import 'fakes.dart';
import 'harness.dart';

class PendingPermissionVpn extends FakeVpn {
  final permission = Completer<bool>();

  @override
  Future<bool> prepare() => permission.future;
}

class WarningVpn extends FakeVpn {
  final events = StreamController<VpnState>.broadcast();

  @override
  Stream<VpnState> get states => events.stream;

  void emit(VpnState value) {
    state = value;
    events.add(value);
  }
}

void main() {
  test('connected warnings preserve VPN and are shown once per message', () async {
    final vpn = WarningVpn();
    final state = testState(vpn: vpn, platform: PlatformKind.ios);
    await state.load();
    await Future<void>.delayed(Duration.zero);
    final notices = <Notice>[];
    final subscription = state.notices.listen(notices.add);
    const warning =
        'VPN is connected, but automatic reconnect could not be enabled: denied';
    const other =
        'VPN is connected, but automatic reconnect could not be enabled: save failed';
    for (final message in <String?>[
      warning,
      warning,
      null,
      other,
      warning,
      '  ',
      ' $other ',
    ]) {
      vpn.emit(VpnState(VpnStatus.connected, message));
      await Future<void>.delayed(Duration.zero);
      expect(state.vpnState.status, VpnStatus.connected);
      expect(state.connectedAt, isNotNull);
    }
    expect(notices.map((notice) => notice.key), [
      'notice.vpnWarning',
      'notice.vpnWarning',
    ]);
    expect(notices.map((notice) => notice.detail), [warning, other]);
    expect(notices.every((notice) => notice.kind == NoticeKind.info), isTrue);

    // A new session may have a fresh failure; clean repeated connected
    // events within the current session must not reset deduplication.
    vpn.emit(VpnState.stopped);
    await Future<void>.delayed(Duration.zero);
    vpn.emit(const VpnState(VpnStatus.connected, warning));
    await Future<void>.delayed(Duration.zero);
    expect(notices.length, 3);
    expect(state.vpnState.status, VpnStatus.connected);
    state.dispose();
    await subscription.cancel();
    await vpn.events.close();
  });

  testWidgets('cancelling while creating the profile cannot start VPN later', (
    tester,
  ) async {
    final vpn = PendingPermissionVpn();
    final (state, features) = await bootApp(tester, vpn: vpn);
    await state.importText(kSampleVless);
    final connecting = state.connect();
    await tester.pump();
    expect(state.vpnState.status, VpnStatus.connecting);
    state.disconnect();
    await settle(tester);
    vpn.permission.complete(true);
    await connecting;
    await settle(tester);
    expect(vpn.starts, 0);
    expect(state.vpnState.status, VpnStatus.stopped);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets(
    'late permission failure cannot overwrite a cancelled connection',
    (tester) async {
      final vpn = PendingPermissionVpn();
      final (state, features) = await bootApp(tester, vpn: vpn);
      await state.importText(kSampleVless);
      final connecting = state.connect();
      state.disconnect();
      await settle(tester);
      vpn.permission.completeError(
        VpnStartException('stale preparation error'),
      );
      await connecting;
      await settle(tester);
      expect(state.vpnState.status, VpnStatus.stopped);
      expect(state.vpnState.message, isNull);
      await shutdownApp(tester, state, features: features);
    },
  );

  testWidgets(
    'native profile errors are not reported as user permission denial',
    (tester) async {
      const channel = MethodChannel('melsi-test-ios-vpn');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        throw PlatformException(
          code: 'prepare_failed',
          message: 'PacketTunnel extension is missing',
        );
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final controller = MobileVpnController(channel: channel);
      await expectLater(
        controller.prepare(),
        throwsA(
          isA<VpnStartException>().having(
            (error) => error.message,
            'message',
            contains('PacketTunnel'),
          ),
        ),
      );
    },
  );
}
