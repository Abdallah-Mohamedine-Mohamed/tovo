import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/registry.dart';
import '../../components/widgets/carte_suivi_theme.dart';
import '../../core/api.dart';
import '../../core/location.dart';
import '../../core/position_livreur.dart';
import '../../core/soleil.dart';
import '../../core/theme.dart';
import 'avatar.dart';

/// La carte des commerces (maquette validée le 07/10) : les commerces trouvés
/// sur une carte, le tracé depuis le client jusqu'à celui qu'il choisit, et
/// une fiche flottante qu'on fait glisser d'un commerce à l'autre.
///
/// - Le commerce choisi : une épingle rouge, sa POINTE sur la boutique.
/// - Les autres : des cercles numérotés (carrés pleins pour les partenaires
///   Tovo), discrets, qui ne concurrencent pas l'épingle.
/// - Ni lieux ni pictogrammes : seulement le quartier du commerce et 2 ou 3
///   repères proches du trajet (GET /carte/itineraire).
/// - Jour : le style « Épure » du suivi ; nuit : le style du fondateur
///   (assets/carte/style-nuit-commerces.json).
/// - Boutons doux, jamais noirs : Faire livrer, Y aller, Appeler.
class CarteCommerces extends StatefulWidget {
  const CarteCommerces({
    super.key,
    required this.commerces,
    required this.onInteraction,
    this.titre = 'Sur la carte',
  });

  final List<CommerceSurCarte> commerces;
  final InteractionCallback onInteraction;
  final String titre;

  /// Les commerces d'un composant `commerces_hors_tovo` (et les boutiques
  /// Tovo jointes), ceux qui ont une position.
  static List<CommerceSurCarte> depuisComposant(TovoComponent c) {
    double? nombre(Object? v) => v is num ? v.toDouble() : null;
    final tovo = [
      for (final b in c.list('boutiques_tovo'))
        if (nombre(b['lat']) != null && nombre(b['lng']) != null)
          CommerceSurCarte(
            nom: '${b['nom'] ?? ''}',
            sousTitre: b['ouverte'] == true ? 'Sur Tovo · ouverte' : 'Sur Tovo',
            position: (lat: nombre(b['lat'])!, lng: nombre(b['lng'])!),
            distanceM: (b['distance_m'] as num?)?.toInt(),
            tovo: true,
            idBoutique: '${b['id'] ?? ''}',
            logo: '${b['logo_url'] ?? ''}',
          ),
    ];
    final ailleurs = [
      for (final i in c.list('items'))
        if (nombre(i['lat']) != null && nombre(i['lng']) != null)
          CommerceSurCarte(
            nom: '${i['nom'] ?? ''}',
            sousTitre: [
              '${i['type'] ?? ''}',
              '${i['quartier'] ?? ''}',
            ].where((s) => s.isNotEmpty && s != 'null').join(' · '),
            position: (lat: nombre(i['lat'])!, lng: nombre(i['lng'])!),
            distanceM: (i['distance_m'] as num?)?.toInt(),
            telephone: '${i['telephone_appel'] ?? ''}'.isEmpty
                ? null
                : '${i['telephone_appel']}',
            livreur: i['livreur'] is Map
                ? Map<String, dynamic>.from(i['livreur'] as Map)
                : null,
          ),
    ];
    return [...tovo, ...ailleurs];
  }

  @override
  State<CarteCommerces> createState() => _CarteCommercesState();
}

class CommerceSurCarte {
  const CommerceSurCarte({
    required this.nom,
    required this.sousTitre,
    required this.position,
    this.distanceM,
    this.telephone,
    this.livreur,
    this.tovo = false,
    this.idBoutique,
    this.logo,
  });

  final String nom;
  final String sousTitre;
  final Point position;
  final int? distanceM;
  final String? telephone;
  final Map<String, dynamic>? livreur;
  final bool tovo;
  final String? idBoutique;
  final String? logo;
}

/// Les teintes de la carte, de jour et de nuit (maquette du 07/10).
class _Teinte {
  const _Teinte({
    required this.nuit,
    required this.fond,
    required this.trace,
    required this.traceBord,
    required this.panneau,
    required this.panneauBord,
    required this.bouton,
    required this.texte,
    required this.second,
    required this.distance,
    required this.repere,
    required this.halo,
    required this.quartier,
    required this.cercleFond,
    required this.cercleBord,
    required this.cercleTexte,
    required this.vous,
    required this.vousBord,
    required this.vousHalo,
  });

  final bool nuit;
  final Color fond;
  final Color trace;
  final Color traceBord;
  final Color panneau;
  final Color panneauBord;
  final Color bouton;
  final Color texte;
  final Color second;
  final Color distance;
  final Color repere;
  final Color halo;
  final Color quartier;
  final Color cercleFond;
  final Color cercleBord;
  final Color cercleTexte;
  final Color vous;
  final Color vousBord;
  final Color vousHalo;

  /// La nuit du fondateur (Documents/map-style.json et sa notice).
  static const nuitCanard = _Teinte(
    nuit: true,
    fond: Color(0xFF025661),
    trace: Color(0xFF03EEFF),
    traceBord: Color(0xFF017180),
    panneau: Color(0xFF0A1F26),
    panneauBord: Color(0xFF1C3A43),
    bouton: Color(0xFF14343D),
    texte: Colors.white,
    second: Color(0xFFA9C3CA),
    distance: Color(0xFF03EEFF),
    repere: Color(0xFFB5D0D6),
    halo: Color(0xFF025661),
    quartier: Colors.white,
    cercleFond: Color(0xFF0A1F26),
    cercleBord: Color(0xFFB5D0D6),
    cercleTexte: Color(0xFFDCEBEF),
    vous: Colors.white,
    vousBord: Color(0xFF017180),
    vousHalo: Color(0x4D03EEFF),
  );

  /// Le jour : la carte « Épure » du suivi, boutons gris doux.
  static const jourEpure = _Teinte(
    nuit: false,
    fond: Color(0xFFF4F2EB),
    trace: Color(0xFF04BBC2),
    traceBord: Color(0xFF0B7F86),
    panneau: Colors.white,
    panneauBord: Color(0xFFE4E8E1),
    bouton: Color(0xFFF0F2EC),
    texte: Color(0xFF14201E),
    second: Color(0xFF55615D),
    distance: Color(0xFF14201E),
    repere: Color(0xFF6F6A5C),
    halo: Color(0xFFF4F2EB),
    quartier: Color(0xFF23262F),
    cercleFond: Colors.white,
    cercleBord: Color(0xFF23262F),
    cercleTexte: Color(0xFF23262F),
    vous: Color(0xFF23262F),
    vousBord: Colors.white,
    vousHalo: Color(0x2623262F),
  );
}

/// L'itinéraire du client jusqu'à un commerce (GET /carte/itineraire).
class _Itineraire {
  const _Itineraire({
    required this.trace,
    required this.distanceM,
    this.dureeS,
    this.quartier,
    this.reperes = const [],
  });

  final List<Point> trace;
  final int distanceM;
  final int? dureeS;
  final String? quartier;
  final List<({String nom, Point position})> reperes;
}

class _CarteCommercesState extends State<CarteCommerces> {
  final _api = TovoApi();
  final _pages = PageController(viewportFraction: 0.92);
  GoogleMapController? _carte;
  Point? _client;
  int _choisi = 0;
  final Map<int, _Itineraire?> _itineraires = {};
  final Map<String, BitmapDescriptor> _images = {};
  String? _styleNuit;
  late final _Teinte _t;

  // L'avatar du client (étape 3, 07/10) : il remplace le point « Vous ».
  // Créé une fois les réglages de l'avatar lus : ses vraies foulées.
  MoteurAvatar? _moteur;
  ImagesAvatar? _avatar;
  StreamSubscription<Position>? _gps;
  Timer? _horloge;
  DateTime _avant = DateTime.now();
  EtatAvatar? _etat;
  BitmapDescriptor? _imageAvatar;
  double _bearing = 0;
  double _tilt = 0;

  @override
  void initState() {
    super.initState();
    final p = TovoLocation.recente;
    _client = p == null ? null : (lat: p.latitude, lng: p.longitude);
    final ici = _client ?? widget.commerces.first.position;
    _t = estLeJour(ici.lat, ici.lng) ? _Teinte.jourEpure : _Teinte.nuitCanard;
    unawaited(_preparer());
  }

  @override
  void dispose() {
    _horloge?.cancel();
    unawaited(_gps?.cancel());
    _pages.dispose();
    _carte?.dispose();
    super.dispose();
  }

  Future<void> _preparer() async {
    if (_t.nuit) {
      _styleNuit = await rootBundle.loadString(
        'assets/carte/style-nuit-commerces.json',
      );
    }
    if (_client == null) {
      final p = await TovoLocation.current();
      if (p != null) _client = (lat: p.latitude, lng: p.longitude);
    }
    if (!mounted) return;
    await _dessinerFixes();
    if (!mounted) return;
    setState(() {});
    unawaited(_choisir(0, deplacerPage: false));
    unawaited(_animerAvatar());
  }

  // ------------------------------------------------------------ avatar

  Future<void> _animerAvatar() async {
    final avatar = ImagesAvatar(await ImagesAvatar.choisi());
    await avatar.chargerFiche();
    if (!mounted) return;
    _avatar = avatar;
    final moteur = MoteurAvatar(fiche: avatar.fiche);
    _moteur = moteur;
    final client = _client;
    if (client != null) moteur.gps(client, vitesseMs: 0);
    // Le GPS en continu, à la meilleure précision, tant que l'écran est ouvert.
    _gps =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
          ),
        ).listen((p) {
          moteur.gps(
            (lat: p.latitude, lng: p.longitude),
            vitesseMs: p.speed,
            capDeg: p.heading,
            precisionM: p.accuracy,
          );
        }, onError: (_) {});
    // 15 images par seconde : assez pour un pas fluide, sans saturer la carte.
    _avant = DateTime.now();
    _horloge = Timer.periodic(const Duration(milliseconds: 66), (_) => _tic());
  }

  void _tic() {
    final avatar = _avatar;
    final moteur = _moteur;
    if (avatar == null || moteur == null || !mounted) return;
    final maintenant = DateTime.now();
    final dt = maintenant.difference(_avant).inMicroseconds / 1e6;
    _avant = maintenant;
    final etat = moteur.avancer(dt);
    if (etat == null) return;
    final t = ImagesAvatar.inclinaisonPour(_tilt);
    final d = ImagesAvatar.directionPour(etat.capDeg, _bearing);
    avatar.prechauffer(etat.animation, t, d, _ratio);
    final bande = avatar.bande(etat.animation, t, d, _ratio);
    final image = bande == null || bande.isEmpty
        ? _imageAvatar
        : bande[etat.image % bande.length];
    final avant = _etat;
    final bouge =
        avant == null ||
        metres(avant.position, etat.position) > 0.05 ||
        !identical(image, _imageAvatar);
    _etat = etat;
    if (bouge) {
      setState(() => _imageAvatar = image);
    }
  }

  // ------------------------------------------------------------ dessins

  double get _ratio => MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;

  /// Dessine en points, rend à la densité de l'écran : net partout.
  Future<BitmapDescriptor> _image(
    Size taille,
    void Function(Canvas c) dessin,
  ) async {
    final ratio = _ratio;
    final r = ui.PictureRecorder();
    final c = Canvas(r)..scale(ratio);
    dessin(c);
    final net = await r.endRecording().toImage(
      (taille.width * ratio).ceil(),
      (taille.height * ratio).ceil(),
    );
    final octets = await net.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      octets!.buffer.asUint8List(),
      imagePixelRatio: ratio,
    );
  }

  TextPainter _texte(
    String texte,
    Color couleur, {
    double taille = 12,
    FontWeight poids = FontWeight.w600,
    double espacement = 0,
  }) => TextPainter(
    text: TextSpan(
      text: texte,
      style: TextStyle(
        fontFamily: TovoTheme.policeClient,
        fontFamilyFallback: const [TovoTheme.fontFamily],
        fontSize: taille,
        fontWeight: poids,
        letterSpacing: espacement,
        height: 1.1,
        color: couleur,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: 220);

  /// Un texte détouré (repère, quartier), ancré en son centre.
  Future<(BitmapDescriptor, Offset)> _etiquetteTexte(
    String texte,
    Color couleur,
    double taille,
    FontWeight poids, {
    double espacement = 0,
  }) async {
    final libelle = _texte(
      texte,
      couleur,
      taille: taille,
      poids: poids,
      espacement: espacement,
    );
    final contour = TextPainter(
      text: TextSpan(
        text: texte,
        style: TextStyle(
          fontFamily: TovoTheme.policeClient,
          fontFamilyFallback: const [TovoTheme.fontFamily],
          fontSize: taille,
          fontWeight: poids,
          letterSpacing: espacement,
          height: 1.1,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeJoin = StrokeJoin.round
            ..color = _t.halo,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 220);
    final taillePx = Size(libelle.width + 8, libelle.height + 8);
    final image = await _image(taillePx, (c) {
      contour.paint(c, const Offset(4, 4));
      libelle.paint(c, const Offset(4, 4));
    });
    return (image, const Offset(0.5, 0.5));
  }

  /// L'épingle rouge : la pointe sur la boutique, une ombre au sol.
  Future<BitmapDescriptor> _epingle() => _image(const Size(30, 46), (c) {
    c.drawOval(
      Rect.fromCenter(center: const Offset(15, 43), width: 12, height: 5),
      Paint()
        ..color = const Color(0x73000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    final chemin = Path()
      ..moveTo(15, 43)
      ..cubicTo(15, 43, 2, 27, 2, 16)
      ..arcToPoint(const Offset(28, 16), radius: const Radius.circular(13))
      ..cubicTo(28, 27, 15, 43, 15, 43)
      ..close();
    c.drawPath(chemin, Paint()..color = const Color(0xFFEA4335));
    c.drawPath(
      chemin,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFFB31412),
    );
    c.drawCircle(
      const Offset(15, 16),
      5,
      Paint()..color = const Color(0xFF7A0C0B),
    );
  });

  /// Un commerce non choisi : un cercle numéroté (carré pour un partenaire).
  Future<BitmapDescriptor> _numero(int n, bool tovo) =>
      _image(const Size(28, 28), (c) {
        final r = RRect.fromRectAndRadius(
          const Rect.fromLTWH(2, 2, 24, 24),
          Radius.circular(tovo ? 7 : 12),
        );
        c.drawRRect(r, Paint()..color = tovo ? _t.cercleBord : _t.cercleFond);
        if (!tovo) {
          c.drawRRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = _t.cercleBord,
          );
        }
        final t = _texte(
          '$n',
          tovo ? _t.cercleFond : _t.cercleTexte,
          taille: 12,
          poids: FontWeight.w700,
        );
        t.paint(c, Offset(14 - t.width / 2, 14 - t.height / 2));
      });

  /// « Vous » : un point, son contour et son halo.
  Future<BitmapDescriptor> _vous() => _image(const Size(40, 40), (c) {
    c.drawCircle(const Offset(20, 20), 19, Paint()..color = _t.vousHalo);
    c.drawCircle(const Offset(20, 20), 8.5, Paint()..color = _t.vousBord);
    c.drawCircle(const Offset(20, 20), 6, Paint()..color = _t.vous);
  });

  /// Le nom du commerce choisi : une étiquette blanche au-dessus de
  /// l'épingle (ancrée sur la boutique, au pied de l'épingle).
  Future<(BitmapDescriptor, Offset)> _nomChoisi(String nom) async {
    final t = _texte(
      nom,
      const Color(0xFF0A0A0A),
      taille: 12.5,
      poids: FontWeight.w700,
    );
    final largeur = math.max(t.width + 22, 30.0);
    const hauteurPilule = 26.0;
    const sousLaPilule = 52.0; // la place de l'épingle
    final taille = Size(largeur + 8, hauteurPilule + sousLaPilule + 4);
    final image = await _image(taille, (c) {
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(4, 2, largeur, hauteurPilule),
        const Radius.circular(13),
      );
      c.drawRRect(
        r.shift(const Offset(0, 2)),
        Paint()
          ..color = const Color(0x40000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      c.drawRRect(r, Paint()..color = Colors.white);
      t.paint(
        c,
        Offset(4 + (largeur - t.width) / 2, 2 + (hauteurPilule - t.height) / 2),
      );
    });
    return (image, const Offset(0.5, 1));
  }

  Future<void> _dessinerFixes() async {
    _images['epingle'] = await _epingle();
    _images['vous'] = await _vous();
    for (var i = 0; i < widget.commerces.length; i++) {
      _images['n$i'] = await _numero(i + 1, widget.commerces[i].tovo);
    }
  }

  // ------------------------------------------------------------ données

  Future<void> _choisir(int i, {bool deplacerPage = true}) async {
    setState(() => _choisi = i);
    if (deplacerPage && _pages.hasClients) {
      unawaited(
        _pages.animateToPage(
          i,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        ),
      );
    }
    final c = widget.commerces[i];
    final nom = await _nomChoisi(c.nom);
    if (!mounted) return;
    _images['nom$i'] = nom.$1;
    await _cadrer();
    if (!_itineraires.containsKey(i)) await _chargerItineraire(i);
  }

  Future<void> _chargerItineraire(int i) async {
    final client = _client;
    if (client == null) return;
    final c = widget.commerces[i];
    final r = await _api.get(
      '/carte/itineraire',
      query: {
        'de': '${client.lat},${client.lng}',
        'a': '${c.position.lat},${c.position.lng}',
      },
    );
    if (!mounted || !r.ok) return;
    final raw = r.raw;
    final code = raw['polyline'] as String?;
    final reperes = <({String nom, Point position})>[];
    for (final x in (raw['reperes'] as List? ?? const [])) {
      if (x is Map && x['lat'] is num && x['lng'] is num) {
        reperes.add((
          nom: '${x['nom']}',
          position: (
            lat: (x['lat'] as num).toDouble(),
            lng: (x['lng'] as num).toDouble(),
          ),
        ));
      }
    }
    final it = _Itineraire(
      trace: code == null ? [client, c.position] : decoderPolyline(code),
      distanceM: (raw['distance_m'] as num?)?.toInt() ?? 0,
      dureeS: (raw['duree_s'] as num?)?.toInt(),
      quartier: raw['quartier'] as String?,
      reperes: reperes,
    );
    // Les étiquettes de ce trajet : le quartier en avant, les repères.
    if (it.quartier != null && it.quartier!.isNotEmpty) {
      final q = await _etiquetteTexte(
        it.quartier!.toUpperCase(),
        _t.quartier,
        12,
        FontWeight.w800,
        espacement: 1.2,
      );
      _images['q$i'] = q.$1;
    }
    for (var k = 0; k < reperes.length; k++) {
      final e = await _etiquetteTexte(
        reperes[k].nom,
        _t.repere,
        10.5,
        FontWeight.w600,
      );
      _images['r$i-$k'] = e.$1;
    }
    if (!mounted) return;
    setState(() => _itineraires[i] = it);
  }

  /// Le client et le commerce choisi dans le cadre, entre la barre du haut
  /// et la fiche du bas.
  Future<void> _cadrer() async {
    final carte = _carte;
    if (carte == null) return;
    final c = widget.commerces[_choisi].position;
    final points = [c, ?_client];
    if (points.length == 1) {
      await carte.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(c.lat, c.lng), 16),
      );
      return;
    }
    final sud = (
      lat: points.map((p) => p.lat).reduce(math.min),
      lng: points.map((p) => p.lng).reduce(math.min),
    );
    final nord = (
      lat: points.map((p) => p.lat).reduce(math.max),
      lng: points.map((p) => p.lng).reduce(math.max),
    );
    await carte.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(sud.lat, sud.lng),
          northeast: LatLng(nord.lat, nord.lng),
        ),
        56,
      ),
    );
  }

  // ------------------------------------------------------------ carte

  Set<Marker> _marqueurs() {
    final m = <Marker>{};
    final client = _client;
    final avatar = _imageAvatar;
    final etat = _etat;
    if (avatar != null && etat != null) {
      m.add(
        Marker(
          markerId: const MarkerId('vous'),
          position: LatLng(etat.position.lat, etat.position.lng),
          icon: avatar,
          // Les pieds de l'avatar sur la position du client.
          anchor: ImagesAvatar.ancre,
          zIndexInt: 4,
          consumeTapEvents: true,
        ),
      );
    } else if (client != null && _images['vous'] != null) {
      m.add(
        Marker(
          markerId: const MarkerId('vous'),
          position: LatLng(client.lat, client.lng),
          icon: _images['vous']!,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: 3,
        ),
      );
    }
    for (var i = 0; i < widget.commerces.length; i++) {
      final c = widget.commerces[i];
      final choisi = i == _choisi;
      final image = choisi ? _images['epingle'] : _images['n$i'];
      if (image == null) continue;
      m.add(
        Marker(
          markerId: MarkerId('c$i'),
          position: LatLng(c.position.lat, c.position.lng),
          icon: image,
          // L'épingle : sa pointe (y = 43 sur 46) sur la boutique.
          anchor: choisi ? const Offset(0.5, 43 / 46) : const Offset(0.5, 0.5),
          zIndexInt: choisi ? 5 : 2,
          onTap: () => _choisir(i),
        ),
      );
      if (choisi && _images['nom$i'] != null) {
        m.add(
          Marker(
            markerId: const MarkerId('nom'),
            position: LatLng(c.position.lat, c.position.lng),
            icon: _images['nom$i']!,
            anchor: const Offset(0.5, 1),
            zIndexInt: 6,
            consumeTapEvents: true,
          ),
        );
      }
    }
    final it = _itineraires[_choisi];
    if (it != null) {
      if (_images['q$_choisi'] != null) {
        final c = widget.commerces[_choisi].position;
        // Le quartier sous l'épingle, jamais dessus.
        m.add(
          Marker(
            markerId: const MarkerId('quartier'),
            position: LatLng(c.lat - 0.0011, c.lng),
            icon: _images['q$_choisi']!,
            anchor: const Offset(0.5, 0),
            zIndexInt: 1,
            consumeTapEvents: true,
          ),
        );
      }
      for (var k = 0; k < it.reperes.length; k++) {
        final image = _images['r$_choisi-$k'];
        if (image == null) continue;
        final p = it.reperes[k].position;
        m.add(
          Marker(
            markerId: MarkerId('repere$k'),
            position: LatLng(p.lat, p.lng),
            icon: image,
            anchor: const Offset(0.5, 0.5),
            zIndexInt: 1,
            consumeTapEvents: true,
          ),
        );
      }
    }
    return m;
  }

  Set<Polyline> _traces() {
    final it = _itineraires[_choisi];
    if (it == null || it.trace.length < 2) return const {};
    final points = [for (final p in it.trace) LatLng(p.lat, p.lng)];
    // Deux traits l'un sur l'autre : le plus large dessous.
    return {
      Polyline(
        polylineId: const PolylineId('bord'),
        points: points,
        color: _t.traceBord,
        width: 9,
        zIndex: 1,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
      Polyline(
        polylineId: const PolylineId('trace'),
        points: points,
        color: _t.trace,
        width: 5,
        zIndex: 2,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
    };
  }

  // ------------------------------------------------------------ actions

  void _agir(TovoInteraction i) {
    Navigator.of(context).pop();
    widget.onInteraction(i);
  }

  Future<void> _yAller(CommerceSurCarte c) async {
    // Étape 2 : le guidage de Google Maps. L'immersion avec l'avatar viendra.
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${c.position.lat},${c.position.lng}&travelmode=driving',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // ------------------------------------------------------------ écran

  @override
  Widget build(BuildContext context) {
    final marges = MediaQuery.paddingOf(context);
    final premier = widget.commerces[_choisi].position;
    final centre = _client ?? premier;
    final pret = _images['epingle'] != null && (!_t.nuit || _styleNuit != null);
    return Scaffold(
      backgroundColor: _t.fond,
      body: Stack(
        children: [
          if (pret)
            GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(centre.lat, centre.lng),
                zoom: 14.5,
              ),
              style: _t.nuit ? _styleNuit : ThemeCarte.clair.style,
              // La barre du haut et la fiche du bas ne cachent rien.
              padding: EdgeInsets.only(top: marges.top + 64, bottom: 210),
              onMapCreated: (carte) {
                _carte = carte;
                unawaited(_cadrer());
              },
              onCameraMove: (position) {
                _bearing = position.bearing;
                _tilt = position.tilt;
              },
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(
                  EagerGestureRecognizer.new,
                ),
              },
              markers: _marqueurs(),
              polylines: _traces(),
              zoomControlsEnabled: false,
              myLocationButtonEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: false,
              buildingsEnabled: false,
              trafficEnabled: false,
              indoorViewEnabled: false,
              minMaxZoomPreference: const MinMaxZoomPreference(11, 19),
            ),
          Positioned(
            top: marges.top + 8,
            left: 16,
            right: 16,
            child: Row(
              children: [
                _Rond(
                  t: _t,
                  etiquette: 'Retour',
                  icone: Icons.arrow_back_ios_new_rounded,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: _t.panneau,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: _t.panneauBord),
                    ),
                    child: Text(
                      widget.titre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _t.texte,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _Rond(
                  t: _t,
                  etiquette: 'Recentrer',
                  icone: Icons.center_focus_strong_rounded,
                  onTap: _cadrer,
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: marges.bottom + 18,
            child: SizedBox(
              height: 168,
              child: PageView.builder(
                controller: _pages,
                itemCount: widget.commerces.length,
                onPageChanged: (i) => _choisir(i, deplacerPage: false),
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: _Fiche(
                    t: _t,
                    commerce: widget.commerces[i],
                    numero: i + 1,
                    total: widget.commerces.length,
                    itineraire: _itineraires[i],
                    precedent: i > 0 ? () => _choisir(i - 1) : null,
                    suivant: i < widget.commerces.length - 1
                        ? () => _choisir(i + 1)
                        : null,
                    faireLivrer: () {
                      final c = widget.commerces[i];
                      if (c.tovo) {
                        _agir(
                          TovoInteraction('select_merchant', {
                            'merchant_id': c.idBoutique,
                            'apercu': {
                              'name': c.nom,
                              'logo_url': ?((c.logo ?? '').isEmpty
                                  ? null
                                  : c.logo),
                            },
                          }),
                        );
                      } else if (c.livreur != null) {
                        _agir(
                          TovoInteraction('quick_reply', {
                            'value': c.livreur!['value'],
                            'label':
                                c.livreur!['label'] ?? 'Envoyer un livreur',
                          }),
                        );
                      }
                    },
                    yAller: () => _yAller(widget.commerces[i]),
                    appeler: widget.commerces[i].telephone == null
                        ? null
                        : () => widget.onInteraction(
                            TovoInteraction('call_phone', {
                              'phone': widget.commerces[i].telephone,
                            }),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Rond extends StatelessWidget {
  const _Rond({
    required this.t,
    required this.etiquette,
    required this.icone,
    required this.onTap,
  });

  final _Teinte t;
  final String etiquette;
  final IconData icone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: etiquette,
    child: Material(
      color: t.panneau,
      shape: CircleBorder(side: BorderSide(color: t.panneauBord)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icone, size: 18, color: t.texte),
        ),
      ),
    ),
  );
}

/// La fiche d'un commerce, flottante, décollée du bas.
class _Fiche extends StatelessWidget {
  const _Fiche({
    required this.t,
    required this.commerce,
    required this.numero,
    required this.total,
    required this.itineraire,
    required this.precedent,
    required this.suivant,
    required this.faireLivrer,
    required this.yAller,
    required this.appeler,
  });

  final _Teinte t;
  final CommerceSurCarte commerce;
  final int numero;
  final int total;
  final _Itineraire? itineraire;
  final VoidCallback? precedent;
  final VoidCallback? suivant;
  final VoidCallback faireLivrer;
  final VoidCallback yAller;
  final VoidCallback? appeler;

  @override
  Widget build(BuildContext context) {
    final distance = itineraire?.distanceM ?? commerce.distanceM;
    final minutes = itineraire?.dureeS == null
        ? null
        : math.max(1, (itineraire!.dureeS! / 60).round());
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: t.panneau,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: t.panneauBord),
        boxShadow: const [
          BoxShadow(
            color: Color(0x8C000C10),
            blurRadius: 36,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Fleche(
                t: t,
                icone: Icons.chevron_left_rounded,
                etiquette: 'Commerce précédent',
                onTap: precedent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      commerce.nom,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: TovoTheme.policeNoms,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: t.texte,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      commerce.sousTitre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: t.second),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (distance != null)
                    Text(
                      Money.distance(distance),
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: t.distance,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  Text(
                    minutes != null ? '~$minutes min' : '$numero / $total',
                    style: TextStyle(fontSize: 12, color: t.second),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              _Fleche(
                t: t,
                icone: Icons.chevron_right_rounded,
                etiquette: 'Commerce suivant',
                onTap: suivant,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _Bouton(
                  t: t,
                  icone: commerce.tovo
                      ? Icons.shopping_bag_outlined
                      : Icons.two_wheeler_rounded,
                  texte: commerce.tovo ? 'Commander' : 'Faire livrer',
                  onTap: commerce.tovo || commerce.livreur != null
                      ? faireLivrer
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _Bouton(
                  t: t,
                  icone: Icons.navigation_outlined,
                  texte: 'Y aller',
                  onTap: yAller,
                ),
              ),
              if (appeler != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: _Bouton(
                    t: t,
                    icone: Icons.call_outlined,
                    texte: 'Appeler',
                    onTap: appeler,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Fleche extends StatelessWidget {
  const _Fleche({
    required this.t,
    required this.icone,
    required this.etiquette,
    required this.onTap,
  });

  final _Teinte t;
  final IconData icone;
  final String etiquette;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: etiquette,
    child: Material(
      color: t.bouton,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            icone,
            size: 20,
            color: onTap == null ? t.second.withValues(alpha: 0.4) : t.texte,
          ),
        ),
      ),
    ),
  );
}

/// Un bouton doux, jamais noir (demande du fondateur, 07/10).
class _Bouton extends StatelessWidget {
  const _Bouton({
    required this.t,
    required this.icone,
    required this.texte,
    required this.onTap,
  });

  final _Teinte t;
  final IconData icone;
  final String texte;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: t.bouton,
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icone, size: 17, color: t.texte),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                texte,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.texte,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
