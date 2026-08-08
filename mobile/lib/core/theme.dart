import 'package:flutter/material.dart';

/// Thème Tovo — blanc et teal, tel que défini par la maquette.
///
/// Une seule source pour les couleurs, les rayons et les espacements. Les
/// widgets de composants ne redéfinissent jamais une couleur en dur : sinon
/// changer l'accent demanderait de fouiller douze fichiers.
class TovoTheme {
  const TovoTheme._();

  static const Color teal = Color(0xFF006666);
  static const Color tealSoft = Color(0xFFF0FAF9);
  static const Color ink = Color(0xFF1A1A1A);
  static const Color muted = Color(0xFF8A8A8A);
  static const Color surface = Color(0xFFF8F8F7);
  static const Color line = Color(0xFFF0F0F0);
  static const Color success = Color(0xFF10B981);
  static const Color danger = Color(0xFFE74C3C);

  /// Déclarée dans pubspec.yaml et embarquée dans l'app.
  ///
  /// Une seule police pour les trois flavors : le client, le livreur et le
  /// boutiquier doivent avoir l'air de venir du même endroit.
  static const String fontFamily = 'DM Sans';

  static const double radiusCard = 16;
  static const double radiusChip = 12;
  static const double gap = 12;

  // -------------------------------------------------------------------
  // Mouvement
  // -------------------------------------------------------------------
  // Trois durées et deux courbes pour toute l'application. Ce qui distingue
  // une interface soignée d'une interface bricolée n'est presque jamais la
  // richesse des animations : c'est leur cohérence. Des durées choisies au
  // cas par cas donnent une impression de désordre que personne ne sait
  // nommer.

  /// Réaction immédiate à un geste : appui, bascule, couleur qui change.
  static const Duration vif = Duration(milliseconds: 150);

  /// Apparition d'un élément, glissement d'une carte.
  static const Duration normal = Duration(milliseconds: 260);

  /// Transition qui porte un changement d'état important.
  static const Duration ample = Duration(milliseconds: 420);

  /// Entrées et sorties. Démarre franchement, finit en douceur — c'est ce
  /// qui donne l'impression que l'élément a du poids.
  static const Curve courbe = Curves.easeOutCubic;

  /// Pour ce qui doit attirer l'œil sans brusquer : un léger dépassement.
  static const Curve courbeAccueil = Curves.easeOutBack;

  static ThemeData build() {
    final base = ThemeData.light(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: Colors.white,
      colorScheme: base.colorScheme.copyWith(
        primary: teal,
        secondary: teal,
        surface: Colors.white,
        error: danger,
      ),
      textTheme: base.textTheme.apply(
        fontFamily: fontFamily,
        bodyColor: ink,
        displayColor: ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: teal,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusChip),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surface,
        selectedColor: tealSoft,
        side: const BorderSide(color: Color(0x14000000)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}
