import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// true: this executable owns the PID; false: absent or a different executable;
/// null: the OS query failed, so neither recovery nor killing is justified.
typedef DesktopProcessProbe = Future<bool?> Function(
  int pid,
  String executable,
);

Future<bool?> desktopProcessMatches(
  int processId,
  String executable, {
  Future<Process> Function(String, List<String>)? startQuery,
  bool? windows,
  String? linuxProcRoot,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final isWindows = windows ?? Platform.isWindows;
  if (processId <= 0) return false;
  String basename(String value) =>
      value.trim().replaceAll('\\', '/').split('/').last;
  final expected = basename(executable);
  if (expected.isEmpty) return null;
  if (!isWindows && (Platform.isLinux || linuxProcRoot != null)) {
    final directory = '${linuxProcRoot ?? '/proc'}/$processId';
    try {
      var image = await Link('$directory/exe').target();
      // The kernel keeps this suffix after an update replaces a running file.
      if (image.endsWith(' (deleted)')) {
        image = image.substring(0, image.length - 10);
      }
      return basename(image) == expected;
    } on FileSystemException catch (error) {
      // Missing exe alone can be a permissions/kernel-process issue. A live
      // PID without a readable executable must not authorize a replacement.
      if (error.osError?.errorCode == 2 && !await Directory(directory).exists()) {
        return false;
      }
      return null;
    }
  }
  Process? query;
  try {
    query = await (startQuery ?? Process.start)(
      isWindows ? 'tasklist' : 'ps',
      isWindows
          ? ['/FI', 'PID eq $processId', '/FO', 'CSV', '/NH']
          : ['-p', '$processId', '-o', 'comm='],
    );
    final values = await Future.wait<Object?>([
      query.exitCode,
      query.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
      query.stderr.drain<void>(),
    ]).timeout(timeout);
    final code = values[0] as int;
    final output = (values[1] as String).trim();
    if (!isWindows && code == 1 && output.isEmpty) return false;
    if (code != 0) return null;
    if (isWindows) {
      final rows = RegExp(
        r'^"([^"]+)","(\d+)"(?:,|$)',
        multiLine: true,
      ).allMatches(output);
      for (final row in rows) {
        if (int.tryParse(row[2]!) == processId) {
          if (row[1]!.contains('\uFFFD')) return null;
          return basename(row[1]!).toLowerCase() == expected.toLowerCase();
        }
      }
      return false;
    }
    return output.isNotEmpty && basename(output) == expected;
  } catch (_) {
    query?.kill();
    return null;
  }
}
