import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/soleil.dart';

void main() {
  // Niamey.
  const lat = 13.5137;
  const lng = 2.1098;

  test('à Niamey, midi est de jour et minuit de nuit', () {
    // Niamey est à UTC+1 ; le midi solaire tombe vers 11 h 50 UTC.
    expect(estLeJour(lat, lng, DateTime.utc(2026, 9, 27, 12)), isTrue);
    expect(estLeJour(lat, lng, DateTime.utc(2026, 9, 27, 0)), isFalse);
  });

  test(
    'bascule au vrai coucher du soleil (vers 17 h 55 UTC fin septembre)',
    () {
      expect(estLeJour(lat, lng, DateTime.utc(2026, 9, 27, 17, 40)), isTrue);
      expect(estLeJour(lat, lng, DateTime.utc(2026, 9, 27, 18, 10)), isFalse);
      // Et au lever, vers 5 h 45 UTC.
      expect(estLeJour(lat, lng, DateTime.utc(2026, 9, 27, 5, 30)), isFalse);
      expect(estLeJour(lat, lng, DateTime.utc(2026, 9, 27, 6)), isTrue);
    },
  );
}
