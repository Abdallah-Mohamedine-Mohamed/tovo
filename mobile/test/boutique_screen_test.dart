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
import 'package:tovo/core/panier.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/boutique_screen.dart';
import 'package:tovo/features/catalog/catalog_screen.dart';

/// La page boutique, sur une vraie carte : Restaurant Albarka Food (base de
/// dev, 24/09 — six de ses dix-neuf rayons, photos comprises).
///
///   flutter test test/boutique_screen_test.dart \
///     --dart-define=TOVO_RENDER_PREVIEW=true
class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _Binding();
  final fixture =
      jsonDecode(File('test/fixtures/boutique/carte.json').readAsStringSync())
          as Map<String, dynamic>;
  final images = {
    for (final e in (fixture['images'] as Map<String, dynamic>).entries)
      e.key: File('test/fixtures/boutique/${e.value}').readAsBytesSync(),
  };
  final apercu = GlobalKey();
  final requetes = <Uri>[];
  late TovoApi api;
  var sansCouverture = false;

  setUpAll(() async {
    final polices = FontLoader(TovoTheme.fontFamily);
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      polices.addFont(rootBundle.load('assets/fonts/DMSans-$g.ttf'));
    }
    await polices.load();
    // Le thème client écrit en police système (Arial sous Windows).
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
    final flame = FontLoader('Flame');
    for (final g in ['Regular', 'Bold']) {
      flame.addFont(rootBundle.load('assets/fonts/Flame-$g.otf'));
    }
    await flame.load();
    final icones = FontLoader('MaterialIcons');
    icones.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icones.load();
  });

  setUp(() {
    PanierEnDirect.instance.vider();
    requetes.clear();
    sansCouverture = false;
    CatalogImage.providerOverride = (url) => NetworkImage(url);
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        requetes.add(request.url);
        Object corps = {'items': [], 'total': 0};
        if (request.url.path.endsWith('/carte')) {
          corps = {
            ...fixture,
            'merchant': {
              ...fixture['merchant'] as Map<String, dynamic>,
              if (sansCouverture) 'cover_url': null,
            },
          };
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

  // Le faux client d'images doit être retiré DANS le test : Flutter vérifie
  // les variables de débogage avant tearDown.
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
        home: BoutiqueScreen(
          api: api,
          merchantId: fixture['merchant']['id'] as String,
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
        'build/design-review/boutique-$nom.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  }

  testVisuel('en-tête, infos en une ligne, puis la carte rayon par rayon', (
    tester,
  ) async {
    await ouvrir(tester);
    expect(requetes.single.path, endsWith('/carte'));
    expect(find.text('Restaurant Albarka Food'), findsOneWidget);
    // Pas de délai affiché : demandé par le client (24/09).
    expect(find.textContaining('Prête'), findsNothing);
    // Les capitales importées sont adoucies : « PETIT DEJEUNER » crie.
    expect(find.text('Petit dejeuner'), findsWidgets);
    expect(find.text('PETIT DEJEUNER'), findsNothing);
    expect(tester.takeException(), isNull);
    await capturer(tester, '1-haut');
  });

  testVisuel('un onglet fait défiler jusqu’à son rayon, sous la barre', (
    tester,
  ) async {
    await ouvrir(tester);
    final rayons = (fixture['sections'] as List).cast<Map<String, dynamic>>();
    final cible = rayons[4]['name'] as String;
    final lisible = cible[0] + cible.substring(1).toLowerCase();
    final onglet = find.descendant(
      of: find.byType(ListView),
      matching: find.text(lisible),
    );
    // Comme un doigt : on fait glisser la barre d'onglets vers la gauche.
    await tester.drag(find.byType(ListView), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.tap(onglet);
    await tester.pumpAndSettle();
    // Le titre du rayon est visible, juste sous la barre d'onglets épinglée.
    final titre = find.text(lisible).last;
    final haut = tester.getTopLeft(titre).dy;
    expect(haut, greaterThan(44 + 52 - 1));
    expect(haut, lessThan(44 + 52 + 60));
    expect(tester.takeException(), isNull);
    await capturer(tester, '2-rayon');
  });

  testVisuel('un gros rayon montre 4 produits et « Tout voir »', (
    tester,
  ) async {
    await ouvrir(tester);
    final gros = (fixture['sections'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((r) => (r['produits'] as num) > 6);
    final nom = '${gros['name']}';
    final lisible = nom[0] + nom.substring(1).toLowerCase();
    final bouton = find.bySemanticsLabel('Tout voir, $lisible');
    await tester.ensureVisible(bouton);
    await tester.pumpAndSettle();
    await tester.tap(bouton);
    await tester.pumpAndSettle();
    final catalogue = tester.widget<CatalogScreen>(find.byType(CatalogScreen));
    expect(catalogue.categoryId, gros['id']);
    expect(catalogue.merchantId, fixture['merchant']['id']);
  });

  testVisuel('sans photo de couverture : pas de fausse image', (tester) async {
    sansCouverture = true;
    await ouvrir(tester);
    expect(find.byTooltip('Retour'), findsOneWidget);
    expect(find.text('Restaurant Albarka Food'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capturer(tester, '3-sans-couverture');
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
