import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api.dart';
import '../../core/icones_phosphor.dart';
import '../../core/position_livreur.dart';
import '../../core/soleil.dart';
import 'carte_suivi_theme.dart';

/// Les étapes de la carte, lues du statut de la commande et de la position
/// du livreur (handoff « Suivi livreur », 27/09).
enum EtapeCarte {
  /// Commande confirmée, pas encore de livreur : tout le trajet, à plat.
  confirmee,

  /// Un livreur file vers la boutique (ou le colis).
  preparation,

  /// Il y est : la boutique pulse.
  auDepart,

  /// Commande récupérée : on suit le livreur, rue par rue.
  enRoute,

  /// À moins de 300 m (le long de la route) : le domicile pulse.
  proche,

  /// Livrée : le domicile, sans livreur.
  livree,
}

/// Le thème de la carte : selon le soleil (par défaut), ou forcé.
enum ThemeChoisi { auto, clair, sombre }

/// Comment la caméra suit la course.
enum VueCarte {
  /// Par étape, nord en haut (le handoff).
  ensemble,

  /// Juste derrière le livreur, la carte tournée dans son sens de marche.
  derriere,

  /// Vue aérienne : tout le trajet d'en haut, à plat, nord en haut.
  aerienne,

  /// Le client a pris la main (zoom, rotation, inclinaison au doigt).
  libre,
}

/// L'écran de suivi : la carte, un bouton retour, le choix du thème et deux
/// boutons de vue.
///
/// - Thème clair ou sombre selon le vrai lever et coucher du soleil chez le
///   client ; bascule en fondu, réévaluée chaque minute. Un petit bouton
///   force clair ou sombre (auto → clair → sombre), gardé d'une fois à
///   l'autre. La barre d'état suit : noire sur clair, blanche sur sombre.
/// - La carte se manipule librement : zoom, rotation et inclinaison au
///   doigt. « Recentrer » rend la main à la caméra automatique.
/// - Caméra automatique : par étape (vue d'ensemble, nord en haut), ou
///   « derrière le livreur », tournée dans son sens de marche.
/// - Le livreur avance à chaque image le long de la route
///   (LivreurSurRoute), sans bonds.
/// - Le livreur est un scooter 3D (« Low poly scooter », Thomas Saint Pierre),
///   rendu sous 4 inclinaisons × 36 directions : on affiche la vue qui correspond
///   à l'angle réel de la caméra — de profil dans un virage, de dos quand
///   il s'éloigne. Debout face à l'écran, il ne s'écrase jamais.
/// - En route, l'arrivée estimée : « Arrivée dans 12 min » (durée Google
///   Routes du trajet, au prorata de ce qui reste).
///
/// Le logo Google reste visible : les conditions de Google Maps l'exigent.
class CarteSuivi extends StatefulWidget {
  const CarteSuivi({
    required this.moto,
    required this.revision,
    required this.orderId,
    required this.statut,
    required this.livreurPresent,
    this.depart,
    this.client,
    this.nomDepart = '',
    this.colis = false,
    this.clientEstVous = true,
    this.onRetour,
    super.key,
  });

  /// Les positions reçues, brutes : la dernière, sa vitesse, et une glisse
  /// en ligne droite quand aucun tracé n'est connu.
  final MotoAnimee moto;

  /// Change à chaque position reçue.
  final int revision;
  final String orderId;
  final String statut;
  final bool livreurPresent;

  /// La boutique, ou le colis à récupérer.
  final Point? depart;

  /// Où la commande est livrée.
  final Point? client;
  final String nomDepart;
  final bool colis;

  /// « Vous » sur la pastille du client ; sinon « Arrivée ».
  final bool clientEstVous;
  final VoidCallback? onRetour;

  @override
  State<CarteSuivi> createState() => _CarteSuiviState();
}

class _CarteSuiviState extends State<CarteSuivi>
    with SingleTickerProviderStateMixin {
  static const _fondu = Duration(milliseconds: 600);

  /// Les inclinaisons de caméra sous lesquelles la moto a été rendue.
  static const _inclinaisons = [0, 30, 45, 60];

  final _api = TovoApi();
  GoogleMapController? _carte;
  late final Ticker _images;
  Timer? _horloge;

  ThemeCarte _theme = ThemeCarte.sombre;

  /// Choisi d'un geste par le client, gardé d'une ouverture à l'autre.
  ThemeChoisi _choix = ThemeChoisi.auto;
  static const _cleChoix = 'carte_suivi_theme';
  Color? _fondAvant;
  final Map<String, BitmapDescriptor> _pastilles = {};
  final Map<String, Offset> _ancres = {};
  ThemeCarte? _pastillesDuTheme;

  /// [inclinaison][direction] : 4 × 36 vues de la moto.
  List<List<BitmapDescriptor>> _vespa = const [];

  /// Durée du trajet selon Google Routes, en secondes (pour l'arrivée).
  double? _dureeTrajetS;

  TraceMesure? _trajet;
  TraceMesure? _approche;
  DateTime? _derniereDemande;

  /// Le livreur sur le tracé qu'il suit ; nul hors tracé (glisse droite).
  LivreurSurRoute? _surRoute;

  // Passage d'une source à l'autre (tracé ↔ ligne droite) : un fondu de
  // 600 ms depuis le dernier point affiché, jamais de saut.
  Point? _dernierAffiche;
  Point? _fonduDepuis;
  DateTime? _debutFondu;
  double? _capLisse;

  /// Vitesse du scooter à l'écran (m/s), lissée.
  double _vitesseAffichee = 0;

  /// Un léger balancement quand il roule (retour du 28/09) : ±1,6° au plus,
  /// à ~1,1 Hz, proportionnel à la vitesse jusqu'à 30 km/h ; nul à l'arrêt.
  /// Calculé à chaque image, comme le déplacement : aucune saccade.
  double _roulis() {
    final ampleur = 1.6 * (_vitesseAffichee / 8.3).clamp(0.0, 1.0);
    if (ampleur < 0.05) return 0;
    final t = DateTime.now().millisecondsSinceEpoch / 1000;
    return ampleur * math.sin(2 * math.pi * 1.1 * t);
  }

  VueCarte _vue = VueCarte.ensemble;

  /// La caméra telle qu'elle est vraiment (suivie, ou déplacée au doigt).
  CameraPosition? _camera;
  Duration _derniereImage = Duration.zero;
  Size _taille = const Size(390, 800);
  bool _doigt = false;

  // La partie fixe des tracés (bordure, restant « loin »), gardée tant
  // qu'elle ne change pas : seul le restant « proche » est renvoyé à chaque
  // image (voir _traces).
  Set<Polyline> _tracesAffiches = const {};
  String _cleTraces = '';

  @override
  void initState() {
    super.initState();
    _theme = _themeDuMoment();
    _images = createTicker(_image)..start();
    _horloge = Timer.periodic(const Duration(seconds: 60), (_) {
      final t = _themeDuMoment();
      if (mounted && t.nuit != _theme.nuit) {
        setState(() {
          _fondAvant = _theme.fond;
          _theme = t;
        });
      }
    });
    unawaited(_chargerVespa());
    unawaited(_demanderTraces(force: true));
    unawaited(_lireChoix());
  }

  Future<void> _lireChoix() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lu = ThemeChoisi.values.asNameMap()[prefs.getString(_cleChoix)];
      if (lu != null && mounted) _appliquerChoix(lu, fondu: false);
    } on Object {
      // Préférences illisibles : le thème automatique fait très bien.
    }
  }

  /// Auto → clair → sombre → auto : un seul petit bouton, trois états.
  void _changerDeTheme() {
    final suivant =
        ThemeChoisi.values[(_choix.index + 1) % ThemeChoisi.values.length];
    _appliquerChoix(suivant);
    unawaited(
      SharedPreferences.getInstance()
          .then((p) => p.setString(_cleChoix, suivant.name))
          .catchError((Object _) => false),
    );
  }

  void _appliquerChoix(ThemeChoisi choix, {bool fondu = true}) {
    _choix = choix;
    final t = _themeDuMoment();
    setState(() {
      if (fondu && t.nuit != _theme.nuit) _fondAvant = _theme.fond;
      _theme = t;
    });
  }

  @override
  void didUpdateWidget(CarteSuivi avant) {
    super.didUpdateWidget(avant);
    if (avant.statut != widget.statut) {
      unawaited(_demanderTraces(force: true));
    }
    if (avant.revision != widget.revision) _recevoir();
  }

  @override
  void dispose() {
    _images.dispose();
    _horloge?.cancel();
    _carte?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- thème

  ThemeCarte _themeDuMoment() {
    if (_choix == ThemeChoisi.clair) return ThemeCarte.clair;
    if (_choix == ThemeChoisi.sombre) return ThemeCarte.sombre;
    final ici =
        widget.client ??
        widget.depart ??
        widget.moto.derniere ??
        (lat: 13.5137, lng: 2.1098);
    return estLeJour(ici.lat, ici.lng) ? ThemeCarte.clair : ThemeCarte.sombre;
  }

  /// Les 144 vues de la moto, 100 points de côté (elle y fait ~80 points de
  /// long, quel que soit le zoom).
  Future<void> _chargerVespa() async {
    Future<BitmapDescriptor> vue(int inclinaison, int direction) =>
        BitmapDescriptor.asset(
          const ImageConfiguration(),
          'assets/carte/scooter/scooter_t${inclinaison}_'
          '${(direction * 10).toString().padLeft(3, '0')}.png',
          width: 100,
          height: 100,
        );
    final vues = await Future.wait([
      for (final t in _inclinaisons)
        Future.wait([for (var i = 0; i < 36; i++) vue(t, i)]),
    ]);
    if (!mounted) return;
    setState(() => _vespa = vues);
  }

  Future<void> _preparerPastilles() async {
    final t = _theme;
    if (_pastillesDuTheme == t) return;
    _pastillesDuTheme = t;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;

    // Dessinées en points, rendues à la densité de l'écran : nettes partout.
    Future<BitmapDescriptor> image(Dessin d) async {
      final r = ui.PictureRecorder();
      Canvas(r)
        ..scale(ratio)
        ..drawPicture(d.image);
      final net = await r.endRecording().toImage(
        (d.taille.width * ratio).round(),
        (d.taille.height * ratio).round(),
      );
      final octets = await net.toByteData(format: ui.ImageByteFormat.png);
      return BitmapDescriptor.bytes(
        octets!.buffer.asUint8List(),
        imagePixelRatio: ratio,
      );
    }

    Offset ancre(Dessin d) =>
        Offset(d.ancre.dx / d.taille.width, d.ancre.dy / d.taille.height);

    final depart = dessinerPastille(
      t,
      icone: widget.colis ? Phosphor.package : Phosphor.forkKnife,
      texte: widget.nomDepart.isEmpty
          ? (widget.colis ? 'Colis' : 'Boutique')
          : widget.nomDepart,
    );
    final client = dessinerPastille(
      t,
      icone: widget.clientEstVous ? Phosphor.houseLine : Phosphor.mapPin,
      texte: widget.clientEstVous ? 'Vous' : 'Arrivée',
      vous: true,
    );
    final images = {
      'depart': await image(depart),
      'client': await image(client),
    };
    if (!mounted || _pastillesDuTheme != t) return;
    setState(() {
      _pastilles
        ..clear()
        ..addAll(images);
      _ancres
        ..['depart'] = ancre(depart)
        ..['client'] = ancre(client);
      _cleTraces = '';
    });
  }

  // --------------------------------------------------------------- tracés

  bool get _recupere =>
      const {'picked_up', 'delivering'}.contains(widget.statut);

  Future<void> _demanderTraces({bool force = false}) async {
    final avant = _derniereDemande;
    if (!force &&
        avant != null &&
        DateTime.now().difference(avant) < const Duration(seconds: 20)) {
      return;
    }
    _derniereDemande = DateTime.now();
    final reponse = await _api.get('/orders/${widget.orderId}/itineraire');
    if (!mounted || !reponse.ok) return;
    TraceMesure? lire(Object? v) {
      final code = v is Map ? v['polyline'] : null;
      return code is String && code.isNotEmpty
          ? TraceMesure(decoderPolyline(code))
          : null;
    }

    setState(() {
      _trajet = lire(reponse.raw['trajet']);
      final trajet = reponse.raw['trajet'];
      _dureeTrajetS = trajet is Map
          ? (trajet['duree_s'] as num?)?.toDouble()
          : null;
      _approche = lire(reponse.raw['approche']);
      _cleTraces = '';
    });
    _recevoir();
  }

  // ------------------------------------------------------------- livreur

  /// Une position reçue : projetée sur le tracé que suit le livreur.
  void _recevoir() {
    final p = widget.moto.derniere;
    if (p == null) return;
    final trace = _recupere ? _trajet : _approche;
    final avant = _surRoute;
    if (trace == null || trace.points.length < 2) {
      if (avant != null) _commencerFondu();
      _surRoute = null;
      return;
    }
    final suivi = avant != null && identical(avant.trace, trace)
        ? avant
        : LivreurSurRoute(trace);
    if (!suivi.recevoir(p, vitesseKmh: widget.moto.vitesseKmh)) {
      // Il a pris une autre rue : nouveau tracé, et d'ici là, la glisse
      // droite vers ses positions — en fondu, pas en saut.
      if (avant != null) _commencerFondu();
      _surRoute = null;
      unawaited(_demanderTraces());
      return;
    }
    if (!identical(suivi, avant)) _commencerFondu();
    _surRoute = suivi;
  }

  void _commencerFondu() {
    _fonduDepuis = _dernierAffiche;
    _debutFondu = DateTime.now();
  }

  /// Où dessiner le livreur maintenant.
  Point? _livreur() {
    final surRoute = _surRoute;
    final source = surRoute?.position ?? widget.moto.position();
    if (source == null) return null;
    var ici = source;
    final depuis = _fonduDepuis;
    final debut = _debutFondu;
    if (depuis != null && debut != null) {
      final f =
          DateTime.now().difference(debut).inMilliseconds /
          _fondu.inMilliseconds;
      if (f >= 1) {
        _fonduDepuis = null;
      } else {
        final e = Curves.easeOut.transform(f.clamp(0.0, 1.0));
        ici = (
          lat: depuis.lat + (source.lat - depuis.lat) * e,
          lng: depuis.lng + (source.lng - depuis.lng) * e,
        );
      }
    }
    _dernierAffiche = ici;
    return ici;
  }

  /// Le cap affiché : celui du tracé (déjà lissé), sinon celui de la glisse
  /// droite, lissé ici par le chemin le plus court.
  double _cap(double dt) {
    final vise = _surRoute?.capDegres ?? widget.moto.capDegres;
    final actuel = _capLisse;
    if (actuel == null || _surRoute?.capDegres != null) {
      return _capLisse = vise;
    }
    return _capLisse = _versAngle(actuel, vise, 1 - math.exp(-dt * 7));
  }

  static double _versAngle(double de, double vers, double k) {
    final ecart = ((vers - de + 540) % 360) - 180;
    return (de + ecart * k + 360) % 360;
  }

  // ---------------------------------------------------------------- étape

  EtapeCarte _etape(Point? livreur) {
    if (widget.statut == 'delivered') return EtapeCarte.livree;
    if (_recupere) {
      final surRoute = _surRoute;
      final trajet = _trajet;
      final client = widget.client;
      final reste =
          surRoute != null &&
              trajet != null &&
              identical(surRoute.trace, trajet) &&
              surRoute.d != null
          ? trajet.longueur - surRoute.d!
          : livreur != null && client != null
          ? metres(livreur, client) * 1.3
          : double.infinity;
      return reste < 300 ? EtapeCarte.proche : EtapeCarte.enRoute;
    }
    if (!widget.livreurPresent || livreur == null) return EtapeCarte.confirmee;
    final depart = widget.depart;
    if (depart != null && metres(livreur, depart) < 60) {
      return EtapeCarte.auDepart;
    }
    return EtapeCarte.preparation;
  }

  bool _livreurVisible(EtapeCarte etape, Point? livreur) =>
      livreur != null &&
      etape != EtapeCarte.confirmee &&
      etape != EtapeCarte.livree;

  // --------------------------------------------------------------- caméra

  /// Le zoom qui fait tenir deux points dans la carte, marges comprises.
  double _zoomPour(Point a, Point b, {double marge = 96}) {
    double x(Point p) => (p.lng + 180) / 360;
    double y(Point p) {
      final s = math.sin(p.lat * math.pi / 180);
      return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
    }

    final dx = (x(a) - x(b)).abs() * 256;
    final dy = (y(a) - y(b)).abs() * 256;
    final largeur = math.max(40.0, _taille.width - marge * 2);
    final hauteur = math.max(40.0, _taille.height - marge * 2.6);
    if (dx == 0 && dy == 0) return 16;
    final z = math.min(
      dx == 0 ? 30.0 : math.log(largeur / dx) / math.ln2,
      dy == 0 ? 30.0 : math.log(hauteur / dy) / math.ln2,
    );
    return z.clamp(11.0, 17.5).toDouble();
  }

  Point _milieu(Point a, Point b) =>
      (lat: (a.lat + b.lat) / 2, lng: (a.lng + b.lng) / 2);

  CameraPosition? _cible(EtapeCarte etape, Point? livreur) {
    final depart = widget.depart;
    final client = widget.client;
    CameraPosition vue(Point p, double zoom, double tilt) =>
        CameraPosition(target: LatLng(p.lat, p.lng), zoom: zoom, tilt: tilt);

    // Vue aérienne : tout ce qui compte encore — le livreur, la boutique
    // tant qu'il n'y est pas passé, le client — d'en haut, à plat.
    if (_vue == VueCarte.aerienne) {
      final points = [
        if (_livreurVisible(etape, livreur)) livreur!,
        if (!_recupere && depart != null) depart,
        ?client,
      ];
      if (points.isEmpty) return null;
      var sud = points.first;
      var nord = points.first;
      for (final p in points) {
        sud = (lat: math.min(sud.lat, p.lat), lng: math.min(sud.lng, p.lng));
        nord = (lat: math.max(nord.lat, p.lat), lng: math.max(nord.lng, p.lng));
      }
      return CameraPosition(
        target: LatLng((sud.lat + nord.lat) / 2, (sud.lng + nord.lng) / 2),
        zoom: points.length == 1 ? 15.5 : _zoomPour(sud, nord, marge: 110),
      );
    }

    // Derrière le livreur : la carte tournée dans son sens de marche,
    // inclinée, le livreur un peu en bas de l'écran pour voir la route
    // devant lui.
    if (_vue == VueCarte.derriere && _livreurVisible(etape, livreur)) {
      final cap = _capLisse ?? 0;
      final r = cap * math.pi / 180;
      const devant = 45.0; // mètres
      return CameraPosition(
        target: LatLng(
          livreur!.lat + devant * math.cos(r) / 110540,
          livreur.lng +
              devant *
                  math.sin(r) /
                  (111320 * math.cos(livreur.lat * math.pi / 180)),
        ),
        zoom: 17.6,
        tilt: 60,
        bearing: cap,
      );
    }
    switch (etape) {
      case EtapeCarte.confirmee:
        if (depart != null && client != null) {
          return vue(_milieu(depart, client), _zoomPour(depart, client), 0);
        }
        final seul = client ?? depart;
        return seul == null ? null : vue(seul, 15, 0);
      case EtapeCarte.preparation:
        if (livreur == null) return null;
        if (depart == null) return vue(livreur, 15, 45);
        return vue(
          _milieu(livreur, depart),
          math.min(15.5, _zoomPour(livreur, depart)),
          45,
        );
      case EtapeCarte.auDepart:
        final ici = depart ?? livreur;
        return ici == null ? null : vue(ici, 16.5, 50);
      case EtapeCarte.enRoute:
        return livreur == null ? null : vue(livreur, 16, 54);
      case EtapeCarte.proche:
        return livreur == null ? null : vue(livreur, 17.5, 54);
      case EtapeCarte.livree:
        final ici = client ?? livreur;
        return ici == null ? null : vue(ici, 17, 45);
    }
  }

  /// Chaque image (60 par seconde au plus) : le livreur avance ; en caméra
  /// automatique, la caméra se rapproche de sa cible par lissage
  /// exponentiel (k = 1 − e^(−dt·2,4)), cap compris.
  void _image(Duration maintenant) {
    if (!mounted) return;
    if (maintenant - _derniereImage < const Duration(milliseconds: 15)) return;
    final dt = ((maintenant - _derniereImage).inMicroseconds / 1e6).clamp(
      0.0,
      0.1,
    );
    _derniereImage = maintenant;
    final avant = _dernierAffiche;
    _surRoute?.avancer(dt);
    _cap(dt);
    final livreur = _livreur();
    // Sa vitesse à l'écran, lissée : elle règle le balancement.
    if (avant != null && livreur != null && dt > 0) {
      final instant = metres(avant, livreur) / dt;
      _vitesseAffichee +=
          (instant - _vitesseAffichee) * (1 - math.exp(-dt * 3));
    }
    final carte = _carte;
    if (_vue != VueCarte.libre && carte != null) {
      final cible = _cible(_etape(livreur), livreur);
      if (cible != null) {
        final actuelle = _camera ?? cible;
        final k = 1 - math.exp(-dt * 2.4);
        double vers(double a, double b) => a + (b - a) * k;
        final suivante = CameraPosition(
          target: LatLng(
            vers(actuelle.target.latitude, cible.target.latitude),
            vers(actuelle.target.longitude, cible.target.longitude),
          ),
          zoom: vers(actuelle.zoom, cible.zoom),
          tilt: vers(actuelle.tilt, cible.tilt),
          bearing: _versAngle(actuelle.bearing, cible.bearing, k),
        );
        _camera = suivante;
        unawaited(carte.moveCamera(CameraUpdate.newCameraPosition(suivante)));
      }
    }
    setState(() {});
  }

  // ---------------------------------------------------------------- dessin

  double get _metresParPoint {
    final zoom = _camera?.zoom ?? 15;
    final lat = (_camera?.target.latitude ?? 13.5) * math.pi / 180;
    return 156543.03 * math.cos(lat) / math.pow(2, zoom);
  }

  Set<Circle> _pulsations(EtapeCarte etape) {
    final t = DateTime.now().millisecondsSinceEpoch;
    final cercles = <Circle>{};
    final depart = widget.depart;
    if (depart != null &&
        (etape == EtapeCarte.confirmee || etape == EtapeCarte.auDepart)) {
      final f = (t % 1800) / 1800;
      cercles.add(
        Circle(
          circleId: const CircleId('pulsation-depart'),
          center: LatLng(depart.lat, depart.lng),
          radius: (18 + 52 * f) * _metresParPoint,
          strokeWidth: 2,
          strokeColor: _theme.pulsation.withValues(alpha: 1 - f),
          fillColor: Colors.transparent,
        ),
      );
    }
    final client = widget.client;
    if (client != null && etape == EtapeCarte.proche) {
      final f = (t % 2200) / 2200;
      cercles.add(
        Circle(
          circleId: const CircleId('pulsation-client'),
          center: LatLng(client.lat, client.lng),
          radius: (24 + 66 * f) * _metresParPoint,
          strokeWidth: 0,
          strokeColor: Colors.transparent,
          fillColor: _theme.pulsation.withValues(alpha: 0.35 * (1 - f)),
        ),
      );
    }
    return cercles;
  }

  /// Les tracés, en deux morceaux pour le restant :
  ///   - « proche » : de la moto jusqu'à ~150 m devant elle, recalculé à
  ///     CHAQUE IMAGE — quelques points seulement, donc léger ; le trait part
  ///     toujours pile de sous la moto (un envoi tous les 3 m laissait
  ///     déborder le trait derrière elle, retour du 27/09) ;
  ///   - « loin » : tout le reste, renvoyé seulement quand la moto a passé
  ///     le point de jonction — rarement.
  /// Renvoyer tout le tracé à chaque image alourdissait les gestes.
  Set<Polyline> _traces(EtapeCarte etape) {
    final surRoute = _surRoute;
    final t = _theme;
    List<LatLng> latLng(List<Point> points) => [
      for (final p in points) LatLng(p.lat, p.lng),
    ];
    Polyline ligne(
      String id,
      List<Point> points,
      Color couleur,
      int largeur,
      int z,
    ) => Polyline(
      polylineId: PolylineId(id),
      points: latLng(points),
      color: couleur,
      width: largeur,
      zIndex: z,
      jointType: JointType.round,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
    );

    final trajet = _trajet;
    final enCourse = etape == EtapeCarte.enRoute || etape == EtapeCarte.proche;
    final dTrajet =
        trajet != null && surRoute != null && identical(surRoute.trace, trajet)
        ? surRoute.d
        : null;
    final suivi = enCourse && dTrajet != null;
    // Le premier point du tracé à plus de 150 m devant la moto : toujours
    // DEVANT elle, même sur une longue ligne droite sans point intermédiaire.
    final jonction = suivi ? trajet!.indiceApres(dTrajet + 150) : -1;

    // La partie fixe : bordure, et le restant « loin ».
    final cle =
        '${etape.index}|${t.nuit}|$suivi|$jonction|'
        '${trajet.hashCode}|${_approche.hashCode}';
    if (cle != _cleTraces) {
      _cleTraces = cle;
      final fixes = <Polyline>{};
      if (trajet != null && etape != EtapeCarte.livree) {
        final opacite = enCourse ? 1.0 : 0.4;
        final loin = suivi
            ? (jonction < trajet.points.length
                  ? trajet.points.sublist(jonction)
                  : const <Point>[])
            : trajet.points;
        // La bordure sous tout le trajet : sous le restant, elle seule
        // montre la partie parcourue.
        fixes.add(ligne('bordure', trajet.points, t.traceBordure, 22, 1));
        final halo = t.traceHalo;
        if (loin.length >= 2) {
          if (halo != null) {
            fixes.add(
              ligne(
                'halo-loin',
                loin,
                halo.withValues(alpha: halo.a * opacite),
                20,
                2,
              ),
            );
          }
          fixes.add(
            ligne(
              'restant-loin',
              loin,
              t.traceRestant.withValues(alpha: opacite),
              13,
              3,
            ),
          );
        }
      }
      _tracesAffiches = fixes;
    }

    final traces = {..._tracesAffiches};
    // La partie vivante : de la moto à la jonction, à chaque image.
    if (suivi) {
      final proche = trajet!.entre(dTrajet, jonction);
      if (proche.length >= 2) {
        final halo = t.traceHalo;
        if (halo != null) {
          traces.add(ligne('halo-proche', proche, halo, 20, 2));
        }
        traces.add(ligne('restant-proche', proche, t.traceRestant, 13, 3));
      }
    }
    final approche = _approche;
    if (approche != null &&
        (etape == EtapeCarte.preparation || etape == EtapeCarte.auDepart)) {
      final dApproche = surRoute != null && identical(surRoute.trace, approche)
          ? surRoute.d
          : null;
      traces.add(
        Polyline(
          polylineId: const PolylineId('approche'),
          points: latLng(
            dApproche == null ? approche.points : approche.depuis(dApproche),
          ),
          color: t.approche,
          width: 6,
          zIndex: 4,
          patterns: [PatternItem.dot, PatternItem.gap(12)],
        ),
      );
    }
    return traces;
  }

  Set<Marker> _marqueurs(EtapeCarte etape, Point? livreur) {
    final marqueurs = <Marker>{};
    Marker pastille(String id, Point p, int z) => Marker(
      markerId: MarkerId(id),
      position: LatLng(p.lat, p.lng),
      icon: _pastilles[id]!,
      anchor: _ancres[id] ?? const Offset(0.5, 1),
      zIndexInt: z,
      consumeTapEvents: true,
    );
    final depart = widget.depart;
    final client = widget.client;
    if (_pastilles.isNotEmpty) {
      if (depart != null) marqueurs.add(pastille('depart', depart, 1));
      if (client != null) marqueurs.add(pastille('client', client, 2));
    }
    if (!_livreurVisible(etape, livreur) || _vespa.length != 4) {
      return marqueurs;
    }
    final cap = _capLisse ?? 0;
    final camera = _camera;
    // La vue de la moto qui correspond à la caméra : son cap VU DE LA CAMÉRA
    // (cap − orientation de la carte), sous l'inclinaison la plus proche.
    final relatif = (cap - (camera?.bearing ?? 0) + 720) % 360;
    final direction = (relatif / 10).round() % 36;
    final tilt = camera?.tilt ?? 0;
    var rang = 0;
    for (var i = 1; i < _inclinaisons.length; i++) {
      if ((_inclinaisons[i] - tilt).abs() <
          (_inclinaisons[rang] - tilt).abs()) {
        rang = i;
      }
    }
    marqueurs.add(
      Marker(
        markerId: const MarkerId('livreur'),
        position: LatLng(livreur!.lat, livreur.lng),
        icon: _vespa[rang][direction],
        // Le centre de l'image est le point de contact au sol.
        anchor: const Offset(0.5, 0.5),
        rotation: _roulis(),
        zIndexInt: 4,
        consumeTapEvents: true,
      ),
    );
    return marqueurs;
  }

  void _changerDeVue(VueCarte vue) => setState(() => _vue = vue);

  /// Minutes avant l'arrivée, en route seulement : avant, l'attente à la
  /// boutique rendrait toute heure fausse. La durée Google du trajet, au
  /// prorata de ce qui reste ; sans elle, la distance à 22 km/h, détours
  /// compris (comme la Live Activity).
  int? _minutesRestantes(EtapeCarte etape, Point? livreur) {
    if (etape != EtapeCarte.enRoute && etape != EtapeCarte.proche) return null;
    final surRoute = _surRoute;
    final trajet = _trajet;
    final duree = _dureeTrajetS;
    double? secondes;
    if (surRoute != null &&
        trajet != null &&
        identical(surRoute.trace, trajet) &&
        surRoute.d != null &&
        duree != null &&
        trajet.longueur > 0) {
      secondes = duree * (trajet.longueur - surRoute.d!) / trajet.longueur;
    } else if (livreur != null && widget.client != null) {
      secondes = metres(livreur, widget.client!) * 1.35 / (22 / 3.6);
    }
    if (secondes == null) return null;
    return math.max(1, (secondes / 60).ceil());
  }

  @override
  Widget build(BuildContext context) {
    if (_pastillesDuTheme != _theme) unawaited(_preparerPastilles());
    final t = _theme;
    final livreur = _dernierAffiche ?? _livreur();
    final etape = _etape(livreur);
    final fondAvant = _fondAvant;
    final marges = MediaQuery.paddingOf(context);
    final visible = _livreurVisible(etape, livreur);
    final minutes = _minutesRestantes(etape, livreur);
    return LayoutBuilder(
      builder: (context, contraintes) {
        _taille = contraintes.biggest;
        final initiale =
            _camera ??
            _cible(etape, livreur) ??
            const CameraPosition(target: LatLng(13.5137, 2.1098), zoom: 13);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: t.nuit
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: ColoredBox(
            // Sous la carte, toujours opaque : sans lui, l'accueil
            // transparaissait tant que les tuiles n'étaient pas chargées.
            color: t.fond,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerDown: (_) => _doigt = true,
                    onPointerUp: (_) => _doigt = false,
                    onPointerCancel: (_) => _doigt = false,
                    child: GoogleMap(
                      initialCameraPosition: initiale,
                      style: t.style,
                      onMapCreated: (carte) {
                        _carte = carte;
                        _camera = initiale;
                      },
                      // Un geste du client : la caméra est à lui, on ne la
                      // déplace plus sous son doigt.
                      onCameraMoveStarted: () {
                        if (_doigt && _vue != VueCarte.libre) {
                          _changerDeVue(VueCarte.libre);
                        }
                      },
                      onCameraMove: (position) {
                        if (_vue == VueCarte.libre) _camera = position;
                      },
                      gestureRecognizers: {
                        Factory<OneSequenceGestureRecognizer>(
                          EagerGestureRecognizer.new,
                        ),
                      },
                      markers: _marqueurs(etape, livreur),
                      polylines: _traces(etape),
                      circles: _pulsations(etape),
                      zoomGesturesEnabled: true,
                      scrollGesturesEnabled: true,
                      rotateGesturesEnabled: true,
                      tiltGesturesEnabled: true,
                      zoomControlsEnabled: false,
                      myLocationButtonEnabled: false,
                      mapToolbarEnabled: false,
                      compassEnabled: false,
                      buildingsEnabled: false,
                      trafficEnabled: false,
                      indoorViewEnabled: false,
                      minMaxZoomPreference: const MinMaxZoomPreference(11, 19),
                    ),
                  ),
                ),
                if (fondAvant != null)
                  IgnorePointer(
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey(t.nuit),
                      tween: Tween(begin: 1, end: 0),
                      duration: const Duration(milliseconds: 400),
                      onEnd: () => setState(() => _fondAvant = null),
                      builder: (context, v, _) => ColoredBox(
                        color: fondAvant.withValues(alpha: v),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                if (widget.onRetour != null)
                  Positioned(
                    top: marges.top + 8,
                    left: 16,
                    child: _BoutonRond(
                      theme: t,
                      etiquette: 'Retour',
                      onTap: widget.onRetour!,
                      // Le chevron est centré sur sa pointe : décalé d'un
                      // point pour paraître centré dans le rond.
                      child: Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: Icon(
                          CupertinoIcons.chevron_back,
                          size: 22,
                          color: t.boutonTexte,
                        ),
                      ),
                    ),
                  ),
                // Arrivée estimée, en haut à droite, à hauteur du retour.
                if (minutes != null)
                  Positioned(
                    top: marges.top + 8,
                    right: 16,
                    child: _Arrivee(theme: t, minutes: minutes),
                  ),
                // Deux vues au choix ; touchée à nouveau, la vue active rend
                // la main à la caméra automatique.
                Positioned(
                  right: 16,
                  bottom: marges.bottom + 28,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _BoutonRond(
                        theme: t,
                        etiquette: switch (_choix) {
                          ThemeChoisi.auto => 'Thème automatique (soleil)',
                          ThemeChoisi.clair => 'Thème clair',
                          ThemeChoisi.sombre => 'Thème sombre',
                        },
                        onTap: _changerDeTheme,
                        child: Icon(
                          switch (_choix) {
                            ThemeChoisi.auto =>
                              CupertinoIcons.circle_lefthalf_fill,
                            ThemeChoisi.clair => CupertinoIcons.sun_max_fill,
                            ThemeChoisi.sombre => CupertinoIcons.moon_fill,
                          },
                          size: 19,
                          color: t.boutonTexte,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _BoutonRond(
                        theme: t,
                        actif: _vue == VueCarte.aerienne,
                        etiquette: 'Vue aérienne',
                        onTap: () => _changerDeVue(
                          _vue == VueCarte.aerienne
                              ? VueCarte.ensemble
                              : VueCarte.aerienne,
                        ),
                        child: Icon(
                          CupertinoIcons.map,
                          size: 20,
                          color: _vue == VueCarte.aerienne
                              ? t.boutonFond.withValues(alpha: 1)
                              : t.boutonTexte,
                        ),
                      ),
                      if (visible) ...[
                        const SizedBox(height: 10),
                        _BoutonRond(
                          theme: t,
                          actif: _vue == VueCarte.derriere,
                          etiquette: 'Suivre derrière le livreur',
                          onTap: () => _changerDeVue(
                            _vue == VueCarte.derriere
                                ? VueCarte.ensemble
                                : VueCarte.derriere,
                          ),
                          child: Icon(
                            CupertinoIcons.location_north_fill,
                            size: 20,
                            color: _vue == VueCarte.derriere
                                ? t.boutonFond.withValues(alpha: 1)
                                : t.boutonTexte,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Positioned(
                  left: 16,
                  bottom: marges.bottom + 28,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _vue == VueCarte.libre
                        ? _BoutonRecentrer(
                            key: const ValueKey('recentrer'),
                            theme: t,
                            onTap: () => _changerDeVue(VueCarte.ensemble),
                          )
                        : const SizedBox.shrink(key: ValueKey('suivi')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BoutonRond extends StatelessWidget {
  const _BoutonRond({
    required this.theme,
    required this.etiquette,
    required this.onTap,
    required this.child,
    this.actif = false,
  });

  final ThemeCarte theme;

  /// La vue en cours : bouton plein, en contraste inversé.
  final bool actif;
  final String etiquette;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: etiquette,
    child: Tooltip(
      message: etiquette,
      child: Material(
        color: actif ? theme.boutonTexte : theme.boutonFond,
        shape: CircleBorder(
          side: BorderSide(color: actif ? theme.boutonTexte : theme.boutonBord),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 46, height: 46, child: Center(child: child)),
        ),
      ),
    ),
  );
}

class _BoutonRecentrer extends StatelessWidget {
  const _BoutonRecentrer({required this.theme, required this.onTap, super.key});

  final ThemeCarte theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: theme.boutonFond,
    shape: StadiumBorder(side: BorderSide(color: theme.boutonBord)),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 20, 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Phosphor.navigationArrow, size: 18, color: theme.boutonTexte),
            const SizedBox(width: 10),
            Text(
              'Recentrer',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: theme.boutonTexte,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// « Arrivée dans 12 min », à hauteur du bouton retour.
class _Arrivee extends StatelessWidget {
  const _Arrivee({required this.theme, required this.minutes});

  final ThemeCarte theme;
  final int minutes;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: 'Arrivée dans $minutes minutes',
    child: ExcludeSemantics(
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: ShapeDecoration(
          color: theme.boutonFond,
          shape: StadiumBorder(side: BorderSide(color: theme.boutonBord)),
        ),
        alignment: Alignment.center,
        child: Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Arrivée dans '),
              TextSpan(
                text: '$minutes min',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          style: TextStyle(
            fontSize: 15,
            color: theme.boutonTexte,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    ),
  );
}
