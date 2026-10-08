import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/mobile_vpn_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.melsi/vpn');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads saved tunnel diagnostics with a bounded line count', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'Last tunnel event: stopped';
    });
    final vpn = MobileVpnController(channel: channel);
    expect(await vpn.readLog(maxLines: 9999), 'Last tunnel event: stopped');
    expect(calls.single.method, 'readLog');
    expect(calls.single.arguments, {'maxLines': 400});
    await vpn.readLog(maxLines: 0);
    expect(calls.last.arguments, {'maxLines': 1});
  });

  test(
    'older native bridges without saved diagnostics remain supported',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw MissingPluginException(),
      );
      expect(await MobileVpnController(channel: channel).readLog(), isNull);
    },
  );
}
