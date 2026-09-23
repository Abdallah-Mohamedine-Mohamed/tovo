import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/order_tracking.dart';
import 'package:tovo/core/theme.dart';

Future<void> afficherSuivi(
  WidgetTester tester, {
  required String type,
  required String statut,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: OrderTracking(
            component: TovoComponent(
              type: 'order_tracking',
              data: {'type': type, 'status': statut},
            ),
            onInteraction: (_) {},
          ),
        ),
      ),
    ),
  );
}

String etapeActive(WidgetTester tester) {
  final active = find.byWidgetPredicate(
    (widget) => widget is Text && widget.style?.color == TovoTheme.teal,
  );
  return tester.widget<Text>(active).data!;
}

void main() {
  testWidgets('un repas en préparation ne se présente pas comme prêt', (
    tester,
  ) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'preparing');

    expect(etapeActive(tester), 'En préparation');
    expect(find.text('La boutique prépare votre commande.'), findsOneWidget);
    expect(find.text('Prête'), findsOneWidget);
  });

  testWidgets('le retrait du repas précède son trajet', (tester) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'picked_up');

    expect(etapeActive(tester), 'Récupérée');
    expect(find.text('Le livreur a récupéré votre commande.'), findsOneWidget);
  });

  testWidgets('le colis possède ses propres étapes', (tester) async {
    await afficherSuivi(tester, type: 'courier', statut: 'assigned');

    expect(etapeActive(tester), 'Livreur trouvé');
    expect(find.text('Livreur trouvé'), findsNWidgets(2));
    expect(find.text('En préparation'), findsNothing);
    expect(find.text('Colis récupéré'), findsOneWidget);
  });

  testWidgets('un colis livré est nommé comme tel', (tester) async {
    await afficherSuivi(tester, type: 'courier', statut: 'delivered');

    expect(find.text('Colis livré'), findsOneWidget);
    expect(etapeActive(tester), 'Livré');
  });

  testWidgets('une commande annulée ne montre pas de progression', (
    tester,
  ) async {
    await afficherSuivi(tester, type: 'delivery', statut: 'cancelled');

    expect(find.text('Annulée'), findsOneWidget);
    expect(find.text('Confirmée'), findsNothing);
  });
}
