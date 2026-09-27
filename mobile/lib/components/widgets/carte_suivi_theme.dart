import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../core/icones_phosphor.dart';

import '../../core/theme.dart';

/// Les deux thèmes de la carte de suivi, repris de la maquette « Suivi
/// Commande » (nuit et jour, 27/09), direction « Épure » : seules les rues,
/// en traits fins ; ni bâtiments, ni parcs, ni eau, ni libellés.
class ThemeCarte {
  const ThemeCarte._({
    required this.nuit,
    required this.fond,
    required this.style,
    required this.traceRestant,
    required this.traceHalo,
    required this.traceBase,
    required this.approche,
    required this.pastilleFond,
    required this.pastilleBord,
    required this.pastilleIconeFond,
    required this.pastilleIcone,
    required this.pastilleTexte,
    required this.pastilleTige,
    required this.pastillePoint,
    required this.vousFond,
    required this.vousTexte,
    required this.vousIconeFond,
    required this.vousIcone,
    required this.livreurFond,
    required this.livreurBord,
    required this.livreurIcone,
    required this.ombre,
    required this.pulsation,
    required this.boutonFond,
    required this.boutonBord,
    required this.boutonTexte,
  });

  final bool nuit;
  final Color fond;

  /// Style JSON de Google Maps.
  final String style;

  final Color traceRestant;

  /// Le halo du tracé : la nuit seulement.
  final Color? traceHalo;

  /// Le tracé complet, sous le tracé restant (la partie parcourue).
  final Color traceBase;

  /// Le pointillé du livreur vers la boutique.
  final Color approche;

  final Color pastilleFond;
  final Color pastilleBord;
  final Color pastilleIconeFond;
  final Color pastilleIcone;
  final Color pastilleTexte;
  final Color pastilleTige;
  final Color pastillePoint;

  /// La pastille « Vous » : contraste inversé par rapport au fond.
  final Color vousFond;
  final Color vousTexte;
  final Color vousIconeFond;
  final Color vousIcone;

  final Color livreurFond;
  final Color livreurBord;
  final Color livreurIcone;

  final Color ombre;
  final Color pulsation;

  final Color boutonFond;
  final Color boutonBord;
  final Color boutonTexte;

  static const sombre = ThemeCarte._(
    nuit: true,
    fond: Color(0xFF1A1D2D),
    style: _styleNuit,
    traceRestant: Color(0xFF9184D9),
    traceHalo: Color(0x559184D9),
    traceBase: Color(0xFF2B2741),
    approche: Color(0xCC9397AB),
    pastilleFond: Color(0xFF232532),
    pastilleBord: Color(0xFF595D6C),
    pastilleIconeFond: Color(0xFF2B2741),
    pastilleIcone: Color(0xFFD2CEFD),
    pastilleTexte: Color(0xFFE9E9ED),
    pastilleTige: Color(0xFF595D6C),
    pastillePoint: Color(0xFFE9E9ED),
    vousFond: Color(0xFFE9E9ED),
    vousTexte: Color(0xFF1A1D2D),
    vousIconeFond: Color(0xFF1A1D2D),
    vousIcone: Color(0xFFE9E9ED),
    livreurFond: Color(0xFF1A1D2D),
    livreurBord: Color(0xFF9184D9),
    livreurIcone: Color(0xFFD2CEFD),
    ombre: Color(0x80000000),
    pulsation: Color(0xFF9184D9),
    boutonFond: Color(0xE6232532),
    boutonBord: Color(0xFF595D6C),
    boutonTexte: Color(0xFFE9E9ED),
  );

  static const clair = ThemeCarte._(
    nuit: false,
    fond: Color(0xFFF1F0EB),
    style: _styleJour,
    traceRestant: Color(0xFF23262F),
    traceHalo: null,
    traceBase: Color(0xFFFDFCF9),
    approche: Color(0xCC5D5B54),
    pastilleFond: Color(0xFFFDFCF9),
    pastilleBord: Color(0xFF8D8A80),
    pastilleIconeFond: Color(0xFFD9D7CF),
    pastilleIcone: Color(0xFF2A2D36),
    pastilleTexte: Color(0xFF23262F),
    pastilleTige: Color(0xFF8D8A80),
    pastillePoint: Color(0xFF23262F),
    vousFond: Color(0xFF1F2129),
    vousTexte: Color(0xFFF1F0EB),
    vousIconeFond: Color(0xFFF1F0EB),
    vousIcone: Color(0xFF1F2129),
    livreurFond: Color(0xFF23262F),
    livreurBord: Color(0xFFFDFCF9),
    livreurIcone: Color(0xFFFDFCF9),
    ombre: Color(0x29281C1C),
    pulsation: Color(0xFF23262F),
    boutonFond: Color(0xF2FDFCF9),
    boutonBord: Color(0xFFD9D7CF),
    boutonTexte: Color(0xFF23262F),
  );
}

/// Un marqueur dessiné : l'image, sa taille (en points) et le point de
/// l'image posé sur la coordonnée.
typedef Dessin = ({ui.Picture image, Size taille, Offset ancre});

TextPainter _texte(String texte, Color couleur, FontWeight poids) =>
    TextPainter(
      text: TextSpan(
        text: texte,
        style: TextStyle(
          fontFamily: TovoTheme.policeClient,
          fontFamilyFallback: const [TovoTheme.fontFamily],
          fontSize: 13,
          fontWeight: poids,
          color: couleur,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 170);

void _icone(
  Canvas c,
  IconData icone,
  Offset centre,
  double taille,
  Color couleur, {
  bool miroir = false,
}) {
  final p = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icone.codePoint),
      style: TextStyle(
        fontFamily: icone.fontFamily,
        package: icone.fontPackage,
        fontSize: taille,
        color: couleur,
        height: 1,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  c.save();
  c.translate(centre.dx, centre.dy);
  if (miroir) c.scale(-1, 1);
  p.paint(c, Offset(-p.width / 2, -p.height / 2));
  c.restore();
}

/// La pastille d'un lieu : icône ronde + nom, tige fine, point au sol.
/// `vous` : la pastille du client, en contraste inversé.
Dessin dessinerPastille(
  ThemeCarte t, {
  required IconData icone,
  required String texte,
  bool vous = false,
}) {
  const marge = 16.0;
  final libelle = _texte(
    texte,
    vous ? t.vousTexte : t.pastilleTexte,
    vous ? FontWeight.w600 : FontWeight.w500,
  );
  final largeurPastille = 6 + 28 + 8 + libelle.width + 12;
  final largeur = largeurPastille + marge * 2;
  const hauteurPastille = 40.0;
  const tige = 12.0;
  final hauteur = marge + hauteurPastille + tige + 8 + 6;
  final r = ui.PictureRecorder();
  final c = Canvas(r);
  final pastille = RRect.fromRectAndRadius(
    Rect.fromLTWH(marge, marge, largeurPastille, hauteurPastille),
    const Radius.circular(20),
  );
  // Ombre douce sous la pastille.
  c.drawRRect(
    pastille.shift(const Offset(0, 6)),
    Paint()
      ..color = t.ombre
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
  );
  c.drawRRect(pastille, Paint()..color = vous ? t.vousFond : t.pastilleFond);
  if (!vous) {
    c.drawRRect(
      pastille,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = t.pastilleBord,
    );
  }
  final centreIcone = Offset(marge + 6 + 14, marge + 20);
  c.drawCircle(
    centreIcone,
    14,
    Paint()..color = vous ? t.vousIconeFond : t.pastilleIconeFond,
  );
  _icone(
    c,
    icone,
    centreIcone,
    vous ? 15 : 16,
    vous ? t.vousIcone : t.pastilleIcone,
  );
  libelle.paint(c, Offset(marge + 6 + 28 + 8, marge + 20 - libelle.height / 2));
  final x = largeur / 2;
  final couleurTige = vous ? t.vousFond : t.pastilleTige;
  c.drawRect(
    Rect.fromLTWH(x - 1, marge + hauteurPastille, 2, tige),
    Paint()..color = couleurTige,
  );
  final sol = Offset(x, marge + hauteurPastille + tige + 4);
  c.drawCircle(sol, 4, Paint()..color = vous ? t.vousFond : t.pastillePoint);
  return (image: r.endRecording(), taille: Size(largeur, hauteur), ancre: sol);
}

/// Le livreur : un rond de 48 points, l'icône scooter (Phosphor « moped »),
/// une pointe dessous. La nuit, un halo lavande ; le jour, une ombre ovale
/// au sol. L'icône regarde vers la droite : vers l'ouest, on la retourne
/// (jamais de rotation, elle se retrouverait à l'envers).
Dessin dessinerLivreur(ThemeCarte t, {required bool versLOuest}) {
  const taille = Size(112, 112);
  const centre = Offset(56, 48);
  const pointe = Offset(56, 80);
  final r = ui.PictureRecorder();
  final c = Canvas(r);
  if (t.nuit) {
    c.drawCircle(
      centre,
      56,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          56,
          const [Color(0x669184D9), Color(0x009184D9)],
          const [0, 0.65],
        ),
    );
    c.drawCircle(centre, 30, Paint()..color = const Color(0x2E9184D9));
    c.drawCircle(
      centre,
      26,
      Paint()
        ..color = const Color(0x999184D9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  } else {
    c.drawOval(
      Rect.fromCenter(
        center: pointe + const Offset(0, 2),
        width: 30,
        height: 8,
      ),
      Paint()
        ..color = const Color(0x40281C1C)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    c.drawCircle(
      centre + const Offset(0, 6),
      24,
      Paint()
        ..color = const Color(0x47281C1C)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
  }
  // La pointe, sous le rond.
  final triangle = Path()
    ..moveTo(pointe.dx - 6, centre.dy + 23)
    ..lineTo(pointe.dx + 6, centre.dy + 23)
    ..lineTo(pointe.dx, pointe.dy)
    ..close();
  c.drawPath(triangle, Paint()..color = t.nuit ? t.livreurBord : t.livreurFond);
  c.drawCircle(centre, 24, Paint()..color = t.livreurBord);
  c.drawCircle(centre, 22, Paint()..color = t.livreurFond);
  _icone(
    c,
    Phosphor.moped,
    centre,
    t.nuit ? 24 : 22,
    t.livreurIcone,
    miroir: versLOuest,
  );
  return (image: r.endRecording(), taille: taille, ancre: pointe);
}

/// Le cône de direction (la nuit) : un faisceau devant le livreur, qui
/// pivote avec son cap. Posé à plat sur la carte, sous le livreur.
Dessin dessinerCone() {
  const taille = Size(64, 80);
  final r = ui.PictureRecorder();
  final c = Canvas(r);
  final faisceau = Path()
    ..moveTo(32, 80)
    ..lineTo(64 * 0.08, 0)
    ..lineTo(64 * 0.92, 0)
    ..close();
  c.drawPath(
    faisceau,
    Paint()
      ..shader = ui.Gradient.linear(const Offset(0, 80), Offset.zero, const [
        Color(0xB3B5ABFC),
        Color(0x009184D9),
      ]),
  );
  return (image: r.endRecording(), taille: taille, ancre: const Offset(32, 80));
}

/// Épure nuit : fond #1A1D2D, rues secondaires #3f424d (1,5 pt), axes
/// #595d6c (2,5 pt) ; tout le reste se fond dans le décor.
const _styleNuit = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1a1d2d"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#1a1d2d"}]},
  {"featureType":"landscape.man_made","stylers":[{"visibility":"off"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#1a1d2d"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"visibility":"off"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#3f424d"},{"weight":1.5}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#595d6c"},{"weight":2.5}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#595d6c"},{"weight":2.5}]}
]
''';

/// Épure jour : fond #f1f0eb, rues secondaires #cfccc2, axes #8d8a80.
const _styleJour = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f1f0eb"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape","elementType":"geometry","stylers":[{"color":"#f1f0eb"}]},
  {"featureType":"landscape.man_made","stylers":[{"visibility":"off"}]},
  {"featureType":"poi","stylers":[{"visibility":"off"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#f1f0eb"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"visibility":"off"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#cfccc2"},{"weight":1.5}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#8d8a80"},{"weight":2.5}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#8d8a80"},{"weight":2.5}]}
]
''';
