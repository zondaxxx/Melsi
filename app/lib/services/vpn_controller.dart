import 'dart:io';

import '../core/models.dart';
import 'desktop_vpn_controller.dart';
import 'mobile_vpn_controller.dart';

enum VpnStatus { stopped, connecting, connected, stopping, error }

/// Tunnel state as reported by the platform side. [message] is set for
/// [VpnStatus.error] (and may carry progress text while connecting).
class VpnState {
  const VpnState(this.status, [this.message]);

  static const stopped = VpnState(VpnStatus.stopped);

  final VpnStatus status;
  final String? message;

  bool get isActive =>
      status == VpnStatus.connected || status == VpnStatus.connecting;

  static VpnStatus parseStatus(String? s) => switch (s) {
        'connecting' => VpnStatus.connecting,
        'connected' => VpnStatus.connected,
        'stopping' => VpnStatus.stopping,
        'error' => VpnStatus.error,
        _ => VpnStatus.stopped,
      };

  @override
  String toString() => 'VpnState(${status.name}${message == null ? '' : ', $message'})';
}

/// Runs a [BuiltConfig]. Mobile: native VpnService / PacketTunnel via
/// MethodChannel. Desktop: the elevated `melsi-core` daemon.
abstract class VpnController {
  Stream<VpnState> get states;

  /// Ask for whatever permission the platform needs (VPN consent on
  /// Android, saving the NETunnelProviderManager on iOS). Desktop: true.
  Future<bool> prepare();

  Future<void> start(BuiltConfig cfg, {required String name});
  Future<void> stop();
  Future<VpnState> currentState();

  /// Core version string(s) for the About screen, if known.
  Future<String?> coreVersion() async => null;

  /// Saved diagnostics: desktop core log, or the iOS tunnel lifecycle journal.
  /// Returns null when the platform has no persisted log.
  Future<String?> readLog({int maxLines = 400}) async => null;

  void dispose() {}

  static VpnController forPlatform() {
    if (Platform.isAndroid || Platform.isIOS) return MobileVpnController();
    return DesktopVpnController();
  }
}

PlatformKind currentPlatformKind() {
  if (Platform.isAndroid) return PlatformKind.android;
  if (Platform.isIOS) return PlatformKind.ios;
  if (Platform.isMacOS) return PlatformKind.macos;
  if (Platform.isWindows) return PlatformKind.windows;
  return PlatformKind.linux;
}

bool get isDesktop =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;
bool get isMobile => Platform.isAndroid || Platform.isIOS;
