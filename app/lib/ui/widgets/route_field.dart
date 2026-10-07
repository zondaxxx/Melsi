import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/vpn_controller.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';

/// What the connect animation is doing. Tests read [RouteFieldState.debugCue].
enum MapCue {
  idle,
  approach,
  waiting,
  travel,
  spread,
  settled,
  retreat,
  failed,
}

enum _Phase {
  idle,
  approach,
  wait,
  travel,
  spread,
  reveal,
  settled,
  hold,
  retreat,
  failed,
}

/// Home status map: Natural Earth country borders, painted locally.
///
/// Connect zooms toward the pre-VPN country and holds a signal there until
/// the tunnel is up and the exit IP has been located. Only then does the
/// signal fly to that country, fill it, and zoom back out. A failure or a
/// lookup that never arrives returns home and fills the origin in red.
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
    this.exitReady = false,
    this.exitFailed = false,
    this.exitSkipped = false,
    this.height = 196,
  });

  final VpnStatus status;
  final String? originCode;
  final String? exitCode;
  final double? originLat;
  final double? originLon;
  final double? exitLat;
  final double? exitLon;

  /// Tunnel is up and [exitCode] / coordinates are the post-VPN exit.
  final bool exitReady;

  /// The exit lookup failed. The shot returns home in red.
  final bool exitFailed;

  /// No lookup will run (IP check is off). After connect, zoom back out
  /// at the origin instead of treating the missing exit as a failure.
  final bool exitSkipped;

  final double height;

  @override
  State<RouteField> createState() => RouteFieldState();
}

class RouteFieldState extends State<RouteField> with TickerProviderStateMixin {
  static const _approachFor = Duration(milliseconds: 900);
  static const _travelFor = Duration(milliseconds: 1100);
  static const _spreadFor = Duration(milliseconds: 500);
  static const _revealFor = Duration(milliseconds: 700);
  static const _backFor = Duration(milliseconds: 1500);
  static const _exitWait = Duration(seconds: 20);

  late final AnimationController _step = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // Starting the next phase inside this tick drops the new ticker.
      scheduleMicrotask(() {
        if (!mounted) return;
        _advance();
      });
    });
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  _Phase _phase = _Phase.idle;
  bool _booted = false;
  bool _advancing = false;
  bool _timedOut = false;
  bool _homeOnly = false;
  double _zoomFrom = _nearZoom;
  _MapPainter? _lastPainter;
  _CameraPose? _cameraFrom;
  bool _wasReduced = false;
  Timer? _exitTimer;

  String? _originCode;
  double? _originLat;
  double? _originLon;
  String? _fromCode;
  double? _fromLat;
  double? _fromLon;
  String? _landedCode;
  double? _landedLat;
  double? _landedLon;

  MapCue get debugCue => switch (_phase) {
    _Phase.idle => MapCue.idle,
    _Phase.approach => MapCue.approach,
    _Phase.wait || _Phase.hold => MapCue.waiting,
    _Phase.travel => MapCue.travel,
    _Phase.spread || _Phase.reveal => MapCue.spread,
    _Phase.settled => MapCue.settled,
    _Phase.retreat => MapCue.retreat,
    _Phase.failed => MapCue.failed,
  };

  @visibleForTesting
  double? get debugZoom => _lastPainter?.cameraPose.zoom;

  @visibleForTesting
  Offset? get debugFocus => _lastPainter?.cameraPose.focus;

  bool get _reduce => context.reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_booted) {
      if (_wasReduced != _reduce) {
        _wasReduced = _reduce;
        if (_reduce) _begin(_phase);
      }
      return;
    }
    _wasReduced = _reduce;
    _booted = true;
    _captureOrigin(force: true);
    _sync(initial: true);
  }

  @override
  void didUpdateWidget(RouteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == VpnStatus.stopped || _originCode == null) {
      _captureOrigin(force: widget.status == VpnStatus.stopped);
    }
    if (oldWidget.status != widget.status ||
        oldWidget.exitReady != widget.exitReady ||
        oldWidget.exitFailed != widget.exitFailed ||
        oldWidget.exitSkipped != widget.exitSkipped ||
        oldWidget.exitCode != widget.exitCode ||
        oldWidget.exitLat != widget.exitLat ||
        oldWidget.exitLon != widget.exitLon) {
      _sync();
    }
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    _step.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _captureOrigin({required bool force}) {
    if (!force && _originCode != null) return;
    _originCode = widget.originCode;
    _originLat = widget.originLat;
    _originLon = widget.originLon;
  }

  void _sync({bool initial = false}) {
    final status = widget.status;
    if (status == VpnStatus.stopped || status == VpnStatus.stopping) {
      _timedOut = false;
      _homeOnly = false;
      _begin(_Phase.idle);
      return;
    }
    if (status == VpnStatus.connecting) {
      _timedOut = false;
      if (_phase == _Phase.idle ||
          _phase == _Phase.failed ||
          _phase == _Phase.retreat) {
        _begin(_Phase.approach);
      }
      return;
    }
    // A lookup timeout describes the old result, not the live tunnel. A
    // later successful lookup (or disabling it) must let the map recover.
    if (widget.exitReady || widget.exitSkipped) _timedOut = false;
    if (status == VpnStatus.error ||
        (widget.exitFailed && !widget.exitReady && !widget.exitSkipped) ||
        _timedOut) {
      if (_phase == _Phase.retreat || _phase == _Phase.failed) return;
      _begin(_Phase.retreat);
      return;
    }
    if ((_phase == _Phase.retreat || _phase == _Phase.failed) &&
        (widget.exitReady || widget.exitSkipped)) {
      _homeOnly = !widget.exitReady;
      _begin(widget.exitReady ? _Phase.travel : _Phase.reveal);
      return;
    }
    if (_phase == _Phase.idle) {
      if (initial) {
        if (widget.exitReady) {
          _homeOnly = false;
          _latchLanded();
          _phase = _Phase.settled;
          _stopMotion();
          _refresh();
        } else if (widget.exitSkipped) {
          _homeOnly = true;
          _phase = _Phase.settled;
          _stopMotion();
          _refresh();
        } else {
          _begin(_Phase.wait);
        }
        return;
      }
      _begin(_Phase.approach);
      return;
    }
    // Let the approach finish; its completion picks wait, travel, or zoom-out.
    if (_phase == _Phase.approach || _phase == _Phase.retreat) return;
    if (widget.exitSkipped && _phase == _Phase.settled) return;
    if (widget.exitSkipped &&
        (_phase == _Phase.wait || _phase == _Phase.hold)) {
      _homeOnly = true;
      _begin(_Phase.reveal);
      return;
    }
    if (widget.exitReady) {
      if (_sameLanded()) {
        if (_phase == _Phase.wait || _phase == _Phase.hold) {
          _begin(_Phase.travel);
        }
        return;
      }
      if (_phase == _Phase.travel ||
          _phase == _Phase.spread ||
          _phase == _Phase.reveal) {
        return;
      }
      _begin(_Phase.travel);
      return;
    }
    if (_phase == _Phase.settled) {
      _begin(_Phase.hold);
    } else if (_phase == _Phase.wait || _phase == _Phase.hold) {
      _armTimer();
    }
  }

  void _advance() {
    if (_advancing) return;
    _advancing = true;
    try {
      switch (_phase) {
        case _Phase.approach:
          _afterApproach();
        case _Phase.travel:
          if (widget.exitReady && !_sameLanded()) {
            _begin(_Phase.travel);
          } else if (!widget.exitReady &&
              !widget.exitSkipped &&
              widget.status == VpnStatus.connected) {
            _begin(_Phase.hold);
          } else if (widget.status == VpnStatus.error ||
              widget.exitFailed ||
              _timedOut) {
            _begin(_Phase.retreat);
          } else {
            _begin(_Phase.spread);
          }
        case _Phase.spread:
          _begin(_Phase.reveal);
        case _Phase.reveal:
          _phase = _Phase.settled;
          _stopMotion();
          _refresh();
        case _Phase.retreat:
          _phase = _Phase.failed;
          _stopMotion();
          _refresh();
        default:
          break;
      }
    } finally {
      _advancing = false;
    }
  }

  void _afterApproach() {
    if (widget.status == VpnStatus.error || widget.exitFailed || _timedOut) {
      _begin(_Phase.retreat);
    } else if (widget.status == VpnStatus.connected && widget.exitReady) {
      _begin(_Phase.travel);
    } else if (widget.status == VpnStatus.connected && widget.exitSkipped) {
      _homeOnly = true;
      _begin(_Phase.reveal);
    } else {
      _begin(_Phase.wait);
    }
  }

  void _begin(_Phase phase) {
    // Interrupt from the frame on screen, including a retry during retreat.
    _cameraFrom = _lastPainter?.cameraPose;
    if (_reduce && phase != _Phase.idle) {
      _stopMotion();
      final connectedWithoutApproach =
          phase == _Phase.approach &&
          widget.status == VpnStatus.connected &&
          (widget.exitReady || widget.exitSkipped);
      if (connectedWithoutApproach ||
          phase == _Phase.travel ||
          phase == _Phase.spread ||
          phase == _Phase.reveal ||
          phase == _Phase.settled) {
        if (widget.exitReady) {
          _homeOnly = false;
          _latchLanded();
        } else if (widget.exitSkipped) {
          _homeOnly = true;
          _clearFlight();
        }
        _phase = _Phase.settled;
      } else if (phase == _Phase.retreat || phase == _Phase.failed) {
        _phase = _Phase.failed;
      } else {
        _phase = _Phase.wait;
        if (widget.status == VpnStatus.connected &&
            !widget.exitSkipped &&
            !widget.exitReady) {
          _armTimer();
        }
      }
      _refresh();
      return;
    }
    switch (phase) {
      case _Phase.idle:
        _phase = _Phase.idle;
        _clearFlight();
        _stopMotion();
        _step.value = 0;
      case _Phase.approach:
        _clearFlight();
        _homeOnly = false;
        _timedOut = false;
        _phase = _Phase.approach;
        _stopPulse();
        _cancelTimer();
        _play(_approachFor);
      case _Phase.wait:
        _phase = _Phase.wait;
        _step.stop();
        _startPulse();
        _armTimer();
      case _Phase.hold:
        _phase = _Phase.hold;
        _step.stop();
        _startPulse();
        _armTimer();
      case _Phase.travel:
        _zoomFrom = _zoomFor(_phase);
        _fromCode = _landedCode ?? _originCode;
        _fromLat = _landedLat ?? _originLat;
        _fromLon = _landedLon ?? _originLon;
        _homeOnly = false;
        _latchLanded();
        _phase = _Phase.travel;
        _stopPulse();
        _cancelTimer();
        _play(_travelFor);
      case _Phase.spread:
        _phase = _Phase.spread;
        _play(_spreadFor);
      case _Phase.reveal:
        _zoomFrom = _homeOnly ? _nearZoom : _arrivalZoom;
        if (_homeOnly) _clearFlight();
        _phase = _Phase.reveal;
        _stopPulse();
        _cancelTimer();
        _play(_revealFor);
      case _Phase.settled:
        _phase = _Phase.settled;
        _stopMotion();
      case _Phase.retreat:
        _zoomFrom = _zoomFor(_phase);
        if (_landedCode == null && _landedLat == null) _clearFlight();
        _phase = _Phase.retreat;
        _stopPulse();
        _cancelTimer();
        _play(_backFor);
      case _Phase.failed:
        _phase = _Phase.failed;
        _stopMotion();
    }
    _refresh();
  }

  void _play(Duration duration) {
    _step.duration = duration;
    _step.forward(from: 0);
  }

  void _startPulse() {
    if (_reduce || _pulse.isAnimating) return;
    _pulse.repeat();
  }

  void _stopPulse() {
    if (_pulse.isAnimating) _pulse.stop();
    _pulse.value = 0;
  }

  void _stopMotion() {
    _step.stop();
    _stopPulse();
    _cancelTimer();
  }

  void _armTimer() {
    if (_exitTimer != null || widget.exitSkipped || widget.exitReady) return;
    if (widget.status != VpnStatus.connected) return;
    _exitTimer = Timer(_exitWait, () {
      _exitTimer = null;
      _timedOut = true;
      if (!mounted) return;
      _begin(_Phase.retreat);
    });
  }

  void _cancelTimer() {
    _exitTimer?.cancel();
    _exitTimer = null;
  }

  void _clearFlight() {
    _fromCode = null;
    _fromLat = null;
    _fromLon = null;
    _landedCode = null;
    _landedLat = null;
    _landedLon = null;
  }

  void _latchLanded() {
    _landedCode = _code(widget.exitCode);
    _landedLat = widget.exitLat;
    _landedLon = widget.exitLon;
  }

  bool _sameLanded() {
    if (!widget.exitReady) return false;
    return _landedCode == _code(widget.exitCode) &&
        _near(_landedLat, widget.exitLat) &&
        _near(_landedLon, widget.exitLon);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  double _zoomFor(_Phase phase) => switch (phase) {
    _Phase.approach || _Phase.wait => _nearZoom,
    _Phase.travel || _Phase.spread => _arrivalZoom,
    _Phase.reveal || _Phase.settled || _Phase.hold || _Phase.idle => 1,
    _Phase.retreat || _Phase.failed => _nearZoom,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final failing =
        _phase == _Phase.retreat ||
        _phase == _Phase.failed ||
        widget.status == VpnStatus.error;
    final route = switch (widget.status) {
      VpnStatus.connected when !failing => c.success,
      VpnStatus.connecting ||
      VpnStatus.stopping ||
      VpnStatus.connected => c.warning,
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
              painter: _lastPainter = _MapPainter(
                map: snap.data,
                land: c.isDark
                    ? const Color(0xFF202426)
                    : const Color(0xFFF9FAFA),
                border: c.label.withValues(alpha: c.isDark ? 0.17 : 0.18),
                ocean: c.background,
                cameraFrom: _cameraFrom,
                reduceMotion: _reduce,
                ink: c.label,
                route: failing ? c.danger : route,
                danger: c.danger,
                originCode: _code(_originCode ?? widget.originCode),
                exitCode: _homeOnly ? null : _landedCode,
                fromCode: _code(_fromCode),
                originLat: _originLat ?? widget.originLat,
                originLon: _originLon ?? widget.originLon,
                exitLat: _homeOnly ? null : _landedLat,
                exitLon: _homeOnly ? null : _landedLon,
                fromLat: _fromLat,
                fromLon: _fromLon,
                status: widget.status,
                phase: _phase,
                step: _step,
                pulse: _pulse,
                zoomFrom: _zoomFrom,
                homeOnly: _homeOnly,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

bool _near(double? a, double? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  return (a - b).abs() < 0.01;
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
      countries.add(
        MapCountry(
          code: m['i'] as String? ?? '',
          lon: (anchor[0] as num).toDouble(),
          lat: (anchor[1] as num).toDouble(),
          rings: rings,
        ),
      );
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

class _Cam {
  const _Cam({
    required this.zoom,
    required this.focus,
    required this.signal,
    required this.trailFrom,
    required this.signalOn,
    required this.spread,
    required this.fail,
    required this.emerge,
    required this.label,
  });

  final double zoom;
  final Offset focus;
  final Offset signal;
  final Offset trailFrom;
  final bool signalOn;
  final double spread;
  final double fail;
  final double emerge;
  final bool label;
}

const _world = Offset(0.5, 0.46);
const _nearZoom = 2.05;
const _arrivalZoom = 1.85;

class _CameraPose {
  const _CameraPose(this.zoom, this.focus);
  final double zoom;
  final Offset focus;
}

_Cam _cam({
  required _Phase phase,
  required double t,
  required double pulse,
  required Offset origin,
  required Offset from,
  required Offset dest,
  required double zoomFrom,
  required bool homeOnly,
}) {
  final e = _ease(t);
  switch (phase) {
    case _Phase.idle:
      return _Cam(
        zoom: 1,
        focus: _world,
        signal: origin,
        trailFrom: origin,
        signalOn: false,
        spread: 0,
        fail: 0,
        emerge: 0,
        label: false,
      );
    case _Phase.approach:
      return _Cam(
        zoom: ui.lerpDouble(1, _nearZoom, e)!,
        focus: Offset.lerp(_world, origin, e)!,
        signal: origin,
        trailFrom: origin,
        signalOn: t > 0.42,
        spread: 0,
        fail: 0,
        emerge: _piece(t, 0.42, 0.45),
        label: false,
      );
    case _Phase.wait:
      final wobble = 0.75 + 0.25 * math.sin(pulse * math.pi * 2);
      return _Cam(
        zoom: _nearZoom,
        focus: origin,
        signal: origin,
        trailFrom: origin,
        signalOn: true,
        spread: 0,
        fail: 0,
        emerge: wobble.abs().clamp(0.55, 1.15),
        label: false,
      );
    case _Phase.hold:
      return _Cam(
        zoom: 1,
        focus: _world,
        signal: dest,
        trailFrom: dest,
        signalOn: false,
        spread: 0.35,
        fail: 0,
        emerge: 0.85 + 0.15 * math.sin(pulse * math.pi * 2).abs(),
        label: true,
      );
    case _Phase.travel:
      final along = _routePoint(from, dest, e);
      final zoom = ui.lerpDouble(zoomFrom, _arrivalZoom, e)!;
      final focus = zoomFrom < 2 ? Offset.lerp(_world, along, e)! : along;
      return _Cam(
        zoom: zoom,
        focus: focus,
        signal: along,
        trailFrom: from,
        signalOn: true,
        spread: 0,
        fail: 0,
        emerge: 1,
        label: false,
      );
    case _Phase.spread:
      return _Cam(
        zoom: _arrivalZoom,
        focus: dest,
        signal: dest,
        trailFrom: from,
        signalOn: true,
        spread: homeOnly ? 0 : e,
        fail: 0,
        emerge: 1,
        label: !homeOnly && t > 0.35,
      );
    case _Phase.reveal:
      return _Cam(
        zoom: ui.lerpDouble(zoomFrom, 1, e)!,
        focus: Offset.lerp(homeOnly ? origin : dest, _world, e)!,
        signal: homeOnly ? origin : dest,
        trailFrom: from,
        signalOn: false,
        spread: homeOnly ? 0 : 1,
        fail: 0,
        emerge: 0,
        label: !homeOnly,
      );
    case _Phase.settled:
      return _Cam(
        zoom: 1,
        focus: _world,
        signal: homeOnly ? origin : dest,
        trailFrom: from,
        signalOn: false,
        spread: homeOnly ? 0 : 1,
        fail: 0,
        emerge: 0,
        label: !homeOnly,
      );
    case _Phase.retreat:
      final home = _piece(t, 0, 0.62);
      final bloom = _piece(t, 0.55, 0.45);
      final back = _routePoint(dest, origin, _ease(home));
      return _Cam(
        zoom: ui.lerpDouble(zoomFrom, _nearZoom, _ease(math.max(home, bloom)))!,
        focus: Offset.lerp(back, origin, _ease(home))!,
        signal: back,
        trailFrom: dest,
        signalOn: bloom < 0.2 && (dest - origin).distance > 0.01,
        spread: 0,
        fail: bloom,
        emerge: bloom < 0.85 ? 1 : 0,
        label: false,
      );
    case _Phase.failed:
      return _Cam(
        zoom: _nearZoom,
        focus: origin,
        signal: origin,
        trailFrom: origin,
        signalOn: false,
        spread: 0,
        fail: 1,
        emerge: 0,
        label: false,
      );
  }
}

double _piece(double t, double start, double span) =>
    ((t - start) / span).clamp(0.0, 1.0);

double _ease(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

Offset _routePoint(Offset from, Offset to, double t) {
  final x = ui.lerpDouble(from.dx, to.dx, t)!;
  final lift = math.min((to - from).distance * 0.24, 0.12);
  final y = ui.lerpDouble(from.dy, to.dy, t)! - math.sin(math.pi * t) * lift;
  return Offset(x, y);
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.map,
    required this.land,
    required this.border,
    required this.ocean,
    required this.cameraFrom,
    required this.reduceMotion,
    required this.ink,
    required this.route,
    required this.danger,
    required this.originCode,
    required this.exitCode,
    required this.fromCode,
    required this.originLat,
    required this.originLon,
    required this.exitLat,
    required this.exitLon,
    required this.fromLat,
    required this.fromLon,
    required this.status,
    required this.phase,
    required this.step,
    required this.pulse,
    required this.zoomFrom,
    required this.homeOnly,
  }) : super(repaint: Listenable.merge([step, pulse]));

  final WorldMapData? map;
  final Color land;
  final Color border;
  final Color ocean;
  final _CameraPose? cameraFrom;
  final bool reduceMotion;
  final Color ink;
  final Color route;
  final Color danger;
  final String? originCode;
  final String? exitCode;
  final String? fromCode;
  final double? originLat;
  final double? originLon;
  final double? exitLat;
  final double? exitLon;
  final double? fromLat;
  final double? fromLon;
  final VpnStatus status;
  final _Phase phase;
  final AnimationController step;
  final AnimationController pulse;
  final double zoomFrom;
  final bool homeOnly;

  (Offset, Offset, Offset) get _points {
    final data = map;
    final origin =
        _point(data?.byCode[originCode], originLon, originLat) ?? _world;
    final from = _point(data?.byCode[fromCode], fromLon, fromLat) ?? origin;
    final dest = _point(data?.byCode[exitCode], exitLon, exitLat) ?? from;
    return (origin, from, dest);
  }

  _Cam _view(double t) {
    final (origin, from, dest) = _points;
    return _cam(
      phase: phase,
      t: t,
      pulse: pulse.value,
      origin: origin,
      from: from,
      dest: dest,
      zoomFrom: zoomFrom,
      homeOnly: homeOnly,
    );
  }

  _CameraPose get cameraPose {
    final cam = _view(step.value);
    if (reduceMotion) return const _CameraPose(1, _world);
    final previous = cameraFrom;
    final animated =
        phase == _Phase.approach ||
        phase == _Phase.travel ||
        phase == _Phase.reveal ||
        phase == _Phase.retreat;
    if (previous == null || !animated) return _CameraPose(cam.zoom, cam.focus);
    final start = _view(0);
    final remaining = 1 - _ease(step.value);
    return _CameraPose(
      cam.zoom + (previous.zoom - start.zoom) * remaining,
      cam.focus + (previous.focus - start.focus) * remaining,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final data = map;
    if (data == null || size.isEmpty) return;
    final (origin, from, dest) = _points;
    final originCountry = data.byCode[originCode];
    final exitCountry = data.byCode[exitCode];
    final active =
        status == VpnStatus.connecting ||
        status == VpnStatus.connected ||
        status == VpnStatus.error ||
        phase == _Phase.retreat ||
        phase == _Phase.failed;
    final cam = _view(step.value);
    final pose = cameraPose;

    // A quiet atlas: geographic grid and land remain behind the route.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width * .52, size.height * .36),
          size.width * .7,
          [Color.alphaBlend(ink.withValues(alpha: .035), ocean), ocean],
        ),
    );
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(pose.zoom);
    canvas.translate(-pose.focus.dx * size.width, -pose.focus.dy * size.height);
    canvas.scale(size.width, size.height);

    final hair = .7 / (pose.zoom * math.min(size.width, size.height));
    final grid = Paint()
      ..color = ink.withValues(alpha: .045)
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair * .7;
    for (var lon = -180; lon <= 180; lon += 30) {
      final x = WorldMapData.xOf(lon.toDouble());
      canvas.drawLine(Offset(x, 0), Offset(x, 1), grid);
    }
    for (var lat = -30; lat <= 60; lat += 30) {
      final y = WorldMapData.yOf(lat.toDouble());
      canvas.drawLine(Offset(0, y), Offset(1, y), grid);
    }
    final fill = Paint()..color = land;
    final stroke = Paint()
      ..color = border
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair
      ..strokeJoin = StrokeJoin.round;
    for (final country in data.countries) {
      final path = WorldMapData.unitPath(country);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }
    if (active && originCountry != null && cam.fail == 0) {
      canvas.drawPath(
        WorldMapData.unitPath(originCountry),
        Paint()..color = route.withValues(alpha: .06),
      );
    }
    if (active && exitCountry != null && cam.spread > 0) {
      _fillCountry(canvas, exitCountry, route, cam.spread, hair);
    }
    if (active && originCountry != null && cam.fail > 0) {
      _fillCountry(canvas, originCountry, danger, cam.fail, hair);
    }
    canvas.restore();

    final originAt = _screen(origin, pose, size);
    if (!active || phase == _Phase.idle) {
      if (originCountry != null || originLat != null) {
        _mark(canvas, originAt, ink.withValues(alpha: .45), quiet: true);
      }
      return;
    }
    final head = _screen(cam.signal, pose, size);
    final landed =
        phase == _Phase.spread ||
        phase == _Phase.reveal ||
        phase == _Phase.settled ||
        phase == _Phase.hold;
    final located = exitCode != null || (exitLat != null && exitLon != null);
    if (!homeOnly && located && (phase == _Phase.travel || landed)) {
      final routeFrom = phase == _Phase.travel ? from : origin;
      final progress = phase == _Phase.travel ? _ease(step.value) : 1.0;
      _trail(
        canvas,
        routeFrom,
        dest,
        pose,
        size,
        route,
        progress: progress,
        quiet: landed,
      );
      _mark(canvas, _screen(routeFrom, pose, size), route, quiet: true);
    } else if (cam.signalOn && (cam.trailFrom - cam.signal).distance > .01) {
      _trail(
        canvas,
        cam.trailFrom,
        origin,
        pose,
        size,
        route,
        progress: _ease(_piece(step.value, 0, .62)),
        quiet: false,
      );
    }
    if (phase == _Phase.wait || phase == _Phase.hold) {
      if (!reduceMotion) _ring(canvas, head, route, pulse.value);
    } else if (phase == _Phase.spread && !reduceMotion) {
      _ring(canvas, head, route, _ease(step.value));
    }
    if (cam.emerge > 0 || landed || phase == _Phase.failed) {
      _mark(canvas, head, route, scale: landed ? 1 : cam.emerge.clamp(.7, 1.2));
    }
    if (cam.label && exitCountry != null) {
      _label(canvas, size, head, exitCountry.code);
    }
  }

  void _fillCountry(
    Canvas canvas,
    MapCountry country,
    Color color,
    double amount,
    double hair,
  ) {
    final path = WorldMapData.unitPath(country);
    canvas.drawPath(
      path,
      Paint()..color = color.withValues(alpha: .06 + .19 * amount),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .25 + .6 * amount)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hair * (1 + .45 * amount)
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _trail(
    Canvas canvas,
    Offset from,
    Offset to,
    _CameraPose pose,
    Size size,
    Color color, {
    required double progress,
    required bool quiet,
  }) {
    if ((from - to).distance < .004) return;
    final path = Path();
    const steps = 64;
    for (var i = 0; i <= steps; i++) {
      final at = _screen(_routePoint(from, to, i / steps), pose, size);
      if (i == 0) {
        path.moveTo(at.dx, at.dy);
      } else {
        path.lineTo(at.dx, at.dy);
      }
    }
    final metric = path.computeMetrics().first;
    final reached = metric.length * progress;
    final traveled = metric.extractPath(0, reached);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      path,
      paint
        ..color = color.withValues(alpha: .12)
        ..strokeWidth = 1,
    );
    canvas.drawPath(
      traveled,
      paint
        ..color = color.withValues(alpha: quiet ? .04 : .08)
        ..strokeWidth = 9,
    );
    canvas.drawPath(
      traveled,
      paint
        ..color = color.withValues(alpha: quiet ? .1 : .18)
        ..strokeWidth = 4,
    );
    canvas.drawPath(
      traveled,
      paint
        ..color = color.withValues(alpha: quiet ? .64 : .8)
        ..strokeWidth = 1.3,
    );
    if (!quiet && reached > 1) {
      final tail = metric.extractPath(math.max(0, reached - 32), reached);
      canvas.drawPath(
        tail,
        paint
          ..color = color
          ..strokeWidth = 1.8,
      );
    }
  }

  void _ring(Canvas canvas, Offset at, Color color, double progress) {
    canvas.drawCircle(
      at,
      7 + 17 * progress,
      Paint()
        ..color = color.withValues(alpha: .25 * (1 - progress))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _mark(
    Canvas canvas,
    Offset at,
    Color color, {
    double scale = 1,
    bool quiet = false,
  }) {
    final radius = (quiet ? 2.3 : 3.2) * scale;
    if (!quiet) {
      canvas.drawCircle(
        at,
        12 * scale,
        Paint()
          ..shader = ui.Gradient.radial(at, 12 * scale, [
            color.withValues(alpha: .22),
            color.withValues(alpha: 0),
          ]),
      );
    }
    canvas.drawCircle(at, radius + 1.8, Paint()..color = ocean);
    canvas.drawCircle(at, radius, Paint()..color = color);
    if (!quiet) {
      canvas.drawCircle(
        at,
        1.05 * scale,
        Paint()..color = Colors.white.withValues(alpha: .9),
      );
    }
  }

  void _label(Canvas canvas, Size size, Offset at, String code) {
    final tp = TextPainter(
      text: TextSpan(
        text: code,
        style: TextStyle(
          fontFamily: kUiFamily,
          fontFamilyFallback: kMonoFallback,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: .7,
          color: ink,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = tp.width + 12;
    final height = tp.height + 9;
    final dx = (at.dx + 10)
        .clamp(8.0, math.max(8.0, size.width - width - 8))
        .toDouble();
    final dy = (at.dy - height - 7)
        .clamp(8.0, math.max(8.0, size.height - height - 8))
        .toDouble();
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(dx, dy, width, height),
      const Radius.circular(5),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = Color.alphaBlend(land.withValues(alpha: .92), ocean),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = route.withValues(alpha: .3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .6,
    );
    tp.paint(canvas, Offset(dx + 6, dy + 4.5));
  }

  Offset? _point(MapCountry? country, double? lon, double? lat) {
    if (lon != null && lat != null) {
      return Offset(WorldMapData.xOf(lon), WorldMapData.yOf(lat));
    }
    if (country == null) return null;
    return Offset(WorldMapData.xOf(country.lon), WorldMapData.yOf(country.lat));
  }

  Offset _screen(Offset unit, _CameraPose cam, Size size) => Offset(
    size.width / 2 + cam.zoom * (unit.dx - cam.focus.dx) * size.width,
    size.height / 2 + cam.zoom * (unit.dy - cam.focus.dy) * size.height,
  );

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.map != map ||
      old.land != land ||
      old.border != border ||
      old.ocean != ocean ||
      old.cameraFrom != cameraFrom ||
      old.reduceMotion != reduceMotion ||
      old.ink != ink ||
      old.route != route ||
      old.danger != danger ||
      old.originCode != originCode ||
      old.exitCode != exitCode ||
      old.fromCode != fromCode ||
      old.originLat != originLat ||
      old.originLon != originLon ||
      old.exitLat != exitLat ||
      old.exitLon != exitLon ||
      old.fromLat != fromLat ||
      old.fromLon != fromLon ||
      old.status != status ||
      old.phase != phase ||
      old.zoomFrom != zoomFrom ||
      old.homeOnly != homeOnly;
}
