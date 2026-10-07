import 'dart:math' as math;

import '../../core/position_livreur.dart';

/// Où en est le client sur son trajet (« Y aller », 07/10) : du calcul pur,
/// testé à part.
class Progres {
  const Progres({
    required this.segment,
    required this.projection,
    required this.restantM,
    required this.ecartM,
  });

  /// Le segment du trajet où il se trouve (entre les points i et i + 1).
  final int segment;

  /// Son point le plus proche SUR le trajet.
  final Point projection;

  /// La distance qui lui reste, le long du trajet.
  final double restantM;

  /// Son écart au trajet (s'il s'en éloigne, on recalcule).
  final double ecartM;

  static Progres? calculer(List<Point> trace, Point ici) {
    if (trace.length < 2) return null;
    // Projection plane locale (en mètres) autour du client : précise à
    // l'échelle d'une ville.
    final kx = 111320 * math.cos(ici.lat * math.pi / 180);
    const ky = 111320.0;
    double x(Point p) => (p.lng - ici.lng) * kx;
    double y(Point p) => (p.lat - ici.lat) * ky;
    var meilleur = double.infinity;
    var segment = 0;
    var t = 0.0;
    for (var i = 0; i < trace.length - 1; i++) {
      final ax = x(trace[i]), ay = y(trace[i]);
      final bx = x(trace[i + 1]), by = y(trace[i + 1]);
      final vx = bx - ax, vy = by - ay;
      final l = vx * vx + vy * vy;
      final k = l == 0 ? 0.0 : (-(ax * vx + ay * vy) / l).clamp(0.0, 1.0);
      final px = ax + vx * k, py = ay + vy * k;
      final d = math.sqrt(px * px + py * py);
      if (d < meilleur) {
        meilleur = d;
        segment = i;
        t = k;
      }
    }
    final a = trace[segment], b = trace[segment + 1];
    final projection = (
      lat: a.lat + (b.lat - a.lat) * t,
      lng: a.lng + (b.lng - a.lng) * t,
    );
    var restant = metres(projection, b);
    for (var i = segment + 1; i < trace.length - 1; i++) {
      restant += metres(trace[i], trace[i + 1]);
    }
    return Progres(
      segment: segment,
      projection: projection,
      restantM: restant,
      ecartM: meilleur,
    );
  }

  /// Le trajet déjà parcouru (éteint sur la carte) et celui qui reste.
  (List<Point>, List<Point>) couper(List<Point> trace) => (
    [...trace.take(segment + 1), projection],
    [projection, ...trace.skip(segment + 1)],
  );
}

/// Un point à `metresDevant` mètres dans la direction `capDeg` : la caméra
/// regarde un peu devant l'avatar, comme une navigation.
Point devant(Point p, double capDeg, double metresDevant) {
  final r = capDeg * math.pi / 180;
  return (
    lat: p.lat + math.cos(r) * metresDevant / 111320,
    lng:
        p.lng +
        math.sin(r) * metresDevant / (111320 * math.cos(p.lat * math.pi / 180)),
  );
}

/// L'écart signé le plus court entre deux angles (degrés), dans [-180, 180].
double ecartAngle(double de, double vers) {
  var d = (vers - de) % 360;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}

/// Une consigne du guidage (Google Routes, en français).
class EtapeGuidage {
  const EtapeGuidage({
    required this.instruction,
    required this.manoeuvre,
    required this.debut,
    required this.restantAuDebut,
  });

  final String instruction;
  final String? manoeuvre;
  final Point debut;

  /// La distance qui reste, le long du trajet, au début de cette étape.
  final double restantAuDebut;
}

/// Le guidage vocal (« Y aller », 07/10) : la prochaine consigne, sa
/// distance, et ce qu'il faut dire — chaque annonce une seule fois.
class Guide {
  Guide(this.etapes);

  final List<EtapeGuidage> etapes;
  final _dites = <String>{};

  /// La prochaine consigne devant lui, et à combien de mètres.
  ({EtapeGuidage etape, int rang, double dansM})? prochaine(double restantM) {
    for (var i = 0; i < etapes.length; i++) {
      final e = etapes[i];
      // Devant lui : il reste plus de route que jusqu'au début de l'étape.
      if (e.restantAuDebut < restantM - 3) {
        return (etape: e, rang: i, dansM: restantM - e.restantAuDebut);
      }
    }
    return null;
  }

  /// Ce qu'il faut annoncer maintenant, ou null.
  String? annonce(double restantM) {
    // Au départ : la première consigne (« Prendre la direction nord… »).
    if (etapes.isNotEmpty && _dites.add('depart')) {
      return etapes.first.instruction;
    }
    if (restantM < 20) {
      return _dites.add('arrivee') ? 'Vous êtes arrivé.' : null;
    }
    final p = prochaine(restantM);
    if (p == null) return null;
    final consigne = p.etape.instruction;
    if (p.dansM <= 35) {
      // Au moment de tourner (l'annonce lointaine n'a plus lieu d'être).
      _dites.add('${p.rang}:loin');
      return _dites.add('${p.rang}:pres') ? consigne : null;
    }
    if (p.dansM <= 160 && _dites.add('${p.rang}:loin')) {
      return 'Dans ${distanceDite(p.dansM)}, ${minusculeInitiale(consigne)}';
    }
    return null;
  }
}

/// « 80 mètres », « 150 mètres » : arrondi comme on le dit.
String distanceDite(double m) {
  final arrondi = m < 100 ? (m / 10).round() * 10 : (m / 50).round() * 50;
  return '$arrondi mètres';
}

String minusculeInitiale(String s) =>
    s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);
