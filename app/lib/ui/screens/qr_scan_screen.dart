import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';
import '../theme/theme.dart';

/// Full-screen camera QR scanner. Pops with the scanned text.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _ctrl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_done) return;
    final v = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (v == null || v.isEmpty) return;
    _done = true;
    HapticFeedback.heavyImpact();
    Navigator.of(context).pop(v);
  }

  /// Controls sit on a dark scrim so they stay legible over the camera.
  Widget _scrim({required Widget child, double radius = 20, EdgeInsetsGeometry? padding}) =>
      Container(
        padding: padding,
        decoration: ShapeDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: Radii.shape(radius,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.15), width: kHairline)),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _ctrl,
            onDetect: _onDetect,
            errorBuilder: (context, e) => Center(
              child: Padding(
                padding: const EdgeInsets.all(Space.x3),
                child: Text(l('qr.noCamera'),
                    textAlign: TextAlign.center,
                    style: context.t.callout.copyWith(color: Colors.white70)),
              ),
            ),
          ),
          // Viewfinder.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: ShapeDecoration(
                shape: Radii.shape(Radii.l,
                    side: const BorderSide(color: Colors.white, width: 2)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Space.l),
              child: Column(children: [
                Row(children: [
                  _scrim(
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const Spacer(),
                  _scrim(
                    child: IconButton(
                      icon: const Icon(Icons.flashlight_on_outlined, color: Colors.white, size: 20),
                      onPressed: _ctrl.toggleTorch,
                    ),
                  ),
                ]),
                const Spacer(),
                _scrim(
                  radius: Radii.m,
                  padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.m),
                  child: Text(l('qr.hint'),
                      style: context.t.subhead.copyWith(color: Colors.white)),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
