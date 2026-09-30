import 'dart:async';

import 'package:melsi/core/models.dart';
import 'package:melsi/services/platform_apps.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/store.dart';

/// In-process VPN that "connects" instantly.
class FakeVpn extends VpnController {
  FakeVpn({this.delay = const Duration(milliseconds: 10)});

  /// How long start/stop take (raise it to observe transitional UI).
  Duration delay;
  int starts = 0;
  final _ctrl = StreamController<VpnState>.broadcast();
  VpnState state = VpnState.stopped;
  BuiltConfig? started;

  void _emit(VpnState s) {
    state = s;
    _ctrl.add(s);
  }

  @override
  Stream<VpnState> get states => _ctrl.stream;

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> start(BuiltConfig cfg, {required String name}) async {
    started = cfg;
    starts++;
    _emit(const VpnState(VpnStatus.connecting));
    await Future<void>.delayed(delay);
    _emit(const VpnState(VpnStatus.connected));
  }

  @override
  Future<void> stop() async {
    _emit(const VpnState(VpnStatus.stopping));
    await Future<void>.delayed(delay);
    _emit(VpnState.stopped);
  }

  @override
  Future<VpnState> currentState() async => state;
}

class FakeApps extends PlatformApps {
  @override
  Future<List<InstalledApp>> list() async => [
        InstalledApp(id: 'Telegram', label: 'Telegram'),
        InstalledApp(id: 'cs2.exe', label: 'cs2.exe'),
      ];
}

AppState testState({Map<String, dynamic>? data, FakeVpn? vpn}) => AppState(
      store: MemoryStateStore(data),
      vpn: vpn ?? FakeVpn(),
      apps: FakeApps(),
      enableNetwork: false,
    );

const kSampleVless =
    'vless://bf000d23-0752-40b4-affe-68f7707a9661@nl1.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179e30d4fc2&type=tcp#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands%20Reality';
