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
