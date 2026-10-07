import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/vpn_controller.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';

/// What the connect animation is doing. Tests read [RouteFieldState.debugCue].
enum MapCue { idle, approach, travel, spread, settled, retreat, failed }

/// Home status map: Natural Earth country borders, painted locally.
///
/// A connect plays one shot. The camera approaches the pre-VPN country, a
/// square signal runs to the selected server's country, the destination
/// fills, then the camera eases back out. A failure runs the signal home
/// and fills the origin in the danger colour.
class RouteField extends StatefulWidget {
  const RouteField({
    super.key,
    required this.status,
    this.originCode,
    this.exitCode,
    this.originLat,
    this.originLon,
    this.exitLat,
    this.exitLon,
    this.height = 196,
  });

  final VpnStatus status;
  final String? originCode;
  final String? exitCode;
  final double? originLat;
  final double? originLon;
  final double? exitLat;
  final double? exitLon;
  final double height;

  @override
  State<RouteField> createState() => RouteFieldState();
}

class RouteFieldState extends State<RouteField> with TickerProviderStateMixin {
  static const _runFor = Duration(milliseconds: 3400);
  static const _backFor = Duration(milliseconds: 1500);

  late final AnimationController _run = AnimationController(vsync: this, duration: _runFor);
  late final AnimationController _back = AnimationController(vsync: this, duration: _backFor);

  bool _failing = false;
  bool _booted = false;
  String? _originCode;
  double? _originLat;
  double? _originLon;

  MapCue get debugCue {
    if (_failing) return _back.value >= 1 ? MapCue.failed : MapCue.retreat;
    final t = _run.value;
    if (t <= 0) return MapCue.idle;
    if (t >= 1) return MapCue.settled;
    if (t < 0.28) return MapCue.approach;
    if (t < 0.64) return MapCue.travel;
    if (t < 0.84) return MapCue.spread;
    return MapCue.spread;
  }

  bool get _reduce => context.reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_booted) return;
    _booted = true;
    _captureOrigin(force: true);
    _apply(widget.status, initial: true);
  }

  @override
  void didUpdateWidget(RouteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == VpnStatus.stopped || _originCode == null) {
      _captureOrigin(force: widget.status == VpnStatus.stopped);
    }
    if (oldWidget.status != widget.status) _apply(widget.status);
  }

  @override
  void dispose() {
    _run.dispose();
    _back.dispose();
    super.dispose();
  }

  void _captureOrigin({required bool force}) {
    if (!force && _originCode != null) return;
    _originCode = widget.originCode;
    _originLat = widget.originLat;
    _originLon = widget.originLon;
  }

  void _apply(VpnStatus status, {bool initial = false}) {
    switch (status) {
      case VpnStatus.connecting:
        _failing = false;
        _back.value = 0;
        if (initial) {
          _playForward(from: 0);
        } else if (!_run.isAnimating) {
          _playForward(from: _run.value >= 1 ? 0 : _run.value);
        }
      case VpnStatus.connected:
        _failing = false;
        _back.value = 0;
        if (initial || _reduce) {
          _run.value = 1;
        } else if (_run.value == 0 && !_run.isAnimating) {
          _playForward(from: 0);
        }
      case VpnStatus.error:
        _failing = true;
        _run.stop();
        if (_reduce) {
          _back.value = 1;
        } else if (!_back.isAnimating) {
          _back.forward(from: 0);
        }
      case VpnStatus.stopped:
      case VpnStatus.stopping:
        _failing = false;
        _run.stop();
        _back.stop();
        _run.value = 0;
        _back.value = 0;
    }
  }

  void _playForward({required double from}) {
    if (_reduce) {
      _run.value = 1;
      return;
    }
    _run.forward(from: from);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final route = switch (widget.status) {
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
        height: widget.height,
        width: double.infinity,
        child: FutureBuilder<WorldMapData>(
          future: WorldMapData.load(),
          builder: (context, snap) => RepaintBoundary(
            child: CustomPaint(
              painter: _MapPainter(
                map: snap.data,
                land: c.isDark ? const Color(0xFF141414) : const Color(0xFFFFFFFF),
                border: c.label.withValues(alpha: c.isDark ? 0.22 : 0.35),
                ink: c.label,
                route: route,
                danger: c.danger,
                originCode: _code(_originCode ?? widget.originCode),
                exitCode: _code(widget.exitCode),
                originLat: _originLat ?? widget.originLat,
                originLon: _originLon ?? widget.originLon,
                exitLat: widget.exitLat,
                exitLon: widget.exitLon,
                status: widget.status,
                run: _run,
                back: _back,
                failing: _failing,
              ),
              child: const SizedBox.expand(),
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
  WorldMapData(this.countries)
      : byCode = {
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
  static final _paths = Expando<Path>();

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

  /// Country outline in unit map space (0–1). Built once per country.
  static Path unitPath(MapCountry country) {
    final cached = _paths[country];
    if (cached != null) return cached;
    final path = Path();
    for (final ring in country.rings) {
      double? prevLon;
      var open = false;
      for (final pt in ring) {
        if (prevLon != null && (pt.$1 - prevLon).abs() > 180) open = false;
        final o = Offset(xOf(pt.$1), yOf(pt.$2));
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
    _paths[country] = path;
    return path;
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

class _Shot {
  const _Shot({required this.zoom, required this.focus});
  final double zoom;
  final Offset focus;

  static _Shot of({
    required double t,
    required double back,
    required Offset origin,
    required Offset dest,
  }) {
    final travel = _piece(t, 0.28, 0.36);
    final spread = _piece(t, 0.64, 0.18);
    final reveal = _piece(t, 0.82, 0.18);
    final approach = _piece(t, 0.0, 0.28);
    var zoom = ui.lerpDouble(1, 3.15, _ease(approach))!;
    var focus = Offset.lerp(const Offset(0.5, 0.46), origin, _ease(approach))!;
    if (travel > 0 && reveal == 0) {
      final along = _routePoint(origin, dest, travel);
      focus = Offset.lerp(origin, along, _ease(travel))!;
      zoom = ui.lerpDouble(3.15, 2.45, travel)!;
    }
    if (spread > 0 && reveal == 0) {
      focus = dest;
      zoom = 2.45;
    }
    if (reveal > 0) {
      focus = Offset.lerp(dest, const Offset(0.5, 0.46), _ease(reveal))!;
      zoom = ui.lerpDouble(2.45, 1, _ease(reveal))!;
    }
    if (back > 0) {
      final home = _piece(back, 0, 0.62);
      final bloom = _piece(back, 0.55, 0.45);
      final backAlong = _routePoint(origin, dest, travel * (1 - home));
      focus = Offset.lerp(backAlong, origin, _ease(home))!;
      zoom = ui.lerpDouble(zoom, bloom > 0 ? 2.7 : 2.5, _ease(math.max(home, bloom)))!;
    }
    return _Shot(zoom: zoom, focus: focus);
  }
}

double _piece(double t, double start, double span) => ((t - start) / span).clamp(0.0, 1.0);

double _ease(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

Offset _routePoint(Offset from, Offset to, double t) {
  final x = ui.lerpDouble(from.dx, to.dx, t)!;
  final y = ui.lerpDouble(from.dy, to.dy, t)!;
  return Offset(x, y);
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.map,
    required this.land,
    required this.border,
    required this.ink,
    required this.route,
    required this.danger,
    required this.originCode,
    required this.exitCode,
    required this.originLat,
    required this.originLon,
    required this.exitLat,
    required this.exitLon,
    required this.status,
    required this.run,
    required this.back,
    required this.failing,
  }) : super(repaint: Listenable.merge([run, back]));

  final WorldMapData? map;
  final Color land;
  final Color border;
  final Color ink;
  final Color route;
  final Color danger;
  final String? originCode;
  final String? exitCode;
  final double? originLat;
  final double? originLon;
  final double? exitLat;
  final double? exitLon;
  final VpnStatus status;
  final AnimationController run;
  final AnimationController back;
  final bool failing;

  @override
  void paint(Canvas canvas, Size size) {
    final data = map;
    if (data == null || size.isEmpty) return;
    final originCountry = originCode == null ? null : data.byCode[originCode];
    final exitCountry = exitCode == null ? null : data.byCode[exitCode];
    final origin = _point(originCountry, originLon, originLat) ?? const Offset(0.5, 0.46);
    final dest = _point(exitCountry, exitLon, exitLat) ?? origin;
    final shot = _Shot.of(
      t: run.value,
      back: failing ? back.value : 0,
      origin: origin,
      dest: dest,
    );
    final active = status == VpnStatus.connecting ||
        status == VpnStatus.connected ||
        status == VpnStatus.error;
    final travel = _piece(run.value, 0.28, 0.36);
    final spread = _piece(run.value, 0.64, 0.20);
    final home = failing ? _piece(back.value, 0, 0.62) : 0.0;
    final failSpread = failing ? _piece(back.value, 0.55, 0.45) : 0.0;
    final signalT = failing ? travel * (1 - home) : travel;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(shot.zoom);
    canvas.translate(-shot.focus.dx * size.width, -shot.focus.dy * size.height);
    canvas.scale(size.width, size.height);

    final hair = 0.9 / (shot.zoom * math.min(size.width, size.height));
    final fill = Paint()..color = land..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = border
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair
      ..strokeJoin = StrokeJoin.bevel;
    for (final country in data.countries) {
      final path = WorldMapData.unitPath(country);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }

    if (active && exitCountry != null && !failing && (spread > 0 || run.value >= 1)) {
      _fillCountry(canvas, exitCountry, route, spread > 0 ? spread : 1, hair);
    } else if (!active && exitCountry != null) {
      _fillCountry(canvas, exitCountry, route, 0.35, hair);
    }
    if (active && originCountry != null && failSpread > 0) {
      _fillCountry(canvas, originCountry, danger, failSpread, hair);
    }
    canvas.restore();

    if (!active || run.value <= 0 && !failing) return;
    final a = _screen(origin, shot, size);
    final b = _screen(dest, shot, size);
    final moving = (a - b).distance > 2;
    if (moving && signalT > 0 && failSpread == 0) {
      _trail(canvas, origin, dest, signalT, shot, size, failing ? danger : route);
    }
    if (spread > 0 && !failing) {
      _mark(canvas, b, route, hollow: false, scale: 1 + spread);
    } else if (signalT > 0 || (run.value > 0.12 && run.value < 0.3)) {
      final at = _screen(_geoRoute(origin, dest, signalT), shot, size);
      final emerge = _piece(run.value, 0.12, 0.16);
      _mark(canvas, at, failing ? danger : route, hollow: false, scale: emerge.clamp(0.2, 1.4));
    }
    if (!failing && exitCountry != null && run.value > 0.7) {
      _label(canvas, size, b, exitCountry.code);
    }
  }

  void _fillCountry(Canvas canvas, MapCountry country, Color color, double amount, double hair) {
    final path = WorldMapData.unitPath(country);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.14 + 0.4 * amount));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = hair * (1 + amount)
        ..strokeJoin = StrokeJoin.bevel,
    );
  }

  void _trail(
    Canvas canvas,
    Offset from,
    Offset to,
    double t,
    _Shot shot,
    Size size,
    Color color,
  ) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.square;
    final path = Path();
    Offset? prev;
    const steps = 24;
    final n = math.max(1, (steps * t).ceil());
    for (var i = 0; i <= n; i++) {
      final at = _screen(_geoRoute(from, to, i / steps), shot, size);
      if (prev == null || (at.dx - prev.dx).abs() > size.width * 0.45) {
        path.moveTo(at.dx, at.dy);
      } else {
        path.lineTo(at.dx, at.dy);
      }
      prev = at;
    }
    canvas.drawPath(path, paint);
  }

  void _mark(Canvas canvas, Offset at, Color color, {required bool hollow, double scale = 1}) {
    final side = 7.0 * scale;
    final rect = Rect.fromCenter(center: at, width: side, height: side);
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = hollow ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = 1.25,
    );
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

  Offset? _point(MapCountry? country, double? lon, double? lat) {
    if (lon != null && lat != null) return Offset(WorldMapData.xOf(lon), WorldMapData.yOf(lat));
    if (country == null) return null;
    return Offset(WorldMapData.xOf(country.lon), WorldMapData.yOf(country.lat));
  }

  Offset _geoRoute(Offset from, Offset to, double t) => _routePoint(from, to, t);

  Offset _screen(Offset unit, _Shot shot, Size size) => Offset(
        size.width / 2 + shot.zoom * (unit.dx - shot.focus.dx) * size.width,
        size.height / 2 + shot.zoom * (unit.dy - shot.focus.dy) * size.height,
      );

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.map != map ||
      old.land != land ||
      old.border != border ||
      old.ink != ink ||
      old.route != route ||
      old.danger != danger ||
      old.originCode != originCode ||
      old.exitCode != exitCode ||
      old.originLat != originLat ||
      old.originLon != originLon ||
      old.exitLat != exitLat ||
      old.exitLon != exitLon ||
      old.status != status ||
      old.failing != failing;
}
