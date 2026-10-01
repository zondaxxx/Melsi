// Country guessing from node names ("🇩🇪 Frankfurt", "NL-2 Амстердам",
// "[US] Los Angeles", "Россия | Москва"...).

/// ISO 3166-1 alpha-2 code for [nodeName], or null when nothing matches.
///
/// Order of evidence: flag emoji (regional indicator pair) → country/city
/// names (English + Russian) → standalone ISO tokens (" DE ", "DE-1", "[US]").
String? guessCountryCode(String nodeName) {
  if (nodeName.isEmpty) return null;

  // 1. Flag emoji: two regional indicator symbols U+1F1E6..U+1F1FF.
  final runes = nodeName.runes.toList();
  for (var i = 0; i + 1 < runes.length; i++) {
    final a = runes[i], b = runes[i + 1];
    if (_isRegional(a) && _isRegional(b)) {
      final code = String.fromCharCodes([a - 0x1F1E6 + 65, b - 0x1F1E6 + 65]);
      if (_isoCodes.contains(code)) return code == 'UK' ? 'GB' : code;
      i++;
    }
  }

  final lower = nodeName.toLowerCase();

  // 2. Names (longest keys first so "south korea" wins over "korea").
  for (final entry in _namesSorted) {
    if (_containsWord(lower, entry.key)) return entry.value;
  }
  for (final entry in _namesSorted) {
    if (_containsInflected(lower, entry.key)) return entry.value;
  }

  // 3. ISO-like tokens: uppercase letter pairs delimited by non-letters.
  final tokenRe = RegExp(r'(?:^|[^A-Za-z])([A-Z]{2})(?=$|[^A-Za-z])');
  for (final m in tokenRe.allMatches(nodeName)) {
    final code = m.group(1)!;
    if (code == 'UK') return 'GB';
    if (_isoCodes.contains(code) && !_ambiguousTokens.contains(code)) {
      return code;
    }
  }
  // Ambiguous two-letter tokens count only if nothing else matched and they
  // look like a node label ("IN-1", "[IT]").
  final strictRe = RegExp(r'(?:^|[\[\(\s|_])([A-Z]{2})(?=[\]\)\s|_-]?\d|[\]\)])');
  for (final m in strictRe.allMatches(nodeName)) {
    final code = m.group(1)!;
    if (_isoCodes.contains(code)) return code;
  }
  return null;
}

/// "DE" -> "🇩🇪". Returns "🏳" for invalid input.
String flagEmoji(String countryCode) {
  final cc = countryCode.trim().toUpperCase();
  if (cc.length != 2 ||
      !RegExp(r'^[A-Z]{2}$').hasMatch(cc)) {
    return '🏳';
  }
  final code = cc == 'UK' ? 'GB' : cc;
  return String.fromCharCodes(
      code.codeUnits.map((c) => 0x1F1E6 + (c - 65)));
}

bool _isRegional(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;

bool _containsWord(String haystack, String needle) {
  var start = 0;
  while (true) {
    final idx = haystack.indexOf(needle, start);
    if (idx < 0) return false;
    final before = idx == 0 ? '' : haystack[idx - 1];
    final afterIdx = idx + needle.length;
    final after = afterIdx >= haystack.length ? '' : haystack[afterIdx];
    // Russian names inflect ("Германии", "Москве"): allow trailing Cyrillic
    // letters when the needle itself is Cyrillic and long enough.
    final cyr = RegExp(r'[а-яё]').hasMatch(needle);
    final okBefore = before.isEmpty || !_isLetter(before);
    final okAfter = after.isEmpty ||
        !_isLetter(after) ||
        (cyr && needle.length >= 4 && RegExp(r'[а-яё]').hasMatch(after));
    if (okBefore && okAfter) return true;
    start = idx + 1;
  }
}

/// Russian inflection: "Германия" matches "Германии", "Москва" → "Москве".
bool _containsInflected(String haystack, String needle) {
  if (needle.length < 5 || !RegExp(r'[аяьйиыео]$').hasMatch(needle)) {
    return false;
  }
  final stem = needle.substring(0, needle.length - 1);
  return RegExp('(?:^|[^a-zа-яё])${RegExp.escape(stem)}[а-яё]{1,3}(?:\$|[^a-zа-яё])')
      .hasMatch(haystack);
}

bool _isLetter(String ch) => RegExp(r'[a-zа-яё]').hasMatch(ch);

/// Tokens that are common English words / abbreviations; they are only
/// accepted in the stricter "label" form.
const _ambiguousTokens = {
  'IN', 'IT', 'IS', 'TO', 'AT', 'BE', 'BY', 'DO', 'GO', 'ME', 'MY', 'NO',
  'OR', 'SO', 'AM', 'AS', 'AI', 'TV', 'VC', 'IO', 'ID', 'PS', 'PE',
  'CO', 'CC', 'BD', 'SS', 'MS',
};

// US and TR are ambiguous only in lowercase-ish contexts; uppercase "US" is
// overwhelmingly the country in node names, so re-allow them explicitly.
final _namesSorted = (() {
  final list = _names.entries.toList()
    ..sort((a, b) => b.key.length.compareTo(a.key.length));
  return list;
})();

const Map<String, String> _names = {
  // --- English countries
  'united states': 'US', 'usa': 'US', 'america': 'US',
  'united kingdom': 'GB', 'great britain': 'GB', 'britain': 'GB',
  'england': 'GB',
  'germany': 'DE', 'netherlands': 'NL', 'holland': 'NL', 'france': 'FR',
  'finland': 'FI', 'sweden': 'SE', 'norway': 'NO', 'denmark': 'DK',
  'poland': 'PL', 'latvia': 'LV', 'lithuania': 'LT', 'estonia': 'EE',
  'russia': 'RU', 'ukraine': 'UA', 'belarus': 'BY', 'kazakhstan': 'KZ',
  'uzbekistan': 'UZ', 'kyrgyzstan': 'KG', 'armenia': 'AM', 'georgia': 'GE',
  'azerbaijan': 'AZ', 'moldova': 'MD', 'tajikistan': 'TJ',
  'turkey': 'TR', 'turkiye': 'TR', 'türkiye': 'TR',
  'switzerland': 'CH', 'austria': 'AT', 'italy': 'IT', 'spain': 'ES',
  'portugal': 'PT', 'czech': 'CZ', 'czechia': 'CZ', 'slovakia': 'SK',
  'hungary': 'HU', 'romania': 'RO', 'bulgaria': 'BG', 'serbia': 'RS',
  'croatia': 'HR', 'slovenia': 'SI', 'greece': 'GR', 'cyprus': 'CY',
  'ireland': 'IE', 'iceland': 'IS', 'belgium': 'BE', 'luxembourg': 'LU',
  'israel': 'IL', 'uae': 'AE', 'emirates': 'AE', 'india': 'IN',
  'japan': 'JP', 'korea': 'KR', 'south korea': 'KR', 'china': 'CN',
  'hong kong': 'HK', 'hongkong': 'HK', 'taiwan': 'TW', 'singapore': 'SG',
  'malaysia': 'MY', 'thailand': 'TH', 'vietnam': 'VN', 'indonesia': 'ID',
  'philippines': 'PH', 'australia': 'AU', 'new zealand': 'NZ',
  'canada': 'CA', 'mexico': 'MX', 'brazil': 'BR', 'argentina': 'AR',
  'chile': 'CL', 'south africa': 'ZA', 'egypt': 'EG', 'saudi arabia': 'SA',
  'qatar': 'QA', 'iran': 'IR', 'mongolia': 'MN', 'albania': 'AL',
  'north macedonia': 'MK', 'montenegro': 'ME', 'bosnia': 'BA',
  // --- English cities
  'frankfurt': 'DE', 'berlin': 'DE', 'munich': 'DE', 'nuremberg': 'DE',
  'falkenstein': 'DE', 'dusseldorf': 'DE', 'hamburg': 'DE',
  'amsterdam': 'NL', 'rotterdam': 'NL', 'paris': 'FR', 'marseille': 'FR',
  'london': 'GB', 'manchester': 'GB', 'helsinki': 'FI', 'stockholm': 'SE',
  'oslo': 'NO', 'copenhagen': 'DK', 'warsaw': 'PL', 'riga': 'LV',
  'vilnius': 'LT', 'tallinn': 'EE', 'moscow': 'RU',
  'saint petersburg': 'RU', 'st. petersburg': 'RU', 'petersburg': 'RU',
  'novosibirsk': 'RU', 'yekaterinburg': 'RU', 'kyiv': 'UA', 'kiev': 'UA',
  'minsk': 'BY', 'almaty': 'KZ', 'astana': 'KZ', 'tashkent': 'UZ',
  'yerevan': 'AM', 'tbilisi': 'GE', 'baku': 'AZ', 'chisinau': 'MD',
  'istanbul': 'TR', 'ankara': 'TR', 'zurich': 'CH', 'vienna': 'AT',
  'milan': 'IT', 'rome': 'IT', 'madrid': 'ES', 'barcelona': 'ES',
  'lisbon': 'PT', 'prague': 'CZ', 'budapest': 'HU', 'bucharest': 'RO',
  'sofia': 'BG', 'belgrade': 'RS', 'athens': 'GR', 'dublin': 'IE',
  'brussels': 'BE', 'tel aviv': 'IL', 'dubai': 'AE', 'mumbai': 'IN',
  'tokyo': 'JP', 'osaka': 'JP', 'seoul': 'KR', 'taipei': 'TW',
  'sydney': 'AU', 'melbourne': 'AU', 'toronto': 'CA', 'montreal': 'CA',
  'vancouver': 'CA', 'new york': 'US', 'los angeles': 'US',
  'san jose': 'US', 'silicon valley': 'US', 'seattle': 'US',
  'chicago': 'US', 'dallas': 'US', 'miami': 'US', 'ashburn': 'US',
  'washington': 'US', 'atlanta': 'US', 'san francisco': 'US',
  'sao paulo': 'BR', 'são paulo': 'BR', 'johannesburg': 'ZA',
  'kuala lumpur': 'MY', 'bangkok': 'TH', 'jakarta': 'ID', 'hanoi': 'VN',
  // --- Russian countries
  'сша': 'US', 'америка': 'US', 'соединенные штаты': 'US',
  'соединённые штаты': 'US', 'великобритания': 'GB', 'англия': 'GB',
  'британия': 'GB', 'германия': 'DE', 'нидерланды': 'NL',
  'голландия': 'NL', 'франция': 'FR', 'финляндия': 'FI', 'швеция': 'SE',
  'норвегия': 'NO', 'дания': 'DK', 'польша': 'PL', 'латвия': 'LV',
  'литва': 'LT', 'эстония': 'EE', 'россия': 'RU', 'рф': 'RU',
  'украина': 'UA', 'беларусь': 'BY', 'белоруссия': 'BY',
  'казахстан': 'KZ', 'узбекистан': 'UZ', 'киргизия': 'KG',
  'кыргызстан': 'KG', 'армения': 'AM', 'грузия': 'GE',
  'азербайджан': 'AZ', 'молдова': 'MD', 'таджикистан': 'TJ',
  'турция': 'TR', 'швейцария': 'CH', 'австрия': 'AT', 'италия': 'IT',
  'испания': 'ES', 'португалия': 'PT', 'чехия': 'CZ', 'словакия': 'SK',
  'венгрия': 'HU', 'румыния': 'RO', 'болгария': 'BG', 'сербия': 'RS',
  'хорватия': 'HR', 'словения': 'SI', 'греция': 'GR', 'кипр': 'CY',
  'ирландия': 'IE', 'исландия': 'IS', 'бельгия': 'BE',
  'люксембург': 'LU', 'израиль': 'IL', 'оаэ': 'AE', 'эмираты': 'AE',
  'индия': 'IN', 'япония': 'JP', 'корея': 'KR', 'южная корея': 'KR',
  'китай': 'CN', 'гонконг': 'HK', 'тайвань': 'TW', 'сингапур': 'SG',
  'малайзия': 'MY', 'таиланд': 'TH', 'тайланд': 'TH', 'вьетнам': 'VN',
  'индонезия': 'ID', 'филиппины': 'PH', 'австралия': 'AU',
  'новая зеландия': 'NZ', 'канада': 'CA', 'мексика': 'MX',
  'бразилия': 'BR', 'аргентина': 'AR', 'чили': 'CL', 'юар': 'ZA',
  'египет': 'EG', 'саудовская аравия': 'SA', 'катар': 'QA', 'иран': 'IR',
  'монголия': 'MN', 'албания': 'AL', 'черногория': 'ME',
  // --- Russian cities
  'франкфурт': 'DE', 'берлин': 'DE', 'мюнхен': 'DE', 'нюрнберг': 'DE',
  'фалькенштайн': 'DE', 'гамбург': 'DE', 'дюссельдорф': 'DE',
  'амстердам': 'NL', 'роттердам': 'NL', 'париж': 'FR', 'марсель': 'FR',
  'лондон': 'GB', 'хельсинки': 'FI', 'стокгольм': 'SE', 'осло': 'NO',
  'копенгаген': 'DK', 'варшава': 'PL', 'рига': 'LV', 'вильнюс': 'LT',
  'таллин': 'EE', 'москва': 'RU', 'санкт-петербург': 'RU', 'питер': 'RU',
  'петербург': 'RU', 'спб': 'RU', 'новосибирск': 'RU',
  'екатеринбург': 'RU', 'казань': 'RU', 'киев': 'UA', 'минск': 'BY',
  'алматы': 'KZ', 'астана': 'KZ', 'ташкент': 'UZ', 'бишкек': 'KG',
  'ереван': 'AM', 'тбилиси': 'GE', 'баку': 'AZ', 'кишинев': 'MD',
  'кишинёв': 'MD', 'стамбул': 'TR', 'анкара': 'TR', 'цюрих': 'CH',
  'вена': 'AT', 'милан': 'IT', 'рим': 'IT', 'мадрид': 'ES',
  'барселона': 'ES', 'лиссабон': 'PT', 'прага': 'CZ', 'будапешт': 'HU',
  'бухарест': 'RO', 'софия': 'BG', 'белград': 'RS', 'афины': 'GR',
  'дублин': 'IE', 'брюссель': 'BE', 'тель-авив': 'IL', 'дубай': 'AE',
  'токио': 'JP', 'осака': 'JP', 'сеул': 'KR', 'тайбэй': 'TW',
  'сидней': 'AU', 'торонто': 'CA', 'нью-йорк': 'US',
  'лос-анджелес': 'US', 'сиэтл': 'US', 'чикаго': 'US', 'даллас': 'US',
  'майами': 'US', 'сан-хосе': 'US', 'вашингтон': 'US',
};

const Set<String> _isoCodes = {
  'AD', 'AE', 'AF', 'AG', 'AI', 'AL', 'AM', 'AO', 'AQ', 'AR', 'AS', 'AT',
  'AU', 'AW', 'AX', 'AZ', 'BA', 'BB', 'BD', 'BE', 'BF', 'BG', 'BH', 'BI',
  'BJ', 'BL', 'BM', 'BN', 'BO', 'BQ', 'BR', 'BS', 'BT', 'BV', 'BW', 'BY',
  'BZ', 'CA', 'CC', 'CD', 'CF', 'CG', 'CH', 'CI', 'CK', 'CL', 'CM', 'CN',
  'CO', 'CR', 'CU', 'CV', 'CW', 'CX', 'CY', 'CZ', 'DE', 'DJ', 'DK', 'DM',
  'DO', 'DZ', 'EC', 'EE', 'EG', 'EH', 'ER', 'ES', 'ET', 'FI', 'FJ', 'FK',
  'FM', 'FO', 'FR', 'GA', 'GB', 'GD', 'GE', 'GF', 'GG', 'GH', 'GI', 'GL',
  'GM', 'GN', 'GP', 'GQ', 'GR', 'GS', 'GT', 'GU', 'GW', 'GY', 'HK', 'HM',
  'HN', 'HR', 'HT', 'HU', 'ID', 'IE', 'IL', 'IM', 'IN', 'IO', 'IQ', 'IR',
  'IS', 'IT', 'JE', 'JM', 'JO', 'JP', 'KE', 'KG', 'KH', 'KI', 'KM', 'KN',
  'KP', 'KR', 'KW', 'KY', 'KZ', 'LA', 'LB', 'LC', 'LI', 'LK', 'LR', 'LS',
  'LT', 'LU', 'LV', 'LY', 'MA', 'MC', 'MD', 'ME', 'MF', 'MG', 'MH', 'MK',
  'ML', 'MM', 'MN', 'MO', 'MP', 'MQ', 'MR', 'MS', 'MT', 'MU', 'MV', 'MW',
  'MX', 'MY', 'MZ', 'NA', 'NC', 'NE', 'NF', 'NG', 'NI', 'NL', 'NO', 'NP',
  'NR', 'NU', 'NZ', 'OM', 'PA', 'PE', 'PF', 'PG', 'PH', 'PK', 'PL', 'PM',
  'PN', 'PR', 'PS', 'PT', 'PW', 'PY', 'QA', 'RE', 'RO', 'RS', 'RU', 'RW',
  'SA', 'SB', 'SC', 'SD', 'SE', 'SG', 'SH', 'SI', 'SJ', 'SK', 'SL', 'SM',
  'SN', 'SO', 'SR', 'SS', 'ST', 'SV', 'SX', 'SY', 'SZ', 'TC', 'TD', 'TF',
  'TG', 'TH', 'TJ', 'TK', 'TL', 'TM', 'TN', 'TO', 'TR', 'TT', 'TV', 'TW',
  'TZ', 'UA', 'UG', 'UM', 'US', 'UY', 'UZ', 'VA', 'VC', 'VE', 'VG', 'VI',
  'VN', 'VU', 'WF', 'WS', 'XK', 'YE', 'YT', 'ZA', 'ZM', 'ZW', 'UK',
};
