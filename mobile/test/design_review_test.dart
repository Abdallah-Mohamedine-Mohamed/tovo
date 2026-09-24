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
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tovo/core/panier.dart';
import 'package:tovo/components/register_all.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/catalog_image.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/catalog_screen.dart';
import 'package:tovo/features/catalog/cart_screen.dart';
import 'package:tovo/features/catalog/product_screen.dart';
import 'package:tovo/features/chat/chat_screen.dart';

class _VisualTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _VisualTestBinding();
  setUp(() => CatalogImage.providerOverride = (url) => NetworkImage(url));
  tearDown(() => CatalogImage.providerOverride = null);
  final fixture =
      jsonDecode(File('test/fixtures/design/catalogue.json').readAsStringSync())
          as Map<String, dynamic>;
  final products = (fixture['products'] as List).cast<Map<String, dynamic>>();
  final merchant = fixture['merchant'] as Map<String, dynamic>;
  final bytes = <String, Uint8List>{
    for (final product in products)
      product['image_url'] as String: File(
        'test/fixtures/design/${product['fixture']}',
      ).readAsBytesSync(),
    merchant['logo_url'] as String: File(
      'test/fixtures/design/logo.webp',
    ).readAsBytesSync(),
  };
  final categories = [
    ('Restaurants', 'restaurants-m3'),
    ('Marché', 'kasuwa-m10'),
    ('Supermarché', 'grocery-m4'),
    ('Beauté & soins', 'beaute-soins'),
    ('Électronique', 'electronique'),
    ('Vêtements', 'vetements'),
    ('Gaz', 'gaz-m12'),
    ('Parapharmacie', 'parapharmacies-m5'),
  ];
  late TovoApi api;
  var conversation = false;
  var liveSearch = false;
  var orderPosts = 0;
  var quoteFails = false;
  var orderBody = <String, dynamic>{};
  final preview = GlobalKey();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/shared_preferences'),
          (call) async => call.method == 'getAll' ? <String, Object>{} : true,
        );
    final loader = FontLoader(TovoTheme.fontFamily);
    for (final weight in [
      'Regular',
      'Medium',
      'SemiBold',
      'Bold',
      'ExtraBold',
    ]) {
      loader.addFont(rootBundle.load('assets/fonts/DMSans-$weight.ttf'));
    }
    await loader.load();
    final previewFont = FontLoader('CupertinoSystemText');
    final systemFonts = Platform.environment['WINDIR'];
    for (final name in ['arial.ttf', 'arialbd.ttf']) {
      final file = File('$systemFonts/Fonts/$name');
      previewFont.addFont(
        file.existsSync()
            ? file.readAsBytes().then((bytes) => ByteData.sublistView(bytes))
            : rootBundle.load(
                'assets/fonts/DMSans-${name == 'arial.ttf' ? 'Regular' : 'Bold'}.ttf',
              ),
      );
    }
    await previewFont.load();
    // La police de l'app client (TovoTheme.policeClient).
    final geist = FontLoader('Geist');
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      geist.addFont(rootBundle.load('assets/fonts/Geist-$g.ttf'));
    }
    await geist.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-only',
      debug: false,
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/image_picker'),
          (_) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          (call) async =>
              call.method == 'isLocationServiceEnabled' ? false : null,
        );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });

  setUp(() {
    // Le panier est partagé par toute l'appli : on repart de zéro.
    PanierEnDirect.instance.vider();
    conversation = false;
    liveSearch = false;
    orderPosts = 0;
    quoteFails = false;
    orderBody = {};
    debugNetworkImageHttpClientProvider = () => _Images(bytes);
    registerTovoComponents();
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        Object body = {};
        if (request.url.path.startsWith('/products/')) {
          final selected = products.firstWhere(
            (product) => request.url.path.endsWith(product['id'] as String),
          );
          return http.Response(
            jsonEncode({
              'components': [
                {
                  'type': 'product_card',
                  'data': {
                    ...selected,
                    'actions': ['add_to_cart'],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        switch (request.url.path) {
          case '/chat':
            if (liveSearch) {
              final component = {
                'type': 'product_carousel',
                'data': {
                  'title': 'Poulet',
                  'items': products.take(3).toList(),
                  'browse': {'merchant_id': 'garba', 'total': 6},
                },
              };
              return http.Response(
                '${jsonEncode({
                  'type': 'results',
                  'components': [component],
                })}\n${jsonEncode({
                  'type': 'done',
                  'content': 'Voici les plats au poulet.',
                  'components': [component],
                  'conversation_id': 'demo',
                })}\n',
                200,
                headers: {'content-type': 'application/x-ndjson'},
              );
            }
            body = {'content': 'Aucun résultat.', 'components': []};
          case '/orders':
            if (request.method == 'POST') {
              orderPosts++;
              orderBody = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({
                  'content': 'Commande enregistrée.',
                  'components': [],
                }),
                201,
              );
            }
            body = {'orders': []};
          case '/addresses':
            body = {
              'addresses': [
                {
                  'id': 'maison',
                  'label': 'Maison',
                  'text_hint': 'Bobiel, porte bleue',
                  'lat': 13.54,
                  'lng': 2.1,
                  'is_default': true,
                },
              ],
            };
          case '/conversations/last':
            body = conversation
                ? {
                    'conversation_id': 'demo',
                    'messages': [
                      {'role': 'user', 'content': 'Je voudrais du garba'},
                      {
                        'role': 'assistant',
                        'content':
                            'Chez **GARBA D’OR**, vous avez le choix. Poulet ou poisson ? Voici un aperçu de la carte.',
                        'components': [
                          {
                            'type': 'product_carousel',
                            'data': {
                              'title': 'Garba d’Or',
                              'items': products.take(3).toList(),
                              'browse': {'merchant_id': 'garba', 'total': 6},
                            },
                          },
                        ],
                      },
                    ],
                  }
                : {'messages': []};
          case '/conversations':
            body = {'conversations': []};
          case '/categories':
            body = {
              'components': [
                {
                  'type': 'category_grid',
                  'data': {
                    'items': [
                      for (final category in categories)
                        {
                          'id': category.$2,
                          'name': category.$1,
                          'slug': category.$2,
                        },
                    ],
                  },
                },
              ],
            };
          case '/cart':
            if (quoteFails && request.url.queryParameters.containsKey('lat')) {
              return http.Response(
                jsonEncode({'error': 'Impossible de calculer la livraison'}),
                503,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            body = {
              'components': [
                {
                  'type': 'cart_summary',
                  'data': {
                    'merchant_name': merchant['name'],
                    'merchant_id': 'garba',
                    'can_checkout': true,
                    'items': [
                      for (final product in products.take(2))
                        {
                          ...product,
                          'item_id': product['id'],
                          'product_name': product['name'],
                          'quantity': 1,
                          'line_total': product['price'],
                        },
                    ],
                    'items_total': 7000,
                    'delivery_fee':
                        request.url.queryParameters.containsKey('lat')
                        ? 500
                        : 0,
                    'total': request.url.queryParameters.containsKey('lat')
                        ? 7500
                        : 7000,
                  },
                },
              ],
            };
          case '/catalog/products':
            body = {
              'items': products,
              'total': 6,
              'next_offset': null,
              'match_type': 'exact',
              'merchant': merchant,
              'categories': [
                {'id': 'plats', 'name': 'Plats', 'produits': 6},
              ],
            };
        }
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> open(
    WidgetTester tester,
    Widget screen, {
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TovoTheme.client(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            textScaler: TextScaler.linear(scale),
          ),
          child: RepaintBoundary(key: preview, child: child!),
        ),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  void visualTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  visualTest('accueil : conversation, suggestions et commandes flottantes', (
    tester,
  ) async {
    await open(tester, ChatScreen(api: api));
    expect(find.text('Essayez quelque chose de nouveau'), findsOneWidget);
    expect(find.text('Trouve-moi un bon repas à Niamey'), findsOneWidget);
    expect(find.byTooltip('Ajouter une photo'), findsOneWidget);
    expect(find.byTooltip('Écrire un message'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await capture(tester, '01-accueil');
    await tester.tap(find.byTooltip('Écrire un message'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await capture(tester, '11-saisie');
    await tester.tapAt(const Offset(200, 260));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Parler à Tovo'), findsOneWidget);
  });

  visualTest('accueil : petits écrans et texte agrandi restent utilisables', (
    tester,
  ) async {
    await open(
      tester,
      ChatScreen(api: api),
      scale: 1.4,
      size: const Size(320, 640),
    );
    expect(find.byTooltip('Parler à Tovo').hitTestable(), findsOneWidget);
    await capture(tester, '12-accueil-accessible');
    expect(tester.takeException(), isNull);
  });

  visualTest('conversation : réponse sans avatar et aperçu lisible', (
    tester,
  ) async {
    conversation = true;
    await open(tester, ChatScreen(api: api));
    expect(find.text('Reprendre où vous en étiez'), findsOneWidget);
    await capture(tester, '13-accueil-historique');
    await tester.tap(find.text('Je voudrais du garba'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Tout voir, 6 produits'), findsOneWidget);
    await capture(tester, '02-conversation');
  });

  visualTest('recherche : résultats intégrés au fil sans changement d’écran', (
    tester,
  ) async {
    liveSearch = true;
    await open(tester, ChatScreen(api: api));
    await tester.tap(find.byTooltip('Écrire un message'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'poulet');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Résultats'), findsNothing);
    expect(
      find.text('Voici les plats au poulet.').hitTestable(),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Attieke poulet'));
    await tester.pumpAndSettle();
    expect(find.text('Attieke poulet').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Retour à la discussion'), findsNothing);
    await capture(tester, '09-resultats-inline');
    await tester.tap(find.text('Attieke poulet'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductScreen), findsOneWidget);
    await capture(tester, '10-fiche-inline');
    await tester.tap(find.byTooltip('Fermer la fiche'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductScreen), findsNothing);
    expect(find.text('Attieke poulet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  visualTest('boutique : vrais produits, catégories et panier', (tester) async {
    await open(tester, CatalogScreen(api: api, merchantId: 'garba'));
    expect(find.text('GARBA D\'OR'), findsOneWidget);
    // Le panier : une icône discrète en haut, plus de grand bandeau en bas.
    expect(find.byTooltip('Voir le panier'), findsOneWidget);
    expect(find.text('Voir mon panier'), findsNothing);
    await capture(tester, '03-boutique');
    await tester.tap(find.byTooltip('Toutes les catégories'));
    await tester.pumpAndSettle();
    expect(find.text('Les catégories'), findsOneWidget);
    await tester.tap(find.text('Plats'));
    await tester.pumpAndSettle();
    expect(find.text('Les catégories'), findsNothing);
  });

  visualTest('produit : photographie réelle et achat sans quitter la carte', (
    tester,
  ) async {
    await open(tester, CatalogScreen(api: api, merchantId: 'garba'));
    await tester.tap(find.text('Attieke demi poulet'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProductScreen), findsOneWidget);
    // Panier déjà commencé : pas de « Commander · prix » qui tairait le total.
    expect(find.text('Ajouter au panier').hitTestable(), findsOneWidget);
    expect(find.textContaining('Commander ·'), findsNothing);
    await capture(tester, '05-produit');
    // Dans le panneau, la photo est une vignette, toujours agrandissable.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Agrandir la photo',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Fermer la photo'));
    await tester.pumpAndSettle();
    // La fiche est un panneau posé sur la carte : on le ferme, la carte
    // n'a jamais été quittée.
    await tester.tap(find.byTooltip('Fermer la fiche'));
    await tester.pumpAndSettle();
    expect(find.text('6 produits'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> checkout(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Mes conversations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mon panier'));
    await tester.pumpAndSettle();
    // Panier et devis sont de vraies requêtes (simulées) : on leur laisse
    // le temps. Aucun geste n'est demandé au client pour avoir le total.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
    }
    await capture(tester, '06-panier');
  }

  /// Le bouton de commande : le seul de l'écran, toujours visible.
  Finder boutonCommander() => find.descendant(
    of: find.byType(CartScreen),
    matching: find.byType(FilledButton),
  );

  visualTest('panier : le total est connu avant la commande, en un geste', (
    tester,
  ) async {
    conversation = true;
    await open(tester, ChatScreen(api: api));
    await checkout(tester);
    // Le total est sur le bouton ET dans le récapitulatif.
    expect(find.text('Commander · ${Money.format(7500)}'), findsOneWidget);
    expect(find.text(Money.format(7500)), findsOneWidget);
    expect(find.text('Bobiel, porte bleue'), findsOneWidget);
    expect(orderPosts, 0);
    await capture(tester, '07-confirmation');
    await tester.tap(boutonCommander());
    await tester.pumpAndSettle();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(orderPosts, 1);
    expect(orderBody['payment_method'], 'cash');
    expect(orderBody['dropoff'], {'lat': 13.54, 'lng': 2.1});
  });

  visualTest('devis indisponible : aucune commande ne part', (tester) async {
    quoteFails = true;
    await open(tester, ChatScreen(api: api));
    await checkout(tester);
    expect(find.textContaining('Commander'), findsNothing);
    expect(orderPosts, 0);
    expect(find.text('Impossible de calculer la livraison'), findsOneWidget);
  });

  visualTest('le client repart sans commander : rien ne part', (tester) async {
    await open(tester, ChatScreen(api: api));
    await checkout(tester);
    // Le total est affiché, le client change d'avis et repart : rien ne
    // part tant qu'il n'a pas appuyé sur « Commander ».
    expect(find.textContaining('Commander ·'), findsOneWidget);
    await tester.tap(find.byTooltip('Retour aux produits'));
    await tester.pumpAndSettle();
    expect(orderPosts, 0);
    expect(find.byType(CartScreen), findsNothing);
  });

  visualTest('planche du parcours enseigne, produit et panier', (tester) async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    Widget frame(String title, Widget screen) => SizedBox(
      width: 390,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: TovoTheme.inkDoux,
              ),
            ),
          ),
          SizedBox(
            width: 390,
            height: 844,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: TovoTheme.client(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: const Size(390, 844),
                    textScaler: TextScaler.noScaling,
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: screen,
              ),
            ),
          ),
        ],
      ),
    );
    await open(
      tester,
      Scaffold(
        backgroundColor: const Color(0xFFF0F2F2),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              frame(
                '01 / LA CARTE DE L’ENSEIGNE',
                CatalogScreen(api: api, merchantId: 'garba'),
              ),
              const SizedBox(width: 24),
              frame(
                '02 / LE PRODUIT',
                ProductScreen(
                  api: api,
                  productId: products[1]['id'] as String,
                  initialProduct: products[1],
                ),
              ),
              const SizedBox(width: 24),
              frame('03 / LE PANIER', CartScreen(api: api)),
            ],
          ),
        ),
      ),
      size: const Size(1266, 928),
    );
    await capture(tester, '08-parcours');
  });

  visualTest('petit écran et texte agrandi restent utilisables', (
    tester,
  ) async {
    await open(
      tester,
      CatalogScreen(api: api, merchantId: 'garba'),
      scale: 1.4,
      size: const Size(360, 780),
    );
    await capture(tester, '04-texte-agrandi');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Images extends Fake implements HttpClient {
  _Images(this.images);
  final Map<String, Uint8List> images;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _ImageRequest(images[url.toString()]!);
}

class _ImageRequest extends Fake implements HttpClientRequest {
  _ImageRequest(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientResponse> close() async => _ImageResponse(bytes);
}

class _ImageResponse extends Fake implements HttpClientResponse {
  _ImageResponse(this.bytes);
  final Uint8List bytes;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
