import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
          body: Center(
            child: PastillePanier(onTap: () => gestes.add('ouvrir')),
          ),
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
      TovoResponse.success(
        content: 'Bonjour',
        components: const [],
        raw: const {},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 · ${Money.format(7000)}'), findsOneWidget);
  });

  // Le bug vu sur téléphone : panier vidé, la pastille gardait l'article.
  // Le serveur ne renvoie aucun panier quand il est vide.
  testWidgets(
    'disparaît quand le dernier article est retiré ou le panier vidé',
    (tester) async {
      final api = TovoApi(
        tokenProvider: () => null,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'content': 'Votre panier est vide.', 'components': []}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await afficher(tester);
      for (final retirer in [
        () => api.delete('/cart/items/a'),
        () => api.patch('/cart/items/a', {'quantity': 0}),
        () => api.delete('/cart'),
      ]) {
        PanierEnDirect.instance.observer(reponseAvecPanier(1));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Voir le panier'), findsOneWidget);
        await tester.runAsync(retirer);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Voir le panier'), findsNothing);
      }
    },
  );
}
