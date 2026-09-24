import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/order_tracking.dart';

Future<List<TovoInteraction>> afficherSuivi(
  WidgetTester tester, {
  required String type,
  required String statut,
  Map<String, dynamic> extra = const {},
}) async {
  final gestes = <TovoInteraction>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: OrderTracking(
            component: TovoComponent(
              type: 'order_tracking',
              data: {'type': type, 'status': statut, ...extra},
            ),
            onInteraction: gestes.add,
          ),
        ),
      ),
    ),
  );
  return gestes;
}

void main() {
  testWidgets('un repas en préparation ne se présente pas comme prêt', (
    tester,
  ) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'preparing');

    expect(find.text('En préparation'), findsOneWidget);
    expect(find.text('La boutique prépare votre commande.'), findsOneWidget);
    expect(find.text('Ensuite : Prête'), findsOneWidget);
  });

  testWidgets('le retrait du repas précède son trajet', (tester) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'picked_up');

    expect(find.text('Le livreur a récupéré votre commande.'), findsOneWidget);
    expect(find.text('Ensuite : En route'), findsOneWidget);
  });

  testWidgets('un livreur : trois étapes, et il va vous appeler', (
    tester,
  ) async {
    await afficherSuivi(tester, type: 'courier', statut: 'pending');

    expect(find.text('Un livreur va vous appeler'), findsOneWidget);
    expect(find.textContaining('7 minutes'), findsOneWidget);
    expect(find.text('Ensuite : Colis récupéré'), findsOneWidget);
    expect(find.text('Destination à préciser au livreur'), findsOneWidget);
    expect(find.text('En préparation'), findsNothing);
    // Personne à appeler tant qu'aucun livreur n'est assigné.
    expect(find.byIcon(Icons.call), findsNothing);
  });

  testWidgets('livreur assigné : un vrai bouton pour l’appeler', (
    tester,
  ) async {
    final gestes = await afficherSuivi(
      tester,
      type: 'courier',
      statut: 'assigned',
      extra: {
        'driver': {'name': 'Moussa Issoufou', 'phone': '+22790000000'},
      },
    );

    expect(find.text('Moussa arrive'), findsOneWidget);
    await tester.tap(find.text('Appeler Moussa'));
    expect(gestes.single.action, 'call_driver');
    expect(gestes.single.payload['phone'], '+22790000000');
  });

  testWidgets('un colis livré est nommé comme tel', (tester) async {
    await afficherSuivi(tester, type: 'courier', statut: 'delivered');

    expect(find.text('Colis livré'), findsOneWidget);
    expect(find.text('Terminé'), findsOneWidget);
  });

  testWidgets('une commande annulée ne montre pas de progression', (
    tester,
  ) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'cancelled');

    expect(find.text('Annulée'), findsOneWidget);
    expect(find.textContaining('Ensuite'), findsNothing);
  });
}
