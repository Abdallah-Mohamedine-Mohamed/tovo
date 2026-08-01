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

  /// Renvoie la position, ou `null` si elle n'est pas obtenable.
  ///
  /// On ne renvoie jamais une position par défaut en cas d'échec : livrer au
  /// centre-ville quelqu'un qui habite Talladjé est pire que de lui demander
  /// d'activer sa localisation.
  static Future<Position?> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          // Sur réseau et GPS instables, mieux vaut une position approximative
          // rapidement qu'un écran figé.
          timeLimit: Duration(seconds: 12),
        ),
      );
    } on Exception {
      return await Geolocator.getLastKnownPosition();
    }
  }
}
