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
import 'package:tovo/core/api.dart';
import 'package:tovo/core/catalog_image.dart';
import 'package:tovo/core/noms.dart';
import 'package:tovo/core/panier.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/boutique_screen.dart';
import 'package:tovo/features/catalog/catalog_screen.dart';
import 'package:tovo/features/catalog/categorie_screen.dart';

/// La page Restaurants, sur de vraies boutiques (base de dev, 24/09 : huit
/// des trente-quatre, dont deux fermées, avec leurs photos).
///
///   flutter test test/categorie_screen_test.dart \
///     --dart-define=TOVO_RENDER_PREVIEW=true
class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _Binding();
  final fixture =
      jsonDecode(
            File('test/fixtures/categorie/restaurants.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final boutiques = (fixture['merchants'] as List).cast<Map<String, dynamic>>();
  final images = {
    for (final e in (fixture['images'] as Map<String, dynamic>).entries)
      e.key: File('test/fixtures/categorie/${e.value}').readAsBytesSync(),
  };
  final apercu = GlobalKey();
  late TovoApi api;
  var modeProduits = false;

  setUpAll(() async {
    final polices = FontLoader(TovoTheme.fontFamily);
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      polices.addFont(rootBundle.load('assets/fonts/DMSans-$g.ttf'));
    }
    await polices.load();
    final systeme = FontLoader('CupertinoSystemText');
    for (final nom in ['arial.ttf', 'arialbd.ttf']) {
      final fichier = File('${Platform.environment['WINDIR']}/Fonts/$nom');
      systeme.addFont(
        fichier.existsSync()
            ? fichier.readAsBytes().then(ByteData.sublistView)
            : rootBundle.load(
                'assets/fonts/DMSans-${nom == 'arial.ttf' ? 'Regular' : 'Bold'}.ttf',
              ),
      );
    }
    await systeme.load();
    // La police de l'app client (TovoTheme.policeClient).
    final geist = FontLoader('Geist');
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      geist.addFont(rootBundle.load('assets/fonts/Geist-$g.ttf'));
    }
    await geist.load();
    final icones = FontLoader('MaterialIcons');
    icones.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icones.load();
  });

  setUp(() {
    PanierEnDirect.instance.vider();
    modeProduits = false;
    CatalogImage.providerOverride = (url) => NetworkImage(url);
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        Object corps = {'items': [], 'total': 0};
        if (request.url.path.endsWith('/boutiques')) {
          corps = modeProduits
              ? {
                  'category': fixture['category'],
                  'mode': 'products',
                  'merchants': [],
                  'rayons': [],
                }
              : fixture;
        }
        return http.Response(
          jsonEncode(corps),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });
  tearDown(() => CatalogImage.providerOverride = null);

  void testVisuel(String nom, Future<void> Function(WidgetTester) corps) {
    testWidgets(nom, (tester) async {
      debugNetworkImageHttpClientProvider = () => _Images(images);
      try {
        await corps(tester);
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  Future<void> ouvrir(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TovoTheme.client(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            padding: const EdgeInsets.only(top: 44),
          ),
          child: RepaintBoundary(key: apercu, child: child!),
        ),
        home: CategorieScreen(
          api: api,
          categoryId: '${fixture['category']['id']}',
          nom: 'Restaurants',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capturer(WidgetTester tester, String nom) async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final limite =
          apercu.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await limite.toImage(pixelRatio: 2);
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/categorie-$nom.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  }

  testVisuel('titre, recherche ciblée, sous-catégories, boutiques', (
    tester,
  ) async {
    await ouvrir(tester);
    expect(find.text('Restaurants'), findsOneWidget);
    expect(find.text('Rechercher dans Restaurants'), findsOneWidget);
    expect(find.text('Ouvertes'), findsOneWidget);
    expect(find.text('Burgers'), findsOneWidget);
    expect(find.text('${boutiques.length} boutiques'), findsOneWidget);
    // Les ouvertes d'abord, les fermées en fin de liste.
    expect(find.textContaining('Fermée pour le moment'), findsNothing);
    expect(tester.takeException(), isNull);
    await capturer(tester, '1-restaurants');
  });

  testVisuel('une sous-catégorie filtre, « Réinitialiser » rend tout', (
    tester,
  ) async {
    await ouvrir(tester);
    final avecBurgers = boutiques
        .where((b) => (b['rayons'] as List).contains('BURGERS'))
        .length;
    await tester.tap(find.text('Burgers'));
    await tester.pumpAndSettle();
    expect(
      find.text('$avecBurgers résultat${avecBurgers > 1 ? 's' : ''}'),
      findsOneWidget,
    );
    await capturer(tester, '2-burgers');
    await tester.tap(find.text('Réinitialiser'));
    await tester.pumpAndSettle();
    expect(find.text('${boutiques.length} boutiques'), findsOneWidget);
  });

  testVisuel('la recherche trouve aussi ce que la boutique sert', (
    tester,
  ) async {
    await ouvrir(tester);
    final avecPizza = boutiques
        .where(
          (b) =>
              (b['rayons'] as List).any((r) => '$r'.contains('PIZZA')) ||
              '${b['name']}'.toLowerCase().contains('pizza'),
        )
        .length;
    await tester.enterText(find.byType(TextField), 'pizza');
    await tester.pumpAndSettle();
    expect(
      find.text('$avecPizza résultat${avecPizza > 1 ? 's' : ''}'),
      findsOneWidget,
    );
  });

  testVisuel('toucher une boutique ouvre sa page', (tester) async {
    await ouvrir(tester);
    await tester.tap(find.text(enPhrase(boutiques.first['name'] as String)));
    await tester.pumpAndSettle();
    final page = tester.widget<BoutiqueScreen>(find.byType(BoutiqueScreen));
    expect(page.merchantId, boutiques.first['id']);
    // L'en-tête s'affiche avec ce qu'on sait déjà, sans attendre.
    expect(page.apercu['cover_url'], boutiques.first['cover_url']);
  });

  testVisuel('catégorie par produits : on ouvre directement la grille', (
    tester,
  ) async {
    modeProduits = true;
    await ouvrir(tester);
    expect(find.byType(CategorieScreen), findsNothing);
    expect(find.byType(CatalogScreen), findsOneWidget);
  });
}

class _Images extends Fake implements HttpClient {
  _Images(this.images);
  final Map<String, List<int>> images;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _Requete(images[url.toString()] ?? images.values.first);
}

class _Requete extends Fake implements HttpClientRequest {
  _Requete(this.octets);
  final List<int> octets;
  @override
  Future<HttpClientResponse> close() async => _Reponse(octets);
}

class _Reponse extends Fake implements HttpClientResponse {
  _Reponse(this.octets);
  final List<int> octets;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => octets.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(octets).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
