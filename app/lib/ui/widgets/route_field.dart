import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/vpn_controller.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';

/// Home status map: Natural Earth country borders, painted locally.
/// Ocean is the page colour. One route runs from the real-IP country to the
/// selected server when both are known.
class RouteField extends StatelessWidget {
  const RouteField({
    super.key,
    required this.status,
    this.originCode,
    this.exitCode,
    this.height = 196,
  });

  final VpnStatus status;
  final String? originCode;
  final String? exitCode;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final route = switch (status) {
      VpnStatus.connected => c.success,
      VpnStatus.connecting || VpnStatus.stopping => c.warning,
      VpnStatus.error => c.danger,
      VpnStatus.stopped => c.secondaryLabel,
    };
    return Panel(
      padding: EdgeInsets.zero,
      clip: true,
      color: c.background,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: FutureBuilder<WorldMapData>(
          future: WorldMapData.load(),
          builder: (context, snap) => CustomPaint(
            painter: _MapPainter(
              map: snap.data,
              land: c.isDark ? const Color(0xFF141414) : const Color(0xFFFFFFFF),
              border: c.label.withValues(alpha: c.isDark ? 0.22 : 0.35),
              ink: c.label,
              route: route,
              originCode: _code(originCode),
              exitCode: _code(exitCode),
            ),
          ),
        ),
      ),
    );
  }
}

String? _code(String? raw) {
  final cc = raw?.trim().toUpperCase();
  if (cc == null || cc.length != 2) return null;
  return cc == 'UK' ? 'GB' : cc;
}

/// Parsed country outlines. Loaded once from the bundled asset.
class WorldMapData {
  WorldMapData(this.countries) : byCode = {
          for (final c in countries)
            if (c.code.isNotEmpty) c.code: c,
        };

  static const asset = 'assets/map/countries.json';

  /// Visible window. Drops the polar stretch so the inhabited world fills
  /// the short home panel.
  static const double minLat = -56;
  static const double maxLat = 78;

  final List<MapCountry> countries;
  final Map<String, MapCountry> byCode;

  static Future<WorldMapData>? _future;

  static Future<WorldMapData> load() => _future ??= _read();

  static Future<WorldMapData> _read() async {
    final raw = await rootBundle.loadString(asset);
    final root = jsonDecode(raw) as Map<String, dynamic>;
    final list = root['c'] as List;
    final countries = <MapCountry>[];
    for (final item in list) {
      final m = item as Map<String, dynamic>;
      final anchor = m['a'] as List;
      final rings = <List<(double, double)>>[];
      for (final ring in m['r'] as List) {
        final pts = <(double, double)>[];
        for (final pt in ring as List) {
          final pair = pt as List;
          pts.add(((pair[0] as num).toDouble(), (pair[1] as num).toDouble()));
        }
        if (pts.length >= 4) rings.add(pts);
      }
      if (rings.isEmpty) continue;
      countries.add(MapCountry(
        code: m['i'] as String? ?? '',
        lon: (anchor[0] as num).toDouble(),
        lat: (anchor[1] as num).toDouble(),
        rings: rings,
      ));
    }
    return WorldMapData(countries);
  }

  static double xOf(double lon) => (lon + 180) / 360;

  static double yOf(double lat) {
    final clamped = lat.clamp(minLat, maxLat);
    double merc(double deg) {
      final r = deg * math.pi / 180;
      return math.log(math.tan(math.pi / 4 + r / 2));
    }

    final top = merc(maxLat);
    final bot = merc(minLat);
    return (top - merc(clamped)) / (top - bot);
  }
}

class MapCountry {
  const MapCountry({
    required this.code,
    required this.lon,
    required this.lat,
    required this.rings,
  });

  final String code;
  final double lon;
  final double lat;
  final List<List<(double, double)>> rings;
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.map,
    required this.land,
    required this.border,
    required this.ink,
    required this.route,
    required this.originCode,
    required this.exitCode,
  });

  final WorldMapData? map;
  final Color land;
  final Color border;
  final Color ink;
  final Color route;
  final String? originCode;
  final String? exitCode;

  @override
  void paint(Canvas canvas, Size size) {
    final data = map;
    if (data == null || size.isEmpty) return;
    final fill = Paint()..color = land..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..strokeJoin = StrokeJoin.bevel;

    for (final country in data.countries) {
      final path = _path(country, size);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }

    final exit = exitCode == null ? null : data.byCode[exitCode];
    final origin = originCode == null ? null : data.byCode[originCode];
    if (exit != null) {
      canvas.drawPath(
        _path(exit, size),
        Paint()..color = route.withValues(alpha: 0.38),
      );
      canvas.drawPath(
        _path(exit, size),
        Paint()
          ..color = route
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeJoin = StrokeJoin.bevel,
      );
    }

    if (origin != null && exit != null && origin.code != exit.code) {
      _route(canvas, size, origin, exit);
    }
    if (origin != null && (exit == null || origin.code != exit.code)) {
      _mark(canvas, _at(origin, size), ink, hollow: true);
    }
    if (exit != null) {
      final at = _at(exit, size);
      _mark(canvas, at, route, hollow: false);
      _label(canvas, size, at, exit.code);
    }
  }

  Path _path(MapCountry country, Size size) {
    final path = Path();
    for (final ring in country.rings) {
      double? prevLon;
      var open = false;
      for (final pt in ring) {
        if (prevLon != null && (pt.$1 - prevLon).abs() > 180) {
          open = false;
        }
        final o = _xy(pt.$1, pt.$2, size);
        if (!open) {
          path.moveTo(o.dx, o.dy);
          open = true;
        } else {
          path.lineTo(o.dx, o.dy);
        }
        prevLon = pt.$1;
      }
      if (open) path.close();
    }
    return path;
  }

  void _route(Canvas canvas, Size size, MapCountry from, MapCountry to) {
    var dLon = to.lon - from.lon;
    if (dLon > 180) dLon -= 360;
    if (dLon < -180) dLon += 360;
    final paint = Paint()
      ..color = route
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25
      ..strokeCap = StrokeCap.square;
    final path = Path();
    Offset? prev;
    const steps = 28;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      var lon = from.lon + dLon * t;
      if (lon > 180) lon -= 360;
      if (lon < -180) lon += 360;
      final lat = from.lat + (to.lat - from.lat) * t;
      final o = _xy(lon, lat, size);
      if (prev == null || (o.dx - prev.dx).abs() > size.width * 0.45) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
      prev = o;
    }
    canvas.drawPath(path, paint);
  }

  void _mark(Canvas canvas, Offset at, Color color, {required bool hollow}) {
    final rect = Rect.fromCenter(center: at, width: 7, height: 7);
    final paint = Paint()
      ..color = color
      ..style = hollow ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeWidth = 1.25;
    canvas.drawRect(rect, paint);
  }

  void _label(Canvas canvas, Size size, Offset at, String code) {
    final tp = TextPainter(
      text: TextSpan(
        text: code,
        style: TextStyle(
          fontFamily: kUiFamily,
          fontFamilyFallback: kMonoFallback,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: ink,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx + 8;
    var dy = at.dy - tp.height - 4;
    if (dx + tp.width > size.width - 6) dx = at.dx - tp.width - 8;
    if (dy < 4) dy = at.dy + 8;
    tp.paint(canvas, Offset(dx, dy));
  }

  Offset _at(MapCountry country, Size size) => _xy(country.lon, country.lat, size);

  Offset _xy(double lon, double lat, Size size) =>
      Offset(WorldMapData.xOf(lon) * size.width, WorldMapData.yOf(lat) * size.height);

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.map != map ||
      old.land != land ||
      old.border != border ||
      old.ink != ink ||
      old.route != route ||
      old.originCode != originCode ||
      old.exitCode != exitCode;
}
