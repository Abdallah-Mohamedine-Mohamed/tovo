import 'package:flutter/material.dart';

/// Thème Tovo — blanc et teal, tel que défini par la maquette.
///
/// Une seule source pour les couleurs, les rayons et les espacements. Les
/// widgets de composants ne redéfinissent jamais une couleur en dur : sinon
/// changer l'accent demanderait de fouiller douze fichiers.
class TovoTheme {
  const TovoTheme._();

  static const Color teal = Color(0xFF006666);
  static const Color tealDeep = Color(0xFF003F40);
  static const Color tealBright = Color(0xFF0A8B86);
  static const Color tealSoft = Color(0xFFE6F4F1);
  static const Color tealMist = Color(0xFFF1F8F5);
  static const Color coral = Color(0xFFFF735C);
  static const Color coralSoft = Color(0xFFFFE9E3);
  static const Color gold = Color(0xFFF2B544);
  static const Color canvas = Color(0xFFFAFAF7);
  static const Color ink = Color(0xFF14201E);
  static const Color muted = Color(0xFF7A8581);
  static const Color surface = Color(0xFFF0F2EC);
  static const Color line = Color(0xFFE4E8E1);
  static const Color success = Color(0xFF168A63);
  static const Color danger = Color(0xFFD94C45);

  // -------------------------------------------------------------------
  // Surfaces
  // -------------------------------------------------------------------
  // Ce qui donnait à l'application son air de logiciel de bureau : chaque
  // bloc cerné d'un trait gris. Un trait dit « ceci est une boîte » ; un
  // fond légèrement teinté dit « ceci va ensemble », ce qui est presque
  // toujours l'intention réelle. On sépare donc par la couleur et par
  // l'espace, et on garde les traits pour les rares cas où une frontière
  // compte vraiment.

  /// Fond des blocs posés sur le blanc. Assez proche pour ne pas découper
  /// l'écran, assez distinct pour se lire sans bordure.
  static const Color bloc = Color(0xFFF0F2EC);

  /// Le même, au contact : ce qu'on voit sous le doigt.
  static const Color blocPresse = Color(0xFFE4E8E1);

  /// Texte secondaire assez sombre pour rester lisible en plein soleil —
  /// `muted` disparaît sur un écran de téléphone dehors, à Niamey.
  static const Color inkDoux = Color(0xFF55615D);

  /// Ombre unique de l'application.
  ///
  /// Très diffuse et très pâle : elle ne doit pas se voir, seulement
  /// détacher. Une ombre qu'on remarque est une ombre trop forte.
  static const List<BoxShadow> ombre = [
    BoxShadow(color: Color(0x0A002E2E), blurRadius: 18, offset: Offset(0, 6)),
  ];

  static const List<BoxShadow> ombreFlottante = [
    BoxShadow(color: Color(0x10002E2E), blurRadius: 24, offset: Offset(0, 8)),
  ];

  /// Déclarée dans pubspec.yaml et embarquée dans l'app.
  ///
  /// Une seule police pour les trois flavors : le client, le livreur et le
  /// boutiquier doivent avoir l'air de venir du même endroit.
  static const String fontFamily = 'DM Sans';

  /// Rayons généreux, dans l'esprit des interfaces de Google aujourd'hui.
  /// 16 restait anguleux à côté d'un contenu aéré ; 22 arrondit franchement
  /// sans virer à la pastille.
  static const double radiusCard = 20;
  static const double radiusChip = 16;
  static const double radiusSmall = 12;
  static const double gap = 14;

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

    final texte = base.textTheme
        .apply(fontFamily: fontFamily, bodyColor: ink, displayColor: ink)
        .copyWith(
          displayLarge: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 46,
            height: 1.02,
            letterSpacing: -2.2,
            fontWeight: FontWeight.w800,
            color: ink,
          ),
          headlineLarge: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 32,
            height: 1.08,
            letterSpacing: -1.1,
            fontWeight: FontWeight.w800,
            color: ink,
          ),
          headlineMedium: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 24,
            height: 1.15,
            letterSpacing: -0.6,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
          titleLarge: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 19,
            height: 1.2,
            letterSpacing: -0.25,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
          titleMedium: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 15,
            height: 1.3,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
          bodyLarge: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 16,
            height: 1.55,
            fontWeight: FontWeight.w400,
            color: ink,
          ),
          bodyMedium: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            height: 1.5,
            fontWeight: FontWeight.w400,
            color: ink,
          ),
          labelLarge: const TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        );

    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      colorScheme: base.colorScheme.copyWith(
        primary: teal,
        secondary: coral,
        surface: Colors.white,
        surfaceContainerHighest: surface,
        onSurface: ink,
        outline: line,
        error: danger,
      ),
      textTheme: texte,
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 60,
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: teal,
          foregroundColor: Colors.white,
          disabledBackgroundColor: line,
          disabledForegroundColor: muted,
          minimumSize: const Size.fromHeight(52),
          elevation: 0,
          textStyle: texte.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size.fromHeight(50),
          side: const BorderSide(color: line),
          textStyle: texte.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: teal,
          textStyle: texte.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        hintStyle: texte.bodyMedium?.copyWith(color: muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: teal, width: 1.6),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.white,
        selectedColor: tealSoft,
        side: const BorderSide(color: line),
        labelStyle: texte.labelLarge?.copyWith(fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.white,
        showDragHandle: true,
        dragHandleColor: line,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: teal),
    );
  }
}
