import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme.dart';

/// L'anneau d'accueil : tout ce que Tovo apporte — un repas, des courses,
/// un parfum, un colis — disposé en cercle, et au centre ce qui les relie.
///
/// Le même anneau ouvre la connexion (le logo au centre) et referme
/// l'inscription (le prénom du client au centre) : le parcours commence par
/// Tovo et finit par lui.
///
/// L'anneau tourne lentement sur lui-même ; le centre, lui, ne bouge pas.
/// La rotation est faite ici plutôt que par le GIF fourni : même effet, une
/// image fixe de 110 Ko au lieu de 9,9 Mo, fluide à toutes les cadences. Si
/// le téléphone demande de réduire les animations, l'anneau reste immobile.
class AnneauTovo extends StatefulWidget {
  const AnneauTovo({super.key, required this.taille, this.centre});

  /// PNG transparent recadré en carré sur le centre de l'anneau.
  static const asset = 'assets/branding/accueil-anneau.webp';

  /// Un tour complet : lent, pour qu'on le sente vivre sans le regarder.
  static const tour = Duration(seconds: 40);

  final double taille;

  /// Ce qui se tient au milieu. Par défaut : le logo.
  final Widget? centre;

  @override
  State<AnneauTovo> createState() => _AnneauTovoState();
}

class _AnneauTovoState extends State<AnneauTovo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: AnneauTovo.tour,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _rotation.stop();
    } else if (!_rotation.isAnimating) {
      _rotation.repeat();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final taille = widget.taille;
    return TweenAnimationBuilder<double>(
      // Une entrée douce : l'anneau se pose, il ne surgit pas.
      tween: Tween(begin: 0, end: 1),
      duration: TovoTheme.ample,
      curve: TovoTheme.courbe,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
      ),
      child: SizedBox.square(
        dimension: taille,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: RotationTransition(
                turns: _rotation,
                child: Image.asset(
                  AnneauTovo.asset,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  // Sans l'image, le centre reste lisible seul.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
            // Le vide intérieur fait à peu près 60 % du carré.
            SizedBox(
              width: taille * 0.52,
              child: Center(
                child:
                    widget.centre ??
                    SvgPicture.asset(
                      'assets/branding/tovo-logo.svg',
                      width: taille * 0.34,
                      semanticsLabel: 'Tovo',
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
