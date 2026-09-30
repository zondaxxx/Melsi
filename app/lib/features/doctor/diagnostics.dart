// Network doctor: an ordered list of checks that run one after another and
// feed a plain-language verdict (see verdict.dart). Every check that touches
// the outside world goes through [DiagProbes], so tests inject canned results
// and never open a socket.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Icons;

import '../../services/tcp_ping.dart';
import '../../state/app_state.dart';
import '../../state/commands.dart';
import '../../state/feature_service.dart';
import 'doctor_widgets.dart';

enum StepStatus { ok, warn, fail, skipped }

/// Outcome of one step. [detail] is either an l10n key (`doctor.timeout`,
/// `unit.ms` with [args]) or a raw string the UI shows as-is: `L10n` returns
/// unknown keys unchanged, so one field serves both. [mono] marks numeric
/// details (latency, skew, file counts) the UI sets in monospace.
class StepResult {
  const StepResult(this.status, [this.detail])
      : args = const {},
        mono = false;

  const StepResult.value(this.status, this.detail, this.args) : mono = true;

  /// "23 мс" — the detail of every latency-style step.
  factory StepResult.ms(StepStatus status, int ms) =>
      StepResult.value(status, 'unit.ms', {'n': '$ms'});

  final StepStatus status;
  final String? detail;
  final Map<String, String> args;
  final bool mono;

  bool get isOk => status == StepStatus.ok;
  bool get isFail => status == StepStatus.fail;

  @override
  String toString() => 'StepResult(${status.name}, $detail)';
}

/// One check: [id] doubles as the l10n key of its title.
class DiagStep {
  const DiagStep({required this.id, required this.run});
  final String id;
  final Future<StepResult> Function() run;
}

/// The I/O behind every step. A null field means "the real thing"; tests
/// replace fields (or use [DiagProbes.canned]) so nothing reaches the
/// network. Parameters carry what the runner resolved from the app state
/// (target host, proxy tag, URL), so a test can assert on them too.
class DiagProbes {
  DiagProbes({
    this.internet,
    this.server,
    this.core,
    this.tunnel,
    this.dns,
    this.leak,
    this.rulesets,
    this.clock,
  });

  /// Every step answers with a fixed result ([fallback] for the rest).
  factory DiagProbes.canned(Map<String, StepResult> results,
      {StepResult fallback = const StepResult(StepStatus.ok)}) {
    Future<StepResult> of(String id) async => results[id] ?? fallback;
    return DiagProbes(
      internet: () => of(Diagnostics.internetId),
      server: (_, _) => of(Diagnostics.serverId),
      core: () => of(Diagnostics.coreId),
      tunnel: (_, _) => of(Diagnostics.tunnelId),
      dns: (_, _) => of(Diagnostics.dnsId),
      leak: () => of(Diagnostics.leakId),
      rulesets: (_) => of(Diagnostics.rulesetsId),
      clock: (_) => of(Diagnostics.clockId),
    );
  }

  Future<StepResult> Function()? internet;
  Future<StepResult> Function(String host, int port)? server;
  Future<StepResult> Function()? core;
  Future<StepResult> Function(String tag, String url)? tunnel;
  Future<StepResult> Function(String tag, String url)? dns;
  Future<StepResult> Function()? leak;
  Future<StepResult> Function(String dir)? rulesets;
  Future<StepResult> Function(String url)? clock;
}

/// Pure: the clock step from the server's `Date` header and the local time.
/// Reality / VMess break silently once the skew passes a minute or so, hence
/// the 90 s line.
StepResult clockResult(DateTime server, DateTime now) {
  final skew = now.difference(server).inSeconds;
  return StepResult.value(
    skew.abs() > Diagnostics.maxSkew.inSeconds ? StepStatus.fail : StepStatus.ok,
    'unit.sec',
    {'n': skew > 0 ? '+$skew' : '$skew'},
  );
}

/// Pure: the leak step from the real and the tunnel-exit IP.
StepResult leakResult(String? real, String? exit) {
  if (real == null || exit == null || real.isEmpty || exit.isEmpty) {
    return const StepResult(StepStatus.warn, 'doctor.leakUnknown');
  }
  if (real == exit) return const StepResult(StepStatus.fail, 'doctor.leakSame');
  return const StepResult(StepStatus.ok, 'doctor.leakOk');
}

/// Step-by-step network diagnostics. Runs only when asked ([run]); streams
/// progress through [notifyListeners] ([results], [running], [currentStep]).
class Diagnostics extends FeatureService {
  Diagnostics(super.app, super.features);

  static const internetId = 'doctor.internet';
  static const serverId = 'doctor.server';
  static const coreId = 'doctor.core';
  static const tunnelId = 'doctor.tunnel';
  static const dnsId = 'doctor.dns';
  static const leakId = 'doctor.leak';
  static const rulesetsId = 'doctor.rulesets';
  static const clockId = 'doctor.clock';

  /// Step order; the UI renders one row per id.
  static const stepIds = [
    internetId,
    serverId,
    coreId,
    tunnelId,
    dnsId,
    leakId,
    rulesetsId,
    clockId,
  ];

  /// Hard cap per step: a hung probe never blocks the list.
  static const stepTimeout = Duration(seconds: 5);
  static const maxSkew = Duration(seconds: 90);

  /// The in-tunnel DNS check resolves through Google's DoH JSON endpoint;
  /// the config builder routes `dns.google` through the proxy on every
  /// preset, so a reply proves DNS works *through the tunnel*.
  static const dnsProbeUrl = 'https://dns.google/resolve?name=example.com';

  DiagProbes probes = DiagProbes();

  /// Results in step order (a step is absent until it has run).
  final Map<String, StepResult> results = {};
  bool running = false;
  String? currentStep;

  /// When the last full run finished (null until one has).
  DateTime? finishedAt;

  /// Cancelled or restarted runs bump this so their late results are dropped.
  int _gen = 0;
  bool _disposed = false;

  bool get complete => !running && results.isNotEmpty;

  @override
  Future<void> load() async {
    features.commands.register(AppCommand(
      id: 'doctor.run',
      titleKey: 'doctor.title',
      group: 'palette.g.tools',
      icon: Icons.troubleshoot_rounded,
      keywords: const ['diagnostics', 'doctor', 'диагностика', 'проверка'],
      run: showDoctorSheet,
    ));
  }

  List<DiagStep> steps() => [
        DiagStep(id: internetId, run: _internet),
        DiagStep(id: serverId, run: _server),
        DiagStep(id: coreId, run: _core),
        DiagStep(id: tunnelId, run: _tunnel),
        DiagStep(id: dnsId, run: _dns),
        DiagStep(id: leakId, run: _leak),
        DiagStep(id: rulesetsId, run: _rulesets),
        DiagStep(id: clockId, run: _clock),
      ];

  /// Runs every step in order. Stops early only when the internet check
  /// fails (nothing after it can succeed); the untouched steps are recorded
  /// as skipped so the report stays complete.
  Future<void> run() async {
    final gen = ++_gen;
    results.clear();
    running = true;
    currentStep = null;
    _notify();
    final all = steps();
    var stopped = false;
    for (final step in all) {
      if (gen != _gen) return;
      if (stopped) {
        results[step.id] = const StepResult(StepStatus.skipped, 'doctor.notRun');
        continue;
      }
      currentStep = step.id;
      _notify();
      final r = await _guard(step.run);
      if (gen != _gen) return;
      results[step.id] = r;
      if (step.id == internetId && r.isFail) stopped = true;
      _notify();
    }
    running = false;
    currentStep = null;
    finishedAt = now();
    _notify();
  }

  /// Stops after the step in flight; results gathered so far stay.
  void cancel() {
    if (!running) return;
    _gen++;
    running = false;
    currentStep = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _gen++;
    _disposed = true;
    super.dispose();
  }

  Future<StepResult> _guard(Future<StepResult> Function() f) async {
    try {
      return await f().timeout(stepTimeout);
    } on TimeoutException {
      return const StepResult(StepStatus.fail, 'doctor.timeout');
    } catch (_) {
      return const StepResult(StepStatus.fail, 'doctor.error');
    }
  }

  // ------------------------------------------------------------ steps

  Future<StepResult> _internet() => (probes.internet ?? _internetDefault)();

  /// A raw TCP connect to 1.1.1.1:443 (no DNS involved) plus a lookup of
  /// example.com: together they tell "no network" from "DNS is broken".
  Future<StepResult> _internetDefault() async {
    if (!networkAllowed) return const StepResult(StepStatus.fail, 'doctor.timeout');
    final ping = tcpPing('1.1.1.1', 443, timeout: const Duration(seconds: 4));
    final lookup = InternetAddress.lookup('example.com')
        .timeout(const Duration(seconds: 4))
        .then((a) => a.isNotEmpty, onError: (_) => false);
    final ms = await ping;
    final dns = await lookup;
    if (ms != null && dns) return StepResult.ms(StepStatus.ok, ms);
    if (ms != null) return const StepResult(StepStatus.warn, 'doctor.dnsBroken');
    if (dns) return const StepResult(StepStatus.warn, 'doctor.tcpBlocked');
    return const StepResult(StepStatus.fail, 'doctor.timeout');
  }

  /// The host the tunnel actually dials first: the chain entry when the
  /// double VPN is on, otherwise the active node.
  Future<StepResult> _server() {
    final node = (app.chain.active ? app.nodeById(app.chain.entryNodeId) : null) ?? app.activeNode;
    if (node == null || node.server.isEmpty || node.port <= 0) {
      return Future.value(const StepResult(StepStatus.skipped, 'doctor.noServer'));
    }
    return (probes.server ?? _serverDefault)(node.server, node.port);
  }

  Future<StepResult> _serverDefault(String host, int port) async {
    if (!networkAllowed) return const StepResult(StepStatus.fail, 'doctor.timeout');
    final ms = await tcpPing(host, port, timeout: const Duration(seconds: 4));
    return ms == null ? const StepResult(StepStatus.fail, 'doctor.timeout') : StepResult.ms(StepStatus.ok, ms);
  }

  Future<StepResult> _core() => (probes.core ?? _coreDefault)();

  /// Desktop: the daemon reported a version at load. Mobile: the platform
  /// side answers a state query.
  Future<StepResult> _coreDefault() async {
    if (app.isDesktopPlatform) {
      final v = app.coreVersion;
      return v == null
          ? const StepResult(StepStatus.fail, 'doctor.noCore')
          : StepResult.value(StepStatus.ok, v, const {});
    }
    await app.vpn.currentState();
    return const StepResult(StepStatus.ok, 'doctor.coreOk');
  }

  Future<StepResult> _tunnel() {
    if (!app.connected) return Future.value(const StepResult(StepStatus.skipped, 'doctor.skipped'));
    return (probes.tunnel ?? _delayDefault)(kProxySelector, app.settings.probeUrl);
  }

  Future<StepResult> _dns() {
    if (!app.connected) return Future.value(const StepResult(StepStatus.skipped, 'doctor.skipped'));
    return (probes.dns ?? _delayDefault)(kProxySelector, dnsProbeUrl);
  }

  /// A real URL test through the selector via the Clash API.
  Future<StepResult> _delayDefault(String tag, String url) async {
    final c = app.clash;
    if (c == null) return const StepResult(StepStatus.skipped, 'doctor.noApi');
    final ms = await c.delay(tag, url: url, timeoutMs: 4000);
    return ms == null ? const StepResult(StepStatus.fail, 'doctor.timeout') : StepResult.ms(StepStatus.ok, ms);
  }

  Future<StepResult> _leak() {
    if (!app.connected) return Future.value(const StepResult(StepStatus.skipped, 'doctor.skipped'));
    return (probes.leak ?? _leakDefault)();
  }

  Future<StepResult> _leakDefault() async {
    final n = features.netcheck;
    await n.refresh();
    return leakResult(n.realIp?.ip, n.exitIp?.ip);
  }

  Future<StepResult> _rulesets() async {
    if (app.isIOS) return const StepResult(StepStatus.skipped, 'doctor.skippedIos');
    final dir = '${await app.store.cacheDir()}/rulesets';
    return (probes.rulesets ?? _rulesetsDefault)(dir);
  }

  /// Missing rule-sets are a warning, not a failure: sing-box downloads
  /// them on first use, but until then presets route less than they claim.
  Future<StepResult> _rulesetsDefault(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return const StepResult(StepStatus.warn, 'doctor.rulesetsNone');
    var n = 0;
    await for (final e in d.list()) {
      if (e is File && e.path.endsWith('.srs')) n++;
    }
    return n == 0
        ? const StepResult(StepStatus.warn, 'doctor.rulesetsNone')
        : StepResult.value(StepStatus.ok, 'doctor.rulesetsN', {'n': '$n'});
  }

  Future<StepResult> _clock() => (probes.clock ?? _clockDefault)(app.settings.probeUrl);

  /// HEAD to the probe URL: every HTTP response carries a `Date` header, so
  /// even a 405 gives a trustworthy server clock.
  Future<StepResult> _clockDefault(String url) async {
    if (!networkAllowed) return const StepResult(StepStatus.warn, 'doctor.clockUnknown');
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return const StepResult(StepStatus.warn, 'doctor.clockUnknown');
    final client = features.httpClient();
    try {
      final r = await client.head(uri).timeout(const Duration(seconds: 4));
      final date = r.headers['date'];
      if (date == null) return const StepResult(StepStatus.warn, 'doctor.clockUnknown');
      return clockResult(HttpDate.parse(date), now());
    } catch (_) {
      return const StepResult(StepStatus.warn, 'doctor.clockUnknown');
    } finally {
      client.close();
    }
  }
}
