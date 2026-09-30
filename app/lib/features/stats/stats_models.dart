// Data of the stats feature: one record per tunnel session and per-day
// totals. Instants are stored as epoch milliseconds so the JSON is
// timezone-free; days are keyed by the *local* calendar date the user sees
// ("2026-10-01"), because "today" on the Home card means the user's today.

/// One tunnel session: when it ran, through which server (a snapshot — the
/// node may be deleted later), how many bytes it moved and how often the
/// engine switched servers underneath it. [end] is null while the session
/// is still running.
class SessionRecord {
  SessionRecord({
    required this.id,
    required this.start,
    required this.nodeName,
    this.end,
    this.nodeId,
    this.countryCode,
    this.up = 0,
    this.down = 0,
    this.switches = 0,
  });

  final String id;
  final DateTime start;
  DateTime? end;
  String? nodeId;
  String nodeName;
  String? countryCode;
  int up;
  int down;
  int switches;

  bool get isOpen => end == null;

  /// Length of the session; an open one is measured up to [now].
  Duration durationAt(DateTime now) => (end ?? now).difference(start);

  /// Length of a closed session (null while it runs).
  Duration? get duration => end?.difference(start);

  int get total => up + down;

  /// The same record closed at [at] (for checkpoints of a running session).
  SessionRecord closedAt(DateTime at) => SessionRecord(
        id: id,
        start: start,
        end: at,
        nodeId: nodeId,
        nodeName: nodeName,
        countryCode: countryCode,
        up: up,
        down: down,
        switches: switches,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': start.millisecondsSinceEpoch,
        if (end != null) 'end': end!.millisecondsSinceEpoch,
        if (nodeId != null) 'nodeId': nodeId,
        'nodeName': nodeName,
        if (countryCode != null) 'countryCode': countryCode,
        'up': up,
        'down': down,
        'switches': switches,
      };

  /// null for a record that cannot be read (a foreign or corrupt entry).
  static SessionRecord? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final start = j['start'];
    if (id is! String || id.isEmpty || start is! num) return null;
    final end = j['end'];
    return SessionRecord(
      id: id,
      start: DateTime.fromMillisecondsSinceEpoch(start.toInt()),
      end: end is num ? DateTime.fromMillisecondsSinceEpoch(end.toInt()) : null,
      nodeId: j['nodeId'] as String?,
      nodeName: j['nodeName'] as String? ?? '',
      countryCode: j['countryCode'] as String?,
      up: _int(j['up']),
      down: _int(j['down']),
      switches: _int(j['switches']),
    );
  }
}

/// Bytes and connected seconds of one local calendar day.
class DayTotal {
  const DayTotal({required this.day, this.up = 0, this.down = 0, this.seconds = 0});

  /// "yyyy-mm-dd" in local time.
  final String day;
  final int up;
  final int down;
  final int seconds;

  bool get isEmpty => up == 0 && down == 0 && seconds == 0;
  int get total => up + down;

  /// Local midnight of [day].
  DateTime get date => dateOf(day);

  /// Key of the local calendar day [t] falls on.
  static String keyOf(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  /// Local midnight of a "yyyy-mm-dd" key (today's for a malformed one).
  static DateTime dateOf(String key) {
    final p = key.split('-');
    if (p.length == 3) {
      final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
      if (y != null && m != null && d != null) return DateTime(y, m, d);
    }
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// This day with [up]/[down]/[seconds] added (negative values subtract;
  /// nothing goes below zero).
  DayTotal plus({int up = 0, int down = 0, int seconds = 0}) => DayTotal(
        day: day,
        up: _nonNegative(this.up + up),
        down: _nonNegative(this.down + down),
        seconds: _nonNegative(this.seconds + seconds),
      );

  Map<String, dynamic> toJson() => {'day': day, 'up': up, 'down': down, 'seconds': seconds};

  static DayTotal? fromJson(Map<String, dynamic> j) {
    final day = j['day'];
    if (day is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) return null;
    return DayTotal(day: day, up: _int(j['up']), down: _int(j['down']), seconds: _int(j['seconds']));
  }

  @override
  bool operator ==(Object other) =>
      other is DayTotal &&
      other.day == day &&
      other.up == up &&
      other.down == down &&
      other.seconds == seconds;

  @override
  int get hashCode => Object.hash(day, up, down, seconds);

  @override
  String toString() => 'DayTotal($day ↑$up ↓$down ${seconds}s)';
}

int _int(Object? v) => v is num ? (v.isFinite ? v.toInt() : 0) : 0;
int _nonNegative(int v) => v < 0 ? 0 : v;
