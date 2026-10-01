import 'dart:async';

import 'package:app_links/app_links.dart';

import '../state/import_input.dart';

/// Listens for `melsi://import?url=…` (and sing-box / clash / hiddify
/// equivalents) and hands the subscription URL to [onImport].
class DeepLinks {
  DeepLinks(this.onImport);
  final void Function(String url, String? name) onImport;
  StreamSubscription<Uri>? _sub;

  Future<void> start() async {
    try {
      final links = AppLinks();
      _sub = links.uriLinkStream.listen(_handle, onError: (Object _) {});
    } catch (_) {
      // Plugin not available on this platform / in tests.
    }
  }

  void _handle(Uri uri) {
    final d = DeepLinkImport.parse(uri.toString());
    if (d != null) onImport(d.url, d.name);
  }

  void dispose() => _sub?.cancel();
}
