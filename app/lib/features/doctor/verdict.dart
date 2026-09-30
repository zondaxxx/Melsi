// The doctor's verdict: pure functions from step results to a headline, its
// one-tap fixes, and the plain-text report the user can send to support.

import '../../l10n/l10n.dart';
import '../../services/vpn_controller.dart';
import '../../state/app_state.dart';
import 'diagnostics.dart';

/// One-tap remedies a verdict can offer (rendered as chips).
enum DoctorFix { antiDpi, switchServer }

/// Plain-language diagnosis. [key] is the l10n key of the headline.
class Verdict {
  const Verdict(this.key, {this.fixes = const []});

  final String key;
  final List<DoctorFix> fixes;

  /// The one verdict that is good news.
  bool get healthy => key == 'doctor.v.ok';

  static const offline = Verdict('doctor.v.offline');
  static const port = Verdict('doctor.v.port', fixes: [DoctorFix.antiDpi, DoctorFix.switchServer]);
  static const core = Verdict('doctor.v.core');
  static const tunnel = Verdict('doctor.v.tunnel', fixes: [DoctorFix.switchServer]);
  static const dns = Verdict('doctor.v.dns');
  static const clock = Verdict('doctor.v.clock');
  static const leak = Verdict('doctor.v.leak', fixes: [DoctorFix.switchServer]);
  static const warn = Verdict('doctor.v.warn');
  static const ok = Verdict('doctor.v.ok');
  static const partial = Verdict('doctor.v.partial');

  @override
  String toString() => 'Verdict($key)';
}

/// Order matters: each rule assumes the ones above it did not fire, so
/// "tunnel fails" is only reported when the server port itself answered.
Verdict diagnose(Map<String, StepResult> results) {
  bool fail(String id) => results[id]?.isFail ?? false;
  bool warn(String id) => results[id]?.status == StepStatus.warn;

  if (fail(Diagnostics.internetId)) return Verdict.offline;
  if (fail(Diagnostics.serverId)) return Verdict.port;
  if (fail(Diagnostics.coreId)) return Verdict.core;
  if (fail(Diagnostics.tunnelId)) return Verdict.tunnel;
  if (fail(Diagnostics.dnsId)) return Verdict.dns;
  if (fail(Diagnostics.clockId)) return Verdict.clock;
  if (fail(Diagnostics.leakId)) return Verdict.leak;
  // A cancelled run has no failure to report, but no clean bill either.
  if (Diagnostics.stepIds.any((id) => !results.containsKey(id))) return Verdict.partial;
  if (Diagnostics.stepIds.any(warn)) return Verdict.warn;
  return Verdict.ok;
}

/// The copyable report: environment, one line per step, the verdict. Only
/// categorical facts about the setup (protocol, preset, platform) — never a
/// server address, a node name (names often embed the host) or a secret.
String doctorReport({
  required L10n l,
  required AppState app,
  required Map<String, StepResult> results,
  Verdict? verdict,
  required String appVersion,
}) {
  final s = app.settings;
  final node = app.activeNode;
  String onOff(bool v) => v ? 'on' : 'off';
  String status(StepResult r) => r.status.name;
  String detail(StepResult r) => r.detail == null ? '' : ' · ${l(r.detail!, r.args)}';

  final lines = <String>[
    '${l('doctor.report.title')} · Melsi $appVersion · ${currentPlatformKind().name}',
    'core: ${app.coreVersion ?? 'n/a'} · status: ${app.vpnState.status.name}',
    'preset: ${app.routing.preset.name} · protocol: ${node?.protocol.label ?? 'n/a'}'
        ' · chain: ${onOff(app.chain.active)} · smart: ${onOff(s.autoSelect)}',
    'capture: ${s.captureMode.name} · stack: ${s.tunStack.name}'
        ' · anti-dpi: ${onOff(s.antiDpi)} · kill switch: ${onOff(s.killSwitch)}',
    '',
    for (final id in Diagnostics.stepIds)
      if (results[id] case final r?) '${l(id)}: ${status(r)}${detail(r)}',
  ];
  if (verdict != null) {
    lines
      ..add('')
      ..add('${l('doctor.verdict')}: ${l(verdict.key)}');
  }
  return lines.join('\n');
}
