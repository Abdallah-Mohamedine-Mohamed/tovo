import 'package:flutter/cupertino.dart' show CupertinoIcons;
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
    // Trois étapes : « confirmée » et « en préparation » ne font qu'une.
    expect(find.text('Confirmée'), findsNothing);
    expect(find.text('En route'), findsOneWidget);
    expect(find.text('Prête'), findsNothing);
  });

  testWidgets('récupérée, c’est en route : une seule étape', (tester) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'picked_up');

    expect(
      find.text('Votre commande est en chemin vers vous.'),
      findsOneWidget,
    );
    expect(find.text('Livrée'), findsOneWidget);
  });

  testWidgets(
    'un livreur sur une commande pas encore confirmée : il va la chercher',
    (tester) async {
      await afficherSuivi(
        tester,
        type: 'delivery',
        statut: 'pending',
        extra: {
          'driver': {'name': 'Moussa Issoufou', 'phone': '+22790000000'},
        },
      );

      expect(find.text('Moussa va la chercher'), findsOneWidget);
      expect(
        find.text('Il se rend à la boutique et récupère votre commande.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('une course demandée : le titre, les étapes, rien de répété', (
    tester,
  ) async {
    final gestes = await afficherSuivi(
      tester,
      type: 'courier',
      statut: 'pending',
      extra: {'total': 1000},
    );

    expect(find.text('Votre livraison'), findsOneWidget);
    expect(find.text('Livreur demandé'), findsOneWidget);
    // Le délai est dit dans la phrase de Tovo, pas sur la carte.
    expect(find.textContaining('7 minutes'), findsNothing);
    // Trois étapes, avec leurs lieux et leurs icônes au trait.
    expect(find.text('Récupération à votre position'), findsOneWidget);
    expect(find.text('En route'), findsOneWidget);
    expect(find.text('Livré'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.cube_box), findsOneWidget);
    expect(find.byIcon(Icons.two_wheeler_outlined), findsOneWidget);
    expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
    expect(find.text('Espèces'), findsOneWidget);
    // Personne à appeler tant qu'aucun livreur n'est assigné ; on peut
    // encore annuler.
    expect(find.byIcon(Icons.call), findsNothing);
    await tester.tap(find.text('Annuler la commande'));
    expect(gestes.single.action, 'cancel_order');
  });

  testWidgets('livreur assigné : l’appeler, le suivre, plus d’annulation', (
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
    expect(find.text('Votre livraison'), findsNothing);
    expect(find.byIcon(Icons.call), findsOneWidget);
    expect(find.byIcon(Icons.map_outlined), findsOneWidget);
    expect(find.text('Suivre sur la carte'), findsOneWidget);
    expect(find.text('Annuler la commande'), findsNothing);
    await tester.tap(find.text('Appeler Moussa'));
    expect(gestes.single.action, 'call_driver');
    expect(gestes.single.payload['phone'], '+22790000000');
  });

  testWidgets(
    '« aller chercher » : le titre et les étapes ne se répètent pas',
    (tester) async {
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
      expect(find.text('Il part le chercher'), findsNothing);
      expect(find.text('Récupération à Chez Awa, Yantala'), findsOneWidget);
      expect(find.text('En route vers vous'), findsOneWidget);
    },
  );

  testWidgets('Harobanda → Banifandou, et la consigne rattachée au trajet', (
    tester,
  ) async {
    await afficherSuivi(
      tester,
      type: 'courier',
      statut: 'ready',
      extra: {
        'mode': 'deposer',
        'pickup': {'hint': 'Harobanda'},
        'dropoff': {'hint': 'Banifandou'},
        'parcel_note': 'Sonner au portail bleu',
        'total': 2750,
      },
    );
    expect(find.text('Récupération à Harobanda'), findsOneWidget);
    expect(find.text('En route vers Banifandou'), findsOneWidget);
    expect(
      find.textContaining(
        'Pour le livreur : « Sonner au portail bleu »',
        findRichText: true,
      ),
      findsOneWidget,
    );
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
      expect(find.text('En route'), findsOneWidget);
    },
  );

  testWidgets('Nita pas encore payé : envoyer au livreur, sans code', (
    tester,
  ) async {
    await afficherSuivi(
      tester,
      type: 'delivery',
      statut: 'picked_up',
      extra: {
        'payment_method': 'mobile_money',
        'payment_status': 'pending',
        'total': 3500,
        'driver': {'name': 'Moussa Issoufou', 'phone': '22796123456'},
      },
    );
    expect(find.textContaining('Pas encore payé ? Envoyez'), findsOneWidget);
    expect(find.textContaining('Moussa, votre livreur'), findsOneWidget);
    expect(find.textContaining('96 12 34 56'), findsOneWidget);
    expect(find.text('Copier'), findsOneWidget);
    // Pas de jargon : jamais de « code ».
    expect(find.textContaining('code'), findsNothing);
  });

  testWidgets('Nita payé : une ligne, sans rien à faire', (tester) async {
    await afficherSuivi(
      tester,
      type: 'delivery',
      statut: 'delivering',
      extra: {
        'payment_method': 'mobile_money',
        'payment_status': 'paid',
        'driver': {'name': 'Moussa', 'phone': '22796123456'},
      },
    );
    expect(find.text('Payé par Nita'), findsOneWidget);
    expect(find.textContaining('Pas encore payé'), findsNothing);
  });

  testWidgets('Nita sans livreur encore : personne à qui envoyer', (
    tester,
  ) async {
    await afficherSuivi(
      tester,
      type: 'delivery',
      statut: 'preparing',
      extra: {'payment_method': 'mobile_money', 'payment_status': 'pending'},
    );
    expect(find.textContaining('Pas encore payé'), findsNothing);
  });
}
