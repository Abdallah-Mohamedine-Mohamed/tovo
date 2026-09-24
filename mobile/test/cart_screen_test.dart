import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/cart_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader(TovoTheme.fontFamily);
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/fonts/DMSans-$weight.ttf'));
    }
    await fonts.load();
  });
  var quantity = 1;
  var blocked = false;
  var failure = false;
  Completer<http.Response>? pending;
  Completer<http.Response>? pendingCart;
  final requests = <http.Request>[];
  late TovoApi api;

  http.Response cart() => http.Response(
    jsonEncode({
      'components': quantity == 0
          ? []
          : [
              {
                'type': 'cart_summary',
                'data': {
                  'merchant_name': 'Restaurant de test',
                  'items': [
                    {
                      'item_id': 'ligne',
                      'product_name': 'Tacos aux boulettes',
                      'selections_label': 'Boulettes, sauce blanche',
                      'quantity': quantity,
                      'line_total': quantity * 3100,
                    },
                  ],
                  'items_total': quantity * 3100,
                  'delivery_fee': 0,
                  'total': quantity * 3100,
                  'can_checkout': !blocked,
                  'blocked_reason': blocked ? 'La boutique est fermée' : null,
                },
              },
            ],
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  setUp(() {
    quantity = 1;
    blocked = false;
    failure = false;
    pending = null;
    pendingCart = null;
    requests.clear();
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        requests.add(request);
        if (failure) return http.Response('{"error":"Hors ligne"}', 503);
        if (request.url.path == '/addresses') {
          return http.Response(
            jsonEncode({
              'addresses': [
                {
                  'id': 'maison',
                  'label': 'Maison',
                  'text_hint': 'Yantala, maison bleue',
                  'lat': 13.5,
                  'lng': 2.1,
                  'is_default': true,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/orders' && request.method == 'POST') {
          return http.Response(
            jsonEncode({'content': 'Commande enregistrée.', 'components': []}),
            201,
          );
        }
        if (request.url.path == '/cart' &&
            request.url.queryParameters.containsKey('lat')) {
          final data = jsonDecode(cart().body) as Map<String, dynamic>;
          final summary =
              (data['components'] as List).first['data']
                  as Map<String, dynamic>;
          summary['delivery_fee'] = 600;
          summary['total'] = quantity * 3100 + 600;
          return http.Response(jsonEncode(data), 200);
        }
        if (request.url.path == '/cart' &&
            request.method == 'GET' &&
            pendingCart != null) {
          return pendingCart!.future;
        }
        if (request.method == 'PATCH') {
          if (pending != null) return pending!.future;
          quantity = jsonDecode(request.body)['quantity'] as int;
        }
        if (request.method == 'DELETE') quantity = 0;
        return cart();
      }),
    );
  });

  Future<void> open(
    WidgetTester tester, {
    double scale = 1,
    TovoComponent? initialCart,
    bool settle = true,
  }) async {
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
        home: CartScreen(api: api, initialCart: initialCart),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> montrerBouton(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets(
    'panier visible immédiatement mais commande bloquée jusqu’à vérification',
    (tester) async {
      pendingCart = Completer<http.Response>();
      final preview = TovoComponent.fromJson(
        (jsonDecode(cart().body) as Map<String, dynamic>)['components'][0]
            as Map<String, dynamic>,
      );
      await open(tester, initialCart: preview, settle: false);
      expect(find.text('Tacos aux boulettes'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await montrerBouton(tester, 'Voir le total avec livraison');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Voir le total avec livraison'),
            )
            .onPressed,
        isNull,
      );

      pendingCart!.complete(cart());
      await tester.pumpAndSettle();
      await montrerBouton(tester, 'Voir le total avec livraison');
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Voir le total avec livraison'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'adresse, prix vérifié et confirmation restent dans un seul flux',
    (tester) async {
      await open(tester);
      await tester.scrollUntilVisible(
        find.text('Livrer à'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Livrer à'), findsOneWidget);
      expect(find.text('Maison'), findsOneWidget);
      expect(
        requests.where((request) => request.url.path == '/orders'),
        isEmpty,
      );

      await tester.scrollUntilVisible(
        find.text('Voir le total avec livraison'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Voir le total avec livraison'));
      await tester.pumpAndSettle();
      expect(find.text('Total avant confirmation'), findsOneWidget);
      expect(find.text(Money.format(600)), findsOneWidget);
      expect(
        requests.where((request) => request.url.path == '/orders'),
        isEmpty,
      );

      await tester.scrollUntilVisible(
        find.text('Confirmer la commande'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Confirmer la commande'));
      await tester.pumpAndSettle();
      final orders = requests
          .where((request) => request.url.path == '/orders')
          .toList();
      expect(orders, hasLength(1));
      final body = jsonDecode(orders.single.body) as Map<String, dynamic>;
      expect(body['dropoff_hint'], 'Yantala, maison bleue');
      expect(body['payment_method'], 'cash');
    },
  );
  testWidgets(
    'quantité et prix serveur, livraison jamais présentée comme gratuite',
    (tester) async {
      await open(tester, scale: 1.4);
      // En grande police, le total est sous la ligne de flottaison.
      await tester.scrollUntilVisible(
        find.text('À calculer'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('À calculer'), findsOneWidget);
      expect(find.text(Money.format(0)), findsNothing);
      await tester.ensureVisible(
        find.byTooltip('Ajouter un Tacos aux boulettes'),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
      await tester.pumpAndSettle();
      expect(find.text(Money.format(6200)), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('supprimer le dernier article donne un vrai état vide', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Retirer Tacos aux boulettes'));
    await tester.pumpAndSettle();
    expect(find.text('Votre panier est encore vide.'), findsOneWidget);
    expect(find.text('Voir le total avec livraison'), findsNothing);
  });

  testWidgets('boutique fermée : livraison bloquée avec raison lisible', (
    tester,
  ) async {
    blocked = true;
    await open(tester);
    expect(find.text('La boutique est fermée'), findsOneWidget);
    await montrerBouton(tester, 'Voir le total avec livraison');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Voir le total avec livraison'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('échec : le panier serveur reste utilisable, pas de cul-de-sac', (
    tester,
  ) async {
    await open(tester);
    failure = true;
    await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
    await tester.pumpAndSettle();
    expect(find.text('Hors ligne'), findsOneWidget);
    // Le panier affiché est le dernier validé par le serveur (quantité 1) :
    // on peut continuer, le serveur revérifie tout à la commande.
    expect(quantity, 1);
    await montrerBouton(tester, 'Voir le total avec livraison');
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Voir le total avec livraison'),
          )
          .onPressed,
      isNotNull,
    );
    // Rien à « réessayer » : le panier est là. Un nouvel appui suffit.
    expect(find.text('Réessayer'), findsNothing);
    failure = false;
    await tester.ensureVisible(
      find.byTooltip('Ajouter un Tacos aux boulettes'),
    );
    await tester.drag(find.byType(ListView), const Offset(0, 180));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
    await tester.pumpAndSettle();
    expect(quantity, 2);
    expect(find.text('Hors ligne'), findsNothing);
  });

  testWidgets('réseau lent : pas de doublon ni total optimiste', (
    tester,
  ) async {
    await open(tester);
    pending = Completer<http.Response>();
    await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
    await tester.pump();
    await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
    expect(
      requests.where((request) => request.method == 'PATCH'),
      hasLength(1),
    );
    expect(find.text(Money.format(6200)), findsNothing);
    quantity = 2;
    pending!.complete(cart());
    await tester.pumpAndSettle();
    expect(find.text(Money.format(6200)), findsNWidgets(2));
  });
}
