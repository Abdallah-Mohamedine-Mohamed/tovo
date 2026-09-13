import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tovo/components/register_all.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/product_carousel.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/catalog_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    final fonts = FontLoader(TovoTheme.fontFamily);
    for (final weight in [
      'Regular',
      'Medium',
      'SemiBold',
      'Bold',
      'ExtraBold',
    ]) {
      fonts.addFont(rootBundle.load('assets/fonts/DMSans-$weight.ttf'));
    }
    await fonts.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  final requests = <Uri>[];
  var cart = false;
  var failNextPage = false;
  Completer<http.Response>? delayed;
  late TovoApi api;
  final previewKey = GlobalKey();

  http.Response jsonResponse(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Map<String, dynamic> product(int index) => {
    'id': 'product-$index',
    'name': 'Poulet grillé $index',
    'price': 2500,
    'merchant_id': 'centre',
    'merchant_name': "O’Takoss Centre Aéré",
    'is_available': true,
  };

  setUp(() {
    requests.clear();
    cart = false;
    failNextPage = false;
    delayed = null;
    registerTovoComponents();
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        requests.add(request.url);
        if (request.url.path == '/cart') {
          return jsonResponse({
            'components': [
              {
                'type': 'cart_summary',
                'data': {
                  'items': cart ? [product(0)] : [],
                  'total': cart ? 2500 : 0,
                },
              },
            ],
          });
        }
        if (request.url.path == '/cart/items') {
          cart = true;
          return jsonResponse({'content': 'Ajouté'});
        }
        if (request.url.path.startsWith('/products/')) {
          return jsonResponse({
            'components': [
              {
                'type': 'product_card',
                'data': {
                  ...product(0),
                  'actions': ['add_to_cart'],
                },
              },
            ],
          });
        }
        final query = request.url.queryParameters;
        final offset = int.tryParse(query['offset'] ?? '') ?? 0;
        if (query['q'] == 'ancien' && delayed != null) return delayed!.future;
        if (offset > 0 && failNextPage) {
          failNextPage = false;
          return jsonResponse({'error': 'Chargement interrompu'}, 500);
        }
        final filtered =
            query['category_id'] != null || (query['q'] ?? '').isNotEmpty;
        final total = filtered ? 2 : 53;
        final count = (total - offset).clamp(0, 24);
        return jsonResponse({
          'items': List.generate(count, (index) => product(offset + index)),
          'total': total,
          'offset': offset,
          'next_offset': offset + count < total ? offset + count : null,
          'match_type': 'exact',
          'merchant': {
            'id': 'centre',
            'name': "O’Takoss Centre Aéré",
            'is_open': true,
            'address_hint': 'Centre Aéré, Niamey',
          },
          'categories': [
            {'id': 'tacos', 'name': 'Tacos', 'produits': 38},
            {'id': 'boissons', 'name': 'Boissons', 'produits': 15},
          ],
        });
      }),
    );
  });

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    tester.view.physicalSize = const Size(390, 844);
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
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('Discussion conservée'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RepaintBoundary(
                    key: previewKey,
                    child: CatalogScreen(api: api, merchantId: 'centre'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Discussion conservée'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'les catégories filtrent sur place et retour retrouve la discussion',
    (tester) async {
      await open(tester, scale: 1.3);
      expect(find.text('53 produits'), findsOneWidget);
      await tester.tap(find.byTooltip('Toutes les catégories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Boissons'));
      await tester.pumpAndSettle();
      expect(
        requests.last.queryParameters,
        containsPair('merchant_id', 'centre'),
      );
      expect(
        requests.last.queryParameters,
        containsPair('category_id', 'boissons'),
      );
      expect(requests.last.queryParameters, containsPair('offset', '0'));
      expect(find.text('2 produits'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Retour'));
      await tester.pumpAndSettle();
      expect(find.text('Discussion conservée'), findsOneWidget);
    },
  );

  testWidgets('toutes les pages sont accessibles avec reprise après échec', (
    tester,
  ) async {
    await open(tester);
    failNextPage = true;
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    for (
      var attempt = 0;
      attempt < 12 &&
          !requests.any((uri) => uri.queryParameters['offset'] == '24');
      attempt++
    ) {
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(find.text('Chargement interrompu'), findsOneWidget);
    await tester.ensureVisible(find.text('Réessayer'));
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    for (
      var attempt = 0;
      attempt < 12 &&
          !requests.any((uri) => uri.queryParameters['offset'] == '48');
      attempt++
    ) {
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(
      requests.any((uri) => uri.queryParameters['offset'] == '48'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'une réponse ancienne ne remplace pas la catégorie choisie ensuite',
    (tester) async {
      await open(tester);
      delayed = Completer<http.Response>();
      await tester.enterText(find.byType(TextField), 'ancien');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), 'nouveau');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      delayed!.complete(
        jsonResponse({
          'items': [product(99)],
          'total': 99,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 produits'), findsOneWidget);
      expect(find.text('99 produits'), findsNothing);
    },
  );

  testWidgets('le détail et ajout au panier restent dans le catalogue', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Poulet grillé 0'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Retour à la carte'), findsOneWidget);
    await tester.tap(find.text('Ajouter au panier'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Retour à la carte'), findsNothing);
    expect(find.text('Voir mon panier'), findsOneWidget);
    expect(find.text('53 produits'), findsOneWidget);
  });

  testWidgets('aperçu ouvre le catalogue en conservant tous ses filtres', (
    tester,
  ) async {
    TovoInteraction? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProductCollection(
            component: TovoComponent(
              type: 'product_carousel',
              data: {
                'title': 'Poulet',
                'items': [product(0)],
                'browse': {
                  'query': 'poulet',
                  'total': 76,
                  'merchant_ids': ['centre'],
                  'category_id': 'tacos',
                },
              },
            ),
            onInteraction: (interaction) => selected = interaction,
            horizontal: true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Parcourir les 76 produits'));
    expect(selected?.action, 'browse_catalog');
    expect(selected?.payload['merchant_ids'], ['centre']);
    expect(selected?.payload['query'], 'poulet');
  });

  testWidgets('aperçu visuel du catalogue sur petit écran', (tester) async {
    await open(tester);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) {
      await tester.runAsync(() async {
        final boundary =
            previewKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'build/catalog-preview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
