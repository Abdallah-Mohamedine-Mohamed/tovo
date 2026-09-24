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

    // Le titre, et l'étape en cours dans la frise.
    expect(find.text('En préparation'), findsNWidgets(2));
    expect(find.text('La boutique prépare votre commande.'), findsOneWidget);
    // Quatre étapes verticales, pas six.
    expect(find.text('Confirmée'), findsOneWidget);
    expect(find.text('En route'), findsOneWidget);
    expect(find.text('Prête'), findsNothing);
  });

  testWidgets('le retrait du repas précède son trajet', (tester) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'picked_up');

    expect(find.text('Le livreur a récupéré votre commande.'), findsOneWidget);
    expect(find.text('Livrée'), findsOneWidget);
  });

  testWidgets('un livreur : trois étapes, et il va vous appeler', (
    tester,
  ) async {
    await afficherSuivi(tester, type: 'courier', statut: 'pending');

    expect(find.text('Un livreur va vous appeler'), findsOneWidget);
    expect(find.textContaining('7 minutes'), findsOneWidget);
    // Trois étapes, de haut en bas.
    expect(find.text('Livreur en route'), findsOneWidget);
    expect(find.text('Colis récupéré'), findsOneWidget);
    expect(find.text('Livré'), findsOneWidget);
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

  testWidgets('« aller chercher » : il part le chercher, puis vous l’apporte', (
    tester,
  ) async {
    await afficherSuivi(
      tester,
      type: 'courier',
      statut: 'assigned',
      extra: {
        'mode': 'recuperer',
        'pickup': {'hint': 'Chez Awa, Yantala'},
        'driver': {'name': 'Moussa Issoufou', 'phone': '+22790000000'},
      },
    );
    expect(find.text('Moussa part le chercher'), findsOneWidget);
    expect(find.text('Il part le chercher'), findsOneWidget);
    expect(find.text('Livré chez vous'), findsOneWidget);
    // Où il va, et pas une « destination » qui est chez le client.
    expect(
      find.textContaining('À récupérer : Chez Awa, Yantala'),
      findsOneWidget,
    );
    expect(find.textContaining('Destination'), findsNothing);
  });

  testWidgets('un colis livré est nommé comme tel', (tester) async {
    await afficherSuivi(tester, type: 'courier', statut: 'delivered');

    expect(find.text('Colis livré'), findsOneWidget);
  });

  testWidgets('une commande annulée ne montre pas de progression', (
    tester,
  ) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'cancelled');

    expect(find.text('Annulée'), findsOneWidget);
    expect(find.text('Confirmée'), findsNothing);
  });

  testWidgets(
    '« À voir avec le client » n’est pas présenté comme une adresse',
    (tester) async {
      await afficherSuivi(
        tester,
        type: 'courier',
        statut: 'pending',
        extra: {
          'dropoff': {'hint': 'À voir avec le client'},
        },
      );
      expect(find.textContaining('À voir avec le client'), findsNothing);
      expect(find.text('Destination à préciser au livreur'), findsOneWidget);
    },
  );
}
