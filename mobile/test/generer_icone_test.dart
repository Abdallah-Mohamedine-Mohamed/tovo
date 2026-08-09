import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/marque.dart';
import 'package:tovo/core/theme.dart';

/// Fabrique les images de l'icône de lancement.
///
/// Écrit comme un test parce que dessiner demande un moteur de rendu, et que
/// `flutter test` en fournit un — sans installer d'outil de conversion SVG,
/// qui serait une dépendance de plus à faire tourner sur trois machines.
///
/// Il ne vérifie rien : il PRODUIT. À relancer seulement quand le symbole
/// change, puis `dart run flutter_launcher_icons` pour décliner les tailles.
///
///     flutter test test/generer_icone_test.dart
void main() {
  const cote = 1024.0;

  Future<void> ecrire(String chemin, Future<ui.Image> Function() dessiner) async {
    final image = await dessiner();
    final octets = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(octets, isNotNull, reason: 'encodage PNG impossible');
    final fichier = File(chemin);
    await fichier.parent.create(recursive: true);
    await fichier.writeAsBytes(octets!.buffer.asUint8List());
    expect(await fichier.length(), greaterThan(1000), reason: '$chemin est vide');
  }

  Future<ui.Image> peindre({required bool fondTeal, required double occupation}) async {
    final enregistreur = ui.PictureRecorder();
    final canvas = Canvas(enregistreur);

    if (fondTeal) {
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, cote, cote),
        Paint()..color = TovoTheme.teal,
      );
    }

    peindreSymboleTovo(
      canvas,
      const Size(cote, cote),
      couleur: Colors.white,
      occupation: occupation,
    );

    return enregistreur.endRecording().toImage(cote.toInt(), cote.toInt());
  }

  test('produit les images de l’icône', () async {
    // Icône classique : le symbole posé sur le teal, presque bord à bord.
    // Android l'affiche telle quelle sur les versions anciennes.
    await ecrire(
      'assets/branding/icone-tovo.png',
      () => peindre(fondTeal: true, occupation: 0.62),
    );

    // Icône adaptative : fond transparent, le teal étant déclaré à part dans
    // pubspec.yaml. Le symbole n'occupe que la moitié du carré parce que le
    // constructeur découpe la forme finale — ronde, carrée, en goutte — et
    // seul le centre survit à coup sûr. Un dessin plus large se ferait
    // rogner sur les téléphones à masque circulaire.
    await ecrire(
      'assets/branding/icone-tovo-premier-plan.png',
      () => peindre(fondTeal: false, occupation: 0.50),
    );
  });
}
