import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/ui/widgets/connect_button.dart';

import 'fakes.dart';
import 'harness.dart';

void main() {
  testWidgets('failed probe explains loss and offers diagnostics on a narrow screen', (tester) async {
    stubPlatformChannels(tester);
    reducedMotion(tester);
    final (state, features) = await bootApp(tester, size: const Size(360, 640));
    await state.importText(kSampleVless);
    state.connect();
    await tester.pump(const Duration(milliseconds: 100));
    state.engineGroups['proxy'] = GroupStatus(selector: 'proxy', current: 'node', nodes: [
      NodeStat(tag: 'node', samples: 2, loss: 1, lastError: 'TLS handshake: certificate verification failed'),
    ]);
    state.notifyListeners();
    await settle(tester);
    expect(find.textContaining('TLS/REALITY'), findsOneWidget);
    expect(find.textContaining('Потери — доля'), findsOneWidget);
    expect(find.text('Диагностика'), findsWidgets);
    expect(tester.takeException(), isNull);
    state.engineGroups.clear();
    state.notifyListeners();
    await settle(tester);
    expect(find.textContaining('Потери — доля'), findsNothing);
    await shutdownApp(tester, state, features: features);
  });

  testWidgets('recovery shows localized progress and remains cancellable', (tester) async {
    stubPlatformChannels(tester);
    reducedMotion(tester);
    final (state, features) = await bootApp(tester);
    await state.importText(kSampleVless);
    state.vpnState = const VpnState(VpnStatus.connecting, 'reconnecting');
    state.notifyListeners();
    await settle(tester);
    expect(find.text('Восстановление…'), findsOneWidget);
    expect(find.text('Повторно подключаемся к выбранному серверу.'), findsOneWidget);
    expect(find.text('reconnecting'), findsNothing);
    await tester.tap(find.byType(ConnectButton));
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.vpnState.status, VpnStatus.stopped);
    await shutdownApp(tester, state, features: features);
  });
}
