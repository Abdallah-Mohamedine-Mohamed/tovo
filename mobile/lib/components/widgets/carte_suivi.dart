import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

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

/// L'écran de suivi : la carte, et rien d'autre qu'un bouton retour.
///
/// - Thème clair ou sombre selon le vrai lever et coucher du soleil chez le
///   client ; bascule en fondu, réévaluée chaque minute.
/// - Caméra par étape (centre, zoom, inclinaison), lissée à chaque image,
///   jamais de saut ; nord toujours en haut. Un geste du client la libère,
///   « Recentrer » la lui rend.
/// - Le livreur AVANCE À CHAQUE IMAGE le long de la route (LivreurSurRoute) :
///   plus de bonds entre deux positions reçues, et il continue sur sa
///   lancée quand la suivante tarde.
/// - Le livreur est un scooter 3D vu du dessus, rendu sous 36 angles ;
///   l'image la plus proche du cap, tournée du reste (±5°).
/// - Tracés (serveur, Google Routes) : l'approche vers la boutique en
///   pointillé ; le trajet vers le client, épais, le restant mis en avant.
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

  final _api = TovoApi();
  GoogleMapController? _carte;
  late final Ticker _images;
  Timer? _horloge;

  ThemeCarte _theme = ThemeCarte.sombre;
  Color? _fondAvant;
  final Map<String, BitmapDescriptor> _pastilles = {};
  final Map<String, Offset> _ancres = {};
  ThemeCarte? _pastillesDuTheme;
  List<BitmapDescriptor> _scooter = const [];

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

  CameraPosition? _camera;
  Duration _derniereImage = Duration.zero;
  Size _taille = const Size(390, 800);

  bool _libre = false;
  bool _doigt = false;

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
    unawaited(_chargerScooter());
    unawaited(_demanderTraces(force: true));
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
    final ici =
        widget.client ??
        widget.depart ??
        widget.moto.derniere ??
        (lat: 13.5137, lng: 2.1098);
    return estLeJour(ici.lat, ici.lng) ? ThemeCarte.clair : ThemeCarte.sombre;
  }

  /// Les 36 vues du scooter (tous les 10°), 100 points de côté : le scooter
  /// y fait ~80 points de long, quel que soit le zoom.
  Future<void> _chargerScooter() async {
    final vues = await Future.wait([
      for (var i = 0; i < 36; i++)
        BitmapDescriptor.asset(
          const ImageConfiguration(),
          'assets/carte/scooter/scooter_${(i * 10).toString().padLeft(3, '0')}.png',
          width: 100,
          height: 100,
        ),
    ]);
    if (mounted) setState(() => _scooter = vues);
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
      _approche = lire(reponse.raw['approche']);
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
    final ecart = ((vise - actuel + 540) % 360) - 180;
    return _capLisse = (actuel + ecart * (1 - math.exp(-dt * 7)) + 360) % 360;
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

  /// Chaque image : le livreur avance, la caméra se rapproche de sa cible
  /// par lissage exponentiel (k = 1 − e^(−dt·2,4)), les lieux pulsent.
  void _image(Duration maintenant) {
    if (!mounted) return;
    // ~30 images par seconde : fluide à l'œil, sans épuiser un téléphone
    // d'entrée de gamme ni saturer le pont vers la carte native.
    if (maintenant - _derniereImage < const Duration(milliseconds: 30)) return;
    final dt = ((maintenant - _derniereImage).inMicroseconds / 1e6).clamp(
      0.0,
      0.1,
    );
    _derniereImage = maintenant;
    _surRoute?.avancer(dt);
    _cap(dt);
    final livreur = _livreur();
    final cible = _cible(_etape(livreur), livreur);
    final carte = _carte;
    if (!_libre && cible != null && carte != null) {
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
      );
      final bouge =
          (suivante.zoom - actuelle.zoom).abs() > 1e-4 ||
          (suivante.tilt - actuelle.tilt).abs() > 1e-3 ||
          (suivante.target.latitude - actuelle.target.latitude).abs() > 1e-8 ||
          (suivante.target.longitude - actuelle.target.longitude).abs() > 1e-8;
      _camera = suivante;
      if (bouge) {
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

  Set<Polyline> _traces(EtapeCarte etape) {
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

    final surRoute = _surRoute;
    final traces = <Polyline>{};
    final trajet = _trajet;
    if (trajet != null && etape != EtapeCarte.livree) {
      final enCourse =
          etape == EtapeCarte.enRoute || etape == EtapeCarte.proche;
      final d = surRoute != null && identical(surRoute.trace, trajet)
          ? surRoute.d
          : null;
      final restant = enCourse && d != null ? trajet.depuis(d) : trajet.points;
      final opacite = enCourse ? 1.0 : 0.4;
      // La bordure sous tout le trajet : sous le restant, elle seule
      // montre la partie parcourue.
      traces.add(ligne('bordure', trajet.points, t.traceBordure, 22, 1));
      final halo = t.traceHalo;
      if (halo != null) {
        traces.add(
          ligne(
            'halo',
            restant,
            halo.withValues(alpha: halo.a * opacite),
            20,
            2,
          ),
        );
      }
      traces.add(
        ligne(
          'restant',
          restant,
          t.traceRestant.withValues(alpha: opacite),
          13,
          3,
        ),
      );
    }
    final approche = _approche;
    if (approche != null &&
        (etape == EtapeCarte.preparation || etape == EtapeCarte.auDepart)) {
      final d = surRoute != null && identical(surRoute.trace, approche)
          ? surRoute.d
          : null;
      traces.add(
        Polyline(
          polylineId: const PolylineId('approche'),
          points: latLng(d == null ? approche.points : approche.depuis(d)),
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
    final visible =
        livreur != null &&
        etape != EtapeCarte.confirmee &&
        etape != EtapeCarte.livree;
    if (visible && _scooter.length == 36) {
      // L'image la plus proche du cap, tournée du reste (±5°) : la lumière
      // du rendu reste à sa place, et la rotation reste continue.
      final cap = _capLisse ?? 0;
      final vue = (cap / 10).round() % 36;
      marqueurs.add(
        Marker(
          markerId: const MarkerId('livreur'),
          position: LatLng(livreur.lat, livreur.lng),
          icon: _scooter[vue],
          anchor: const Offset(0.5, 0.5),
          rotation: cap - vue * 10,
          flat: true,
          zIndexInt: 3,
          consumeTapEvents: true,
        ),
      );
    }
    return marqueurs;
  }

  @override
  Widget build(BuildContext context) {
    if (_pastillesDuTheme != _theme) unawaited(_preparerPastilles());
    final t = _theme;
    final livreur = _dernierAffiche ?? _livreur();
    final etape = _etape(livreur);
    final fondAvant = _fondAvant;
    final marges = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, contraintes) {
        _taille = contraintes.biggest;
        final initiale =
            _camera ??
            _cible(etape, livreur) ??
            const CameraPosition(target: LatLng(13.5137, 2.1098), zoom: 13);
        return ColoredBox(
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
                    onCameraMoveStarted: () {
                      if (_doigt && !_libre) setState(() => _libre = true);
                    },
                    onCameraMove: (position) {
                      if (_libre) _camera = position;
                    },
                    gestureRecognizers: {
                      Factory<OneSequenceGestureRecognizer>(
                        EagerGestureRecognizer.new,
                      ),
                    },
                    markers: _marqueurs(etape, livreur),
                    polylines: _traces(etape),
                    circles: _pulsations(etape),
                    rotateGesturesEnabled: false,
                    tiltGesturesEnabled: false,
                    zoomControlsEnabled: false,
                    myLocationButtonEnabled: false,
                    mapToolbarEnabled: false,
                    compassEnabled: false,
                    buildingsEnabled: false,
                    trafficEnabled: false,
                    indoorViewEnabled: false,
                    minMaxZoomPreference: const MinMaxZoomPreference(11, 18.5),
                  ),
                ),
              ),
              // Le haut se fond dans le décor, sous la barre d'état.
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        t.fond,
                        t.fond.withValues(alpha: 0.85),
                        t.fond.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.07, 0.2],
                    ),
                  ),
                  child: const SizedBox.expand(),
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
                  child: _BoutonRetour(theme: t, onTap: widget.onRetour!),
                ),
              Positioned(
                left: 16,
                bottom: marges.bottom + 28,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _libre
                      ? _BoutonRecentrer(
                          key: const ValueKey('recentrer'),
                          theme: t,
                          onTap: () => setState(() => _libre = false),
                        )
                      : const SizedBox.shrink(key: ValueKey('suivi')),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Retour, à la manière d'iOS : un chevron fin, dans un rond discret.
class _BoutonRetour extends StatelessWidget {
  const _BoutonRetour({required this.theme, required this.onTap});

  final ThemeCarte theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Retour',
    child: Material(
      color: theme.boutonFond,
      shape: CircleBorder(side: BorderSide(color: theme.boutonBord)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Padding(
            // Le chevron est centré sur sa pointe : on le décale d'un
            // point à gauche pour qu'il paraisse centré dans le rond.
            padding: const EdgeInsets.only(right: 2),
            child: Icon(
              CupertinoIcons.chevron_back,
              size: 22,
              color: theme.boutonTexte,
            ),
          ),
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
