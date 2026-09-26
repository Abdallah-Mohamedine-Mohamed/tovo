import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tovo/components/widgets/numero_nita.dart';
import 'package:tovo/core/theme.dart';

void main() {
  String? recu;
  Future<void> ouvrir(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TovoTheme.client(),
        home: Scaffold(body: NumeroNita(onChanged: (n) => recu = n)),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => recu = null);

  test('seuls les numéros du Niger sont repris du compte', () {
    expect(NumeroNita.nigerien('22790123456'), '90123456');
    expect(NumeroNita.nigerien('+227 90 12 34 56'), '90123456');
    expect(NumeroNita.nigerien('33612345678'), isNull);
    expect(NumeroNita.lisible('90123456'), '90 12 34 56');
  });

  testWidgets('un numéro déjà utilisé est repris, modifiable d’un geste', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'numero_nita': '90123456'});
    await ouvrir(tester);
    expect(find.textContaining('+227 90 12 34 56'), findsOneWidget);
    expect(recu, '90123456');

    await tester.tap(find.text('Modifier'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('numero-nita')), '9612');
    expect(recu, isNull, reason: 'incomplet : pas encore de numéro');
    await tester.enterText(
      find.byKey(const ValueKey('numero-nita')),
      '96123456',
    );
    expect(recu, '96123456');
  });

  testWidgets('sans numéro nigérien connu : le champ, directement', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await ouvrir(tester);
    expect(find.byKey(const ValueKey('numero-nita')), findsOneWidget);
    expect(recu, isNull);
    expect(tester.takeException(), isNull);
  });
}
