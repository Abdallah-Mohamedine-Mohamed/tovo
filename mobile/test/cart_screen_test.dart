import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tovo/core/panier.dart';
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
  var quoteFails = false;
  Completer<http.Response>? pendingPatch;
  Completer<http.Response>? pendingQuote;
  final requests = <http.Request>[];
  late TovoApi api;

  /// Le panier tel que le serveur le renvoie ; avec une position, il porte
  /// les frais de livraison (600 F), comme le vrai.
  http.Response cart({bool devis = false}) => http.Response(
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
                  'delivery_fee': devis ? 600 : 0,
                  'total': quantity * 3100 + (devis ? 600 : 0),
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
    // Le panier est partagé par toute l'appli : on repart de zéro.
    PanierEnDirect.instance.vider();
    quantity = 1;
    blocked = false;
    failure = false;
    quoteFails = false;
    pendingPatch = null;
    pendingQuote = null;
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
          if (pendingQuote != null) return pendingQuote!.future;
          if (quoteFails) {
            return http.Response(
              '{"error":"Impossible de calculer la livraison"}',
              503,
            );
          }
          return cart(devis: true);
        }
        if (request.method == 'PATCH') {
          if (pendingPatch != null) return pendingPatch!.future;
          final corps = jsonDecode(request.body) as Map<String, dynamic>;
          quantity = corps['quantity'] as int;
          return cart(devis: corps.containsKey('lat'));
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

  FilledButton bouton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  // Pendant le fondu d'un libellé à l'autre, l'ancien et le nouveau
  // coexistent : le nouveau est le dernier.
  String libelle(WidgetTester tester) =>
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(FilledButton),
                  matching: find.byType(Text),
                )
                .last,
          )
          .data ??
      '';

  TovoComponent apercu() => TovoComponent.fromJson(
    (jsonDecode(cart().body) as Map<String, dynamic>)['components'][0]
        as Map<String, dynamic>,
  );

  testWidgets(
    'le panier de la discussion s’affiche aussitôt ; on ne commande qu’une fois le total connu',
    (tester) async {
      pendingQuote = Completer<http.Response>();
      await open(tester, initialCart: apercu(), settle: false);
      await tester.pump();
      // Rien à attendre pour VOIR : les articles sont là tout de suite.
      expect(find.text('Tacos aux boulettes'), findsOneWidget);
      expect(find.text('Yantala, maison bleue'), findsOneWidget);
      // Le total se calcule : le bouton le dit, sans « 0 F » trompeur.
      expect(libelle(tester), 'Calcul du total…');
      expect(bouton(tester).onPressed, isNull);
      expect(find.text(Money.format(0)), findsNothing);

      pendingQuote!.complete(cart(devis: true));
      await tester.pumpAndSettle();
      expect(libelle(tester), 'Commander · ${Money.format(3700)}');
      expect(bouton(tester).onPressed, isNotNull);
    },
  );

  testWidgets('un seul geste : le prix est sur le bouton, la commande part', (
    tester,
  ) async {
    await open(tester);
    // Un seul devis : panier ET livraison dans la même requête.
    expect(
      requests.where(
        (r) => r.url.path == '/cart' && r.url.queryParameters['lat'] != null,
      ),
      hasLength(1),
    );
    expect(find.text(Money.format(600)), findsOneWidget);
    expect(libelle(tester), 'Commander · ${Money.format(3700)}');
    expect(requests.where((r) => r.url.path == '/orders'), isEmpty);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    final commandes = requests.where((r) => r.url.path == '/orders').toList();
    expect(commandes, hasLength(1));
    final corps = jsonDecode(commandes.single.body) as Map<String, dynamic>;
    expect(corps['dropoff_hint'], 'Yantala, maison bleue');
    expect(corps['payment_method'], 'cash');
  });

  testWidgets('le paiement se choisit d’un geste, sans liste à cocher', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await open(tester);
    await tester.tap(find.text('Nita'));
    await tester.pumpAndSettle();
    // Aucun numéro nigérien connu : Nita ne pourrait pas être réglé, la
    // commande attend le numéro.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.url.path == '/orders'), isEmpty);
    expect(find.text('Indiquez le numéro Nita qui paiera.'), findsOneWidget);

    // Le champ est plus bas dans le panier : on y descend.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('numero-nita')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const ValueKey('numero-nita')),
      '90123456',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    final corps =
        jsonDecode(requests.singleWhere((r) => r.url.path == '/orders').body)
            as Map<String, dynamic>;
    expect(corps['payment_method'], 'mobile_money');
    expect(corps['payment_phone'], '90123456');
  });

  testWidgets(
    'la quantité change aussitôt, et la livraison est recalculée avec',
    (tester) async {
      await open(tester, scale: 1.4);
      pendingPatch = Completer<http.Response>();
      await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
      await tester.pump();
      // Affiché sans attendre le serveur…
      expect(find.text('2'), findsOneWidget);
      expect(find.text(Money.format(6200)), findsWidgets);
      // … et un second appui pendant l'envoi ne crée pas de doublon.
      await tester.tap(
        find.byTooltip('Ajouter un Tacos aux boulettes'),
        warnIfMissed: false,
      );
      final envois = requests.where((r) => r.method == 'PATCH').toList();
      expect(envois, hasLength(1));
      // La position part avec la quantité : un seul aller-retour.
      expect(
        (jsonDecode(envois.single.body) as Map<String, dynamic>)['lat'],
        13.5,
      );
      quantity = 2;
      pendingPatch!.complete(cart(devis: true));
      await tester.pumpAndSettle();
      expect(libelle(tester), 'Commander · ${Money.format(6800)}');
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
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('boutique fermée : raison lisible au-dessus du bouton, bloqué', (
    tester,
  ) async {
    blocked = true;
    await open(tester);
    expect(find.text('La boutique est fermée'), findsOneWidget);
    expect(bouton(tester).onPressed, isNull);
  });

  testWidgets(
    'échec d’une quantité : on revient au panier connu, sans impasse',
    (tester) async {
      await open(tester);
      failure = true;
      await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
      await tester.pumpAndSettle();
      // L'erreur s'affiche près des articles, et le panier redevient celui
      // que le serveur connaît : quantité 1, toujours commandable.
      expect(find.text('Hors ligne'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(bouton(tester).onPressed, isNotNull);
      failure = false;
      await tester.tap(find.byTooltip('Ajouter un Tacos aux boulettes'));
      await tester.pumpAndSettle();
      expect(quantity, 2);
      expect(find.text('Hors ligne'), findsNothing);
    },
  );

  testWidgets('devis impossible : message au-dessus du bouton, qui réessaie', (
    tester,
  ) async {
    quoteFails = true;
    await open(tester, initialCart: apercu());
    expect(find.text('Impossible de calculer la livraison'), findsOneWidget);
    expect(libelle(tester), 'Réessayer');
    expect(requests.where((r) => r.url.path == '/orders'), isEmpty);

    quoteFails = false;
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('Impossible de calculer la livraison'), findsNothing);
    expect(libelle(tester), 'Commander · ${Money.format(3700)}');
  });

  testWidgets('changer d’adresse : une feuille, un geste, le total suit', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Changer'));
    await tester.pumpAndSettle();
    expect(find.text('Où livrer ?'), findsOneWidget);
    expect(find.text('Ma position actuelle'), findsOneWidget);
    await tester.tap(find.text('Yantala, maison bleue').last);
    await tester.pumpAndSettle();
    expect(find.text('Où livrer ?'), findsNothing);
    expect(libelle(tester), 'Commander · ${Money.format(3700)}');
  });
}
