// Pure fuzzy matching for the command palette. No Flutter imports, so it
// is unit-testable in isolation and reusable by any list that searches
// localised titles.

/// Scores [query] against [title] and [keywords]. 0 means no match; higher
/// is better. Title tiers: exact 100 > prefix 90 > word start 80 >
/// substring 60 > subsequence 20–50. Keywords (host, country code, "fav")
/// cap at 70, so a title that matches always outranks a keyword that
/// matches. A multi-word query is scored as a whole ("kill switch" is an
/// exact hit) and word by word (every word must match somewhere); the
/// better of the two counts. Ties go to the shorter title.
double paletteScore(String query, String title, List<String> keywords) {
  final q = normalizeForSearch(query);
  if (q.isEmpty) return 0;
  final t = normalizeForSearch(title);
  final ks = [for (final k in keywords) normalizeForSearch(k)];
  final whole = _best(q, t, ks);
  final tokens = q.split(' ').where((s) => s.isNotEmpty).toList();
  var perWord = 0.0;
  if (tokens.length > 1) {
    var total = 0.0;
    for (final tok in tokens) {
      final s = _best(tok, t, ks);
      if (s <= 0) {
        total = 0;
        break;
      }
      total += s;
    }
    perWord = total / tokens.length;
  }
  final score = whole > perWord ? whole : perWord;
  return score <= 0 ? 0 : score - t.length * 0.01;
}

double _best(String tok, String title, List<String> keywords) {
  var best = _titleScore(tok, title);
  for (final k in keywords) {
    final s = _keywordScore(tok, k);
    if (s > best) best = s;
  }
  return best;
}

/// Lower-case, collapsed whitespace, and ё folded to е so a query typed
/// either way finds "Тёмное".
String normalizeForSearch(String s) =>
    s.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'\s+'), ' ').trim();

final _wordBreak = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

double _titleScore(String tok, String title) {
  if (title.isEmpty) return 0;
  if (title == tok) return 100;
  if (title.startsWith(tok)) return 90;
  for (final w in title.split(_wordBreak)) {
    if (w.isNotEmpty && w.startsWith(tok)) return 80;
  }
  if (title.contains(tok)) return 60;
  return _subsequenceScore(tok, title);
}

double _keywordScore(String tok, String k) {
  if (k.isEmpty) return 0;
  if (k == tok) return 70;
  if (k.startsWith(tok)) return 55;
  if (k.contains(tok)) return 40;
  return 0;
}

/// Greedy in-order character match. Rewards characters that land on word
/// starts ("ksw" → **K**ill **sw**itch) and a compact span; 0 when the
/// characters cannot be found in order.
double _subsequenceScore(String tok, String title) {
  var pos = 0;
  var first = -1;
  var last = -1;
  var starts = 0;
  for (final ch in tok.runes) {
    final s = String.fromCharCode(ch);
    final i = title.indexOf(s, pos);
    if (i < 0) return 0;
    if (i == 0 || _wordBreak.hasMatch(title[i - 1])) starts++;
    if (first < 0) first = i;
    last = i;
    pos = i + 1;
  }
  final len = tok.runes.length;
  if (len == 0) return 0;
  final span = last - first + 1;
  return 20 + 20 * (starts / len) + 10 * (len / span);
}
