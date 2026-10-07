import 'package:flutter/material.dart';

import '../../services/vpn_controller.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';

/// Lightweight status map: a square grid, a pixel landmass, and one route
/// from the device to the selected server. Not a map SDK — a status picture.
class RouteField extends StatelessWidget {
  const RouteField({
    super.key,
    required this.status,
    this.originCode,
    this.exitCode,
    this.height = 156,
  });

  final VpnStatus status;
  final String? originCode;
  final String? exitCode;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Panel(
      padding: EdgeInsets.zero,
      clip: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _RoutePainter(
            land: c.fillStrong,
            grid: c.separator,
            ink: c.label,
            route: switch (status) {
              VpnStatus.connected => c.success,
              VpnStatus.connecting || VpnStatus.stopping => c.warning,
              VpnStatus.error => c.danger,
              VpnStatus.stopped => c.tertiaryLabel,
            },
            origin: _place(originCode),
            exit: _place(exitCode),
            exitLabel: _code(exitCode),
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

/// Normalized map position, or null when the code is unknown.
({double x, double y})? _place(String? raw) {
  final cc = _code(raw);
  if (cc == null) return null;
  return _places[cc];
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.land,
    required this.grid,
    required this.ink,
    required this.route,
    required this.origin,
    required this.exit,
    required this.exitLabel,
  });

  final Color land;
  final Color grid;
  final Color ink;
  final Color route;
  final ({double x, double y})? origin;
  final ({double x, double y})? exit;
  final String? exitLabel;

  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()
      ..color = grid
      ..strokeWidth = 1;
    const cols = 8;
    const rows = 4;
    for (var i = 1; i < cols; i++) {
      final x = size.width * i / cols;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), g);
    }
    for (var i = 1; i < rows; i++) {
      final y = size.height * i / rows;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }

    final cell = size.width / _landWidth;
    final landPaint = Paint()..color = land;
    for (var r = 0; r < _landRows.length; r++) {
      final row = _landRows[r];
      for (var c = 0; c < row.length; c++) {
        if (row[c] != '#') continue;
        canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell, cell), landPaint);
      }
    }

    final from = origin == null
        ? Offset(size.width * 0.08, size.height * 0.62)
        : Offset(size.width * origin!.x, size.height * origin!.y);
    _square(canvas, from, 7, ink, filled: false);

    if (exit != null) {
      final to = Offset(size.width * exit!.x, size.height * exit!.y);
      final line = Paint()
        ..color = route
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..lineTo(to.dx, from.dy)
        ..lineTo(to.dx, to.dy);
      canvas.drawPath(path, line);
      _square(canvas, to, 7, route, filled: true);
    }

    final label = exitLabel;
    if (label != null) {
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontFamily: kUiFamily,
            fontFamilyFallback: kMonoFallback,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: ink,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(12, size.height - tp.height - 10));
    }
  }

  void _square(Canvas canvas, Offset at, double s, Color color, {required bool filled}) {
    final rect = Rect.fromCenter(center: at, width: s, height: s);
    final paint = Paint()
      ..color = color
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) =>
      old.land != land ||
      old.grid != grid ||
      old.ink != ink ||
      old.route != route ||
      old.origin?.x != origin?.x ||
      old.origin?.y != origin?.y ||
      old.exit?.x != exit?.x ||
      old.exit?.y != exit?.y ||
      old.exitLabel != exitLabel;
}

const int _landWidth = 40;

/// 40 columns. `#` is land. Rows are equal length.
const List<String> _landRows = [
  '                                        ',
  '      ####          ######              ',
  '     ######        ########             ',
  '     ######        ########    ##       ',
  '      ####          ######    ####      ',
  '       ##            ####    ######     ',
  '                    #####     ####      ',
  '                   #######     ##       ',
  '                    #####               ',
  '                     ###                ',
  '                      ##     ####       ',
  '                             ######     ',
  '                              ####      ',
  '                                        ',
];

/// Approximate country positions on the same 0–1 field as [_landRows].
const Map<String, ({double x, double y})> _places = {
  'US': (x: 0.18, y: 0.36),
  'CA': (x: 0.16, y: 0.26),
  'MX': (x: 0.15, y: 0.46),
  'BR': (x: 0.30, y: 0.68),
  'AR': (x: 0.28, y: 0.78),
  'CL': (x: 0.26, y: 0.76),
  'GB': (x: 0.46, y: 0.30),
  'IE': (x: 0.44, y: 0.30),
  'FR': (x: 0.48, y: 0.36),
  'DE': (x: 0.51, y: 0.32),
  'NL': (x: 0.49, y: 0.30),
  'BE': (x: 0.48, y: 0.32),
  'LU': (x: 0.49, y: 0.33),
  'CH': (x: 0.50, y: 0.36),
  'AT': (x: 0.52, y: 0.35),
  'IT': (x: 0.52, y: 0.40),
  'ES': (x: 0.46, y: 0.40),
  'PT': (x: 0.44, y: 0.40),
  'SE': (x: 0.53, y: 0.22),
  'NO': (x: 0.51, y: 0.20),
  'FI': (x: 0.56, y: 0.20),
  'DK': (x: 0.51, y: 0.28),
  'PL': (x: 0.54, y: 0.32),
  'CZ': (x: 0.52, y: 0.34),
  'UA': (x: 0.58, y: 0.34),
  'RO': (x: 0.56, y: 0.38),
  'BG': (x: 0.56, y: 0.40),
  'GR': (x: 0.55, y: 0.42),
  'TR': (x: 0.58, y: 0.42),
  'RU': (x: 0.70, y: 0.26),
  'KZ': (x: 0.66, y: 0.38),
  'AE': (x: 0.63, y: 0.48),
  'IL': (x: 0.58, y: 0.46),
  'IN': (x: 0.70, y: 0.50),
  'SG': (x: 0.76, y: 0.60),
  'HK': (x: 0.78, y: 0.48),
  'TW': (x: 0.80, y: 0.48),
  'JP': (x: 0.86, y: 0.40),
  'KR': (x: 0.82, y: 0.40),
  'CN': (x: 0.76, y: 0.40),
  'TH': (x: 0.74, y: 0.54),
  'VN': (x: 0.76, y: 0.52),
  'ID': (x: 0.78, y: 0.64),
  'AU': (x: 0.84, y: 0.76),
  'NZ': (x: 0.92, y: 0.82),
  'ZA': (x: 0.54, y: 0.78),
  'EG': (x: 0.56, y: 0.48),
  'NG': (x: 0.48, y: 0.56),
  'KE': (x: 0.58, y: 0.58),
};
