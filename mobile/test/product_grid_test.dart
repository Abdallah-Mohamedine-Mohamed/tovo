import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/product_carousel.dart';

Map<String, dynamic> produit(
  int i, {
  bool dispo = true,
  bool options = false,
}) => {
  'id': 'p$i',
  'name': 'Produit $i',
  'merchant_name': 'Boutique',
  'price': 1000 + i,
  'is_available': dispo,
  'requires_options': options,
};

Future<List<TovoInteraction>> afficher(
  WidgetTester tester,
  List<Map<String, dynamic>> items, {
  Map<String, dynamic>? browse,
}) async {
  final gestes = <TovoInteraction>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ProductCollection(
            component: TovoComponent(
              type: 'product_carousel',
              data: {'title': 'Résultats', 'items': items, 'browse': ?browse},
            ),
            onInteraction: gestes.add,
            horizontal: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gestes;
}

void main() {
  testWidgets('quatre produits, et « Tout voir » en haut à droite', (
    tester,
  ) async {
    final gestes = await afficher(
      tester,
      [for (var i = 0; i < 6; i++) produit(i)],
      browse: {'query': 'tacos', 'total': 38},
    );

    expect(find.text('Produit 3'), findsOneWidget);
    expect(find.text('Produit 4'), findsNothing);
    expect(find.text('38 produits'), findsOneWidget);
    // Plus de barre « Parcourir » ni de « Voir les autres » en bas.
    expect(find.textContaining('Parcourir'), findsNothing);
    expect(find.textContaining('Voir les'), findsNothing);

    final fleche = find.bySemanticsLabel('Tout voir, 38 produits');
    // À droite du titre, au-dessus du premier produit.
    expect(
      tester.getCenter(fleche).dy,
      lessThan(tester.getTopLeft(find.text('Produit 0')).dy),
    );
    expect(
      tester.getCenter(fleche).dx,
      greaterThan(tester.getCenter(find.text('Résultats')).dx),
    );
    await tester.tap(fleche);
    expect(gestes.single.action, 'browse_catalog');
    expect(gestes.single.payload['query'], 'tacos');
    expect(tester.takeException(), isNull);
  });

  testWidgets('sans catalogue derrière, la suite se déplie sur place', (
    tester,
  ) async {
    await afficher(tester, [for (var i = 0; i < 6; i++) produit(i)]);
    expect(find.bySemanticsLabel(RegExp('Tout voir')), findsNothing);
    await tester.ensureVisible(find.text('Voir les 2 autres'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voir les 2 autres'));
    await tester.pumpAndSettle();
    expect(find.text('Produit 5', skipOffstage: false), findsOneWidget);
  });

  testWidgets('« + » ajoute sans ouvrir la fiche, sauf produit à options', (
    tester,
  ) async {
    final gestes = await afficher(tester, [
      produit(1),
      produit(2, options: true),
    ]);

    await tester.tap(find.byTooltip('Ajouter Produit 1'));
    expect(gestes.last.action, 'add_to_cart');
    expect(gestes.last.payload['product_id'], 'p1');

    await tester.tap(find.byTooltip('Ajouter Produit 2'));
    expect(gestes.last.action, 'select_product');
  });

  testWidgets('les indisponibles passent en dernier, sans « + »', (
    tester,
  ) async {
    await afficher(tester, [produit(1, dispo: false), produit(2), produit(3)]);

    final x1 = tester.getTopLeft(find.text('Produit 1'));
    final x2 = tester.getTopLeft(find.text('Produit 2'));
    // Produit 2 prend la première place, Produit 1 passe à la ligne.
    expect(x1.dy, greaterThan(x2.dy));
    expect(find.byTooltip('Ajouter Produit 1'), findsNothing);
    expect(find.text('Indisponible pour le moment'), findsOneWidget);
  });

  testWidgets('texte agrandi sur petit écran : pas de débordement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(1.4),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ProductCollection(
                component: TovoComponent(
                  type: 'product_carousel',
                  data: {
                    'items': [
                      for (var i = 0; i < 4; i++)
                        {
                          ...produit(i, options: true),
                          'name': 'Un nom de plat particulièrement long $i',
                        },
                    ],
                  },
                ),
                onInteraction: (_) {},
                horizontal: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // Demande du client (25/09) : on parcourt souvent tard, boutiques fermées.
  testWidgets(
    'boutique fermée : ni voile, ni « Boutique fermée », « + » présent',
    (tester) async {
      await afficher(tester, [
        {...produit(1), 'merchant_open': false},
        produit(2, options: true),
      ]);
      expect(find.text('Boutique fermée'), findsNothing);
      expect(find.text('À personnaliser'), findsNothing);
      expect(find.byTooltip('Ajouter Produit 1'), findsOneWidget);
      final voiles = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .where((o) => o.opacity < 1 && o.opacity > 0);
      expect(voiles, isEmpty);
    },
  );

  testWidgets('un article indisponible reste en retrait, sans « + »', (
    tester,
  ) async {
    await afficher(tester, [produit(1, dispo: false)]);
    expect(find.text('Indisponible pour le moment'), findsOneWidget);
    expect(find.byTooltip('Ajouter Produit 1'), findsNothing);
  });
}
