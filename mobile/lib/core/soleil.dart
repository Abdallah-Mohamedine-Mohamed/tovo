import 'dart:math' as math;

/// Fait-il jour, à cet endroit, à cet instant ?
///
/// La carte de suivi passe en thème clair ou sombre avec le vrai lever et
/// le vrai coucher du soleil chez le client, pas à heure fixe (maquette
/// « Suivi Commande », 27/09). Le soleil est levé quand son centre dépasse
/// -0,833° sous l'horizon — la convention des éphémérides (réfraction et
/// rayon apparent compris), la même que SunCalc.
///
/// Formules astronomiques simplifiées (précision de l'ordre de la minute,
/// largement assez pour choisir un thème).
bool estLeJour(double lat, double lng, [DateTime? instant]) =>
    hauteurDuSoleil(lat, lng, instant) > -0.833;

/// Hauteur du soleil au-dessus de l'horizon, en degrés.
double hauteurDuSoleil(double lat, double lng, [DateTime? instant]) {
  const rad = math.pi / 180;
  final t = (instant ?? DateTime.now()).toUtc();
  // Jours depuis J2000 (1er janvier 2000, 12 h TU).
  final n = t.millisecondsSinceEpoch / 86400000 + 2440587.5 - 2451545.0;
  final l = (280.460 + 0.9856474 * n) % 360; // longitude moyenne
  final g = ((357.528 + 0.9856003 * n) % 360) * rad; // anomalie moyenne
  final lambda = (l + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) * rad;
  final epsilon = (23.439 - 0.0000004 * n) * rad;
  final ascension = math.atan2(
    math.cos(epsilon) * math.sin(lambda),
    math.cos(lambda),
  );
  final declinaison = math.asin(math.sin(epsilon) * math.sin(lambda));
  final tsmg = (18.697374558 + 24.06570982441908 * n) % 24; // heures
  final angleHoraire = (tsmg * 15 + lng) * rad - ascension;
  final phi = lat * rad;
  return math.asin(
        math.sin(phi) * math.sin(declinaison) +
            math.cos(phi) * math.cos(declinaison) * math.cos(angleHoraire),
      ) /
      rad;
}
