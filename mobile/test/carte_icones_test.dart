import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/icones_phosphor.dart';
import 'package:tovo/components/widgets/carte_suivi_theme.dart';
import 'package:tovo/core/theme.dart';

/// Rendu de contrôle des marqueurs de la carte, nuit et jour, sur le fond
/// de chaque thème. Écrit une image seulement si TOVO_RENDU est défini —
/// pour les regarder avant d'installer l'app.
Future<void> _chargerPolices() async {
  final geist = FontLoader(TovoTheme.policeClient);
  for (final poids in ['Regular', 'Medium', 'SemiBold']) {
    geist.addFont(rootBundle.load('assets/fonts/Geist-$poids.ttf'));
  }
  await geist.load();
  final phosphor = FontLoader('PhosphorFill');
  phosphor.addFont(rootBundle.load('assets/fonts/Phosphor-Fill.ttf'));
  await phosphor.load();
}

void main() {
  testWidgets('les marqueurs de la carte se dessinent', (tester) async {
    await tester.runAsync(() async {
      await _chargerPolices();
      const echelle = 3.0;
      const largeur = 420.0;
      const hauteur = 200.0;
      final enregistreur = ui.PictureRecorder();
      final c = Canvas(enregistreur)..scale(echelle);
      var y = 0.0;
      for (final t in [ThemeCarte.sombre, ThemeCarte.clair]) {
        c.drawRect(
          Rect.fromLTWH(0, y, largeur, hauteur / 2),
          Paint()..color = t.fond,
        );
        void poser(Dessin d, double x) {
          c.save();
          c.translate(x, y + 4);
          c.drawPicture(d.image);
          c.restore();
        }

        poser(
          dessinerPastille(t, icone: Phosphor.forkKnife, texte: 'Maison Grill'),
          0,
        );
        poser(
          dessinerPastille(
            t,
            icone: Phosphor.houseLine,
            texte: 'Vous',
            vous: true,
          ),
          150,
        );
        y += hauteur / 2;
      }
      final image = await enregistreur.endRecording().toImage(
        (largeur * echelle).round(),
        (hauteur * echelle).round(),
      );
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(octets, isNotNull);
      final sortie = Platform.environment['TOVO_RENDU'];
      if (sortie != null) {
        File(sortie).writeAsBytesSync(octets!.buffer.asUint8List());
      }
    });
  });
}
