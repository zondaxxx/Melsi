import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/store.dart';

import '../ui/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('choosing B then reconnecting starts B', () async {
    final vpn = FakeVpn();
    final state = testState(vpn: vpn, platform: PlatformKind.linux);
    await state.load();
    await state.importText(kSampleVless);
    await state.importText(kSampleVless
        .replaceAll('nl1.example.com', 'de1.example.com')
        .replaceAll('Netherlands', 'Germany'));
    final germany = state.nodes.firstWhere((n) => n.name.contains('Germany'));
    final netherlands = state.nodes.firstWhere((n) => n.name.contains('Netherlands'));

    await state.selectNode(germany.id);
    expect(state.settings.autoSelect, isFalse);
    expect((state.store as MemoryStateStore).data?['selectedNodeId'], germany.id);

    await state.connect();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(state.vpnState.status, VpnStatus.connected);
    expect(state.activeNode!.id, germany.id);
    final first = jsonDecode(vpn.started!.singBox) as Map<String, dynamic>;
    final proxy = (first['outbounds'] as List).cast<Map>().firstWhere((o) => o['tag'] == 'proxy');
    expect(proxy['default'], vpn.started!.nodeTags[germany.id]);
    expect(first['experimental']['cache_file']['cache_id'], 'manual:${germany.id}');

    // The engine still reports the previous outbound. Manual mode must not
    // show that one, and the restarted tunnel must not restore it.
    state.engineGroups['proxy'] = GroupStatus(
      selector: 'proxy',
      current: vpn.started!.nodeTags[netherlands.id],
    );
    expect(state.activeNode!.id, germany.id);

    await state.selectNode(netherlands.id);
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    expect(state.activeNode!.id, netherlands.id);
    expect(vpn.starts, greaterThan(1));
    final second = jsonDecode(vpn.started!.singBox) as Map<String, dynamic>;
    final proxyB = (second['outbounds'] as List).cast<Map>().firstWhere((o) => o['tag'] == 'proxy');
    expect(proxyB['default'], vpn.started!.nodeTags[netherlands.id]);
    expect(second['experimental']['cache_file']['cache_id'], 'manual:${netherlands.id}');
    state.dispose();
  });

  test('a switch during prepare is the config that starts', () async {
    final vpn = _SlowPrepare();
    final state = testState(vpn: vpn, platform: PlatformKind.linux);
    await state.load();
    await state.importText(kSampleVless);
    await state.importText(kSampleVless
        .replaceAll('nl1.example.com', 'de1.example.com')
        .replaceAll('Netherlands', 'Germany'));
    final germany = state.nodes.firstWhere((n) => n.name.contains('Germany'));
    final pending = state.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await state.selectNode(germany.id);
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(vpn.starts, 1);
    final config = jsonDecode(vpn.started!.singBox) as Map<String, dynamic>;
    final proxy = (config['outbounds'] as List).cast<Map>().firstWhere((o) => o['tag'] == 'proxy');
    expect(proxy['default'], vpn.started!.nodeTags[germany.id]);
    expect(state.activeNode!.id, germany.id);
    state.dispose();
  });

  test('phone refuses Xray without starting a tunnel', () async {
    final vpn = FakeVpn();
    final state = testState(vpn: vpn, platform: PlatformKind.android);
    await state.load();
    await state.importText(kSampleVless);
    state.updateSettings((s) => s.core = VpnCore.xray);
    await state.connect();
    expect(state.vpnState.status, VpnStatus.error);
    expect(vpn.starts, 0);
    state.dispose();
  });
}

class _SlowPrepare extends FakeVpn {
  @override
  Future<bool> prepare() async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return true;
  }
}
