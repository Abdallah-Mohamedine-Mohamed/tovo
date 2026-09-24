import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/pastille_panier.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/panier.dart';

TovoResponse reponseAvecPanier(int quantite, {int prix = 3500}) =>
    TovoResponse.success(
      content: 'Ajouté à votre panier.',
      components: [
        TovoComponent(
          type: 'cart_summary',
          data: {
            'merchant_name': 'GARBA D’OR',
            'items': [
              {'item_id': 'a', 'product_name': 'Attiéké', 'quantity': quantite},
            ],
            'items_total': quantite * prix,
          },
        ),
      ],
      raw: const {},
    );

void main() {
  setUp(PanierEnDirect.instance.vider);

  Future<List<String>> afficher(WidgetTester tester) async {
    final gestes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: PastillePanier(onTap: () => gestes.add('ouvrir'))),
        ),
      ),
    );
    return gestes;
  }

  testWidgets('invisible tant que le panier est vide', (tester) async {
    await afficher(tester);
    expect(find.byTooltip('Voir le panier'), findsNothing);
  });

  testWidgets('apparaît dès le premier ajout, d’où qu’il vienne', (
    tester,
  ) async {
    final gestes = await afficher(tester);
    // Une réponse du serveur contenant un panier suffit.
    PanierEnDirect.instance.observer(reponseAvecPanier(2));
    await tester.pumpAndSettle();
    expect(find.text('2 · ${Money.format(7000)}'), findsOneWidget);

    await tester.tap(find.byTooltip('Voir le panier'));
    expect(gestes, ['ouvrir']);
  });

  testWidgets('suit les quantités, puis disparaît quand tout est retiré', (
    tester,
  ) async {
    await afficher(tester);
    PanierEnDirect.instance.observer(reponseAvecPanier(1));
    await tester.pumpAndSettle();
    PanierEnDirect.instance.observer(reponseAvecPanier(3));
    await tester.pumpAndSettle();
    expect(find.text('3 · ${Money.format(10500)}'), findsOneWidget);

    PanierEnDirect.instance.vider();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Voir le panier'), findsNothing);
  });

  testWidgets('une réponse sans panier ne touche pas à la pastille', (
    tester,
  ) async {
    await afficher(tester);
    PanierEnDirect.instance.observer(reponseAvecPanier(2));
    await tester.pumpAndSettle();
    PanierEnDirect.instance.observer(
      TovoResponse.success(content: 'Bonjour', components: const [], raw: const {}),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 · ${Money.format(7000)}'), findsOneWidget);
  });
}
