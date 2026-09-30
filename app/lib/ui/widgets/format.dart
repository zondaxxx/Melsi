String formatBytes(num bytes, {int decimals = 1}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final d = i == 0 || v >= 100 ? 0 : decimals;
  return '${v.toStringAsFixed(d)} ${units[i]}';
}

/// Bytes/s → "1.2 MB/s".
String formatSpeed(num bps) => '${formatBytes(bps)}/s';

/// Splits a speed into value + unit for typographic layouts.
(String, String) splitSpeed(num bps) {
  final s = formatBytes(bps).split(' ');
  return (s[0], '${s[1]}/s');
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  return '${two(h)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}
