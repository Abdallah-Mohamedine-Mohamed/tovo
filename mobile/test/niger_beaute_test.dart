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
import 'package:tovo/components/widgets/galet.dart';
import 'package:tovo/components/widgets/product_carousel.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/catalog_image.dart';
import 'package:tovo/core/panier.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/boutique_screen.dart';
import 'package:tovo/features/catalog/rayon_boutique_screen.dart';

/// Niger Beauté en affichage « catégories » (22/10) : deux écrans. La
/// boutique ne montre que ses 12 catégories ; une catégorie montre ses
/// articles, filtrés sur place par des pastilles. Vraies données de la base
/// de dev (icônes, photos, prix).
///
///   flutter test test/niger_beaute_test.dart \
///     --dart-define=TOVO_RENDER_PREVIEW=true
class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _Binding();
  Map<String, dynamic> lire(String nom) =>
      jsonDecode(File('test/fixtures/niger-beaute/$nom').readAsStringSync())
          as Map<String, dynamic>;
  final carte = lire('carte.json');
  final parfums = lire('rayon-parfums.json');
  final images = {
    for (final e in (carte['images'] as Map<String, dynamic>).entries)
      e.key: File('test/fixtures/niger-beaute/${e.value}').readAsBytesSync(),
  };
  final apercu = GlobalKey();
  final requetes = <Uri>[];
  // Les images dont le PREMIER téléchargement échoue (raté réseau).
  final echecs = <String>{};
  late TovoApi api;

  setUpAll(() async {
    final geist = FontLoader('Geist');
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      geist.addFont(rootBundle.load('assets/fonts/Geist-$g.ttf'));
    }
    await geist.load();
    final polices = FontLoader(TovoTheme.fontFamily);
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      polices.addFont(rootBundle.load('assets/fonts/DMSans-$g.ttf'));
    }
    await polices.load();
    final icones = FontLoader('MaterialIcons');
    icones.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icones.load();
  });

  setUp(() {
    PanierEnDirect.instance.vider();
    requetes.clear();
    echecs.clear();
    // Une image chargée par un test précédent ne doit pas servir au suivant.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    CatalogImage.providerOverride = (url) => NetworkImage(url);
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        requetes.add(request.url);
        final chemin = request.url.path;
        final Object corps = chemin.endsWith('/carte')
            ? carte
            : chemin.endsWith('/rayons/parfums')
            ? parfums
            : {'items': [], 'total': 0};
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
      debugNetworkImageHttpClientProvider = () => _Images(images, echecs);
      try {
        await corps(tester);
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  Future<void> attendreLesImages(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
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
        home: BoutiqueScreen(
          api: api,
          merchantId: carte['merchant']['id'] as String,
        ),
      ),
    );
    await attendreLesImages(tester);
  }

  Future<void> capturer(WidgetTester tester, String nom) async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await attendreLesImages(tester);
    await tester.runAsync(() async {
      final limite =
          apercu.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await limite.toImage(pixelRatio: 2);
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/niger-beaute-$nom.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  }

  testVisuel('la boutique ne montre que ses 12 catégories, 4 par rangée', (
    tester,
  ) async {
    await ouvrir(tester);
    expect(requetes.single.path, endsWith('/carte'));
    expect(find.byType(Galet), findsNWidgets(12));
    // Ni rayon, ni produit, ni « les plus commandés » sur la page.
    expect(find.byType(ProductTile), findsNothing);
    expect(find.text('Les plus commandés'), findsNothing);
    // Quatre par rangée : Parfums, Déodorants, Laits et crèmes, Huiles
    // alignés ; Gels douche commence la deuxième rangée, sous Parfums.
    double haut(String nom) => tester.getTopLeft(find.text(nom)).dy;
    double gauche(String cle) =>
        tester.getTopLeft(find.byKey(ValueKey('categorie-$cle'))).dx;
    expect(haut('Huiles'), haut('Parfums'));
    expect(haut('Gels douche'), greaterThan(haut('Parfums')));
    expect(gauche('gels-douche'), gauche('parfums'));
    // Les trois rangées tiennent dans l'écran, sous l'en-tête.
    expect(tester.getBottomLeft(find.text('Bébé')).dy, lessThan(844));
    expect(tester.takeException(), isNull);
    await capturer(tester, '1-categories');
  });

  testVisuel('une icône qui n’a pas pu se télécharger est redemandée', (
    tester,
  ) async {
    const dents = 'https://exemple.test/rayons/dents-et-haleine.webp';
    echecs.add(dents);
    await ouvrir(tester);
    bool chargee() => tester
        .widgetList<RawImage>(
          find.descendant(
            of: find.byKey(const ValueKey('categorie-dents-et-haleine')),
            matching: find.byType(RawImage),
          ),
        )
        .any((r) => r.image != null);
    // Le premier essai a échoué : le galet est vide.
    expect(echecs, isEmpty);
    expect(chargee(), isFalse);
    // Deux secondes plus tard, l'icône est redemandée, et elle arrive.
    await tester.pump(const Duration(seconds: 3));
    await attendreLesImages(tester);
    expect(chargee(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testVisuel('une catégorie : « Tous » d’abord, les pastilles filtrent sur place', (
    tester,
  ) async {
    await ouvrir(tester);
    await tester.tap(find.byKey(const ValueKey('categorie-parfums')));
    await attendreLesImages(tester);
    expect(find.byType(RayonBoutiqueScreen), findsOneWidget);
    expect(requetes.last.path, endsWith('/rayons/parfums'));
    final items = (parfums['items'] as List).cast<Map<String, dynamic>>();
    expect(find.text('${items.length} articles'), findsOneWidget);
    // « Tous » est choisi en arrivant.
    final tous = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('pastille-tous')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(tous.properties.selected, isTrue);
    await capturer(tester, '2-parfums');

    // « Pour femme » : seulement les parfums pour femme, même écran.
    final femme = items.where((p) => p['sous_rayon'] == 'Pour femme').length;
    await tester.tap(find.byKey(const ValueKey('pastille-Pour femme')));
    await attendreLesImages(tester);
    expect(find.byType(RayonBoutiqueScreen), findsOneWidget);
    expect(find.text('$femme articles'), findsOneWidget);
    expect(requetes.where((u) => u.path.contains('/rayons/')).length, 1);
    expect(tester.takeException(), isNull);
    await capturer(tester, '3-pour-femme');
  });

  testVisuel('budget et ordre se choisissent dans une feuille, sans requête', (
    tester,
  ) async {
    await ouvrir(tester);
    await tester.tap(find.byKey(const ValueKey('categorie-parfums')));
    await attendreLesImages(tester);
    final items = (parfums['items'] as List).cast<Map<String, dynamic>>();

    await tester.tap(find.byKey(const ValueKey('menu-budget')));
    await tester.pumpAndSettle();
    await capturer(tester, '4-budget');
    await tester.tap(find.text('Moins de 5 000 F'));
    await tester.pumpAndSettle();
    final petits = items.where((p) => (p['price'] as num) < 5000).length;
    expect(
      find.text(petits == 1 ? '1 article' : '$petits articles'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('menu-ordre')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prix croissant'));
    await tester.pumpAndSettle();
    final prix = [
      for (final t in tester.widgetList<ProductTile>(find.byType(ProductTile)))
        t.data['price'] as num,
    ];
    expect(prix, [...prix]..sort());
    expect(requetes.where((u) => u.path.contains('/rayons/')).length, 1);
    expect(tester.takeException(), isNull);
  });
}

class _Images extends Fake implements HttpClient {
  _Images(this.images, this.echecs);
  final Map<String, List<int>> images;
  final Set<String> echecs;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (echecs.remove(url.toString())) {
      throw const SocketException('connexion interrompue');
    }
    return _Requete(images[url.toString()] ?? images.values.first);
  }
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
