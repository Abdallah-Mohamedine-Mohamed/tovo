import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
/// du livreur (maquette « Suivi Commande », 27/09).
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

/// L'écran de suivi : la carte, et rien d'autre.
///
/// - Thème clair ou sombre selon le vrai lever et coucher du soleil chez le
///   client ; bascule en fondu, réévaluée chaque minute.
/// - Caméra par étape (centre, zoom, inclinaison), lissée à chaque image,
///   jamais de saut ; nord toujours en haut, plus lisible pour un client
///   que la rotation « GPS ». Un geste du client la libère, « Recentrer »
///   la lui rend.
/// - Le livreur glisse LE LONG DE LA ROUTE : chaque position reçue est
///   projetée sur le tracé, et il avance d'une distance à l'autre.
/// - Deux tracés (serveur, Google Routes) : l'approche du livreur vers la
///   boutique, en pointillé ; le trajet vers le client, le restant mis en
///   avant, le parcouru effacé.
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
  final _api = TovoApi();
  GoogleMapController? _carte;
  late final Ticker _images;
  Timer? _horloge;

  ThemeCarte _theme = ThemeCarte.sombre;
  Color? _fondAvant;
  final Map<String, BitmapDescriptor> _icones = {};
  final Map<String, Offset> _ancres = {};
  ThemeCarte? _iconesDuTheme;

  TraceMesure? _trajet;
  TraceMesure? _approche;
  DateTime? _derniereDemande;

  // La glisse du livreur le long du tracé qu'il suit.
  TraceMesure? _suivie;
  double? _dDepart;
  double? _dCible;
  DateTime _debutGlisse = DateTime.now();
  Duration _dureeGlisse = const Duration(seconds: 4);
  double _cap = 90;
  bool _versLOuest = false;

  // La caméra, lissée vers sa cible à chaque image.
  CameraPosition? _camera;
  Duration _derniereImage = Duration.zero;
  Duration _dernierDessin = Duration.zero;
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

  Future<void> _preparerIcones() async {
    final t = _theme;
    if (_iconesDuTheme == t) return;
    _iconesDuTheme = t;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;

    // Dessinés en points, rendus à la densité de l'écran : nets partout.
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
      icone: widget.colis ? Phosphor.package : Phosphor.storefront,
      texte: widget.nomDepart.isEmpty
          ? (widget.colis ? 'Colis' : 'Boutique')
          : widget.nomDepart,
    );
    final client = dessinerPastille(
      t,
      icone: widget.clientEstVous ? Phosphor.houseSimple : Phosphor.mapPin,
      texte: widget.clientEstVous ? 'Vous' : 'Arrivée',
      vous: true,
    );
    final droite = dessinerLivreur(t, versLOuest: false);
    final gauche = dessinerLivreur(t, versLOuest: true);
    final cone = dessinerCone();
    final icones = {
      'depart': await image(depart),
      'client': await image(client),
      'droite': await image(droite),
      'gauche': await image(gauche),
      'cone': await image(cone),
    };
    if (!mounted || _iconesDuTheme != t) return;
    setState(() {
      _icones
        ..clear()
        ..addAll(icones);
      _ancres
        ..['depart'] = ancre(depart)
        ..['client'] = ancre(client)
        ..['livreur'] = ancre(droite)
        ..['cone'] = ancre(cone);
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
    _recevoir(premiere: true);
  }

  // ------------------------------------------------------------- livreur

  /// Une position reçue : projetée sur le tracé suivi, le livreur glisse
  /// de là où il est affiché jusqu'à elle, en autant de temps qu'il en a
  /// fallu pour la recevoir.
  void _recevoir({bool premiere = false}) {
    final p = widget.moto.derniere;
    if (p == null) return;
    final trace = _recupere ? _trajet : _approche;
    if (trace == null || trace.points.length < 2) {
      _suivie = null;
      return;
    }
    final projection = trace.projeter(p);
    if (projection.ecart > 50) {
      // Sorti de la route (il a pris une autre rue) : nouveau tracé.
      _suivie = null;
      unawaited(_demanderTraces());
      return;
    }
    final actuel = _dAffiche();
    final memeTrace = identical(_suivie, trace);
    _suivie = trace;
    // Le GPS tremble : un léger recul n'est pas un demi-tour.
    final cible =
        memeTrace &&
            actuel != null &&
            projection.d < actuel &&
            actuel - projection.d < 30
        ? actuel
        : projection.d;
    _dDepart = memeTrace && actuel != null && !premiere ? actuel : cible;
    _dCible = cible;
    _debutGlisse = DateTime.now();
    _dureeGlisse = widget.moto.duree;
  }

  double? _dAffiche() {
    final depart = _dDepart;
    final cible = _dCible;
    if (depart == null || cible == null || _suivie == null) return null;
    final ms = _dureeGlisse.inMilliseconds;
    final f = ms <= 0
        ? 1.0
        : (DateTime.now().difference(_debutGlisse).inMilliseconds / ms).clamp(
            0.0,
            1.0,
          );
    return depart + (cible - depart) * f;
  }

  /// Où dessiner le livreur maintenant.
  Point? _livreur() {
    final trace = _suivie;
    final d = _dAffiche();
    if (trace != null && d != null) {
      final avant = trace.pointA(d - 3);
      final apres = trace.pointA(d + 3);
      if (metres(avant, apres) > 2) _cap = cap(avant, apres);
      _orienter();
      return trace.pointA(d);
    }
    _cap = widget.moto.capDegres;
    _orienter();
    return widget.moto.position();
  }

  /// L'icône regarde vers la droite ; vers l'ouest, on la retourne. Rien ne
  /// change sur un trajet presque vertical, pour éviter le clignotement.
  void _orienter() {
    final est = math.sin(_cap * math.pi / 180);
    if (est.abs() > 0.3) _versLOuest = est < 0;
  }

  // ---------------------------------------------------------------- étape

  EtapeCarte _etape(Point? livreur) {
    if (widget.statut == 'delivered') return EtapeCarte.livree;
    if (_recupere) {
      final trajet = _trajet;
      final d = _dAffiche();
      final client = widget.client;
      final reste = trajet != null && d != null && identical(_suivie, trajet)
          ? trajet.longueur - d
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

  /// Chaque image (~30 par seconde) : la caméra se rapproche de sa cible
  /// par lissage exponentiel (k = 1 − e^(−dt·2,4)), le livreur glisse, les
  /// lieux pulsent.
  void _image(Duration maintenant) {
    if (!mounted) return;
    if (maintenant - _dernierDessin < const Duration(milliseconds: 33)) return;
    final dt = ((maintenant - _derniereImage).inMicroseconds / 1e6).clamp(
      0.0,
      0.1,
    );
    _derniereImage = maintenant;
    _dernierDessin = maintenant;
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
    if (client != null &&
        (etape == EtapeCarte.proche || etape == EtapeCarte.livree)) {
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
    final traces = <Polyline>{};
    final trajet = _trajet;
    if (trajet != null && etape != EtapeCarte.livree) {
      final enCourse =
          etape == EtapeCarte.enRoute || etape == EtapeCarte.proche;
      final d = _dAffiche();
      final restant = enCourse && identical(_suivie, trajet) && d != null
          ? trajet.depuis(d)
          : trajet.points;
      final opacite = enCourse ? 1.0 : 0.35;
      traces.add(
        Polyline(
          polylineId: const PolylineId('base'),
          points: latLng(trajet.points),
          color: t.traceBase,
          width: 12,
          zIndex: 1,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      );
      final halo = t.traceHalo;
      if (halo != null) {
        traces.add(
          Polyline(
            polylineId: const PolylineId('halo'),
            points: latLng(restant),
            color: halo.withValues(alpha: halo.a * opacite),
            width: 14,
            zIndex: 2,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        );
      }
      traces.add(
        Polyline(
          polylineId: const PolylineId('restant'),
          points: latLng(restant),
          color: t.traceRestant.withValues(alpha: opacite),
          width: 6,
          zIndex: 3,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      );
    }
    final approche = _approche;
    if (approche != null &&
        (etape == EtapeCarte.preparation || etape == EtapeCarte.auDepart)) {
      final d = identical(_suivie, approche) ? _dAffiche() : null;
      traces.add(
        Polyline(
          polylineId: const PolylineId('approche'),
          points: latLng(d == null ? approche.points : approche.depuis(d)),
          color: t.approche,
          width: 4,
          zIndex: 4,
          patterns: [PatternItem.dot, PatternItem.gap(10)],
        ),
      );
    }
    return traces;
  }

  Set<Marker> _marqueurs(EtapeCarte etape, Point? livreur) {
    if (_icones.isEmpty) return const {};
    Marker marqueur(
      String id,
      Point p, {
      String? icone,
      int z = 1,
      double rotation = 0,
      bool aPlat = false,
    }) => Marker(
      markerId: MarkerId(id),
      position: LatLng(p.lat, p.lng),
      icon: _icones[icone ?? id]!,
      anchor: _ancres[id] ?? const Offset(0.5, 1),
      zIndexInt: z,
      rotation: rotation,
      flat: aPlat,
      consumeTapEvents: true,
    );

    final depart = widget.depart;
    final client = widget.client;
    final visible =
        livreur != null &&
        etape != EtapeCarte.confirmee &&
        etape != EtapeCarte.livree;
    return {
      if (depart != null) marqueur('depart', depart),
      if (client != null) marqueur('client', client, z: 2),
      if (visible && _theme.nuit)
        marqueur('cone', livreur, z: 3, rotation: _cap, aPlat: true),
      if (visible)
        marqueur(
          'livreur',
          livreur,
          icone: _versLOuest ? 'gauche' : 'droite',
          z: 4,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_iconesDuTheme != _theme) unawaited(_preparerIcones());
    final t = _theme;
    final livreur = _livreur();
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
              // Le haut se fond dans le décor, sous la barre d'état ; la
              // nuit, les bords s'assombrissent doucement.
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        t.fond,
                        t.fond.withValues(alpha: 0.9),
                        t.fond.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.1, 0.26],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              if (t.nuit)
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(0, -0.2),
                        radius: 1.25,
                        colors: [Color(0x000C0D14), Color(0xB30C0D14)],
                        stops: [0.55, 1],
                      ),
                    ),
                    child: SizedBox.expand(),
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
                    icone: Phosphor.caretLeft,
                    etiquette: 'Retour',
                    onTap: widget.onRetour!,
                  ),
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

class _BoutonRond extends StatelessWidget {
  const _BoutonRond({
    required this.theme,
    required this.icone,
    required this.etiquette,
    required this.onTap,
  });

  final ThemeCarte theme;
  final IconData icone;
  final String etiquette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: etiquette,
    child: Material(
      color: theme.boutonFond,
      shape: CircleBorder(side: BorderSide(color: theme.boutonBord)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(icone, size: 20, color: theme.boutonTexte),
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
