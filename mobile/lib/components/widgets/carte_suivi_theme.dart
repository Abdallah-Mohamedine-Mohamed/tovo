import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Les deux thèmes de la carte de suivi, repris du handoff « Suivi livreur »
/// (Claude Design, 27/09), direction « Épure » : rues en traits fins avec
/// leurs noms ; parcs et eau ; de jour, grands axes jaune doré. Aucun point
/// d'intérêt ni pictogramme de transport.
class ThemeCarte {
  const ThemeCarte._({
    required this.nuit,
    required this.fond,
    required this.style,
    required this.traceRestant,
    required this.traceHalo,
    required this.traceBordure,
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

  /// Le tracé restant, 13 points.
  final Color traceRestant;

  /// Son halo : la nuit seulement.
  final Color? traceHalo;

  /// La bordure du tracé, 22 points, sous tout le trajet : sous le tracé
  /// restant, elle seule marque la partie déjà parcourue.
  final Color traceBordure;

  /// Le pointillé du livreur vers la boutique, 6 points.
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

  final Color ombre;
  final Color pulsation;

  final Color boutonFond;
  final Color boutonBord;
  final Color boutonTexte;

  /// Nuit teal (choix du 28/09) : fond #176a73, trajet restant cyan vif
  /// #41F3F1 avec son halo ; le parcouru en teal très sombre, les rues en
  /// teal plus clair que le fond.
  static const sombre = ThemeCarte._(
    nuit: true,
    fond: Color(0xFF176A73),
    style: _styleNuit,
    traceRestant: Color(0xFF41F3F1),
    traceHalo: Color(0x4D41F3F1),
    traceBordure: Color(0xFF0D4A51),
    approche: Color(0xFFB5E6E8),
    pastilleFond: Color(0xFF0F4A51),
    pastilleBord: Color(0xFF3A9AA3),
    pastilleIconeFond: Color(0xFF0A3A40),
    pastilleIcone: Color(0xFF9FF7F5),
    pastilleTexte: Color(0xFFEAF8F8),
    pastilleTige: Color(0xFF3A9AA3),
    pastillePoint: Color(0xFFEAF8F8),
    vousFond: Color(0xFFEAF8F8),
    vousTexte: Color(0xFF0F4A51),
    vousIconeFond: Color(0xFF0F4A51),
    vousIcone: Color(0xFFEAF8F8),
    ombre: Color(0x66031E22),
    pulsation: Color(0xFF41F3F1),
    boutonFond: Color(0xF00F4A51),
    boutonBord: Color(0xFF3A9AA3),
    boutonTexte: Color(0xFFEAF8F8),
  );

  static const clair = ThemeCarte._(
    nuit: false,
    fond: Color(0xFFF4F2EB),
    style: _styleJour,
    // Cyan (choix du 28/09) : plus doux que le bleu « Google Maps ». La
    // bordure cyan pâle, sous tout le trajet, montre la partie parcourue.
    traceRestant: Color(0xFF04BBC2),
    traceHalo: null,
    traceBordure: Color(0xFFD5F6F7),
    approche: Color(0xFF5D5B54),
    pastilleFond: Color(0xFFFDFCF9),
    pastilleBord: Color(0xFF8D8A80),
    pastilleIconeFond: Color(0xFFD9D7CF),
    pastilleIcone: Color(0xFF2A2D36),
    pastilleTexte: Color(0xFF23262F),
    pastilleTige: Color(0xFF8D8A80),
    pastillePoint: Color(0xFF23262F),
    vousFond: Color(0xFF1F2129),
    vousTexte: Color(0xFFF4F2EB),
    vousIconeFond: Color(0xFFF4F2EB),
    vousIcone: Color(0xFF1F2129),
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
  Color couleur,
) {
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
  p.paint(c, centre - Offset(p.width / 2, p.height / 2));
}

/// La pastille d'un lieu : un rond de 32 points avec son icône, le nom,
/// une tige fine de 12 points et un point au sol. Marges 5/14/5/5.
/// `vous` : la pastille du client, en contraste inversé.
Dessin dessinerPastille(
  ThemeCarte t, {
  required IconData icone,
  required String texte,
  bool vous = false,
}) {
  const marge = 16.0;
  const rond = 32.0;
  const hauteurPastille = 5 + rond + 5;
  const tige = 12.0;
  final libelle = _texte(
    texte,
    vous ? t.vousTexte : t.pastilleTexte,
    vous ? FontWeight.w600 : FontWeight.w500,
  );
  final largeurPastille = 5 + rond + 8 + libelle.width + 14;
  final largeur = largeurPastille + marge * 2;
  final hauteur = marge + hauteurPastille + tige + 8 + 6;
  final r = ui.PictureRecorder();
  final c = Canvas(r);
  final pastille = RRect.fromRectAndRadius(
    Rect.fromLTWH(marge, marge, largeurPastille, hauteurPastille),
    const Radius.circular(hauteurPastille / 2),
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
  const centreIcone = Offset(marge + 5 + rond / 2, marge + hauteurPastille / 2);
  c.drawCircle(
    centreIcone,
    rond / 2,
    Paint()..color = vous ? t.vousIconeFond : t.pastilleIconeFond,
  );
  _icone(c, icone, centreIcone, 18, vous ? t.vousIcone : t.pastilleIcone);
  libelle.paint(
    c,
    Offset(
      marge + 5 + rond + 8,
      marge + hauteurPastille / 2 - libelle.height / 2,
    ),
  );
  final x = largeur / 2;
  c.drawRect(
    Rect.fromLTWH(x - 1, marge + hauteurPastille, 2, tige),
    Paint()..color = vous ? t.vousFond : t.pastilleTige,
  );
  final sol = Offset(x, marge + hauteurPastille + tige + 4);
  c.drawCircle(sol, 4, Paint()..color = vous ? t.vousFond : t.pastillePoint);
  return (image: r.endRecording(), taille: Size(largeur, hauteur), ancre: sol);
}

/// Épure nuit teal : fond #176a73 ; îlots à peine plus sombres ; rues
/// secondaires #2e848d (1,5 pt), grands axes #4aa2ab (2,5 pt) ; espaces
/// verts #1d7b6c, eau #0f5059 ; noms de rues #cdeef0, liseré du fond.
///
/// Repères (28/09) : les noms de quelques lieux qui guident à Niamey —
/// mosquées, écoles, santé, administrations, lieux connus, parcs — en petit,
/// sans pictogramme ; ni commerces, ni transports, ni quartiers.
const _styleNuit = '''
[
  {"elementType":"geometry","stylers":[{"color":"#176a73"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape.man_made","elementType":"geometry","stylers":[{"color":"#15646c"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#176a73"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1d7b6c"}]},
  {"featureType":"poi.sports_complex","elementType":"geometry","stylers":[{"color":"#1d7b6c"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0f5059"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"visibility":"off"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#2e848d"},{"weight":1.5}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#4aa2ab"},{"weight":2.5}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#4aa2ab"},{"weight":2.5}]},
  {"featureType":"road","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#cdeef0"}]},
  {"featureType":"road","elementType":"labels.text.stroke","stylers":[{"color":"#176a73"},{"weight":3}]},
  {"featureType":"road","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.place_of_worship","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.school","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.medical","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.government","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.attraction","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.park","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#a9dde1"}]},
  {"featureType":"poi","elementType":"labels.text.stroke","stylers":[{"color":"#176a73"},{"weight":3}]},
  {"featureType":"poi","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.business","stylers":[{"visibility":"off"}]}
]
''';

/// Épure jour : fond #f4f2eb ; rues secondaires #d6cdb6 (4 pt), grands axes
/// jaune doré #f5bd4f (7 pt) ; espaces verts en vert léger #d3ecc5, eau
/// #9fd0f2 ; noms de rues #6f6a5c, liseré de la couleur du fond. Mêmes
/// repères que la nuit.
const _styleJour = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f4f2eb"}]},
  {"elementType":"labels","stylers":[{"visibility":"off"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape.man_made","elementType":"geometry","stylers":[{"color":"#e9e5da"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#f4f2eb"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#d3ecc5"}]},
  {"featureType":"poi.sports_complex","elementType":"geometry","stylers":[{"color":"#dcefd0"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#9fd0f2"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"visibility":"off"}]},
  {"featureType":"road.local","elementType":"geometry.fill","stylers":[{"color":"#d6cdb6"},{"weight":4}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#f5bd4f"},{"weight":7}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#f5bd4f"},{"weight":7}]},
  {"featureType":"road","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#6f6a5c"}]},
  {"featureType":"road","elementType":"labels.text.stroke","stylers":[{"color":"#f4f2eb"},{"weight":3}]},
  {"featureType":"road","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.place_of_worship","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.school","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.medical","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.government","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.attraction","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi.park","elementType":"labels.text","stylers":[{"visibility":"on"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#8c8778"}]},
  {"featureType":"poi","elementType":"labels.text.stroke","stylers":[{"color":"#f4f2eb"},{"weight":3}]},
  {"featureType":"poi","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.business","stylers":[{"visibility":"off"}]}
]
''';
