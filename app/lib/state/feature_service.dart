import 'package:flutter/foundation.dart';

import '../services/vpn_controller.dart';
import 'app_state.dart';
import 'features.dart';

/// Base class of a feature module's service: a [ChangeNotifier] that
/// observes [AppState] (through [Features]'s fan-out hooks) and owns its
/// own state. Services never edit [AppState] internals; they call its
/// public API and persist their data under `app.sections[...]`.
abstract class FeatureService extends ChangeNotifier {
  FeatureService(this.app, this.features) {
    now = features.clock;
  }

  final AppState app;
  final Features features;

  /// Injectable clock (tests pass a fake through [Features.clock]).
  late DateTime Function() now;

  /// Called once after the app state is loaded.
  Future<void> load() async {}

  /// App returned to the foreground.
  void onResume() {}

  /// Tunnel status changed.
  void onVpn(VpnStatus prev, VpnStatus next) {}

  /// Tests turn networking off; every outgoing request checks this.
  bool get networkAllowed => app.enableNetwork;
}
