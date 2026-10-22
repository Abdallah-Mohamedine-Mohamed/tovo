import 'package:flutter/material.dart';

/// Le galet gris derrière une icône de catégorie, comme chez Glovo : une
/// forme arrondie un peu irrégulière, la MÊME pour toutes les catégories
/// (demande du client, 22/10 — ni rond, ni carré, ni bordure).
class Galet extends StatelessWidget {
  const Galet({super.key, this.couleur = const Color(0xFFEEEBEA)});

  /// Le gris mesuré sur les catégories de Glovo, légèrement chaud.
  final Color couleur;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _GaletPeintre(couleur), size: Size.infinite);
}

class _GaletPeintre extends CustomPainter {
  _GaletPeintre(this.couleur);
  final Color couleur;

  @override
  void paint(Canvas canvas, Size taille) {
    // Le tracé de la maquette validée, dans un carré de 100 × 100.
    final x = taille.width / 100, y = taille.height / 100;
    final forme = Path()
      ..moveTo(52 * x, 5 * y)
      ..cubicTo(75 * x, 4 * y, 93 * x, 15 * y, 95 * x, 39 * y)
      ..cubicTo(97 * x, 62 * y, 91 * x, 85 * y, 67 * x, 93 * y)
      ..cubicTo(45 * x, 100 * y, 15 * x, 94 * y, 7 * x, 71 * y)
      ..cubicTo(1 * x, 51 * y, 4 * x, 25 * y, 22 * x, 13 * y)
      ..cubicTo(31 * x, 7 * y, 41 * x, 5 * y, 52 * x, 5 * y)
      ..close();
    canvas.drawPath(forme, Paint()..color = couleur..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(covariant _GaletPeintre ancien) => ancien.couleur != couleur;
}
