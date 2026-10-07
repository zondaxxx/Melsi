import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/config_builder.dart';
import '../core/country.dart';
import '../core/link_parser.dart';
import '../core/models.dart';
import '../core/subscription_fetcher.dart';
import '../services/clash_api.dart';
import '../services/desktop_vpn_controller.dart';
import '../services/engine_api.dart';
import '../services/platform_apps.dart';
import '../services/tcp_ping.dart';
import '../services/vpn_controller.dart';
import 'import_input.dart';
import 'store.dart';
import 'traffic.dart';

/// Result of one latency test.
class Latency {
  const Latency(this.ms, {required this.viaUrl, required this.at});

  /// null = failed / timed out.
  final int? ms;

  /// true: real URL test through the tunnel (Clash API delay).
  /// false: TCP connect time to server:port ("TCP ping").
  final bool viaUrl;
  final DateTime at;
  bool get failed => ms == null;
}

enum NoticeKind { info, success, error }

/// A transient message for the UI (snack bar). [key] is an l10n key;
/// [detail] is appended verbatim (e.g. an error string).
class Notice {
  const Notice(this.key, {this.kind = NoticeKind.info, this.args = const {}, this.detail});
  final String key;
  final NoticeKind kind;
  final Map<String, String> args;
  final String? detail;
}

enum NodeSort { none, latency, name }

/// Progress of applying config changes to a running tunnel.
/// idle → pending (debouncing) → applying → done / failed → idle.
enum ApplyPhase { idle, pending, applying, done, failed }

/// Selector tags the config builder emits.
const kProxySelector = 'proxy';
const kGameSelector = 'game';

/// The one app-wide state object. Plain ChangeNotifier; the UI listens via
/// [AppScope] / ListenableBuilder.
class AppState extends ChangeNotifier {
  AppState({
    StateStore? store,
    VpnController? vpn,
    PlatformApps? apps,
    SubscriptionFetcher? fetcher,
    PlatformKind? platform,
    this.enableNetwork = true,
  })  : store = store ?? FileStateStore(),
        vpn = vpn ?? VpnController.forPlatform(),
        apps = apps ?? PlatformApps(),
        platform = platform ?? currentPlatformKind(),
        _fetcher = fetcher; // ignore: prefer_initializing_formals

  final StateStore store;
  final VpnController vpn;
  final PlatformApps apps;
  final PlatformKind platform;
  final SubscriptionFetcher? _fetcher;

  /// Tests turn this off: no auto-updates / pings on load.
  final bool enableNetwork;

  SubscriptionFetcher get fetcher => _fetcher ?? SubscriptionFetcher();

  // ----------------------------------------------------------- persisted
  final List<Subscription> subscriptions = [];
  final List<ProxyNode> nodes = [];
  String? selectedNodeId;
  RoutingSettings routing = RoutingSettings();
  GameSettings game = GameSettings();
  AppSettings settings = AppSettings();
  ChainSettings chain = ChainSettings();
  String? _lastSecret;

  /// Pinned servers (node ids, in pin order).
  final List<String> favouriteIds = [];

  /// Recently selected servers, newest first (max [maxRecents]).
  final List<String> recentIds = [];
  static const maxRecents = 6;

  /// Feature-owned JSON blobs persisted in the same document
  /// (`sections.<name>`), loaded and saved verbatim.
  final Map<String, Map<String, dynamic>> sections = {};

  // ----------------------------------------------------------- hooks
  /// Called after every tunnel status change (only when it changed).
  final List<void Function(VpnStatus prev, VpnStatus next)> statusHooks = [];

  /// Called when the app returns to the foreground.
  final List<VoidCallback> resumeHooks = [];

  // ----------------------------------------------------------- runtime
  bool loaded = false;
  int onboardingRevision = 0;
  VpnState vpnState = VpnState.stopped;
  DateTime? connectedAt;
  final Map<String, Latency> latencies = {};
  final Set<String> pinging = {};
  bool pingingAll = false;
  final Set<String> updating = {};
  final Map<String, GroupStatus> engineGroups = {};

  /// Latency of the game selector's current node, oldest first (for the
  /// Game route chart). null = failed sample.
  final List<int?> gameLatencyHistory = [];
  final List<int?> proxyLatencyHistory = [];
  bool needsReconnect = false;

  /// Config changes made while connected are applied automatically once the
  /// user stops changing things for [applyDebounce].
  ApplyPhase applyPhase = ApplyPhase.idle;
  static const applyDebounce = Duration(milliseconds: 1200);
  Timer? _applyTimer;
  Timer? _applyResetTimer;
  DateTime? _applySince;
  bool _applyAborted = false;
  int _connectAttempt = 0;
  BuiltConfig? lastBuilt;
  String? coreVersion;
  final TrafficMonitor traffic = TrafficMonitor();

  final _notices = StreamController<Notice>.broadcast();
  Stream<Notice> get notices => _notices.stream;

  ClashApi? clash;
  EngineApi? engine;
  StreamSubscription<VpnState>? _vpnSub;
  Timer? _poll;
  Timer? _notifyTimer;
  Timer? _disconnectTimer;
  DateTime? disconnectAt;

  bool get hideAddresses => sectionOf('dashboard')?['hideAddresses'] == true;

  void setHideAddresses(bool value) =>
      setSection('dashboard', {...?sectionOf('dashboard'), 'hideAddresses': value});

  void scheduleDisconnect(Duration? duration) {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    disconnectAt = null;
    if (duration != null && duration > Duration.zero && connected) {
      disconnectAt = DateTime.now().add(duration);
      _disconnectTimer = Timer(duration, () => unawaited(_finishScheduledDisconnect()));
    }
    notifyListeners();
  }

  bool _checkDisconnectDeadline() {
    final deadline = disconnectAt;
    if (deadline == null || DateTime.now().isBefore(deadline)) return false;
    unawaited(_finishScheduledDisconnect());
    return true;
  }

  Future<void> _finishScheduledDisconnect() async {
    scheduleDisconnect(null);
    if (connected || applying || busy) {
      _applyAborted = true;
      await disconnect();
      if (vpnState.status == VpnStatus.stopped) notice('dashboard.timerFinished');
    }
  }
  RuntimeEndpoints? _endpoints;

  bool get connected => vpnState.status == VpnStatus.connected;
  bool get busy =>
      vpnState.status == VpnStatus.connecting || vpnState.status == VpnStatus.stopping;

  bool get applying => applyPhase == ApplyPhase.applying;

  /// Status the UI shows. While settings are being applied the tunnel
  /// restarts under the hood, but to the user it stays connected.
  VpnStatus get displayStatus =>
      applying && vpnState.status != VpnStatus.error ? VpnStatus.connected : vpnState.status;

  /// Start of the current session (kept across seamless re-applies).
  DateTime? get sessionSince => connectedAt ?? (applying ? _applySince : null);

  // ============================================================ lifecycle

  Future<void> load() async {
    final j = await store.load();
    if (j != null) _fromJson(j);
    loaded = true;
    notifyListeners();
    unawaited(_prepareBundledRuleSets());

    _vpnSub = vpn.states.listen(_onVpnState, onError: (Object _) {});
    unawaited(_attach());
    unawaited(vpn.coreVersion().then((v) {
      coreVersion = v;
      notifyListeners();
    }));

    if (enableNetwork) {
      unawaited(updateDueSubscriptions());
      if (settings.connectOnLaunch && nodes.isNotEmpty) {
        // Give the attach check a moment so we don't double-start.
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          if (vpnState.status == VpnStatus.stopped) connect();
        });
      } else {
        Future<void>.delayed(const Duration(seconds: 1), () {
          if (!connected && latencies.isEmpty) pingAll();
        });
      }
    }
  }

  /// Re-attaches to a tunnel that is already running (app restart).
  Future<void> _attach() async {
    final s = await vpn.currentState();
    if (s.status == VpnStatus.connected) {
      var secret = _lastSecret;
      if (vpn is DesktopVpnController) {
        secret = await (vpn as DesktopVpnController).attachedSecret() ?? secret;
      }
      if (secret != null) {
        _endpoints = RuntimeEndpoints(secret: secret);
        try {
          lastBuilt = await _build(_endpoints!);
        } catch (_) {}
      }
      // This process did not launch the tunnel, so the live selector may
      // still be the outbound sing-box restored from an older cache.
      _startedForNodeId = null;
      _onVpnState(s);
    }
  }

  /// Called by the UI when the app returns to the foreground.
  void onResume() {
    final timerExpired = _checkDisconnectDeadline();
    if (enableNetwork) unawaited(updateDueSubscriptions());
    if (!timerExpired) {
      unawaited(vpn.currentState().then((s) {
        if (s.status != vpnState.status && s.status != VpnStatus.error) _onVpnState(s);
      }));
    }
    // A tunnel restored in the background can still be sitting on the
    // outbound sing-box cached before this manual pick.
    if (connected && !settings.autoSelect) unawaited(_pinManualSelection());
    for (final h in List.of(resumeHooks)) {
      h();
    }
  }

  @override
  void dispose() {
    _disconnectTimer?.cancel();
    _vpnSub?.cancel();
    _poll?.cancel();
    _notifyTimer?.cancel();
    _applyTimer?.cancel();
    _applyResetTimer?.cancel();
    traffic.dispose();
    clash?.close();
    engine?.close();
    vpn.dispose();
    _notices.close();
    unawaited(store.flush());
    super.dispose();
  }

  void _save() => store.scheduleSave(toJson);

  void _changed({bool save = true}) {
    // Anyone who already has servers has nothing to be onboarded about.
    if (!settings.onboardingDone && nodes.isNotEmpty) settings.onboardingDone = true;
    if (save) _save();
    notifyListeners();
  }

  /// Coalesces bursts of updates (pinging hundreds of nodes).
  void _notifySoon() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  void notice(String key,
      {NoticeKind kind = NoticeKind.info, Map<String, String> args = const {}, String? detail}) {
    if (!_notices.isClosed) {
      _notices.add(Notice(key, kind: kind, args: args, detail: detail));
    }
  }

  // ============================================================ JSON

  Map<String, dynamic> toJson() => {
        'version': 1,
        'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
        'nodes': nodes.map((e) => e.toJson()).toList(),
        'selectedNodeId': selectedNodeId,
        'routing': routing.toJson(),
        'game': game.toJson(),
        'settings': settings.toJson(),
        'chain': chain.toJson(),
        'favourites': favouriteIds,
        'recents': recentIds,
        'sections': sections,
        'lastSecret': _lastSecret,
      };

  void _fromJson(Map<String, dynamic> j) {
    T? tryParse<T>(T Function() f) {
      try {
        return f();
      } catch (_) {
        return null;
      }
    }

    Map<String, dynamic> m(Object? o) =>
        o is Map ? o.cast<String, dynamic>() : <String, dynamic>{};

    subscriptions
      ..clear()
      ..addAll((j['subscriptions'] as List? ?? const [])
          .map((e) => tryParse(() => Subscription.fromJson(m(e))))
          .whereType<Subscription>());
    nodes
      ..clear()
      ..addAll((j['nodes'] as List? ?? const [])
          .map((e) => tryParse(() => ProxyNode.fromJson(m(e))))
          .whereType<ProxyNode>());
    selectedNodeId = j['selectedNodeId'] as String?;
    routing = tryParse(() => RoutingSettings.fromJson(m(j['routing']))) ?? RoutingSettings();
    game = tryParse(() => GameSettings.fromJson(m(j['game']))) ?? GameSettings();
    settings = tryParse(() => AppSettings.fromJson(m(j['settings']))) ?? AppSettings();
    chain = tryParse(() => ChainSettings.fromJson(m(j['chain']))) ?? ChainSettings();
    _lastSecret = j['lastSecret'] as String?;
    favouriteIds
      ..clear()
      ..addAll((j['favourites'] as List? ?? const []).map((e) => e.toString()));
    recentIds
      ..clear()
      ..addAll((j['recents'] as List? ?? const []).map((e) => e.toString()).take(maxRecents));
    sections.clear();
    (j['sections'] as Map? ?? const {}).forEach((k, v) {
      if (v is Map) sections[k.toString()] = v.cast<String, dynamic>();
    });
    _pruneRefs();
  }

  /// Replaces the whole persisted state (backup restore). Config-affecting,
  /// so a running tunnel re-applies.
  void replaceFromJson(Map<String, dynamic> j) {
    final snapshot = (jsonDecode(jsonEncode(j)) as Map).cast<String, dynamic>();
    snapshot['lastSecret'] = _lastSecret;
    _fromJson(snapshot);
    _markConfigChanged();
    _changed();
  }

  /// Drops favourites / recents / chain entry that point at removed nodes.
  void _pruneRefs() {
    final ids = nodes.map((n) => n.id).toSet();
    if (!ids.contains(selectedNodeId)) selectedNodeId = nodes.firstOrNull?.id;
    if (!ids.contains(game.gameNodeId)) game.gameNodeId = null;
    favouriteIds.removeWhere((id) => !ids.contains(id));
    recentIds.removeWhere((id) => !ids.contains(id));
    if (chain.entryNodeId != null && !ids.contains(chain.entryNodeId)) {
      chain.entryNodeId = null;
    }
  }

  // ============================================================ favourites / sections

  bool isFavourite(String id) => favouriteIds.contains(id);

  void toggleFavourite(String id) {
    if (!favouriteIds.remove(id)) favouriteIds.add(id);
    _changed();
  }

  /// Favourites in pin order (missing nodes skipped).
  List<ProxyNode> get favouriteNodes =>
      favouriteIds.map(nodeById).whereType<ProxyNode>().toList();

  /// Recently selected, newest first.
  List<ProxyNode> get recentNodes =>
      recentIds.map(nodeById).whereType<ProxyNode>().toList();

  /// Lowest known latency per country: country code -> node id.
  Map<String, String> bestByCountry() {
    final best = <String, (String, int)>{};
    for (final n in nodes) {
      final cc = n.countryCode;
      final ms = latencyOf(n);
      if (cc == null || ms == null || ms <= 0) continue;
      final cur = best[cc];
      if (cur == null || ms < cur.$2) best[cc] = (n.id, ms);
    }
    return {for (final e in best.entries) e.key: e.value.$1};
  }

  Map<String, dynamic>? sectionOf(String name) => sections[name];

  void setSection(String name, Map<String, dynamic> json) {
    sections[name] = json;
    _save();
    notifyListeners();
  }

  void updateChain(void Function(ChainSettings c) f) {
    f(chain);
    _markConfigChanged();
    _changed();
  }

  void finishOnboarding() {
    settings.onboardingDone = true;
    onboardingRevision++;
    _changed();
  }

  // ============================================================ queries

  ProxyNode? nodeById(String? id) {
    if (id == null) return null;
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  Subscription? subscriptionById(String? id) {
    if (id == null) return null;
    for (final s in subscriptions) {
      if (s.id == id) return s;
    }
    return null;
  }

  ProxyNode? get selectedNode => nodeById(selectedNodeId) ?? nodes.firstOrNull;

  List<ProxyNode> nodesOf(String? subscriptionId) =>
      nodes.where((n) => n.subscriptionId == subscriptionId).toList();

  bool get hasManualNodes => nodes.any((n) => n.subscriptionId == null);

  String? tagOf(String nodeId) => lastBuilt?.nodeTags[nodeId];

  ProxyNode? nodeByTag(String? tag) {
    if (tag == null || lastBuilt == null) return null;
    for (final e in lastBuilt!.nodeTags.entries) {
      if (e.value == tag) return nodeById(e.key);
    }
    return null;
  }

  GroupStatus? get proxyGroup => engineGroups[kProxySelector];
  GroupStatus? get gameGroup => engineGroups[kGameSelector];

  /// The node traffic actually uses right now.
  ///
  /// Auto mode follows the engine. A manual pick follows [selectedNodeId]
  /// even while the engine is still reporting the previous outbound, so the
  /// UI and the next start agree with the server the user chose.
  ProxyNode? get activeNode {
    if (connected && settings.autoSelect) {
      final n = nodeByTag(proxyGroup?.current);
      if (n != null) return n;
    }
    return selectedNode;
  }

  NodeStat? statOf(ProxyNode n, {String selector = kProxySelector}) =>
      engineGroups[selector]?.stat(tagOf(n.id));

  /// Best-known latency for a node: engine stat when connected, else the last
  /// explicit test.
  int? latencyOf(ProxyNode n) {
    final l = latencies[n.id];
    if (l != null) return l.ms;
    return statOf(n)?.latencyMs;
  }

  List<ProxyNode> filteredNodes({
    String? subscriptionId,
    bool allSubscriptions = true,
    String query = '',
    ProxyProtocol? protocol,
    String? country,
    NodeSort sort = NodeSort.none,
  }) {
    final q = query.trim().toLowerCase();
    final list = nodes.where((n) {
      if (!allSubscriptions && n.subscriptionId != subscriptionId) return false;
      if (protocol != null && n.protocol != protocol) return false;
      if (country != null && n.countryCode != country) return false;
      if (q.isNotEmpty &&
          !n.name.toLowerCase().contains(q) &&
          !n.server.toLowerCase().contains(q) &&
          !n.protocol.label.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
    switch (sort) {
      case NodeSort.latency:
        int key(ProxyNode n) => latencyOf(n) ?? 1 << 30;
        list.sort((a, b) => key(a).compareTo(key(b)));
      case NodeSort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case NodeSort.none:
        break;
    }
    return list;
  }

  Set<String> get countries =>
      nodes.map((n) => n.countryCode).whereType<String>().toSet();
  Set<ProxyProtocol> get protocols => nodes.map((n) => n.protocol).toSet();

  // ============================================================ import

  /// Imports whatever the user pasted/scanned/opened. Returns number of
  /// nodes added (subscriptions count their nodes).
  Future<int> importText(String raw, {String? name}) async {
    final input = ImportInput.classify(raw);
    switch (input) {
      case ImportEmpty():
        notice('notice.nothingToImport', kind: NoticeKind.error);
        return 0;
      case SubscriptionUrlInput(:final url, name: final n):
        final sub = await addSubscription(url, name: n ?? name);
        return sub == null ? 0 : nodesOf(sub.id).length;
      case SingleLinkInput(:final link):
        final node = LinkParser.parseLink(link);
        if (node == null) {
          // Maybe it's a subscription after all (odd URL shape).
          if (link.startsWith('http')) {
            final sub = await addSubscription(link, name: name);
            return sub == null ? 0 : nodesOf(sub.id).length;
          }
          notice('notice.unsupportedLink', kind: NoticeKind.error);
          return 0;
        }
        return _addManual([node]);
      case ContentInput(:final content):
        final parsed = LinkParser.parseContent(content);
        if (parsed.isEmpty) {
          notice('notice.nothingToImport', kind: NoticeKind.error);
          return 0;
        }
        if (parsed.length == 1 && name == null) return _addManual(parsed);
        final sub = Subscription(
          id: _newId(),
          name: name ?? '${settings.locale == 'en' ? 'Import' : 'Импорт'} ${subscriptions.length + 1}',
          updatedAt: DateTime.now(),
        );
        final ns = LinkParser.parseContent(content, subscriptionId: sub.id);
        _prepareNodes(ns);
        subscriptions.add(sub);
        nodes.addAll(_dedupe(ns));
        selectedNodeId ??= ns.firstOrNull?.id;
        _markConfigChanged();
        _changed();
        notice('notice.imported', kind: NoticeKind.success, args: {'n': '${ns.length}'});
        return ns.length;
    }
  }

  int _addManual(List<ProxyNode> ns) {
    _prepareNodes(ns);
    final existing = nodes.map((e) => e.id).toSet();
    final fresh = ns.where((n) => !existing.contains(n.id)).toList();
    nodes.addAll(fresh);
    if (fresh.isNotEmpty) selectedNodeId ??= fresh.first.id;
    _markConfigChanged();
    _changed();
    notice(fresh.isEmpty ? 'notice.alreadyAdded' : 'notice.imported',
        kind: fresh.isEmpty ? NoticeKind.info : NoticeKind.success,
        args: {'n': '${fresh.length}'});
    return fresh.length;
  }

  void _prepareNodes(List<ProxyNode> ns) {
    for (final n in ns) {
      n.countryCode ??= guessCountryCode(n.name);
    }
  }

  List<ProxyNode> _dedupe(List<ProxyNode> ns) {
    final seen = <String>{};
    return ns.where((n) => seen.add(n.id)).toList();
  }

  Future<Subscription?> addSubscription(String url, {String? name}) async {
    final existing = subscriptions.where((s) => s.url == url).firstOrNull;
    if (existing != null) {
      await updateSubscription(existing.id);
      return existing;
    }
    final sub = Subscription(
      id: _newId(),
      name: name ?? Uri.tryParse(url)?.host ?? 'Subscription',
      url: url,
    );
    subscriptions.add(sub);
    _changed();
    // On failure the subscription is kept (empty) so the user can retry.
    await updateSubscription(sub.id, userNamed: name != null);
    return sub;
  }

  Future<bool> updateSubscription(String id, {bool userNamed = false, bool quiet = false}) async {
    final sub = subscriptionById(id);
    if (sub == null || sub.url == null || updating.contains(id)) return false;
    updating.add(id);
    notifyListeners();
    try {
      final r = await fetcher.fetch(sub.url!, userAgent: sub.userAgent, subscriptionId: id);
      if (r.nodes.isEmpty) throw const FormatException('empty');
      _prepareNodes(r.nodes);
      final wasSelected = nodeById(selectedNodeId)?.subscriptionId == id;
      final oldIds = nodesOf(id).map((n) => n.id).toSet();
      nodes.removeWhere((n) => n.subscriptionId == id);
      nodes.addAll(_dedupe(r.nodes));
      if (!userNamed && r.title != null && r.title!.trim().isNotEmpty) {
        sub.name = r.title!.trim();
      }
      sub
        ..updatedAt = DateTime.now()
        ..upload = r.upload ?? sub.upload
        ..download = r.download ?? sub.download
        ..total = r.total ?? sub.total
        ..expire = r.expire ?? sub.expire
        ..updateIntervalHours = r.updateIntervalHours ?? sub.updateIntervalHours
        ..supportUrl = r.supportUrl ?? sub.supportUrl
        ..webPageUrl = r.webPageUrl ?? sub.webPageUrl
        ..announce = r.announce ?? sub.announce;
      if (selectedNodeId == null || (wasSelected && nodeById(selectedNodeId) == null)) {
        selectedNodeId = nodesOf(id).firstOrNull?.id ?? nodes.firstOrNull?.id;
      }
      final newIds = nodesOf(id).map((n) => n.id).toSet();
      _pruneRefs();
      if (!setEquals(oldIds, newIds)) _markConfigChanged();
      if (!quiet) {
        notice('notice.subUpdated',
            kind: NoticeKind.success, args: {'name': sub.name, 'n': '${newIds.length}'});
      }
      return true;
    } catch (e) {
      if (!quiet) {
        notice('notice.subFailed',
            kind: NoticeKind.error, args: {'name': sub.name}, detail: _short(e));
      }
      return false;
    } finally {
      updating.remove(id);
      _changed();
    }
  }

  Future<void> updateAllSubscriptions() async {
    await Future.wait(subscriptions
        .where((s) => s.url != null)
        .map((s) => updateSubscription(s.id, quiet: true)));
    notice('notice.allUpdated', kind: NoticeKind.success);
  }

  /// Auto-update subscriptions whose interval has elapsed.
  Future<void> updateDueSubscriptions() async {
    final now = DateTime.now();
    final due = subscriptions.where((s) =>
        s.url != null &&
        (s.updatedAt == null ||
            now.difference(s.updatedAt!) >= Duration(hours: max(1, s.updateIntervalHours))));
    await Future.wait(due.map((s) => updateSubscription(s.id, quiet: true)));
  }

  void removeSubscription(String id) {
    subscriptions.removeWhere((s) => s.id == id);
    nodes.removeWhere((n) => n.subscriptionId == id);
    if (nodeById(selectedNodeId) == null) selectedNodeId = nodes.firstOrNull?.id;
    _pruneRefs();
    _markConfigChanged();
    _changed();
  }

  void renameSubscription(String id, String name) {
    subscriptionById(id)?.name = name;
    _changed();
  }

  void setSubscriptionInterval(String id, int hours) {
    subscriptionById(id)?.updateIntervalHours = hours;
    _changed();
  }

  void removeNode(String id) {
    nodes.removeWhere((n) => n.id == id);
    latencies.remove(id);
    if (selectedNodeId == id) selectedNodeId = nodes.firstOrNull?.id;
    if (game.gameNodeId == id) game.gameNodeId = null;
    _pruneRefs();
    _markConfigChanged();
    _changed();
  }

  void renameNode(String id, String name) {
    nodeById(id)?.name = name;
    _markConfigChanged();
    _changed();
  }

  // ============================================================ selection

  /// Bumps when the manual server changes, so a connect that is still
  /// building its config starts the newly chosen node.
  int _selectionEpoch = 0;

  /// Node id baked into the config that was actually started. Null after
  /// attaching to a tunnel this process did not start.
  String? _startedForNodeId;

  Future<void> selectNode(String id) async {
    if (nodeById(id) == null) return;
    final same = selectedNodeId == id && !settings.autoSelect;
    selectedNodeId = id;
    recentIds
      ..remove(id)
      ..insert(0, id);
    if (recentIds.length > maxRecents) recentIds.removeLast();
    final wasAuto = settings.autoSelect;
    // Turn auto off before any await. A connect already in flight reads
    // these fields, and a failed live switch must not leave auto on.
    settings.autoSelect = false;
    if (!same) _selectionEpoch++;
    if (wasAuto) notice('notice.autoOffManual');
    _changed();
    await store.flush();
    if (same) {
      if (connected) unawaited(_applyManualSelection());
      return;
    }
    if (vpnState.status == VpnStatus.connecting) return;
    if (connected) await _applyManualSelection();
  }

  /// Points the running selector at [selectedNodeId] and drops old flows.
  /// A failed switch marks the config dirty so the next restart uses the
  /// manual cache namespace instead of the previous outbound.
  Future<void> _applyManualSelection() async {
    if (settings.autoSelect) return;
    final id = selectedNodeId;
    if (id == null) return;
    final tag = tagOf(id);
    if (tag == null) {
      _markConfigChanged();
      return;
    }
    try {
      if (engine != null) {
        await engine!.setAuto(kProxySelector, false);
        engineGroups[kProxySelector] = await engine!.select(kProxySelector, tag);
      } else if (clash != null) {
        final ok = await clash!.select(kProxySelector, tag);
        if (!ok) throw StateError('select failed');
      } else {
        _markConfigChanged();
        return;
      }
      _startedForNodeId = id;
      unawaited(clash?.closeAllConnections().catchError((_) {}));
      notifyListeners();
    } catch (_) {
      _markConfigChanged();
      notifyListeners();
    }
  }

  /// After start or resume, move a live tunnel onto the manual pick when
  /// the running config was not built for it.
  Future<void> _pinManualSelection() async {
    if (settings.autoSelect) return;
    final id = selectedNodeId;
    if (id == null || _startedForNodeId == id) return;
    final epoch = _selectionEpoch;
    for (var i = 0; i < 6; i++) {
      if (!connected || settings.autoSelect || selectedNodeId != id || _selectionEpoch != epoch) {
        return;
      }
      final tag = tagOf(id);
      if (tag == null) break;
      try {
        if (engine != null) {
          await engine!.setAuto(kProxySelector, false);
          final group = await engine!.select(kProxySelector, tag);
          if (selectedNodeId != id || _selectionEpoch != epoch) return;
          engineGroups[kProxySelector] = group;
          _startedForNodeId = id;
          unawaited(clash?.closeAllConnections().catchError((_) {}));
          notifyListeners();
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(Duration(milliseconds: 80 * (i + 1)));
    }
    if (connected && !settings.autoSelect && selectedNodeId == id && _selectionEpoch == epoch) {
      _markConfigChanged();
    }
  }

  Future<void> setAutoSelect(bool on) async {
    settings.autoSelect = on;
    _changed();
    if (connected && engine != null) {
      try {
        engineGroups[kProxySelector] = await engine!.setAuto(kProxySelector, on);
        notifyListeners();
      } catch (_) {
        _markConfigChanged();
        notifyListeners();
      }
    }
  }

  Future<void> setSmartMode(SmartMode mode) async {
    settings.smartMode = mode;
    _changed();
    if (connected && engine != null) {
      try {
        engineGroups[kProxySelector] = await engine!.setMode(kProxySelector, mode.name);
        notifyListeners();
      } catch (_) {
        _markConfigChanged();
        notifyListeners();
      }
    }
  }

  Future<void> setGameNode(String? nodeId) async {
    game.gameNodeId = nodeId;
    _changed();
    if (connected && engine != null && gameGroup != null) {
      try {
        if (nodeId == null) {
          engineGroups[kGameSelector] = await engine!.setAuto(kGameSelector, true);
        } else {
          final tag = tagOf(nodeId);
          if (tag == null) throw StateError('no tag');
          engineGroups[kGameSelector] = await engine!.select(kGameSelector, tag);
        }
        notifyListeners();
      } catch (_) {
        _markConfigChanged();
        notifyListeners();
      }
    }
  }

  Future<void> probeNow() async {
    if (engine == null) return;
    try {
      engineGroups[kProxySelector] = await engine!.probe(kProxySelector);
      notifyListeners();
    } catch (_) {}
  }

  // ============================================================ settings

  /// Mutations that change the generated config. While connected they are
  /// applied automatically after a short debounce (see [applyNow]).
  void updateRouting(void Function(RoutingSettings r) f) {
    f(routing);
    _markConfigChanged();
    _changed();
  }

  void updateGame(void Function(GameSettings g) f) {
    f(game);
    _markConfigChanged();
    _changed();
  }

  void updateSettings(void Function(AppSettings s) f, {bool affectsConfig = true}) {
    f(settings);
    if (affectsConfig) _markConfigChanged();
    _changed();
  }

  void _markConfigChanged() {
    if (connected || vpnState.status == VpnStatus.connecting || applying) {
      needsReconnect = true;
      _scheduleApply();
    }
  }

  void dismissReconnect() {
    needsReconnect = false;
    _applyTimer?.cancel();
    if (applyPhase == ApplyPhase.pending) applyPhase = ApplyPhase.idle;
    notifyListeners();
  }

  /// (Re)starts the debounce: every further change pushes the apply back, so
  /// a burst of edits results in a single restart.
  void _scheduleApply() {
    _applyTimer?.cancel();
    _applyResetTimer?.cancel();
    if (!applying) applyPhase = ApplyPhase.pending;
    _applyTimer = Timer(applyDebounce, () => unawaited(applyNow()));
  }

  /// Applies pending config changes to the running tunnel: a hot reload on
  /// iOS, a quick stop + start elsewhere. The session timer is preserved.
  Future<void> applyNow() async {
    _applyTimer?.cancel();
    if (!needsReconnect) {
      if (applyPhase == ApplyPhase.pending) {
        applyPhase = ApplyPhase.idle;
        notifyListeners();
      }
      return;
    }
    if (applying || vpnState.status == VpnStatus.connecting) {
      // Still settling from the previous start; try again shortly.
      _applyTimer = Timer(applyDebounce, () => unawaited(applyNow()));
      return;
    }
    if (!connected) {
      needsReconnect = false;
      applyPhase = ApplyPhase.idle;
      notifyListeners();
      return;
    }
    applyPhase = ApplyPhase.applying;
    _applySince = connectedAt;
    notifyListeners();
    var ok = false;
    try {
      if (Platform.isIOS && _endpoints != null) {
        needsReconnect = false;
        final built = await _build(_endpoints!);
        lastBuilt = built;
        _startedForNodeId = selectedNodeId;
        await vpn.start(built, name: selectedNode?.name ?? 'Melsi');
        _startRuntime();
      } else {
        _applyAborted = false;
        needsReconnect = false;
        await disconnect(preserveTimer: true);
        await _waitForStatus(
            (s) => s == VpnStatus.stopped || s == VpnStatus.error, const Duration(seconds: 8));
        if (!_applyAborted) await connect();
        await _waitForStatus(
            (s) => s == VpnStatus.connected || s == VpnStatus.error || s == VpnStatus.stopped,
            const Duration(seconds: 20));
      }
      ok = connected;
    } catch (e) {
      notice('notice.applyFailed', kind: NoticeKind.error, detail: _short(e));
    }
    if (!ok) scheduleDisconnect(null);
    if (ok && _applySince != null) connectedAt = _applySince;
    _applySince = null;
    applyPhase = ok
        ? ApplyPhase.done
        : _applyAborted
            ? ApplyPhase.idle
            : ApplyPhase.failed;
    notifyListeners();
    if (ok && needsReconnect) {
      // More edits arrived while we were restarting.
      _scheduleApply();
      return;
    }
    _applyResetTimer?.cancel();
    _applyResetTimer = Timer(Duration(milliseconds: ok ? 1600 : 3200), () {
      if (applyPhase == ApplyPhase.done || applyPhase == ApplyPhase.failed) {
        applyPhase = ApplyPhase.idle;
        notifyListeners();
      }
    });
  }

  /// Waits until [vpnState] satisfies [done]. Listens to this notifier (not
  /// the controller stream) so an event already queued can't be missed.
  Future<void> _waitForStatus(bool Function(VpnStatus s) done, Duration timeout) async {
    if (done(vpnState.status)) return;
    final c = Completer<void>();
    void check() {
      if (done(vpnState.status) && !c.isCompleted) c.complete();
    }

    addListener(check);
    try {
      await c.future.timeout(timeout, onTimeout: () {});
    } finally {
      removeListener(check);
    }
  }

  // ============================================================ ping

  Future<void> pingAll() async {
    if (pingingAll || nodes.isEmpty) return;
    pingingAll = true;
    notifyListeners();
    final viaUrl = connected && clash != null && lastBuilt != null;
    final list = List<ProxyNode>.from(nodes);
    await runPool<ProxyNode>(list, viaUrl ? 8 : 24, (n) => _ping(n, viaUrl));
    pingingAll = false;
    notifyListeners();
  }

  Future<void> pingNode(String id) async {
    final n = nodeById(id);
    if (n == null) return;
    final viaUrl = connected && clash != null && lastBuilt != null;
    await _ping(n, viaUrl);
    notifyListeners();
  }

  Future<void> _ping(ProxyNode n, bool viaUrl) async {
    pinging.add(n.id);
    _notifySoon();
    int? ms;
    if (viaUrl) {
      final tag = tagOf(n.id);
      ms = tag == null
          ? null
          : await clash!.delay(tag, url: settings.probeUrl, timeoutMs: 5000);
    } else {
      ms = await tcpPing(n.server, n.port);
    }
    pinging.remove(n.id);
    latencies[n.id] = Latency(ms, viaUrl: viaUrl, at: DateTime.now());
    _notifySoon();
  }

  // ============================================================ connect

  Future<BuiltConfig> _build(RuntimeEndpoints endpoints) async {
    return ConfigBuilder.build(
      nodes: nodes,
      selectedNodeId: selectedNode?.id,
      routing: routing,
      game: game,
      settings: settings,
      chain: chain,
      platform: platform,
      endpoints: endpoints,
      cacheDir: await store.cacheDir(),
      bundledRuleSetDir: _ruleSetDir,
    );
  }

  /// Directory holding copies of the bundled rule-sets, used by sing-box as
  /// `initial_path`. Stays null on iOS: the extension can't read the app's
  /// container, so it relies on downloads there.
  String? _ruleSetDir;

  Future<void> _prepareBundledRuleSets() async {
    if (Platform.isIOS) return;
    try {
      final dir = Directory('${await store.cacheDir()}/rulesets');
      await dir.create(recursive: true);
      for (final tag in ConfigBuilder.bundledRuleSets) {
        final file = File('${dir.path}/$tag.srs');
        if (await file.exists()) continue;
        final data = await rootBundle.load('assets/rulesets/$tag.srs');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      _ruleSetDir = dir.path;
    } catch (e) {
      debugPrint('bundled rule-sets unavailable: $e');
    }
  }

  /// Builds the config that *would* be used (for export).
  Future<String> exportConfig() async {
    final b = lastBuilt ?? await _build(RuntimeEndpoints(secret: _randomSecret()));
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(b.singBox));
  }

  Future<void> toggle() async {
    if (applying) {
      // The user sees "connected" while we restart; a tap means "stop".
      _applyAborted = true;
      _applyTimer?.cancel();
      await disconnect();
      return;
    }
    switch (vpnState.status) {
      case VpnStatus.stopped || VpnStatus.error:
        await connect();
      case VpnStatus.connected || VpnStatus.connecting:
        await disconnect();
      case VpnStatus.stopping:
        break;
    }
  }

  Future<void> connect() async {
    if (busy || connected) return;
    if (nodes.isEmpty) {
      notice('notice.addServerFirst', kind: NoticeKind.error);
      return;
    }
    final attempt = ++_connectAttempt;
    _setVpn(const VpnState(VpnStatus.connecting));
    try {
      final ok = await vpn.prepare();
      if (attempt != _connectAttempt) return;
      if (!ok) {
        _setVpn(const VpnState(VpnStatus.error, 'permission'));
        notice('notice.permissionDenied', kind: NoticeKind.error);
        return;
      }
      final secret = _randomSecret();
      _endpoints = RuntimeEndpoints(secret: secret);
      _lastSecret = secret;
      _save();
      while (true) {
        if (attempt != _connectAttempt) return;
        final epoch = _selectionEpoch;
        final built = await _build(_endpoints!);
        if (attempt != _connectAttempt) return;
        if (epoch != _selectionEpoch) continue;
        lastBuilt = built;
        needsReconnect = false;
        _startedForNodeId = selectedNodeId;
        await vpn.start(built, name: selectedNode?.name ?? 'Melsi');
        break;
      }
    } catch (e) {
      if (attempt != _connectAttempt) return;
      _setVpn(VpnState(VpnStatus.error, _short(e)));
      notice('notice.connectFailed', kind: NoticeKind.error, detail: _short(e));
    }
  }

  Future<void> disconnect({bool preserveTimer = false}) async {
    _connectAttempt++;
    if (!preserveTimer) {
      scheduleDisconnect(null);
      if (applying) _applyAborted = true;
    }
    if (vpnState.status == VpnStatus.stopped) return;
    _setVpn(const VpnState(VpnStatus.stopping));
    try {
      await vpn.stop();
    } catch (e) {
      _setVpn(VpnState(VpnStatus.error, _short(e)));
    }
  }

  Future<void> reconnect() async {
    needsReconnect = false;
    if (connected || vpnState.status == VpnStatus.connecting) {
      await disconnect();
      await _waitForStatus(
          (s) => s == VpnStatus.stopped || s == VpnStatus.error, const Duration(seconds: 8));
    }
    await connect();
  }

  void _setVpn(VpnState s) {
    _onVpnState(s);
  }

  void _onVpnState(VpnState s) {
    final prev = vpnState.status;
    vpnState = s;
    switch (s.status) {
      case VpnStatus.connected:
        connectedAt ??= DateTime.now();
        if (prev != VpnStatus.connected) _startRuntime();
      case VpnStatus.stopped:
      case VpnStatus.error:
        if (!applying && disconnectAt != null) scheduleDisconnect(null);
        connectedAt = null;
        if (!applying) {
          needsReconnect = false;
          _applyTimer?.cancel();
          if (applyPhase == ApplyPhase.pending) applyPhase = ApplyPhase.idle;
        }
        _stopRuntime();
        if (s.status == VpnStatus.error && prev != VpnStatus.error &&
            s.message != null && s.message != 'permission' && prev != VpnStatus.connecting) {
          notice('notice.vpnError', kind: NoticeKind.error, detail: s.message);
        }
      case VpnStatus.connecting:
      case VpnStatus.stopping:
        break;
    }
    notifyListeners();
    if (prev != s.status) {
      for (final h in List.of(statusHooks)) {
        h(prev, s.status);
      }
    }
  }

  void _startRuntime() {
    final ep = _endpoints ?? (_lastSecret == null ? null : RuntimeEndpoints(secret: _lastSecret!));
    if (ep == null) return;
    clash?.close();
    engine?.close();
    clash = ClashApi(endpoint: ep.clashApi, secret: ep.secret);
    engine = EngineApi(endpoint: ep.engineApi, secret: ep.secret);
    traffic.start(clash!);
    latencies.removeWhere((_, l) => !l.viaUrl); // TCP pings are stale now
    gameLatencyHistory.clear();
    proxyLatencyHistory.clear();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _pollRuntime());
    _pollRuntime();
    unawaited(_pinManualSelection());
  }

  void _stopRuntime() {
    _poll?.cancel();
    _poll = null;
    traffic.stop(reset: true);
    engineGroups.clear();
    clash?.close();
    engine?.close();
    clash = null;
    engine = null;
  }

  Future<void> _pollRuntime() async {
    final e = engine;
    if (e != null) {
      try {
        final groups = await e.status();
        engineGroups
          ..clear()
          ..addEntries(groups.map((g) => MapEntry(g.selector, g)));
        _pushHistory(proxyLatencyHistory, proxyGroup?.currentStat?.latencyMs);
        if (gameGroup != null) {
          _pushHistory(gameLatencyHistory, gameGroup?.currentStat?.latencyMs);
        }
        notifyListeners();
      } catch (_) {}
    }
    final c = clash;
    if (c != null) {
      try {
        traffic.setTotals(await c.connections());
      } catch (_) {}
    }
  }

  void _pushHistory(List<int?> h, int? v) {
    h.add(v);
    if (h.length > 60) h.removeAt(0);
  }

  // ============================================================ utils

  static final _rng = Random.secure();
  static String _randomSecret() =>
      List.generate(16, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  static String _newId() =>
      List.generate(6, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  static String _short(Object e) {
    var s = e.toString();
    for (final p in ['Exception: ', 'FormatException: ', 'SocketException: ']) {
      if (s.startsWith(p)) s = s.substring(p.length);
    }
    return s.length > 400 ? '${s.substring(0, 400)}…' : s;
  }

  /// Platform helpers for the UI.
  bool get isDesktopPlatform => !isMobilePlatform;
  bool get isMobilePlatform => isAndroid || isIOS;
  bool get isIOS => platform == PlatformKind.ios;
  bool get isAndroid => platform == PlatformKind.android;
}
