import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/api.dart';
import '../../core/position_livreur.dart';

/// La carte de suivi, façon navigation Google Maps (retour du 27/09) :
/// fond nuit, vue inclinée, et le trait lumineux de l'itinéraire qui mène
/// le livreur jusqu'au client.
///
/// - Le livreur est un scooter vu du dessus, qui tourne avec la route.
/// - Le trait vient du serveur (GET /orders/:id/itineraire, Google Routes) ;
///   le bout déjà parcouru disparaît au fil de la course.
/// - La caméra suit d'elle-même : orientée du livreur vers sa destination,
///   inclinée, à la bonne distance. Un geste du client la libère ; le
///   bouton « Recentrer » la rend au suivi.
///
/// Le logo Google reste : les conditions d'utilisation de Google Maps
/// interdisent de le masquer.
class CarteSuivi extends StatefulWidget {
  const CarteSuivi({
    required this.moto,
    required this.revision,
    required this.orderId,
    required this.statut,
    this.arrivee,
    super.key,
  });

  final MotoAnimee moto;

  /// Change à chaque position reçue : relance la glisse et le cadrage.
  final int revision;

  final String orderId;

  /// L'étape : quand elle change, la destination change, le trait aussi.
  final String statut;

  /// Où va le livreur : la boutique, le colis, ou le client.
  final Point? arrivee;

  @override
  State<CarteSuivi> createState() => _CarteSuiviState();
}

class _CarteSuiviState extends State<CarteSuivi> {
  final _api = TovoApi();
  GoogleMapController? _carte;
  Timer? _anime;
  BitmapDescriptor? _scooter;
  BitmapDescriptor? _destination;

  /// Le tracé complet, décodé ; vide tant que le serveur n'en a pas donné.
  List<Point> _trace = const [];
  DateTime? _derniereDemande;

  /// Le client a déplacé la carte : on ne la recadre plus sous son doigt.
  bool _libre = false;

  /// Un doigt est posé sur la carte. Seul un mouvement de caméra qui
  /// démarre doigt posé vient du client ; les autres (ouverture de la
  /// feuille, nos propres recadrages) ne libèrent rien.
  bool _doigt = false;

  @override
  void initState() {
    super.initState();
    unawaited(_preparerIcones());
    unawaited(_demanderTrace());
    _animer();
  }

  @override
  void didUpdateWidget(CarteSuivi avant) {
    super.didUpdateWidget(avant);
    if (avant.statut != widget.statut) {
      // Nouvelle destination : l'ancien trait ne mène plus nulle part.
      _trace = const [];
      unawaited(_demanderTrace(force: true));
    }
    if (avant.revision != widget.revision) {
      _animer();
      if (!_libre) _cadrer();
      final moto = widget.moto.position();
      // Sorti du tracé (il a pris une autre rue) : on en redemande un.
      if (moto != null &&
          _trace.isNotEmpty &&
          !_trace.any((p) => metres(moto, p) < 60)) {
        unawaited(_demanderTrace());
      }
    }
  }

  @override
  void dispose() {
    _anime?.cancel();
    _carte?.dispose();
    super.dispose();
  }

  Future<void> _demanderTrace({bool force = false}) async {
    final avant = _derniereDemande;
    if (!force &&
        avant != null &&
        DateTime.now().difference(avant) < const Duration(seconds: 20)) {
      return;
    }
    _derniereDemande = DateTime.now();
    final reponse = await _api.get('/orders/${widget.orderId}/itineraire');
    final code = reponse.raw['polyline'];
    if (!mounted || code is! String || code.isEmpty) return;
    setState(() => _trace = decoderPolyline(code));
    if (!_libre) _cadrer();
  }

  /// ~30 images par seconde pendant que le scooter glisse ; à l'arrêt, rien.
  void _animer() {
    _anime?.cancel();
    _anime = Timer.periodic(const Duration(milliseconds: 33), (t) {
      if (!mounted) return t.cancel();
      setState(() {});
      if (!widget.moto.enMouvement()) t.cancel();
    });
  }

  /// Vue de navigation : orientée du livreur vers sa destination (elle est
  /// « devant », en haut de l'écran), inclinée, à une distance qui les
  /// garde tous les deux dans le cadre.
  void _cadrer() {
    final carte = _carte;
    // Là où le scooter VA : cadrer sur sa prochaine position évite un
    // second recadrage quand il y sera.
    final moto = widget.moto.position(
      DateTime.now().add(const Duration(minutes: 1)),
    );
    if (carte == null || moto == null) return;
    final arrivee = widget.arrivee;
    final CameraPosition vue;
    if (arrivee == null || metres(moto, arrivee) < 80) {
      vue = CameraPosition(
        target: LatLng(moto.lat, moto.lng),
        zoom: 16.8,
        tilt: 45,
        bearing: widget.moto.capDegres,
      );
    } else {
      final distance = metres(moto, arrivee);
      final hauteur = (context.size?.height ?? 600) * 0.62;
      // Mètres par point à un zoom z : 156543 × cos(lat) / 2^z. On cherche
      // le zoom où la distance tient dans ~60 % de la hauteur.
      final zoom =
          (math.log(
                    156543.03 *
                        math.cos(moto.lat * math.pi / 180) *
                        hauteur /
                        distance,
                  ) /
                  math.ln2)
              .clamp(12.5, 17.0)
              .toDouble();
      vue = CameraPosition(
        target: LatLng(
          (moto.lat + arrivee.lat) / 2,
          (moto.lng + arrivee.lng) / 2,
        ),
        zoom: zoom,
        tilt: 45,
        bearing: cap(moto, arrivee),
      );
    }
    unawaited(carte.animateCamera(CameraUpdate.newCameraPosition(vue)));
  }

  void _recentrer() {
    setState(() => _libre = false);
    _cadrer();
  }

  Future<void> _preparerIcones() async {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 3;
    final scooter = await _dessiner(ratio, 72, peindreScooter);
    final destination = await _dessiner(ratio, 44, peindreDestination);
    if (!mounted) return;
    setState(() {
      _scooter = scooter;
      _destination = destination;
    });
  }

  static Future<BitmapDescriptor> _dessiner(
    double ratio,
    double taille,
    void Function(Canvas canvas, double taille) peindre,
  ) async {
    final enregistreur = ui.PictureRecorder();
    final canvas = Canvas(enregistreur)..scale(ratio);
    peindre(canvas, taille);
    final image = await enregistreur.endRecording().toImage(
      (taille * ratio).round(),
      (taille * ratio).round(),
    );
    final octets = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      octets!.buffer.asUint8List(),
      imagePixelRatio: ratio,
    );
  }

  @override
  Widget build(BuildContext context) {
    final moto = widget.moto.position();
    if (moto == null) return const SizedBox.shrink();
    final arrivee = widget.arrivee;
    final reste = _trace.isEmpty ? const <Point>[] : resteDuTrace(_trace, moto);
    List<LatLng> latLng(List<Point> points) => [
      for (final p in points) LatLng(p.lat, p.lng),
    ];
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            onPointerDown: (_) => _doigt = true,
            onPointerUp: (_) => _doigt = false,
            onPointerCancel: (_) => _doigt = false,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(moto.lat, moto.lng),
                zoom: 15.5,
                tilt: 45,
              ),
              style: _styleNuit,
              minMaxZoomPreference: const MinMaxZoomPreference(11, 18),
              onMapCreated: (carte) {
                _carte = carte;
                _cadrer();
              },
              onCameraMoveStarted: () {
                if (_doigt && !_libre) setState(() => _libre = true);
              },
              // La carte est dans une feuille : sans ça, la feuille volerait
              // les glissés du doigt.
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(
                  EagerGestureRecognizer.new,
                ),
              },
              polylines: {
                if (reste.length >= 2) ...{
                  // Le contour sombre, puis le cœur lumineux : le trait se
                  // détache des rues, comme dans Google Maps.
                  Polyline(
                    polylineId: const PolylineId('contour'),
                    points: latLng(reste),
                    color: const Color(0xFF0E5A78),
                    width: 11,
                    jointType: JointType.round,
                    startCap: Cap.roundCap,
                    endCap: Cap.roundCap,
                  ),
                  Polyline(
                    polylineId: const PolylineId('trace'),
                    points: latLng(reste),
                    color: const Color(0xFF52E3F0),
                    width: 7,
                    zIndex: 1,
                    jointType: JointType.round,
                    startCap: Cap.roundCap,
                    endCap: Cap.roundCap,
                  ),
                },
              },
              markers: {
                if (arrivee != null && _destination != null)
                  Marker(
                    markerId: const MarkerId('arrivee'),
                    position: LatLng(arrivee.lat, arrivee.lng),
                    icon: _destination!,
                    anchor: const Offset(0.5, 38 / 44),
                    consumeTapEvents: true,
                  ),
                if (_scooter != null)
                  Marker(
                    markerId: const MarkerId('livreur'),
                    position: LatLng(moto.lat, moto.lng),
                    icon: _scooter!,
                    anchor: const Offset(0.5, 0.5),
                    rotation: widget.moto.capDegres,
                    // À plat sur la carte : il tourne avec les rues et
                    // s'incline avec la vue.
                    flat: true,
                    zIndexInt: 2,
                    consumeTapEvents: true,
                  ),
              },
              rotateGesturesEnabled: true,
              tiltGesturesEnabled: false,
              zoomControlsEnabled: false,
              myLocationButtonEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: false,
              buildingsEnabled: false,
              trafficEnabled: false,
              indoorViewEnabled: false,
            ),
          ),
        ),
        Positioned(
          left: 16,
          bottom: 28,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: _libre
                ? _BoutonNuit(
                    key: const ValueKey('recentrer'),
                    icone: Icons.navigation_rounded,
                    libelle: 'Recentrer',
                    onTap: _recentrer,
                  )
                : const SizedBox.shrink(key: ValueKey('suivi')),
          ),
        ),
      ],
    );
  }
}

/// Bouton sombre et arrondi, comme ceux de la navigation Google Maps.
class _BoutonNuit extends StatelessWidget {
  const _BoutonNuit({
    required this.icone,
    required this.libelle,
    required this.onTap,
    super.key,
  });

  final IconData icone;
  final String libelle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xF2121A26),
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 20, 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icone, size: 20, color: Colors.white),
            const SizedBox(width: 10),
            Text(
              libelle,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Fond nuit, inspiré de la navigation Google Maps : bleu nuit, rues
/// claires, noms lisibles ; le fleuve garde une pointe du vert-bleu Tovo.
/// Pas de pictogrammes ni de commerces : seuls le trait, le livreur et
/// l'arrivée attirent l'œil.
const _styleNuit = '''
[
  {"elementType":"geometry","stylers":[{"color":"#1b2940"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#9fb0c8"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#1b2940"},{"weight":3}]},
  {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#e6ecf5"}]},
  {"featureType":"administrative.neighborhood","elementType":"labels.text.fill","stylers":[{"color":"#c3cee0"}]},
  {"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#1f3049"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#7d8ea7"}]},
  {"featureType":"poi.business","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1c3a3d"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#3b4c6b"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#1b2940"}]},
  {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#4b5e82"}]},
  {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#5c7199"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#e1e8f2"}]},
  {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#8395ae"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#0d4752"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#6fa3aa"}]}
]
''';

/// Un scooter de livraison vu du dessus, tourné vers le haut (le nord) ; la
/// carte le fait pivoter selon son cap. Un halo clair autour, pour qu'on le
/// trouve d'un coup d'œil sur le fond sombre. Public pour le rendu de
/// contrôle (test/carte_icones_test.dart).
@visibleForTesting
void peindreScooter(Canvas c, double t) {
  final u = t / 72; // le dessin est pensé sur une grille de 72 points
  Offset o(double x, double y) => Offset(x * u, y * u);
  RRect rr(double x, double y, double l, double h, double rayon) =>
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x * u, y * u, l * u, h * u),
        Radius.circular(rayon * u),
      );
  Paint trait(Color couleur, double epaisseur) => Paint()
    ..color = couleur
    ..strokeWidth = epaisseur * u
    ..strokeCap = StrokeCap.round;

  // Halo : on trouve le livreur d'un coup d'œil sur le fond sombre.
  c.drawCircle(
    o(36, 36),
    30 * u,
    Paint()
      ..shader = ui.Gradient.radial(o(36, 36), 30 * u, const [
        Color(0x5552E3F0),
        Color(0x0052E3F0),
      ]),
  );
  // Ombre portée, sous toute la machine.
  c.drawRRect(
    rr(27, 9, 18, 58, 9),
    Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.2 * u),
  );
  // Roues : seuls leurs bouts dépassent, devant et derrière.
  final pneu = Paint()..color = const Color(0xFF15191D);
  c.drawRRect(rr(33, 6, 6, 11, 3), pneu);
  c.drawRRect(rr(33, 58, 6, 10, 3), pneu);
  // Carénage : une coque effilée, brillante sur son arête.
  c.drawRRect(
    rr(29, 12, 14, 48, 7),
    Paint()
      ..shader = ui.Gradient.linear(
        o(29, 0),
        o(43, 0),
        const [Color(0xFF0B8F8F), Color(0xFF12A6A6), Color(0xFF006666)],
        const [0, 0.4, 1],
      ),
  );
  c.drawRRect(
    rr(33.5, 14, 2.4, 14, 1.2),
    Paint()..color = const Color(0x40FFFFFF),
  );
  // Phare.
  c.drawCircle(o(36, 13.5), 1.8 * u, Paint()..color = const Color(0xFFFFF3C4));
  // Caisse de livraison, à l'arrière, avec son couvercle.
  c.drawRRect(rr(27, 45, 18, 15, 3), Paint()..color = const Color(0xFF094F4F));
  c.drawRRect(
    rr(28.4, 46.4, 15.2, 12.2, 2.2),
    Paint()..color = const Color(0xFF0E6C6C),
  );
  c.drawLine(o(31, 52.5), o(41, 52.5), trait(const Color(0x33FFFFFF), 1));
  // Guidon, devant le livreur, et ses poignées.
  c.drawLine(o(24, 23), o(48, 23), trait(const Color(0xFF1E2328), 2.4));
  c.drawCircle(o(23.5, 23), 2 * u, Paint()..color = const Color(0xFF0F1215));
  c.drawCircle(o(48.5, 23), 2 * u, Paint()..color = const Color(0xFF0F1215));
  // Bras : des épaules aux poignées.
  final bras = trait(const Color(0xFFC9D0D8), 3.2);
  c.drawLine(o(29.5, 34), o(24.5, 24.5), bras);
  c.drawLine(o(42.5, 34), o(47.5, 24.5), bras);
  // Épaules, puis le casque blanc, visière vers l'avant.
  c.drawOval(
    Rect.fromLTWH(26 * u, 31 * u, 20 * u, 10 * u),
    Paint()..color = const Color(0xFFD9DEE4),
  );
  c.drawCircle(
    o(36, 35),
    6.6 * u,
    Paint()
      ..shader = ui.Gradient.radial(o(34.5, 33.5), 7 * u, const [
        Colors.white,
        Color(0xFFE3E7EC),
      ]),
  );
  c.drawRRect(
    rr(31.8, 28.8, 8.4, 3.4, 1.7),
    Paint()..color = const Color(0xFF1B2530),
  );
}

/// L'arrivée : une épingle claire, posée sur un anneau au sol.
@visibleForTesting
void peindreDestination(Canvas c, double t) {
  final u = t / 44;
  final sol = Offset(22 * u, 38 * u);
  c.drawCircle(sol, 5.5 * u, Paint()..color = Colors.white);
  c.drawCircle(sol, 3 * u, Paint()..color = const Color(0xFF14201E));
  final epingle = Path()
    ..moveTo(22 * u, 34 * u)
    ..cubicTo(14 * u, 24 * u, 10 * u, 20 * u, 10 * u, 14 * u)
    ..arcToPoint(Offset(34 * u, 14 * u), radius: Radius.circular(12 * u))
    ..cubicTo(34 * u, 20 * u, 30 * u, 24 * u, 22 * u, 34 * u)
    ..close();
  c.drawShadow(epingle, Colors.black, 3 * u, false);
  c.drawPath(epingle, Paint()..color = Colors.white);
  c.drawCircle(
    Offset(22 * u, 14 * u),
    4.5 * u,
    Paint()..color = const Color(0xFF14201E),
  );
}
