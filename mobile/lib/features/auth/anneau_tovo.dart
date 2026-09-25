import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme.dart';

/// L'image des écrans d'entrée, à la Glovo : tout ce que Tovo apporte — un
/// repas, des courses, un parfum, un colis — posé AUX BORDS de l'écran, en
/// partie rogné, sur le vert Tovo ; au milieu, le logo en blanc.
///
/// Les objets forment un cercle plus large que l'écran : ceux des côtés
/// sortent à gauche et à droite, ceux du haut passent sous la barre d'état,
/// ceux du bas sous la feuille. On ne voit donc jamais « un cercle autour du
/// logo », mais des objets qui débordent du cadre. Immobile : la rotation
/// n'a pas convaincu (retour du client, 25/09).
class AnneauTovo extends StatelessWidget {
  const AnneauTovo({super.key, this.centre, this.margeHaut = 0});

  /// PNG transparent recadré en carré sur le centre de l'anneau.
  static const asset = 'assets/branding/accueil-anneau.webp';

  /// Le fond : le vert Tovo, franc, comme le jaune de Glovo.
  static const fond = TovoTheme.teal;

  /// Diamètre de l'anneau rapporté à la largeur de l'écran : un peu plus
  /// large que lui, pour que les objets des côtés soient coupés à moitié.
  static const debord = 1.12;

  /// Ce qui se tient au milieu. Par défaut : le logo, en blanc.
  final Widget? centre;

  /// La barre d'état : l'image passe dessous, mais le logo se centre dans
  /// ce qui reste visible.
  final double margeHaut;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final diametre = c.maxWidth * debord;
        return ClipRect(
          child: Stack(
            children: [
              Positioned(
                top: margeHaut,
                left: 0,
                right: 0,
                bottom: 0,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    // Plus grand que son cadre : il déborde, le cadre le rogne.
                    OverflowBox(
                      maxWidth: diametre,
                      maxHeight: diametre,
                      child: TweenAnimationBuilder<double>(
                        // Une entrée douce : les objets se posent, ils ne surgissent
                        // pas.
                        tween: Tween(begin: 0, end: 1),
                        duration: TovoTheme.ample,
                        curve: TovoTheme.courbe,
                        builder: (context, t, child) => Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 1.04 - 0.04 * t,
                            child: child,
                          ),
                        ),
                        child: Image.asset(
                          asset,
                          width: diametre,
                          height: diametre,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                          // Sans l'image, le logo reste lisible seul.
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    centre ??
                        SvgPicture.asset(
                          'assets/branding/tovo-logo.svg',
                          width: (c.maxWidth * 0.42).clamp(120.0, 200.0),
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                          semanticsLabel: 'Tovo',
                        ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
