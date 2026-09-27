import 'dart:math' as math;
import 'dart:typed_data';

/// Un point sur la carte.
typedef Point = ({double lat, double lng});

/// Lit un point PostGIS tel que Realtime l'envoie : EWKB en hexadécimal
/// (« 0101000020E6100000… »), ou GeoJSON ({"type":"Point","coordinates":[lng,lat]}).
/// `null` si la valeur n'est pas un point lisible.
Point? lirePoint(Object? valeur) {
  if (valeur is Map) {
    final c = valeur['coordinates'];
    if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
      return (lat: (c[1] as num).toDouble(), lng: (c[0] as num).toDouble());
    }
    final lat = valeur['lat'];
    final lng = valeur['lng'];
    if (lat is num && lng is num) {
      return (lat: lat.toDouble(), lng: lng.toDouble());
    }
    return null;
  }
  if (valeur is! String || valeur.length < 42 || valeur.length.isOdd) {
    return null;
  }
  try {
    final octets = Uint8List(valeur.length ~/ 2);
    for (var i = 0; i < octets.length; i++) {
      octets[i] = int.parse(valeur.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final donnees = ByteData.sublistView(octets);
    final ordre = octets[0] == 1 ? Endian.little : Endian.big;
    final type = donnees.getUint32(1, ordre);
    // Bit 0x20000000 : un SRID suit le type (EWKB).
    var decalage = 5 + ((type & 0x20000000) != 0 ? 4 : 0);
    if ((type & 0xFF) != 1) return null; // pas un point
    final x = donnees.getFloat64(decalage, ordre);
    decalage += 8;
    final y = donnees.getFloat64(decalage, ordre);
    if (!x.isFinite || !y.isFinite) return null;
    return (lat: y, lng: x);
  } on Object {
    return null;
  }
}

/// Le cap de `de` vers `vers`, en degrés (0 = nord, sens horaire).
double cap(Point de, Point vers) {
  final phi1 = de.lat * math.pi / 180;
  final phi2 = vers.lat * math.pi / 180;
  final dl = (vers.lng - de.lng) * math.pi / 180;
  final y = math.sin(dl) * math.cos(phi2);
  final x =
      math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Distance approchée en mètres (suffisante à l'échelle d'une ville).
double metres(Point a, Point b) {
  final dLat = (b.lat - a.lat) * 111320;
  final dLng = (b.lng - a.lng) * 111320 * math.cos(a.lat * math.pi / 180);
  return math.sqrt(dLat * dLat + dLng * dLng);
}

/// Décode une polyligne Google (précision 1e-5) : le tracé de l'itinéraire
/// envoyé par le serveur (GET /orders/:id/itineraire).
List<Point> decoderPolyline(String code) {
  final points = <Point>[];
  var i = 0;
  var lat = 0;
  var lng = 0;
  while (i < code.length) {
    for (var axe = 0; axe < 2; axe++) {
      var resultat = 0;
      var decalage = 0;
      int octet;
      do {
        octet = code.codeUnitAt(i++) - 63;
        resultat |= (octet & 0x1f) << decalage;
        decalage += 5;
      } while (octet >= 0x20 && i < code.length);
      final delta = (resultat & 1) != 0 ? ~(resultat >> 1) : resultat >> 1;
      if (axe == 0) {
        lat += delta;
      } else {
        lng += delta;
      }
    }
    points.add((lat: lat / 1e5, lng: lng / 1e5));
  }
  return points;
}

/// Le tracé qui reste à parcourir : depuis la position du livreur, à partir
/// du point du tracé le plus proche de lui. Le chemin déjà fait disparaît,
/// comme dans Google Maps.
List<Point> resteDuTrace(List<Point> trace, Point livreur) {
  if (trace.isEmpty) return const [];
  var proche = 0;
  var meilleur = double.infinity;
  for (var i = 0; i < trace.length; i++) {
    final d = metres(livreur, trace[i]);
    if (d < meilleur) {
      meilleur = d;
      proche = i;
    }
  }
  // Le point le plus proche est-il déjà derrière lui ? S'il est plus loin
  // de la suite que le livreur lui-même, on le saute.
  if (proche + 1 < trace.length &&
      metres(livreur, trace[proche + 1]) <
          metres(trace[proche], trace[proche + 1])) {
    proche++;
  }
  return [livreur, ...trace.sublist(proche)];
}

/// Un tracé mesuré : chaque point connaît sa distance depuis le départ.
///
/// C'est ce qui fait avancer le livreur LE LONG DES RUES : chaque position
/// GPS reçue est projetée sur le tracé (distance parcourue `d`), puis le
/// livreur glisse de l'ancienne distance à la nouvelle — il prend les
/// virages au lieu de couper à travers les pâtés de maisons.
class TraceMesure {
  TraceMesure(this.points) : _cumul = _cumuler(points);

  final List<Point> points;
  final List<double> _cumul;

  static List<double> _cumuler(List<Point> points) {
    final cumul = <double>[];
    var total = 0.0;
    for (var i = 0; i < points.length; i++) {
      if (i > 0) total += metres(points[i - 1], points[i]);
      cumul.add(total);
    }
    return cumul;
  }

  double get longueur => _cumul.isEmpty ? 0 : _cumul.last;

  /// Le point du tracé le plus proche de `p` : sa distance depuis le départ
  /// (`d`), et l'écart en mètres entre `p` et le tracé.
  ({double d, double ecart}) projeter(Point p) {
    if (points.length < 2) {
      return (
        d: 0,
        ecart: points.isEmpty ? double.infinity : metres(p, points.first),
      );
    }
    var meilleurD = 0.0;
    var meilleurEcart = double.infinity;
    // Projection plane locale : à l'échelle d'une rue, la Terre est plate.
    final kx = 111320 * math.cos(p.lat * math.pi / 180);
    const ky = 110540.0;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      final ax = (a.lng - p.lng) * kx;
      final ay = (a.lat - p.lat) * ky;
      final bx = (b.lng - p.lng) * kx;
      final by = (b.lat - p.lat) * ky;
      final dx = bx - ax;
      final dy = by - ay;
      final l2 = dx * dx + dy * dy;
      final f = l2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / l2).clamp(0.0, 1.0);
      final x = ax + f * dx;
      final y = ay + f * dy;
      final ecart = math.sqrt(x * x + y * y);
      if (ecart < meilleurEcart) {
        meilleurEcart = ecart;
        meilleurD = _cumul[i] + f * (_cumul[i + 1] - _cumul[i]);
      }
    }
    return (d: meilleurD, ecart: meilleurEcart);
  }

  /// Le point à la distance `d` du départ.
  Point pointA(double d) {
    if (points.isEmpty) return (lat: 0, lng: 0);
    if (d <= 0 || points.length == 1) return points.first;
    if (d >= longueur) return points.last;
    var i = 0;
    while (i < _cumul.length - 2 && _cumul[i + 1] < d) {
      i++;
    }
    final segment = _cumul[i + 1] - _cumul[i];
    final f = segment == 0 ? 0.0 : (d - _cumul[i]) / segment;
    final a = points[i];
    final b = points[i + 1];
    return (lat: a.lat + (b.lat - a.lat) * f, lng: a.lng + (b.lng - a.lng) * f);
  }

  /// L'indice du premier point du tracé situé au-delà de `d`.
  int indiceApres(double d) {
    var i = 0;
    while (i < _cumul.length && _cumul[i] <= d) {
      i++;
    }
    return i;
  }

  /// Du point à la distance `d` jusqu'au point d'indice `jusqua` inclus.
  List<Point> entre(double d, int jusqua) {
    if (points.isEmpty) return const [];
    final fin = jusqua.clamp(0, points.length - 1);
    final debut = indiceApres(d);
    return [pointA(d), if (debut <= fin) ...points.sublist(debut, fin + 1)];
  }

  /// Le tracé de `d` jusqu'au bout (ce qui reste à parcourir).
  List<Point> depuis(double d) {
    if (points.isEmpty) return const [];
    var i = 0;
    while (i < _cumul.length && _cumul[i] <= d) {
      i++;
    }
    return [pointA(d), ...points.sublist(i)];
  }
}

/// Le livreur sur la carte du client, le long de la route : il avance à
/// CHAQUE IMAGE, jamais par bonds (retour du 27/09 : « ça saute, puis rien »).
///
/// - Chaque position GPS reçue est projetée sur le tracé : c'est la distance
///   cible.
/// - La distance affichée avance vers la cible à vitesse constante, sur la
///   durée moyenne entre deux positions : elle y arrive à peu près quand la
///   suivante tombe.
/// - La suivante tarde : il continue sur sa lancée (vitesse du GPS, sinon
///   celle mesurée) pendant 10 s au plus, puis ralentit jusqu'à l'arrêt.
/// - Un recul de moins de 15 m (le GPS tremble) est ignoré. Parti trop loin
///   devant, il s'arrête et attend que la réalité le rattrape.
/// - Le cap suit la route (entre −3 m et +3 m), lissé : il tourne, il ne
///   pivote pas d'un coup.
class LivreurSurRoute {
  LivreurSurRoute(this.trace);

  final TraceMesure trace;

  double? _d;
  double? _cible;
  double _vitesseAvance = 0;
  double _vitesseRoute = 0;
  double _intervalle = 3;
  DateTime? _derniereReception;
  bool _attend = false;
  double? _cap;

  /// La distance affichée depuis le départ du tracé.
  double? get d => _d;

  Point? get position => _d == null ? null : trace.pointA(_d!);

  /// Le cap lissé, en degrés (0 = nord).
  double? get capDegres => _cap;

  /// Une position reçue. Faux quand elle est à plus de 50 m de la route :
  /// il a pris une autre rue, il faut un nouveau tracé.
  bool recevoir(Point p, {double? vitesseKmh, DateTime? maintenant}) {
    final t = maintenant ?? DateTime.now();
    final projection = trace.projeter(p);
    if (projection.ecart > 50) return false;
    final avant = _derniereReception;
    final ecart = avant == null
        ? null
        : (t.difference(avant).inMilliseconds / 1000).clamp(0.5, 20.0);
    if (ecart != null) _intervalle = _intervalle * 0.7 + ecart * 0.3;
    final ancienneCible = _cible;
    if (_d == null || ancienneCible == null) {
      _d = projection.d;
      _cible = projection.d;
      _vitesseAvance = 0;
    } else {
      final recul = ancienneCible - projection.d;
      if (recul <= 0 || recul >= 15) _cible = projection.d;
      final mesuree = ecart == null
          ? 0.0
          : ((_cible! - ancienneCible) / ecart).clamp(0.0, 25.0);
      _vitesseRoute = vitesseKmh != null && vitesseKmh > 1
          ? vitesseKmh / 3.6
          : mesuree;
      _attend = _d! - _cible! > 15;
      _vitesseAvance = math.max(0, _cible! - _d!) / _intervalle;
    }
    _derniereReception = t;
    return true;
  }

  /// Fait avancer d'une image (`dt` en secondes).
  void avancer(double dt, {DateTime? maintenant}) {
    final d = _d;
    final cible = _cible;
    if (d == null || cible == null) return;
    final t = maintenant ?? DateTime.now();
    final depuis = _derniereReception == null
        ? 0.0
        : t.difference(_derniereReception!).inMilliseconds / 1000;
    double vitesse;
    // En avance sur la réalité (la dernière position l'a dit) : il attend
    // qu'elle le rattrape. Jamais de recul à l'écran.
    if (_attend) {
      vitesse = 0;
    } else if (d < cible) {
      vitesse = _vitesseAvance;
    } else if (depuis < 10) {
      vitesse = _vitesseRoute;
    } else {
      _vitesseRoute *= math.exp(-dt * 1.2);
      vitesse = _vitesseRoute;
    }
    _d = math.min(trace.longueur, _d! + vitesse * dt);

    final avant = trace.pointA(_d! - 3);
    final apres = trace.pointA(_d! + 3);
    if (metres(avant, apres) > 2) {
      final vise = cap(avant, apres);
      final actuel = _cap;
      if (actuel == null) {
        _cap = vise;
      } else {
        final ecart = ((vise - actuel + 540) % 360) - 180;
        _cap = (actuel + ecart * (1 - math.exp(-dt * 7)) + 360) % 360;
      }
    }
  }
}

/// La moto sur la carte : elle GLISSE d'une position reçue à la suivante,
/// en autant de temps qu'il en a fallu pour la recevoir (≈ 5 s), au lieu de
/// sauter. Le cap suit la route ; immobile, elle garde son dernier cap.
class MotoAnimee {
  Point? _depart;
  Point? _arrivee;
  DateTime? _debut;
  Duration _duree = const Duration(seconds: 5);
  double _cap = 0;
  DateTime? _derniereReception;

  /// Une nouvelle position reçue. `capDonne` : celui du GPS du livreur, s'il
  /// est fiable (en mouvement).
  void recevoir(
    Point p, {
    double? capDonne,
    double? vitesseKmh,
    DateTime? maintenant,
  }) {
    final t = maintenant ?? DateTime.now();
    _vitesseKmh = vitesseKmh;
    final actuel = position(t);
    if (actuel == null) {
      _depart = p;
      _arrivee = p;
      _debut = t;
      _derniereReception = t;
      if (capDonne != null) _cap = capDonne;
      return;
    }
    // Un saut aberrant (plus de 2 km en un envoi : GPS perdu, reprise après
    // un tunnel) : on se pose directement, sans traverser la ville.
    if (metres(actuel, p) > 2000) {
      _depart = p;
      _arrivee = p;
      _debut = t;
      _derniereReception = t;
      return;
    }
    final ecart = _derniereReception == null
        ? const Duration(seconds: 5)
        : t.difference(_derniereReception!);
    _duree = Duration(
      milliseconds: ecart.inMilliseconds.clamp(800, 12000).toInt(),
    );
    _derniereReception = t;
    if (metres(actuel, p) >= 3) {
      _cap = capDonne ?? cap(actuel, p);
    }
    _depart = actuel;
    _arrivee = p;
    _debut = t;
  }

  /// Où dessiner la moto à l'instant `t`.
  Point? position([DateTime? t]) {
    final depart = _depart;
    final arrivee = _arrivee;
    final debut = _debut;
    if (depart == null || arrivee == null || debut == null) return null;
    final ecoule = (t ?? DateTime.now()).difference(debut).inMilliseconds;
    final f = _duree.inMilliseconds == 0
        ? 1.0
        : (ecoule / _duree.inMilliseconds).clamp(0.0, 1.0);
    return (
      lat: depart.lat + (arrivee.lat - depart.lat) * f,
      lng: depart.lng + (arrivee.lng - depart.lng) * f,
    );
  }

  double get capDegres => _cap;

  double? _vitesseKmh;

  /// La vitesse donnée par le GPS du livreur avec la dernière position,
  /// quand il l'a donnée.
  double? get vitesseKmh => _vitesseKmh;

  /// La dernière position reçue (là où la glisse s'arrêtera).
  Point? get derniere => _arrivee;

  /// La durée de la glisse en cours : l'écart entre les deux dernières
  /// positions reçues.
  Duration get duree => _duree;

  /// Encore en train de glisser ?
  bool enMouvement([DateTime? t]) {
    final debut = _debut;
    if (debut == null) return false;
    return (t ?? DateTime.now()).difference(debut) < _duree;
  }
}
