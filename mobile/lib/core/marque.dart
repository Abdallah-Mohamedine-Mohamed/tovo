import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Le symbole Tovo, dessiné plutôt qu'importé.
///
/// La géométrie vient de `logo/tovo-symbol.svg` : trois arcs d'un même
/// cercle, chacun terminé par un point. Le reproduire au pinceau plutôt que
/// d'embarquer un moteur SVG évite une dépendance pour cinq traits, ne pèse
/// rien, et surtout se colore et s'anime librement — un SVG rasterisé
/// n'aurait ni l'un ni l'autre.
///
/// Les angles sont calculés depuis les coordonnées d'origine, pas recopiés à
/// la main : une valeur arrondie décalerait les points par rapport aux arcs,
/// et le défaut ne se verrait qu'à grande taille.

/// Cercle du symbole dans le repère 160×160 du SVG.
const Offset _centre = Offset(80, 80);
const double _rayon = 59.5;

/// Les trois arcs, en (début, fin) repris du SVG. Le point se pose sur la fin.
const List<List<Offset>> _arcs = [
  [Offset(22.40, 65.10), Offset(80.00, 20.50)],
  [Offset(112.84, 30.38), Offset(136.26, 99.37)],
  [Offset(115.39, 127.83), Offset(23.84, 99.67)],
];

double _angle(Offset p) => math.atan2(p.dy - _centre.dy, p.dx - _centre.dx);

/// Écart angulaire en allant dans le sens horaire, toujours positif.
double _balayage(double de, double a) {
  var d = a - de;
  while (d <= 0) {
    d += 2 * math.pi;
  }
  return d;
}

/// Trace le symbole sur un canevas quelconque.
///
/// Publique parce que l'icône de lancement se fabrique avec — un générateur
/// qui recopierait les coordonnées créerait une seconde vérité, et les deux
/// dessins divergeraient au premier ajustement.
///
/// [occupation] est la part du carré que remplit le symbole. 1 le colle aux
/// bords ; les icônes adaptatives d'Android ont besoin de marge, la forme
/// finale étant découpée par le constructeur.
void peindreSymboleTovo(
  Canvas canvas,
  Size size, {
  required Color couleur,
  double rotation = 0,
  double occupation = 1,
}) {
  // Le SVG est dessiné dans un carré de 160 : on met à l'échelle une fois
  // plutôt que de convertir chaque coordonnée.
  final echelle = size.shortestSide / 160 * occupation;
  canvas.save();
  canvas.translate(size.width / 2, size.height / 2);
  canvas.rotate(rotation * 2 * math.pi);
  canvas.scale(echelle);
  canvas.translate(-_centre.dx, -_centre.dy);

  final trait = Paint()
    ..color = couleur
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5.8
    ..strokeCap = StrokeCap.round;

  final plein = Paint()..color = couleur;
  final boite = Rect.fromCircle(center: _centre, radius: _rayon);

  for (final arc in _arcs) {
    final debut = _angle(arc[0]);
    final fin = _angle(arc[1]);
    canvas.drawArc(boite, debut, _balayage(debut, fin), false, trait);
    canvas.drawCircle(arc[1], 15.2, plein);
  }

  canvas.restore();
}

class _SymboleTovo extends CustomPainter {
  const _SymboleTovo({required this.couleur, required this.rotation});

  final Color couleur;

  /// Tour complet exprimé en fraction, de 0 à 1.
  final double rotation;

  @override
  void paint(Canvas canvas, Size size) =>
      peindreSymboleTovo(canvas, size, couleur: couleur, rotation: rotation);

  @override
  bool shouldRepaint(_SymboleTovo ancien) =>
      ancien.rotation != rotation || ancien.couleur != couleur;
}

/// Le symbole immobile, à la taille voulue.
class MarqueTovo extends StatelessWidget {
  const MarqueTovo({super.key, this.taille = 40, this.couleur = TovoTheme.teal});

  final double taille;
  final Color couleur;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(taille),
        painter: _SymboleTovo(couleur: couleur, rotation: 0),
      );
}

/// Fond animé : le symbole tourne lentement, très large et très pâle.
///
/// Une vidéo de fond aurait coûté plusieurs mégaoctets, un décodeur, et un
/// premier affichage noir le temps du chargement — sur un réseau nigérien,
/// l'écran d'accueil aurait clignoté avant de s'installer. Ici le mouvement
/// est calculé, démarre à la première image, et c'est la marque elle-même
/// qui tourne plutôt qu'une image de stock qui ne dit rien de Tovo.
class FondAnime extends StatefulWidget {
  const FondAnime({super.key, this.child});

  final Widget? child;

  @override
  State<FondAnime> createState() => _FondAnimeState();
}

class _FondAnimeState extends State<FondAnime> with SingleTickerProviderStateMixin {
  /// Quarante secondes le tour : assez lent pour qu'on ne le regarde pas,
  /// assez présent pour que l'écran ne paraisse pas figé.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 40),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF00807F), TovoTheme.teal, Color(0xFF004D4D)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Débordant volontairement : un cercle coupé par les bords donne
          // une impression d'échelle qu'un symbole entier, posé au milieu,
          // n'aurait pas.
          Positioned(
            right: -110,
            top: -60,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                size: const Size.square(340),
                painter: _SymboleTovo(
                  couleur: Colors.white.withValues(alpha: 0.13),
                  rotation: _c.value,
                ),
              ),
            ),
          ),
          Positioned(
            left: -140,
            bottom: -100,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                size: const Size.square(300),
                painter: _SymboleTovo(
                  couleur: Colors.white.withValues(alpha: 0.08),
                  // Sens inverse : deux cercles tournant ensemble donnent
                  // l'impression d'une image qui glisse, pas d'un mouvement.
                  rotation: -_c.value,
                ),
              ),
            ),
          ),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }
}
