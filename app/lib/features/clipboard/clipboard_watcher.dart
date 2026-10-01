import 'dart:async';

import 'package:flutter/services.dart' show Clipboard;

import '../../core/link_parser.dart';
import '../../core/models.dart';
import '../../state/feature_service.dart';
import '../../state/import_input.dart';
import '../favorites/favorites_service.dart';

/// What the clipboard held, as far as the offer is concerned.
enum ClipboardOfferKind { link, subscription, many }

/// A pending "import from the clipboard?" offer. The text stays in memory
/// only for as long as the offer is showing; only [hash] is ever persisted.
class ClipboardOffer {
  const ClipboardOffer(this.text, this.hash,
      {required this.kind, this.count = 1, this.host});
  final String text;
  final String hash;
  final ClipboardOfferKind kind;

  /// Number of servers found (for [ClipboardOfferKind.many]).
  final int count;

  /// Host of the subscription URL (for [ClipboardOfferKind.subscription]).
  final String? host;
}

/// Offers to import a proxy link found on the clipboard when the app
/// starts or comes back to the foreground. Non-blocking: the UI shows a
/// toast; nothing happens until the user taps "Add".
class ClipboardWatcher extends FeatureService {
  ClipboardWatcher(super.app, super.features);

  /// The favourites half of this package rides on the same lifecycle
  /// because [Features] has no slot of its own for it.
  late final FavoritesService favorites = FavoritesService(app, features);

  ClipboardOffer? offer;
  bool _disposed = false;
  int _generation = 0;

  /// Off on iOS by default: reading the pasteboard there shows a system
  /// "pasted from …" banner on every resume.
  bool get enabled => app.settings.clipboardWatch ?? !app.isIOS;

  Future<String?> Function() get _read =>
      features.readClipboard ??
      () => Clipboard.getData(Clipboard.kTextPlain).then((d) => d?.text);

  @override
  Future<void> load() async {
    _generation++;
    await favorites.load();
    // During onboarding the import panel is on screen already; an offer on
    // top of it would only compete with it.
    if (!app.settings.onboardingDone) return;
    // Never awaited: a platform that does not answer (or is slow to) must
    // not hold up the app's start — the offer simply arrives when it does.
    unawaited(check());
  }

  @override
  void onResume() {
    favorites.onResume();
    if (app.settings.onboardingDone) unawaited(check());
  }

  /// Reads the clipboard and, when it holds something importable that we
  /// have not offered (or already have), publishes an [offer].
  Future<void> check() async {
    if (_disposed || !enabled) return;
    final generation = ++_generation;
    String? raw;
    try {
      raw = await _read();
    } catch (_) {
      // Linux without a clipboard manager, sandboxed hosts: no clipboard.
      return;
    }
    if (_disposed || !enabled || generation != _generation) return;
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return;
    final hash = fingerprint(text);
    if (hash == app.settings.lastClipboardHash || hash == offer?.hash) return;
    if (app.nodes.any((n) => n.rawLink == text) ||
        app.subscriptions.any((s) => s.url == text)) {
      return;
    }
    final next = classify(text, hash);
    if (next == null) return;
    offer = next;
    notifyListeners();
  }

  /// FNV-1a (the node id hash) over the trimmed text: enough to recognise
  /// the same clipboard twice, useless for recovering it.
  static String fingerprint(String text) => ProxyNode.computeId({'t': text.trim()});

  /// Maps clipboard text to an offer, or null when it is not importable.
  static ClipboardOffer? classify(String text, String hash) {
    switch (ImportInput.classify(text)) {
      case SingleLinkInput(:final link):
        if (LinkParser.parseLink(link) == null) return null;
        return ClipboardOffer(text, hash, kind: ClipboardOfferKind.link);
      case ContentInput(:final content):
        final nodes = LinkParser.parseContent(content);
        if (nodes.isEmpty) return null;
        return ClipboardOffer(text, hash,
            kind: nodes.length == 1 ? ClipboardOfferKind.link : ClipboardOfferKind.many,
            count: nodes.length);
      case SubscriptionUrlInput(:final url):
        return ClipboardOffer(text, hash,
            kind: ClipboardOfferKind.subscription, host: Uri.tryParse(url)?.host);
      case ImportEmpty():
        return null;
    }
  }

  /// Imports the offered text. The fingerprint is remembered first so a
  /// resume during the import cannot offer the same text again.
  Future<int> accept() async {
    final o = offer;
    if (o == null) return 0;
    _remember(o);
    return app.importText(o.text);
  }

  /// Drops the offer; the same clipboard is not offered again.
  void dismiss() {
    final o = offer;
    if (o == null) return;
    _remember(o);
  }

  void _remember(ClipboardOffer o) {
    offer = null;
    app.updateSettings((s) => s.lastClipboardHash = o.hash, affectsConfig: false);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    offer = null;
    favorites.dispose();
    super.dispose();
  }
}
