import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/mobile_vpn_controller.dart';
import 'package:melsi/services/vpn_controller.dart';

import 'fakes.dart';
import 'harness.dart';

class PendingPermissionVpn extends FakeVpn {
  final permission = Completer<bool>();

  @override
  Future<bool> prepare() => permission.future;
}

void main() {
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
