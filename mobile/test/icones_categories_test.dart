import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/icones_categories.dart';

/// Les icônes de catégories sont des fichiers, et un fichier peut être
/// absent, mal nommé ou mal formé. Aucun de ces trois cas ne fait échouer la
/// compilation : ils donnent une tuile vide sur le téléphone, et on ne s'en
/// aperçoit qu'en la regardant.
void main() {
  // Les neuf modules affichés à l'accueil, tels que la base les nomme.
  const slugs = [
    'boutiques-m2',
    'restaurants-m3',
    'grocery-m4',
    'parapharmacies-m5',
    'tovo-market-m8',
    'kasuwa-1-m9',
    'kasuwa-m10',
    'street-food-m11',
    'billetterie-evenements-m13',
  ];

  test('chaque module affiché a une icône', () {
    for (final slug in slugs) {
      expect(IconesCategories.pour(slug), isNotNull,
          reason: '$slug n’a pas d’icône : la grille afficherait un sac gris');
    }
  });

  test('un slug inconnu ne renvoie rien plutôt que de planter', () {
    // Les rayons de boutique n'ont pas de slug, et une catégorie ajoutée
    // demain n'aura pas d'icône embarquée. Les deux doivent retomber sur le
    // repli, pas lever.
    expect(IconesCategories.pour(null), isNull);
    expect(IconesCategories.pour(''), isNull);
    expect(IconesCategories.pour('categorie-inventee-c999'), isNull);
  });

  testWidgets('les fichiers existent et se dessinent', (tester) async {
    final chemins = {
      ...slugs.map((s) => IconesCategories.pour(s)!),
      IconesCategories.generique,
    };

    for (final chemin in chemins) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: SvgPicture.asset(chemin, width: 44, height: 44)),
        ),
      );
      // Le chargement d'un asset passe par le bundle : sans ce délai, on
      // vérifierait l'état vide qui précède le décodage.
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '$chemin ne se dessine pas');
      expect(find.byType(SvgPicture), findsOneWidget);
    }
  });
}
