import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';
import '../theme/glass.dart';
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
              width: 250,
              height: 250,
              decoration: ShapeDecoration(
                shape: Radii.shape(Radii.xl,
                    side: const BorderSide(color: Colors.white, width: 3)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Space.l),
              child: Column(children: [
                Row(children: [
                  Glass(
                    radius: 22,
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const Spacer(),
                  Glass(
                    radius: 22,
                    child: IconButton(
                      icon: const Icon(Icons.flashlight_on_rounded, color: Colors.white),
                      onPressed: _ctrl.toggleTorch,
                    ),
                  ),
                ]),
                const Spacer(),
                Glass(
                  radius: Radii.pill,
                  padding: const EdgeInsets.symmetric(horizontal: Space.xl, vertical: Space.m),
                  child: Text(l('qr.hint'),
                      style: context.t.callout.copyWith(color: Colors.white, fontWeight: FontWeight.w500)),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
