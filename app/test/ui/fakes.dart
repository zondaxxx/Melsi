import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/services/platform_apps.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';
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

/// Deterministic clock for feature tests.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime(2026, 10, 1, 12);
  DateTime now;
  void advance(Duration d) => now = now.add(d);
  DateTime call() => now;
}

/// App state for tests: in-memory store, fake VPN, no network. Unless the
/// data says otherwise, onboarding counts as done so tests boot straight
/// into the shell (onboarding tests pass `onboardingDone: false`).
AppState testState({Map<String, dynamic>? data, FakeVpn? vpn}) {
  final merged = <String, dynamic>{...?data};
  final settings = <String, dynamic>{...?(merged['settings'] as Map?)?.cast<String, dynamic>()};
  settings.putIfAbsent('onboardingDone', () => true);
  merged['settings'] = settings;
  return AppState(
    store: MemoryStateStore(merged),
    vpn: vpn ?? FakeVpn(),
    apps: FakeApps(),
    enableNetwork: false,
  );
}

/// Feature modules wired to [state] with an offline HTTP client (every
/// request answers 404 unless [client] is given), a fake clock and an
/// optional fake clipboard.
Features testFeatures(
  AppState state, {
  http.Client? client,
  DateTime Function()? clock,
  Future<String?> Function()? readClipboard,
}) =>
    Features(
      state,
      httpClient: () => client ?? MockClient((_) async => http.Response('', 404)),
      clock: clock ?? FakeClock().call,
      readClipboard: readClipboard,
    );

const kSampleVless =
    'vless://bf000d23-0752-40b4-affe-68f7707a9661@nl1.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179e30d4fc2&type=tcp#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands%20Reality';
