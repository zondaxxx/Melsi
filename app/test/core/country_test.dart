import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/core/country.dart';
import 'package:melsi/core/game_presets.dart';

void main() {
  test('flag emoji', () {
    expect(guessCountryCode('🇩🇪 Frankfurt'), 'DE');
    expect(guessCountryCode('Fast 🇺🇸 node'), 'US');
    expect(guessCountryCode('🇬🇧 London'), 'GB');
    expect(flagEmoji('DE'), '🇩🇪');
    expect(flagEmoji('nl'), '🇳🇱');
    expect(flagEmoji('UK'), '🇬🇧');
    expect(flagEmoji('???'), '🏳');
  });

  test('ISO tokens', () {
    expect(guessCountryCode('DE-1'), 'DE');
    expect(guessCountryCode('Server NL 2'), 'NL');
    expect(guessCountryCode('[US] Premium'), 'US');
    expect(guessCountryCode('vless | FI | reality'), 'FI');
    expect(guessCountryCode('IT-3'), 'IT');
    expect(guessCountryCode('UK_London'), 'GB');
  });

  test('English names', () {
    expect(guessCountryCode('Germany Premium'), 'DE');
    expect(guessCountryCode('amsterdam-01'), 'NL');
    expect(guessCountryCode('Hong Kong 3'), 'HK');
    expect(guessCountryCode('South Korea Seoul'), 'KR');
    expect(guessCountryCode('Los Angeles gaming'), 'US');
  });

  test('Russian names incl. inflections', () {
    expect(guessCountryCode('Германия #1'), 'DE');
    expect(guessCountryCode('Нидерланды'), 'NL');
    expect(guessCountryCode('Франкфурт'), 'DE');
    expect(guessCountryCode('Амстердам VIP'), 'NL');
    expect(guessCountryCode('Москва'), 'RU');
    expect(guessCountryCode('США 🚀'), 'US');
    expect(guessCountryCode('Сервер в Германии'), 'DE');
    expect(guessCountryCode('Казахстан, Алматы'), 'KZ');
    expect(guessCountryCode('Финляндия Хельсинки'), 'FI');
  });

  test('no match', () {
    expect(guessCountryCode(''), isNull);
    expect(guessCountryCode('Best server'), isNull);
    expect(guessCountryCode('trojan 443'), isNull);
    expect(guessCountryCode('Go to it'), isNull);
  });

  test('game presets', () {
    expect(kGamePresets.length, greaterThanOrEqualTo(25));
    final ids = kGamePresets.map((p) => p.id).toSet();
    expect(ids.length, kGamePresets.length, reason: 'ids unique');
    expect(gamePresetById('cs2')!.desktopProcesses, contains('cs2.exe'));
    expect(gamePresetById('pubg_mobile')!.androidPackages,
        contains('com.tencent.ig'));
    expect(gamePresetById('nope'), isNull);
    for (final p in kGamePresets) {
      expect(
          p.androidPackages.isNotEmpty ||
              p.desktopProcesses.isNotEmpty ||
              p.domainSuffixes.isNotEmpty,
          isTrue,
          reason: p.id);
      for (final d in [...p.domainSuffixes, ...p.downloadDomainSuffixes]) {
        expect(RegExp(r'^[a-z0-9.-]+\.[a-z]{2,}$').hasMatch(d), isTrue,
            reason: '${p.id}: $d');
      }
    }
  });
}
