import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/models.dart';
import 'package:melsi/services/clash_api.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/services/vpn_controller.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/store.dart';

import '../ui/fakes.dart' show FakeApps, kSampleVless;

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

class _AttachStore extends MemoryStateStore {
  _AttachStore(super.data);
  final building = Completer<void>();
  final release = Completer<void>();
  var calls = 0;

  @override
  Future<String> cacheDir() async {
    // First call prepares bundled rules, second belongs to the old attach.
    if (++calls == 2) {
      building.complete();
      await release.future;
    }
    return super.cacheDir();
  }
}

class _Vpn extends VpnController {
  final events = StreamController<VpnState>.broadcast(sync: true);
  VpnState state = VpnState.stopped;
  Future<BuiltConfig> Function()? rebuild;
  Completer<VpnState>? pendingState;
  Completer<bool>? permission;
  BuiltConfig? config;
  int starts = 0;
  bool emitOnCurrentState = false;

  void emit(VpnState next) {
    state = next;
    events.add(next);
  }

  @override
  Stream<VpnState> get states => events.stream;
  @override
  void setRecoveryConfigProvider(Future<BuiltConfig> Function() provider) =>
      rebuild = provider;
  @override
  Future<bool> prepare() async =>
      permission == null ? true : await permission!.future;
  @override
  Future<VpnState> currentState() async {
    if (emitOnCurrentState) emit(state);
    return pendingState == null ? state : await pendingState!.future;
  }

  @override
  Future<void> start(BuiltConfig cfg, {required String name}) async {
    starts++;
    config = cfg;
    emit(const VpnState(VpnStatus.connected));
  }

  @override
  Future<void> stop() async => emit(VpnState.stopped);
  @override
  void dispose() => unawaited(events.close());
}

class _Engine extends Fake implements EngineApi {
  _Engine(this.session, this.secret);
  final int session;
  @override
  final String secret;
  int statusCalls = 0;
  final selections = <String>[];
  Completer<List<GroupStatus>>? pendingStatus;
  Completer<GroupStatus>? pendingProbe;
  Completer<GroupStatus>? pendingAuto;
  GroupStatus group([String? tag]) =>
      GroupStatus(selector: 'proxy', current: tag ?? 'session-$session');
  @override
  Future<List<GroupStatus>> status() async {
    statusCalls++;
    return pendingStatus == null ? [group()] : await pendingStatus!.future;
  }

  @override
  Future<GroupStatus> probe(String selector) async =>
      await pendingProbe!.future;
  @override
  Future<GroupStatus> setAuto(String selector, bool auto) async =>
      pendingAuto == null ? group() : await pendingAuto!.future;
  @override
  Future<GroupStatus> select(String selector, String tag) async {
    selections.add(tag);
    return group(tag);
  }

  @override
  void close() {}
}

class _Clash extends Fake implements ClashApi {
  _Clash(this.session);
  final int session;
  int totalCalls = 0;
  int closedConnections = 0;
  int delayCalls = 0;
  Completer<int?>? pendingDelay;
  Completer<ConnectionsSnapshot>? pendingTotals;
  @override
  Stream<TrafficSample> traffic() => const Stream.empty();
  @override
  Future<ConnectionsSnapshot> connections() async {
    totalCalls++;
    return pendingTotals == null
        ? ConnectionsSnapshot(
            uploadTotal: session * 100,
            downloadTotal: session * 1000,
            count: session,
          )
        : await pendingTotals!.future;
  }

  @override
  Future<void> closeAllConnections() async {
    closedConnections++;
  }

  @override
  Future<int?> delay(
    String name, {
    required String url,
    int timeoutMs = 5000,
  }) async {
    delayCalls++;
    return pendingDelay == null ? 42 : await pendingDelay!.future;
  }

  @override
  void close() {}
}

class _Harness {
  final vpn = _Vpn();
  final engines = <_Engine>[];
  final clashes = <_Clash>[];
  late AppState state;

  Future<void> open({
    void Function(_Engine)? engineSetup,
    void Function(_Clash)? clashSetup,
    Future<int?> Function(String, int)? tcpProbe,
  }) async {
    state = AppState(
      store: MemoryStateStore(),
      vpn: vpn,
      apps: FakeApps(),
      platform: PlatformKind.windows,
      enableNetwork: false,
      tcpProbe: tcpProbe,
      engineFactory: (ep) {
        final e = _Engine(engines.length + 1, ep.secret);
        engines.add(e);
        engineSetup?.call(e);
        return e;
      },
      clashFactory: (_) {
        final c = _Clash(clashes.length + 1);
        clashes.add(c);
        clashSetup?.call(c);
        return c;
      },
    );
    await state.load();
    await state.importText(kSampleVless);
    await state.importText(
      kSampleVless
          .replaceAll('nl1.example.com', 'de1.example.com')
          .replaceAll('Netherlands', 'Germany'),
    );
    await state.connect();
    await settle();
  }

  Future<void> reconnect() async {
    await state.disconnect();
    await state.connect();
    await settle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_Harness> harness({
    void Function(_Engine)? engineSetup,
    void Function(_Clash)? clashSetup,
    Future<int?> Function(String, int)? tcpProbe,
  }) async {
    final h = _Harness();
    await h.open(
      engineSetup: engineSetup,
      clashSetup: clashSetup,
      tcpProbe: tcpProbe,
    );
    addTearDown(h.state.dispose);
    return h;
  }

  test(
    'late engine status cannot replace a newer runtime or fetch its totals',
    () async {
      final pending = Completer<List<GroupStatus>>();
      final h = await harness(
        engineSetup: (e) {
          if (e.session == 1) e.pendingStatus = pending;
        },
      );
      expect(h.engines.first.statusCalls, 1);
      await h.reconnect();
      expect(h.state.proxyGroup?.current, 'session-2');
      pending.complete([h.engines.first.group('obsolete')]);
      await settle();
      expect(h.state.proxyGroup?.current, 'session-2');
      expect(h.clashes.first.totalCalls, 0);
      expect(h.state.traffic.downTotal, 2000);
    },
  );

  test(
    'late attach build cannot replace a new connection config or credentials',
    () async {
      final store = _AttachStore({
        'lastSecret': 'old-attachment-secret',
        'nodes': [LinkParser.parseLink(kSampleVless)!.toJson()],
      });
      final vpn = _Vpn()..state = const VpnState(VpnStatus.connected);
      final state = AppState(
        store: store,
        vpn: vpn,
        apps: FakeApps(),
        enableNetwork: false,
        platform: PlatformKind.windows,
        engineFactory: (ep) => _Engine(1, ep.secret),
        clashFactory: (_) => _Clash(1),
      );
      addTearDown(state.dispose);
      await state.load();
      await store.building.future;
      await state.connect();
      final started = state.lastBuilt;
      final secret = (jsonDecode(started!.engine) as Map)['secret'];
      expect(secret, isNot('old-attachment-secret'));
      store.release.complete();
      await settle();
      expect(state.lastBuilt, same(started));
      expect(state.engine!.secret, secret);
      expect(
        (jsonDecode((await vpn.rebuild!()).engine) as Map)['secret'],
        secret,
      );
    },
  );

  test(
    'attach accepts the connected event emitted by currentState itself',
    () async {
      final vpn = _Vpn()
        ..state = const VpnState(VpnStatus.connected)
        ..emitOnCurrentState = true;
      final state = AppState(
        store: MemoryStateStore({
          'lastSecret': 'attached-secret',
          'nodes': [LinkParser.parseLink(kSampleVless)!.toJson()],
        }),
        vpn: vpn,
        apps: FakeApps(),
        enableNetwork: false,
        platform: PlatformKind.windows,
        engineFactory: (ep) => _Engine(1, ep.secret),
        clashFactory: (_) => _Clash(1),
      );
      addTearDown(state.dispose);
      await state.load();
      await settle();
      expect(state.connected, isTrue);
      expect(state.lastBuilt, isNotNull);
      expect(
        (jsonDecode((await vpn.rebuild!()).engine) as Map)['secret'],
        'attached-secret',
      );
    },
  );

  for (final next in const [
    VpnState(VpnStatus.connecting, 'reconnecting'),
    VpnState(VpnStatus.error, 'recovery exhausted'),
  ]) {
    test(
      'late attach build cannot overwrite ${next.status.name} event',
      () async {
        final store = _AttachStore({
          'lastSecret': 'attachment-secret',
          'nodes': [LinkParser.parseLink(kSampleVless)!.toJson()],
        });
        final vpn = _Vpn()..state = const VpnState(VpnStatus.connected);
        final state = AppState(
          store: store,
          vpn: vpn,
          apps: FakeApps(),
          enableNetwork: false,
          platform: PlatformKind.windows,
          engineFactory: (ep) => _Engine(1, ep.secret),
          clashFactory: (_) => _Clash(1),
        );
        addTearDown(state.dispose);
        await state.load();
        await store.building.future;
        vpn.emit(next);
        store.release.complete();
        await settle();
        expect(state.vpnState.status, next.status);
        expect(state.vpnState.message, next.message);
        expect(state.engine, isNull);
        expect(state.lastBuilt, isNull);
      },
    );
  }

  test(
    'late connection totals cannot restore counters from the previous session',
    () async {
      final pending = Completer<ConnectionsSnapshot>();
      final h = await harness(
        clashSetup: (c) {
          if (c.session == 1) c.pendingTotals = pending;
        },
      );
      expect(h.clashes.first.totalCalls, 1);
      await h.reconnect();
      pending.complete(
        ConnectionsSnapshot(uploadTotal: 999, downloadTotal: 999, count: 99),
      );
      await settle();
      expect(h.state.traffic.downTotal, 2000);
      expect(h.state.traffic.connections, 2);
    },
  );

  test('late probe cannot overwrite a recovered runtime', () async {
    final h = await harness();
    final pending = h.engines.first.pendingProbe = Completer<GroupStatus>();
    final probing = h.state.probeNow();
    await h.reconnect();
    pending.complete(h.engines.first.group('obsolete'));
    await probing;
    expect(h.state.proxyGroup?.current, 'session-2');
  });

  test('late probe cannot overwrite a newer manual server choice', () async {
    final h = await harness();
    final pending = h.engines.single.pendingProbe = Completer<GroupStatus>();
    final probing = h.state.probeNow();
    final selected = h.state.nodes.last;
    await h.state.selectNode(selected.id);
    pending.complete(h.engines.single.group('obsolete'));
    await probing;
    expect(h.state.proxyGroup?.current, h.state.tagOf(selected.id));
  });

  test('manual selection resumed after reconnect does not issue an obsolete select', () async {
    final h = await harness();
    final old = h.engines.single;
    final pending = old.pendingAuto = Completer<GroupStatus>();
    final selecting = h.state.selectNode(h.state.nodes.last.id);
    await settle();
    await h.reconnect();
    pending.complete(old.group());
    await selecting;
    expect(old.selections, isEmpty);
    expect(h.clashes.first.closedConnections, 0);
    expect(h.state.proxyGroup?.current, 'session-2');
    expect(h.state.needsReconnect, isFalse);
  });

  test(
    'late resume result cannot revive a tunnel after explicit disconnect',
    () async {
      final h = await harness();
      final pending = h.vpn.pendingState = Completer<VpnState>();
      h.state.onResume();
      await h.state.disconnect();
      pending.complete(const VpnState(VpnStatus.connected));
      await settle();
      expect(h.state.vpnState.status, VpnStatus.stopped);
      expect(h.state.engine, isNull);
      expect(h.vpn.starts, 1);
    },
  );

  test(
    'resume retains recovery progress and surfaces its final error',
    () async {
      final h = await harness();
      h.vpn.state = const VpnState(VpnStatus.connecting, 'reconnecting');
      h.state.onResume();
      await settle();
      expect(h.state.vpnState.message, 'reconnecting');
      expect(h.state.engine, isNull);
      final notices = <Notice>[];
      final subscription = h.state.notices.listen(notices.add);
      addTearDown(subscription.cancel);
      h.vpn.state = const VpnState(VpnStatus.error, 'recovery exhausted');
      h.state.onResume();
      await settle();
      expect(h.state.vpnState.status, VpnStatus.error);
      expect(notices.single.key, 'notice.vpnError');
    },
  );

  test(
    'recovery rebuild uses latest manual choice with the same credentials',
    () async {
      final h = await harness();
      final before = jsonDecode(h.vpn.config!.engine) as Map;
      h.vpn.emit(const VpnState(VpnStatus.connecting, 'reconnecting'));
      final selected = h.state.nodes.last;
      await h.state.selectNode(selected.id);
      final rebuilt = await h.vpn.rebuild!();
      final after = jsonDecode(rebuilt.engine) as Map;
      final sing = jsonDecode(rebuilt.singBox) as Map;
      final proxy = (sing['outbounds'] as List).cast<Map>().firstWhere(
        (e) => e['tag'] == 'proxy',
      );
      expect(after['secret'], before['secret']);
      expect(after['control_listen'], before['control_listen']);
      expect(proxy['default'], rebuilt.nodeTags[selected.id]);
      expect(h.state.selectedNodeId, selected.id);
      expect(h.state.settings.autoSelect, isFalse);
    },
  );

  test('failed URL probe does not initiate a VPN restart', () async {
    final h = await harness();
    final pending = h.engines.single.pendingProbe = Completer<GroupStatus>();
    final probing = h.state.probeNow();
    pending.completeError(StateError('URL is unreachable'));
    await probing;
    expect(h.state.connected, isTrue);
    expect(h.vpn.starts, 1);
  });

  test(
    'connected latency prefers engine data and never falls back to TCP',
    () async {
      final h = await harness();
      final node = h.state.nodes.first;
      h.state.latencies[node.id] = Latency(
        2,
        viaUrl: false,
        at: DateTime.now(),
      );
      expect(h.state.latencyOf(node), isNull);
      h.state.engineGroups['proxy'] = GroupStatus(
        selector: 'proxy',
        nodes: [
          NodeStat(tag: h.state.tagOf(node.id)!, latencyMs: 80, alive: true),
        ],
      );
      expect(h.state.latencyOf(node), 80);
      h.state.latencies[node.id] = Latency(3, viaUrl: true, at: DateTime.now());
      expect(h.state.latencyOf(node), 80);
      await h.state.disconnect();
      expect(h.state.latencies, isEmpty);
      h.state.latencies[node.id] = Latency(3, viaUrl: true, at: DateTime.now());
      expect(h.state.latencyOf(node), isNull);
      h.state.latencies[node.id] = Latency(
        4,
        viaUrl: false,
        at: DateTime.now(),
      );
      expect(h.state.latencyOf(node), 4);
    },
  );

  test('late TCP ping cannot publish into a connected session', () async {
    final pending = Completer<int?>();
    final h = await harness(tcpProbe: (_, _) => pending.future);
    await h.state.disconnect();
    final ping = h.state.pingNode(h.state.nodes.first.id);
    expect(h.state.pinging, isNotEmpty);
    await h.state.connect();
    pending.complete(7);
    await ping;
    expect(h.state.latencies, isEmpty);
    expect(h.state.pinging, isEmpty);
  });

  test('late URL ping cannot publish into a replacement session', () async {
    final h = await harness();
    final pending = h.clashes.single.pendingDelay = Completer<int?>();
    final ping = h.state.pingNode(h.state.nodes.first.id);
    await h.reconnect();
    pending.complete(7);
    await ping;
    expect(h.state.latencies, isEmpty);
    expect(h.state.pinging, isEmpty);
  });

  test(
    'queued pingAll workers cannot start against a replacement client',
    () async {
      final h = await harness();
      for (var i = 0; i < 9; i++) {
        await h.state.importText(
          kSampleVless.replaceAll('nl1.example.com', 'nl$i.example.net'),
        );
      }
      final old = h.clashes.single;
      final pending = old.pendingDelay = Completer<int?>();
      // Rebuild once so the starting session has tags for every candidate.
      await h.reconnect();
      final active = h.clashes.last;
      active.pendingDelay = pending;
      final ping = h.state.pingAll();
      expect(active.delayCalls, 8);
      await h.reconnect();
      pending.complete(7);
      await ping;
      expect(active.delayCalls, 8);
      expect(h.clashes.last.delayCalls, 0);
      expect(h.state.latencies, isEmpty);
      expect(h.state.pingingAll, isFalse);
    },
  );

  test(
    'a ping completing after disposal cannot notify or publish a result',
    () async {
      final h = _Harness();
      await h.open();
      final pending = h.clashes.single.pendingDelay = Completer<int?>();
      final ping = h.state.pingNode(h.state.nodes.first.id);
      h.state.dispose();
      pending.complete(7);
      await ping;
      expect(h.state.latencies, isEmpty);
    },
  );

  test(
    'disposing during permission preparation cannot start a late daemon',
    () async {
      final h = _Harness();
      await h.open();
      await h.state.disconnect();
      final permission = h.vpn.permission = Completer<bool>();
      final connecting = h.state.connect();
      h.state.dispose();
      permission.complete(true);
      await connecting;
      expect(h.vpn.starts, 1);
    },
  );
}
