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
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/article_manquant_sheet.dart';

/// « Un article manque » côté client (02/11) : remplacer, retirer, annuler.
///
///   flutter test test/article_manquant_test.dart --dart-define=TOVO_RENDER_PREVIEW=true
void main() {
  final apercu = GlobalKey();
  final envois = <http.Request>[];
  late TovoApi api;

  final commande = {
    'id': '11111111-1111-4111-8111-111111111111',
    'merchant_name': 'Miam Pizza',
    'total': 15000,
  };
  final manquant = {
    'id': '22222222-2222-4222-8222-222222222222',
    'nom': 'Pizza Double Fromage',
    'quantite': 1,
    'prix_unitaire': 4250,
    'suggestions': [
      {
        'product_id': '33333333-3333-4333-8333-333333333333',
        'nom': 'Pizza Margherita',
        'prix': 4250,
        'image_url': '',
      },
      {
        'product_id': '44444444-4444-4444-8444-444444444444',
        'nom': 'Pizza Honolulu Poulet',
        'prix': 4250,
        'image_url': '',
      },
    ],
  };

  setUpAll(() async {
    final geist = FontLoader('Geist');
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      geist.addFont(rootBundle.load('assets/fonts/Geist-$g.ttf'));
    }
    await geist.load();
    final polices = FontLoader(TovoTheme.fontFamily);
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      polices.addFont(rootBundle.load('assets/fonts/DMSans-$g.ttf'));
    }
    await polices.load();
  });

  setUp(() {
    envois.clear();
    CatalogImage.providerOverride = (url) => NetworkImage(url);
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        envois.add(request);
        return http.Response(
          jsonEncode({'statut': 'pending', 'total': 15000}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  tearDown(() => CatalogImage.providerOverride = null);

  Future<String?> ouvrir(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? resultat;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TovoTheme.client(),
        builder: (context, child) =>
            RepaintBoundary(key: apercu, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  resultat = await choisirPourArticleManquant(
                    context,
                    api: api,
                    commande: commande,
                    manquant: manquant,
                  );
                },
                child: const Text('ouvrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    return resultat;
  }

  Future<void> capturer(WidgetTester tester, String nom) async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await tester.runAsync(() async {
      final limite =
          apercu.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await limite.toImage(pixelRatio: 2);
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/manquant-$nom.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'la feuille propose deux remplacements, le retrait avec le nouveau total, l’annulation',
    (tester) async {
      await ouvrir(tester);
      expect(find.text('Un article manque'), findsOneWidget);
      expect(find.text('Pizza Margherita'), findsOneWidget);
      expect(find.text('Pizza Honolulu Poulet'), findsOneWidget);
      expect(find.textContaining('nouveau total 10 750 F'), findsOneWidget);
      expect(find.text('Annuler la commande'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capturer(tester, 'client');
    },
  );

  testWidgets('choisir un remplacement l’envoie au serveur', (tester) async {
    await ouvrir(tester);
    await tester.tap(find.text('Choisir').first);
    await tester.pumpAndSettle();
    final envoi = envois.single;
    expect(
      envoi.url.path,
      '/orders/${commande['id']}/manquants/${manquant['id']}',
    );
    expect(jsonDecode(envoi.body), {
      'decision': 'remplacer',
      'product_id': '33333333-3333-4333-8333-333333333333',
    });
    expect(find.text('Un article manque'), findsNothing);
  });

  testWidgets('retirer l’article', (tester) async {
    await ouvrir(tester);
    await tester.tap(find.byKey(const ValueKey('retirer-article')));
    await tester.pumpAndSettle();
    expect(jsonDecode(envois.single.body), {'decision': 'retirer'});
  });
}
