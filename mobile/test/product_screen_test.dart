import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/product_screen.dart';

void main() {
  final requests = <http.Request>[];
  late TovoApi api;
  var detailFailure = false;
  var conflict = false;
  var unavailable = false;
  var withOptions = true;
  Completer<http.Response>? pendingAdd;

  http.Response response(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  setUp(() {
    requests.clear();
    detailFailure = false;
    conflict = false;
    unavailable = false;
    withOptions = true;
    pendingAdd = null;
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/cart/items') {
          if (conflict) {
            return response({
              'error':
                  'Votre panier contient les articles d’une autre boutique.',
            }, 409);
          }
          if (pendingAdd != null) return pendingAdd!.future;
          return response({'content': 'Ajouté'});
        }
        if (request.method == 'DELETE') {
          conflict = false;
          return response({});
        }
        if (detailFailure) {
          return response({'error': 'Produit introuvable'}, 404);
        }
        return response({
          'components': [
            if (!withOptions)
              {
                'type': 'product_card',
                'data': {
                  'id': 'produit',
                  'name': 'Un plat',
                  'price': 2500,
                  'is_available': !unavailable,
                  'actions': ['add_to_cart'],
                },
              }
            else
              {
                'type': 'option_selector',
                'data': {
                  'product_id': 'produit',
                  'product_name': 'Un plat à personnaliser',
                  'base_price': 2500,
                  'options': [
                    {
                      'id': 'viande',
                      'name': 'Votre viande',
                      'required': true,
                      'min_select': 1,
                      'max_select': 1,
                      'values': [
                        {
                          'id': 'boulette',
                          'name': 'Boulettes',
                          'price_delta': 600,
                          'available': true,
                        },
                        {
                          'id': 'poulet',
                          'name': 'Poulet',
                          'price_delta': 0,
                          'available': true,
                        },
                        {
                          'id': 'merguez',
                          'name': 'Merguez',
                          'price_delta': 500,
                          'available': false,
                        },
                      ],
                    },
                    {
                      'id': 'sauce',
                      'name': 'Vos sauces',
                      'required': false,
                      'min_select': 0,
                      'max_select': 2,
                      'values': [
                        {
                          'id': 'mayo',
                          'name': 'Mayonnaise',
                          'price_delta': 0,
                          'available': true,
                        },
                        {
                          'id': 'ketchup',
                          'name': 'Ketchup',
                          'price_delta': 0,
                          'available': true,
                        },
                        {
                          'id': 'barbecue',
                          'name': 'Barbecue',
                          'price_delta': 0,
                          'available': true,
                        },
                      ],
                    },
                  ],
                },
              },
          ],
        });
      }),
    );
  });

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: TovoTheme.client(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProductScreen(api: api, productId: 'produit'),
                ),
              ),
              child: const Text('Ouvrir le produit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir le produit'));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pump();
    await tester.tap(find.text(text));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'options obligatoires, indisponibilité, remplacement et prix exact',
    (tester) async {
      await open(tester);
      FilledButton addButton() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Ajouter au panier'),
      );
      expect(addButton().onPressed, isNull);
      await tap(tester, 'Merguez');
      expect(addButton().onPressed, isNull);
      await tap(tester, 'Poulet');
      await tap(tester, 'Boulettes');
      expect(addButton().onPressed, isNotNull);
      await tester.tap(find.byTooltip('Augmenter la quantité'));
      await tester.pumpAndSettle();
      expect(find.text(Money.format(6200)), findsOneWidget);
      await tester.tap(find.text('Ajouter au panier'));
      await tester.pumpAndSettle();
      final body = jsonDecode(requests.last.body);
      expect(body['quantity'], 2);
      expect(body['selections'], [
        {
          'option_id': 'viande',
          'value_ids': ['boulette'],
        },
      ]);
      expect(find.byType(ProductScreen), findsNothing);
    },
  );

  testWidgets(
    'choix multiples limités, texte agrandi et bouton toujours accessible',
    (tester) async {
      await open(tester, scale: 1.5);
      await tap(tester, 'Boulettes');
      await tap(tester, 'Mayonnaise');
      await tap(tester, 'Ketchup');
      await tap(tester, 'Barbecue');
      expect(find.text('Ajouter au panier').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Ajouter au panier'));
      await tester.pumpAndSettle();
      final body = jsonDecode(requests.last.body);
      expect((body['selections'] as List).last['value_ids'], [
        'mayo',
        'ketchup',
      ]);
    },
  );

  testWidgets(
    'conflit : conserver ne supprime rien et remplacer exige confirmation',
    (tester) async {
      withOptions = false;
      conflict = true;
      await open(tester);
      await tap(tester, 'Ajouter au panier');
      await tap(tester, 'Garder mon panier');
      expect(requests.where((request) => request.method == 'DELETE'), isEmpty);
      expect(find.byType(ProductScreen), findsOneWidget);
      await tap(tester, 'Ajouter au panier');
      await tap(tester, 'Remplacer le panier');
      expect(
        requests.where((request) => request.method == 'DELETE'),
        hasLength(1),
      );
      expect(find.byType(ProductScreen), findsNothing);
    },
  );

  testWidgets(
    'ajout en attente : pas de double envoi ni fermeture prématurée',
    (tester) async {
      withOptions = false;
      pendingAdd = Completer<http.Response>();
      await open(tester);
      await tester.tap(find.text('Ajouter au panier'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Retour à la carte',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        requests.where((request) => request.url.path == '/cart/items'),
        hasLength(1),
      );
      pendingAdd!.complete(response({'error': 'Réessayez'}, 503));
      await tester.pumpAndSettle();
      expect(find.text('Réessayez'), findsOneWidget);
      expect(find.byType(ProductScreen), findsOneWidget);
    },
  );

  testWidgets('chargement échoué puis reprise et produit indisponible', (
    tester,
  ) async {
    detailFailure = true;
    await open(tester);
    expect(find.text('Produit introuvable'), findsOneWidget);
    detailFailure = false;
    withOptions = false;
    unavailable = true;
    await tap(tester, 'Réessayer');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Indisponible'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
