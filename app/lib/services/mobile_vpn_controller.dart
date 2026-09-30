import 'dart:async';

import 'package:flutter/services.dart';

import '../core/models.dart';
import 'vpn_controller.dart';

/// Bridge to the native tunnel (CONTRACT §5).
class MobileVpnController extends VpnController {
  MobileVpnController({MethodChannel? channel, EventChannel? events})
      : _ch = channel ?? const MethodChannel('app.melsi/vpn'),
        _ev = events ?? const EventChannel('app.melsi/vpn/events');

  final MethodChannel _ch;
  final EventChannel _ev;
  Stream<VpnState>? _states;

  @override
  Stream<VpnState> get states => _states ??= _ev
      .receiveBroadcastStream()
      .map((e) {
        final m = (e as Map?) ?? const {};
        return VpnState(VpnState.parseStatus(m['state'] as String?),
            m['message'] as String?);
      })
      .handleError((Object _) {})
      .asBroadcastStream();

  @override
  Future<bool> prepare() async {
    try {
      return await _ch.invokeMethod<bool>('prepare') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> start(BuiltConfig cfg, {required String name}) async {
    try {
      await _ch.invokeMethod<void>('start', {
        'config': cfg.singBox,
        'engine': cfg.engine,
        'name': name,
      });
    } on PlatformException catch (e) {
      throw VpnStartException(e.message ?? e.code);
    }
  }

  @override
  Future<void> stop() => _ch.invokeMethod<void>('stop');

  @override
  Future<VpnState> currentState() async {
    try {
      final s = await _ch.invokeMethod<String>('status');
      return VpnState(VpnState.parseStatus(s));
    } catch (_) {
      return VpnState.stopped;
    }
  }

  @override
  Future<String?> coreVersion() async {
    try {
      return await _ch.invokeMethod<String>('coreVersion');
    } catch (_) {
      return null;
    }
  }
}

class VpnStartException implements Exception {
  VpnStartException(this.message);
  final String message;
  @override
  String toString() => message;
}
