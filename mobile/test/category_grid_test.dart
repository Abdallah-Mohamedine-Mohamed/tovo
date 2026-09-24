import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/category_grid.dart';
import 'package:tovo/core/icones_3d.dart';
import 'package:tovo/core/theme.dart';

/// Les catégories, en icônes 3D à la Glovo. Les slugs sont ceux de la base
/// (browsable_categories, 24/09).
///
///   flutter test test/category_grid_test.dart \
///     --dart-define=TOVO_RENDER_PREVIEW=true
void main() {
  const categories = [
    ('Restaurants', 'restaurants-m3'),
    ('Marché', 'kasuwa-m10'),
    ('Supermarché', 'grocery-m4'),
    ('Beauté & soins', 'beaute-soins'),
    ('Électronique & téléphone', 'electronique'),
    ('Vêtements', 'vetements'),
    ('Gaz', 'gaz-m12'),
    ('Parapharmacies', 'parapharmacies-m5'),
    ('Repas', 'repas'),
  ];
  final apercu = GlobalKey();

  setUpAll(() async {
    final polices = FontLoader(TovoTheme.fontFamily);
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      polices.addFont(rootBundle.load('assets/fonts/DMSans-$g.ttf'));
    }
    await polices.load();
    final systeme = FontLoader('CupertinoSystemText');
    for (final nom in ['arial.ttf', 'arialbd.ttf']) {
      final fichier = File('${Platform.environment['WINDIR']}/Fonts/$nom');
      if (fichier.existsSync()) {
        systeme.addFont(fichier.readAsBytes().then(ByteData.sublistView));
      }
    }
    await systeme.load();
  });

  test(
    'chaque catégorie du catalogue a son icône 3D, et le fichier existe',
    () {
      for (final (nom, slug) in categories) {
        final icone = Icones3d.categorie(slug);
        expect(icone, isNotNull, reason: nom);
        expect(File(icone!).existsSync(), isTrue, reason: icone);
      }
    },
  );

  test('les rayons se reconnaissent à leur nom', () {
    expect(Icones3d.rayon('BURGERS'), endsWith('burger.png'));
    expect(Icones3d.rayon('BOX POULET PANE'), endsWith('poulet.png'));
    expect(Icones3d.rayon('BOISSONS CHAUDES'), endsWith('boisson-chaude.png'));
    expect(Icones3d.rayon('Crêpes'), endsWith('crepes.png'));
    expect(Icones3d.rayon('RIZ, PATES ET FECULENTS'), endsWith('riz.png'));
    expect(Icones3d.rayon('Quincaillerie'), isNull);
  });

  testWidgets('la grille des catégories', (tester) async {
    tester.view.physicalSize = const Size(390, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TovoTheme.client(),
        home: Scaffold(
          body: RepaintBoundary(
            key: apercu,
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: CategoryGrid(
                  component: TovoComponent(
                    type: 'category_grid',
                    data: {
                      'items': [
                        for (final (nom, slug) in categories)
                          {'id': slug, 'name': nom, 'slug': slug},
                      ],
                    },
                  ),
                  onInteraction: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNWidgets(categories.length));
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await tester.runAsync(() async {
      final limite =
          apercu.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await limite.toImage(pixelRatio: 2);
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/categories-grille.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  });
}
