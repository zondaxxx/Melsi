import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/clash_api.dart';
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

void main() {
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
}
