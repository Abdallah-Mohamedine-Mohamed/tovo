import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/courier_form.dart';

Future<List<TovoInteraction>> _afficher(
  WidgetTester tester,
  Map<String, dynamic> data,
) async {
  final gestes = <TovoInteraction>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CourierForm(
            component: TovoComponent(type: 'courier_form', data: data),
            onInteraction: gestes.add,
          ),
        ),
      ),
    ),
  );
  return gestes;
}

void main() {
  testWidgets('un seul geste : la position suffit, espèces par défaut', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {
      'pickup': {'lat': 13.51, 'lng': 2.11, 'hint': 'Ma position actuelle'},
      'estimate': {'price': 1000, 'flat': true},
      'callback_minutes': 7,
    });

    expect(find.text('Ma position actuelle'), findsOneWidget);
    expect(find.textContaining('7 minutes'), findsOneWidget);
    expect(find.text('Course en ville'), findsOneWidget);
    // Rien à remplir : pas de champ visible avant « Ajouter des détails ».
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Appeler un livreur'));
    await tester.pump();

    expect(gestes, hasLength(1));
    expect(gestes.single.action, 'submit_courier');
    expect(gestes.single.payload['pickup'], containsPair('lat', 13.51));
    expect(gestes.single.payload['payment_method'], 'cash');
    expect(gestes.single.payload.containsKey('dropoff'), isFalse);

    // Un second tap ne fait pas venir deux livreurs.
    await tester.tap(find.text('Appeler un livreur'));
    expect(gestes, hasLength(1));
  });

  testWidgets('ce que le client a dit est repris, détails ouverts', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {
      'pickup': {'lat': 13.51, 'lng': 2.11},
      'dropoff': {'hint': 'Harobanda'},
      'dropoff_contact': '90123456',
    });

    expect(find.text('Harobanda'), findsOneWidget);
    expect(find.text('90123456'), findsOneWidget);

    await tester.tap(find.text('Appeler un livreur'));
    expect(gestes.single.payload['dropoff_hint'], 'Harobanda');
    expect(gestes.single.payload['dropoff_contact'], '90123456');
  });

  testWidgets('sans position, le bouton attend « Ma position »', (
    tester,
  ) async {
    await _afficher(tester, const {});
    expect(find.text('Ma position'), findsOneWidget);
    final bouton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(bouton.onPressed, isNull);
  });
}
