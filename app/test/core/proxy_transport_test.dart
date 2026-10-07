// Real payload through a local VLESS WebSocket server. No remote credentials,
// system proxy changes, TUN, or internet access are required.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/config_builder.dart';
import 'package:melsi/core/link_parser.dart';
import 'package:melsi/core/models.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  final binary = Platform.environment['MELSI_CORE_BIN'];
  for (final core in [VpnCore.singBox, VpnCore.mihomo, VpnCore.xray]) {
    test('iOS $core WS passes data with the saved multiplex toggle on', () async {
      final dir = await Directory.systemTemp.createTemp('melsi-ws-');
      addTearDown(() => dir.delete(recursive: true));
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.write('transport-ok');
        await request.response.close();
      });
      addTearDown(() => origin.close(force: true));
      final wsPort = await freePort();
      final mixedPort = await freePort();
      final apiPort = await freePort();
      const uuid = '00000000-0000-4000-8000-000000000001';
      final node = LinkParser.parseLink(
        'vless://$uuid@127.0.0.1:$wsPort?type=ws&path=%2Ftest&security=none#WS',
      )!;
      final built = ConfigBuilder.build(
        nodes: [node],
        selectedNodeId: node.id,
        routing: RoutingSettings(
          preset: RoutingPreset.global,
          bypassLan: false,
        ),
        game: GameSettings(),
        settings: AppSettings(core: core, multiplex: true, autoSelect: false),
        platform: PlatformKind.ios,
        endpoints: RuntimeEndpoints(
          clashApi: '127.0.0.1:$apiPort',
          secret: 'local-test',
        ),
        cacheDir: dir.path,
      );
      final config = jsonDecode(built.singBox) as Map<String, dynamic>;
      // The harness has no TUN/physical interface. Keep its deliberately
      // loopback-only proxy and origin sockets off the OS's default interface.
      config['route']['auto_detect_interface'] = false;
      config['inbounds'] = [
        {
          'type': 'mixed',
          'tag': 'test-client',
          'listen': '127.0.0.1',
          'listen_port': mixedPort,
        },
        {
          'type': 'vless',
          'tag': 'test-server',
          'listen': '127.0.0.1',
          'listen_port': wsPort,
          'users': [
            {'uuid': uuid},
          ],
          'transport': {'type': 'ws', 'path': '/test'},
        },
      ];
      (config['route']['rules'] as List).insert(0, {
        'inbound': ['test-server'],
        'outbound': 'direct',
      });
      final configFile = File('${dir.path}/config.json');
      final engineFile = File('${dir.path}/engine.json');
      await configFile.writeAsString(jsonEncode(config));
      await engineFile.writeAsString(
        jsonEncode({
          'clash_api': '127.0.0.1:$apiPort',
          'secret': 'local-test',
          'groups': [],
        }),
      );
      final process = await Process.start(binary!, [
        'run',
        '--config',
        configFile.path,
        '--engine',
        engineFile.path,
      ]);
      final output = StringBuffer();
      process.stdout.transform(utf8.decoder).listen(output.write);
      process.stderr.transform(utf8.decoder).listen(output.write);
      addTearDown(() async {
        process.kill();
        await process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      });
      final client = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
      addTearDown(() => client.close(force: true));
      Object? lastError;
      for (var attempt = 0; attempt < 30; attempt++) {
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          expect(await response.transform(utf8.decoder).join(), 'transport-ok');
          return;
        } catch (error) {
          lastError = error;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      fail('No proxy payload: $lastError\n$output');
    }, skip: binary == null ? 'MELSI_CORE_BIN not set' : false);
  }
}
