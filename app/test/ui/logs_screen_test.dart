import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/clash_api.dart';
import 'package:melsi/services/engine_api.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/store.dart';
import 'package:melsi/ui/screens/logs_screen.dart';
import 'package:melsi/ui/theme/theme.dart';

import 'fakes.dart';

class SavedLogVpn extends FakeVpn {
  final saved = Completer<String?>();

  @override
  Future<String?> readLog({int maxLines = 400}) => saved.future;
}

class LiveLogApi extends ClashApi {
  LiveLogApi() : super(endpoint: '127.0.0.1:1', secret: 'test');
  final events = StreamController<ClashLogLine>();

  @override
  Stream<ClashLogLine> logs({String level = 'info'}) => events.stream;
}

class ProbeLogState extends AppState {
  ProbeLogState(FakeVpn vpn)
    : super(store: MemoryStateStore(), vpn: vpn, enableNetwork: false);

  bool get observed => hasListeners;

  void report(List<GroupStatus> groups) {
    engineGroups
      ..clear()
      ..addEntries(groups.map((group) => MapEntry(group.selector, group)));
    notifyListeners();
  }
}

GroupStatus probeGroup(
  String? error, {
  String selector = 'proxy',
  String tag = 'node-a',
}) => GroupStatus(
  selector: selector,
  current: tag,
  nodes: [
    NodeStat(tag: tag, lastError: error, loss: error == null ? 0 : 1),
    NodeStat(tag: 'unselected', lastError: 'Unselected node failed'),
  ],
);

Widget logApp(AppState state) => MaterialApp(
  theme: buildTheme(Brightness.dark),
  home: LogsScreen(state: state),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<List<String>> copyLines(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    return copied!.split('\n').where((line) => line.isNotEmpty).toList();
  }

  testWidgets('saved stop diagnostics survive a live event arriving first', (
    tester,
  ) async {
    final vpn = SavedLogVpn();
    final api = LiveLogApi();
    final state = testState(vpn: vpn)..clash = api;
    // Dispose async stream/client resources outside the widget fake-async zone.
    addTearDown(state.dispose);
    addTearDown(api.events.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: LogsScreen(state: state),
      ),
    );
    api.events.add(
      ClashLogLine('info', 'Live connection restored', DateTime.now()),
    );
    await tester.pump();
    expect(find.text('Live connection restored'), findsOneWidget);
    expect(find.text('Previous tunnel stopped: provider failed'), findsNothing);
    vpn.saved.complete('Previous tunnel stopped: provider failed');
    await tester.pump();
    expect(find.text('Live connection restored'), findsOneWidget);
    expect(
      find.text('Previous tunnel stopped: provider failed'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'selected probe errors are copied once and recur after recovery',
    (tester) async {
      final state = ProbeLogState(SavedLogVpn());
      addTearDown(state.dispose);
      state.report([
        probeGroup('REALITY authentication failed'),
        probeGroup('DNS timeout', selector: 'game', tag: 'node-b'),
      ]);
      await tester.pumpWidget(logApp(state));
      const proxyLine =
          '[probe] selector=proxy node=node-a: REALITY authentication failed';
      const gameLine = '[probe] selector=game node=node-b: DNS timeout';
      expect(find.text(proxyLine), findsOneWidget);
      expect(find.text(gameLine), findsOneWidget);
      expect(find.textContaining('Unselected node failed'), findsNothing);
      for (var poll = 0; poll < 3; poll++) {
        state.report([
          probeGroup('REALITY authentication failed'),
          probeGroup('DNS timeout', selector: 'game', tag: 'node-b'),
        ]);
      }
      expect(await copyLines(tester), [proxyLine, gameLine]);
      state.report([probeGroup('Connection refused')]);
      state.report([probeGroup(null)]);
      state.report([probeGroup('REALITY authentication failed')]);
      await tester.pump();
      expect(await copyLines(tester), [
        proxyLine,
        gameLine,
        '[probe] selector=proxy node=node-a: Connection refused',
        proxyLine,
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pause, resume and clear preserve probe deduplication', (
    tester,
  ) async {
    final state = ProbeLogState(SavedLogVpn());
    addTearDown(state.dispose);
    state.report([probeGroup('First failure')]);
    await tester.pumpWidget(logApp(state));
    await tester.tap(find.byIcon(Icons.pause_rounded));
    state.report([probeGroup('Latest failure')]);
    await tester.pump();
    expect(find.textContaining('Latest failure'), findsNothing);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(find.textContaining('Latest failure'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pump();
    state.report([probeGroup('Latest failure')]);
    expect(await copyLines(tester), isEmpty);
    state.report([probeGroup(null)]);
    state.report([probeGroup('Latest failure')]);
    await tester.pump();
    expect(await copyLines(tester), [
      '[probe] selector=proxy node=node-a: Latest failure',
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('file history polling retains selected probe diagnostics', (
    tester,
  ) async {
    final vpn = SavedLogVpn();
    final state = ProbeLogState(vpn);
    addTearDown(state.dispose);
    state.report([probeGroup('TLS handshake failed')]);
    await tester.pumpWidget(logApp(state));
    vpn.saved.complete('INFO Saved tunnel diagnostics');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(await copyLines(tester), [
      'INFO Saved tunnel diagnostics',
      '[probe] selector=proxy node=node-a: TLS handshake failed',
    ]);
    state.report([probeGroup('DNS timeout')]);
    await tester.pump(const Duration(seconds: 2));
    expect(await copyLines(tester), [
      'INFO Saved tunnel diagnostics',
      '[probe] selector=proxy node=node-a: TLS handshake failed',
      '[probe] selector=proxy node=node-a: DNS timeout',
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('probe history is bounded and records a new selected node', (
    tester,
  ) async {
    final state = ProbeLogState(SavedLogVpn());
    addTearDown(state.dispose);
    await tester.pumpWidget(logApp(state));
    for (var index = 0; index < 205; index++) {
      state.report([probeGroup('Failure $index')]);
    }
    state.report([probeGroup('Failure 204', tag: 'node-b')]);
    await tester.pump();
    final lines = await copyLines(tester);
    expect(lines, hasLength(200));
    expect(lines.first, '[probe] selector=proxy node=node-a: Failure 6');
    expect(lines.last, '[probe] selector=proxy node=node-b: Failure 204');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('probe state listener is removed on dispose', (tester) async {
    final state = ProbeLogState(SavedLogVpn());
    addTearDown(state.dispose);
    expect(state.observed, isFalse);
    await tester.pumpWidget(logApp(state));
    expect(state.observed, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(state.observed, isFalse);
    state.report([probeGroup('After disposal')]);
    expect(tester.takeException(), isNull);
  });
}
