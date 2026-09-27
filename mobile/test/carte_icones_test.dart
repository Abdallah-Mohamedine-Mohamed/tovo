import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/widgets/carte_suivi.dart';

/// Rendu de contrôle des icônes de la carte : le scooter (droit et tourné)
/// et l'épingle d'arrivée, sur le fond nuit. Écrit une image seulement si
/// TOVO_RENDU est défini — pour les regarder avant d'installer l'app.
void main() {
  testWidgets('les icônes de la carte se dessinent', (tester) async {
    await tester.runAsync(() async {
      const echelle = 4.0;
      final enregistreur = ui.PictureRecorder();
      final c = Canvas(enregistreur)..scale(echelle);
      c.drawRect(
        const Rect.fromLTWH(0, 0, 260, 110),
        Paint()..color = const Color(0xFF1B2940),
      );
      // Une rue, pour juger du contraste.
      c.drawRect(
        const Rect.fromLTWH(0, 44, 260, 18),
        Paint()..color = const Color(0xFF3B4C6B),
      );
      c.save();
      c.translate(10, 18);
      peindreScooter(c, 72);
      c.restore();
      c.save();
      c.translate(130, 54);
      c.rotate(35 * math.pi / 180);
      c.translate(-36, -36);
      peindreScooter(c, 72);
      c.restore();
      c.save();
      c.translate(190, 20);
      peindreDestination(c, 44);
      c.restore();
      final image = await enregistreur.endRecording().toImage(
        (260 * echelle).round(),
        (110 * echelle).round(),
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
