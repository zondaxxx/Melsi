import '../../l10n/l10n.dart';

const _unitsEn = ['B', 'KB', 'MB', 'GB', 'TB'];

List<String> _units(L10n? l) {
  if (l == null) return _unitsEn;
  final u = l('unit.bytes').split('|');
  return u.length == 5 ? u : _unitsEn;
}

/// Splits a byte count into a value and a localized unit ("1.2", "МБ").
(String, String) splitBytes(num bytes, {L10n? l, int decimals = 1}) {
  final units = _units(l);
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final d = i == 0 || v >= 100 ? 0 : decimals;
  return (v.toStringAsFixed(d), units[i]);
}

/// "40.4 ГБ" / "40.4 GB".
String formatBytes(num bytes, {L10n? l, int decimals = 1}) {
  final (v, u) = splitBytes(bytes, l: l, decimals: decimals);
  return '$v $u';
}

/// Bytes/s → "1.2 МБ/с" / "1.2 MB/s".
String formatSpeed(num bps, {L10n? l}) {
  final (v, u) = splitSpeed(bps, l: l);
  return '$v $u';
}

/// Splits a speed into value + unit for typographic layouts.
(String, String) splitSpeed(num bps, {L10n? l}) {
  final (v, u) = splitBytes(bps, l: l);
  return (v, '$u${l == null ? '/s' : l('unit.perSec')}');
}

/// "48 мс" / "48 ms"; "—" when unknown.
String formatMs(int? ms, L10n l) => ms == null ? '—' : l('unit.ms', {'n': '$ms'});

/// Packet loss fraction → "0.4%".
String formatLoss(double loss) =>
    '${(loss * 100).toStringAsFixed(loss < 0.1 ? 1 : 0)}%';

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  return '${two(h)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// "только что" / "4 мин назад" / "2 ч назад".
String formatAgo(L10n l, Duration d) {
  if (d.inSeconds < 60) return l('time.justNow');
  if (d.inMinutes < 60) return l('time.minAgo', {'n': '${d.inMinutes}'});
  if (d.inHours < 48) return l('time.hAgo', {'n': '${d.inHours}'});
  return l('time.dAgo', {'n': '${d.inDays}'});
}
