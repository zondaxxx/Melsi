// Semantic versions, just enough to answer "is this release newer than the
// build I am?". Pure; no dependencies.

/// `1.2.3`, `v1.2.3`, `1.2` (patch 0), `1.2.3-beta.1` (pre-release sorts
/// below the release), `1.2.3+42` (build metadata ignored).
class Semver implements Comparable<Semver> {
  const Semver(this.major, this.minor, this.patch, {this.preRelease = const []});

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated pre-release identifiers; empty for a release.
  final List<String> preRelease;

  static final _core = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?$');

  /// null when [s] is not a version (an odd tag like `nightly`).
  static Semver? parse(String s) {
    var v = s.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    final plus = v.indexOf('+');
    if (plus >= 0) v = v.substring(0, plus);
    final dash = v.indexOf('-');
    final core = dash >= 0 ? v.substring(0, dash) : v;
    final pre = dash >= 0 ? v.substring(dash + 1) : '';
    final m = _core.firstMatch(core);
    if (m == null) return null;
    int part(String? x) => x == null ? 0 : int.parse(x);
    final ids = pre.isEmpty ? const <String>[] : pre.split('.');
    if (ids.any((id) => id.isEmpty)) return null;
    return Semver(part(m[1]), part(m[2]), part(m[3]), preRelease: ids);
  }

  bool get isPreRelease => preRelease.isNotEmpty;

  @override
  int compareTo(Semver other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    // A release outranks any pre-release of the same core.
    if (preRelease.isEmpty || other.preRelease.isEmpty) {
      return other.preRelease.length.compareTo(preRelease.length);
    }
    final n = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < n; i++) {
      final c = _compareId(preRelease[i], other.preRelease[i]);
      if (c != 0) return c;
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }

  /// SemVer §11: numeric identifiers compare numerically and rank below
  /// alphanumeric ones.
  static int _compareId(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }

  bool operator >(Semver other) => compareTo(other) > 0;
  bool operator <(Semver other) => compareTo(other) < 0;
  bool operator >=(Semver other) => compareTo(other) >= 0;
  bool operator <=(Semver other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) => other is Semver && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease.join('.'));

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease.isEmpty ? '' : '-${preRelease.join('.')}'}';
}

/// Shorthand for [Semver.parse].
Semver? parseSemver(String s) => Semver.parse(s);

/// True when [candidate] is a version strictly newer than [current]. Either
/// side failing to parse means "not newer" (never nag over a bad tag).
bool isNewerVersion(String candidate, String current) {
  final a = Semver.parse(candidate);
  final b = Semver.parse(current);
  return a != null && b != null && a > b;
}
