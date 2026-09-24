import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Position de livraison.
///
/// À Niamey, l'adresse postale n'existe pas : le point GPS fait foi et le
/// texte n'est qu'un repère pour le livreur. C'est pourquoi la position est
/// obligatoire pour commander, et pas une commodité.
class TovoLocation {
  const TovoLocation._();

  /// Centre de Niamey — utilisé uniquement comme repère de secours affiché à
  /// l'utilisateur, jamais envoyé silencieusement à sa place.
  static const double niameyLat = 13.5137;
  static const double niameyLng = 2.1098;

  static Future<bool> ensurePermission({bool requestPermission = false}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && requestPermission) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Renvoie la position, ou `null` si elle n'est pas obtenable.
  ///
  /// On ne renvoie jamais une position par défaut en cas d'échec : livrer au
  /// centre-ville quelqu'un qui habite Talladjé est pire que de lui demander
  /// d'activer sa localisation.
  static Future<Position?> current({bool requestPermission = false}) async {
    try {
      if (!await ensurePermission(requestPermission: requestPermission)) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          // Sur réseau et GPS instables, mieux vaut une position approximative
          // rapidement qu'un écran figé.
          timeLimit: Duration(seconds: 12),
        ),
      );
      _retenir(position);
      return position;
    } on Exception {
      try {
        return requestPermission
            ? null
            : await Geolocator.getLastKnownPosition();
      } on Exception {
        return null;
      }
    }
  }

  static Position? _derniere;
  static DateTime? _le;

  static void _retenir(Position position) {
    _derniere = position;
    _le = DateTime.now();
  }

  /// La position obtenue il y a moins de dix minutes, sans attendre.
  ///
  /// Un fix GPS prend plusieurs secondes ; le client qui demande un livreur
  /// n'a pas bougé depuis l'ouverture de l'application.
  static Position? get recente {
    final le = _le;
    if (le == null || DateTime.now().difference(le).inMinutes >= 10) {
      return null;
    }
    return _derniere;
  }

  /// À l'ouverture de l'application : prend la position en arrière-plan,
  /// SANS demander l'autorisation (aucune fenêtre au démarrage). Si elle est
  /// déjà accordée, la carte livreur et le panier l'ont tout de suite.
  static void prechauffer() => unawaited(current());
}
