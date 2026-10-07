import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/ui/widgets/route_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled borders cover common server countries', () async {
    final map = await WorldMapData.load();
    expect(map.countries.length, greaterThan(150));
    for (final code in ['DE', 'US', 'RU', 'JP', 'NL', 'FR', 'GB', 'KZ']) {
      final country = map.byCode[code];
      expect(country, isNotNull, reason: code);
      expect(country!.rings.first.length, greaterThan(3), reason: code);
      expect(country.lat, inInclusiveRange(-56, 78), reason: code);
    }
    expect(map.byCode['DE']!.lon, inInclusiveRange(5, 15));
  });
}
