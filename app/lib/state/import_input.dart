/// Classifies what the user pasted / scanned / opened.
sealed class ImportInput {
  const ImportInput();

  static ImportInput classify(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const ImportEmpty();

    // Deep links wrap a subscription URL.
    final deep = DeepLinkImport.parse(text);
    if (deep != null) return deep;

    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length == 1) {
      final l = lines.first;
      if (looksLikeSubscriptionUrl(l)) return SubscriptionUrlInput(l);
      if (RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(l)) {
        return SingleLinkInput(l);
      }
    }
    return ContentInput(text);
  }

  /// `https://host/path?token` is a subscription; `http://1.2.3.4:8080` or
  /// `https://user:pass@host:443` is an HTTP proxy share link.
  static bool looksLikeSubscriptionUrl(String s) {
    final u = Uri.tryParse(s);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return false;
    if (u.host.isEmpty) return false;
    if (u.userInfo.isNotEmpty) return false;
    final hasPath = u.path.isNotEmpty && u.path != '/';
    return hasPath || u.hasQuery;
  }
}

class ImportEmpty extends ImportInput {
  const ImportEmpty();
}

class SubscriptionUrlInput extends ImportInput {
  const SubscriptionUrlInput(this.url, {this.name});
  final String url;
  final String? name;
}

class SingleLinkInput extends ImportInput {
  const SingleLinkInput(this.link);
  final String link;
}

class ContentInput extends ImportInput {
  const ContentInput(this.content);
  final String content;
}

/// `melsi://import?url=…&name=…`, `sing-box://import-remote-profile?url=…#name`,
/// `clash://install-config?url=…`, `hiddify://import/<url>#name`.
class DeepLinkImport extends SubscriptionUrlInput {
  const DeepLinkImport(super.url, {super.name});

  static DeepLinkImport? parse(String s) {
    final u = Uri.tryParse(s.trim());
    if (u == null) return null;
    String? url;
    String? name;
    switch (u.scheme) {
      case 'melsi':
        if (u.host == 'import' || u.path.contains('import')) {
          url = u.queryParameters['url'];
          name = u.queryParameters['name'];
        }
      case 'sing-box':
        if (u.host == 'import-remote-profile') {
          url = u.queryParameters['url'];
          name = u.fragment.isEmpty ? u.queryParameters['name'] : Uri.decodeComponent(u.fragment);
        }
      case 'clash' || 'clashmeta' || 'mihomo':
        if (u.host == 'install-config') {
          url = u.queryParameters['url'];
          name = u.queryParameters['name'];
        }
      case 'hiddify':
        if (u.host == 'import') {
          final idx = s.indexOf('import/');
          var rest = idx >= 0 ? s.substring(idx + 7) : '';
          final hash = rest.lastIndexOf('#');
          if (hash > 0) {
            name = Uri.decodeComponent(rest.substring(hash + 1));
            rest = rest.substring(0, hash);
          }
          url = Uri.decodeComponent(rest);
        }
    }
    if (url == null || url.isEmpty) return null;
    return DeepLinkImport(url, name: (name?.isEmpty ?? true) ? null : name);
  }
}
