import 'package:flutter/services.dart';

/// Le suivi de commande sur Android (voir TovoSuiviPlugin.kt).
///
/// Disponible aussi dans le moteur d'arrière-plan de Firebase : la
/// notification se met à jour app fermée.
class TovoSuivi {
  const TovoSuivi._();

  static const _canal = MethodChannel('tovo/suivi');

  /// Affiche ou met à jour la notification de suivi d'une commande.
  static Future<void> afficher({
    required String id,
    required String phrase,
    required String etape,
    required String court,
    required String image,
    required int index,
    required DateTime debut,
    required DateTime fin,
    required bool fini,
    required bool annule,
    required bool alerte,
  }) => _canal.invokeMethod<bool>('afficher', {
    'id': id,
    'phrase': phrase,
    'etape': etape,
    'court': court,
    'image': image,
    'index': index,
    'debut': debut.millisecondsSinceEpoch,
    'fin': fin.millisecondsSinceEpoch,
    'fini': fini,
    'annule': annule,
    'alerte': alerte,
  });

  /// Retire la notification de suivi d'une commande.
  static Future<void> retirer(String id) =>
      _canal.invokeMethod<bool>('retirer', {'id': id});

  /// Vrai sur Android 16 et plus (« Live Updates »).
  static Future<bool> liveUpdates() async =>
      await _canal.invokeMethod<bool>('liveUpdates') ?? false;
}
