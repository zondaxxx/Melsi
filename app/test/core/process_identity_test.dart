import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/services/process_identity.dart';

class _Query extends Fake implements Process {
  _Query(this.bytes, {this.code = 0, this.hung = false});
  final List<int> bytes;
  final int code;
  final bool hung;
  final done = Completer<int>();
  bool killed = false;
  @override
  Stream<List<int>> get stdout => Stream.value(bytes);
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => hung ? done.future : Future.value(code);
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!done.isCompleted) done.complete(-1);
    return true;
  }
}

void main() {
  test(
    'Linux executable lookup preserves long image names and unknown live PIDs',
    () async {
      final proc = await Directory.systemTemp.createTemp('melsi-proc-test-');
      addTearDown(() => proc.delete(recursive: true));
      final entry = await Directory('${proc.path}/421').create();
      // Windows symlink creation can require developer mode. Its native query
      // path is covered below and does not use /proc.
      if (!Platform.isWindows) {
        await Link('${entry.path}/exe')
            .create('/opt/melsi/melsi-core-linux-amd64');
        expect(
          await desktopProcessMatches(
            421,
            '/opt/melsi/melsi-core-linux-amd64',
            windows: false,
            linuxProcRoot: proc.path,
          ),
          isTrue,
        );
        expect(
          await desktopProcessMatches(
            421,
            'different-core',
            windows: false,
            linuxProcRoot: proc.path,
          ),
          isFalse,
        );
        await Link('${entry.path}/exe').delete();
        expect(
          await desktopProcessMatches(
            421,
            'melsi-core-linux-amd64',
            windows: false,
            linuxProcRoot: proc.path,
          ),
          isNull,
        );
        await entry.delete();
        expect(
          await desktopProcessMatches(
            421,
            'melsi-core-linux-amd64',
            windows: false,
            linuxProcRoot: proc.path,
          ),
          isFalse,
        );
      }
    },
  );
  test('OS query identifies the running test process and rejects a different image', () async {
    expect(
      await desktopProcessMatches(pid, Platform.resolvedExecutable),
      isTrue,
    );
    expect(
      await desktopProcessMatches(pid, 'unrelated-melsi-test-process.exe'),
      isFalse,
    );
  });

  test(
    'Windows OEM session bytes do not obscure ASCII executable and PID',
    () async {
      final query = _Query([
        ...ascii.encode('"xray.exe","421","'),
        0x91,
        0xa5,
        0xa0,
        0xad,
        0xe1,
        ...ascii.encode('","1","10 K"\r\n'),
      ]);
      final result = await desktopProcessMatches(
        421,
        r'C:\Melsi\XRAY.EXE',
        windows: true,
        startQuery: (command, args) async {
          expect(command, 'tasklist');
          expect(args, ['/FI', 'PID eq 421', '/FO', 'CSV', '/NH']);
          return query;
        },
      );
      expect(result, isTrue);
      expect(query.killed, isFalse);
    },
  );

  test(
    'a reused Windows PID owned by another executable is not Xray',
    () async {
      final query = _Query(
        ascii.encode('"other.exe","421","Console","1","10 K"'),
      );
      expect(
        await desktopProcessMatches(
          421,
          'xray.exe',
          windows: true,
          startQuery: (_, _) async => query,
        ),
        isFalse,
      );
    },
  );

  test(
    'failed OS query is unknown rather than a proven process death',
    () async {
      final query = _Query(ascii.encode('Access denied'), code: 1);
      expect(
        await desktopProcessMatches(
          421,
          'xray.exe',
          windows: true,
          startQuery: (_, _) async => query,
        ),
        isNull,
      );
    },
  );

  test(
    'a query timeout kills only its own query and returns unknown',
    () async {
      final query = _Query([], hung: true);
      expect(
        await desktopProcessMatches(
          421,
          'xray.exe',
          windows: true,
          timeout: const Duration(milliseconds: 20),
          startQuery: (_, _) async => query,
        ),
        isNull,
      );
      expect(query.killed, isTrue);
    },
  );
}
