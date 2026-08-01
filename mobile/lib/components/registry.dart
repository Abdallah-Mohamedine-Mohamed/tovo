// =============================================================================
// Tovo — Registre de composants
// =============================================================================
// Implémente le contrat UI côté Flutter (docs/tovo_ui_contract.md).
//
// Le backend décrit, Flutter rend. Ce fichier n'a qu'une responsabilité :
// transformer un descripteur JSON en widget natif, et faire remonter les taps
// sous forme d'interactions normalisées.
//
// Il ne contient AUCUN widget. Chaque composant vit dans son propre fichier et
// s'enregistre au démarrage via ComponentRegistry.register() — voir
// components/register_all.dart. Conséquence : ce fichier compile seul, ne
// change jamais quand on ajoute un composant, et un composant inconnu d'une
// vieille version de l'app est ignoré au lieu de crasher le fil.
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Version du contrat comprise par ce client.
/// Envoyée au backend dans l'en-tête `X-Tovo-Contract` ; le backend n'émet
/// que des composants supportés par cette version.
const int kTovoContractVersion = 1;

// -----------------------------------------------------------------------------
// Modèles
// -----------------------------------------------------------------------------

/// Un descripteur de composant tel que renvoyé par le backend.
@immutable
class TovoComponent {
  const TovoComponent({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;

  factory TovoComponent.fromJson(Map<String, dynamic> json) {
    final raw = json['data'];
    return TovoComponent(
      type: (json['type'] as String?)?.trim() ?? '',
      data: raw is Map<String, dynamic> ? raw : const <String, dynamic>{},
    );
  }

  /// Lecture tolérante : un champ absent ou mal typé ne fait jamais planter le
  /// rendu, il retombe sur la valeur par défaut. Le contrat dit que Flutter
  /// ignore ce qu'il ne connaît pas — il ne devine pas.
  T? get<T>(String key) {
    final value = data[key];
    return value is T ? value : null;
  }

  String str(String key, [String fallback = '']) => get<String>(key) ?? fallback;

  bool flag(String key, [bool fallback = false]) => get<bool>(key) ?? fallback;

  /// Les montants arrivent en entiers XOF. Un backend qui enverrait un double
  /// viole le contrat ; on le tronque plutôt que de crasher.
  int money(String key, [int fallback = 0]) {
    final value = data[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  List<Map<String, dynamic>> list(String key) {
    final value = data[key];
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  Map<String, dynamic> map(String key) {
    final value = data[key];
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }
}

/// Un tap remonté vers le backend.
///
/// [action] doit être une des actions normalisées du contrat §3. C'est le
/// routeur d'interactions (features/chat) qui décide si elle part vers
/// POST /chat (tour LLM) ou vers une route REST directe — le registre ne
/// connaît pas cette distinction.
@immutable
class TovoInteraction {
  const TovoInteraction(this.action, [this.payload = const {}]);

  final String action;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {'action': action, 'payload': payload};

  @override
  String toString() => 'TovoInteraction($action, $payload)';
}

typedef InteractionCallback = void Function(TovoInteraction interaction);

/// Construit le widget d'un composant. Reçoit le descripteur et le callback
/// d'interaction à câbler sur les zones tapables.
typedef ComponentBuilder = Widget Function(
  TovoComponent component,
  InteractionCallback onInteraction,
);

// -----------------------------------------------------------------------------
// Registre
// -----------------------------------------------------------------------------

class ComponentRegistry {
  ComponentRegistry._();

  static final Map<String, ComponentBuilder> _builders = {};

  /// Enregistre le constructeur d'un type de composant.
  /// Appelé une fois au démarrage depuis register_all.dart.
  static void register(String type, ComponentBuilder builder) {
    assert(type.isNotEmpty, 'Un type de composant ne peut pas être vide');
    _builders[type] = builder;
  }

  static void registerAll(Map<String, ComponentBuilder> builders) {
    builders.forEach(register);
  }

  static bool supports(String type) => _builders.containsKey(type);

  @visibleForTesting
  static void reset() => _builders.clear();

  /// Construit un composant.
  ///
  /// Retourne `null` — jamais une exception — dans trois cas :
  ///   * type inconnu (composant introduit après cette version de l'app) ;
  ///   * descripteur malformé ;
  ///   * le builder lui-même lève.
  ///
  /// Un fil de conversation ne doit jamais être cassé par un seul composant.
  static Widget? build(
    TovoComponent component,
    InteractionCallback onInteraction,
  ) {
    final builder = _builders[component.type];
    if (builder == null) {
      _report('type inconnu', component.type);
      return null;
    }
    try {
      return builder(component, onInteraction);
    } catch (error, stack) {
      _report('erreur de rendu', component.type, error, stack);
      return null;
    }
  }

  /// Construit tous les composants d'un message, dans l'ordre.
  /// Les composants non rendus sont retirés silencieusement.
  static List<Widget> buildAll(
    List<TovoComponent> components,
    InteractionCallback onInteraction,
  ) {
    final widgets = <Widget>[];
    for (final component in components) {
      final widget = build(component, onInteraction);
      if (widget != null) widgets.add(widget);
    }
    return widgets;
  }

  /// Variante prenant le JSON brut du champ `components` d'un message.
  static List<Widget> buildAllFromJson(
    List<dynamic> raw,
    InteractionCallback onInteraction,
  ) {
    final components = raw
        .whereType<Map<String, dynamic>>()
        .map(TovoComponent.fromJson)
        .where((c) => c.type.isNotEmpty)
        .toList(growable: false);
    return buildAll(components, onInteraction);
  }

  static void _report(
    String reason,
    String type, [
    Object? error,
    StackTrace? stack,
  ]) {
    // En debug on veut le voir tout de suite ; en production on remonte à
    // l'observabilité sans jamais interrompre l'utilisateur.
    if (kDebugMode) {
      debugPrint('[ComponentRegistry] $reason : "$type" ${error ?? ''}');
    }
    onRenderFailure?.call(reason, type, error, stack);
  }

  /// Hook d'observabilité, branché sur Sentry dans main_client.dart.
  /// Un pic de « type inconnu » signale des clients en retard de version.
  static void Function(String reason, String type, Object? error, StackTrace? stack)?
      onRenderFailure;
}

// -----------------------------------------------------------------------------
// Formatage monétaire
// -----------------------------------------------------------------------------

/// Le XOF n'a pas de subdivision : jamais de décimales, jamais de conversion.
/// Le backend envoie des entiers, Flutter les met en forme. Un seul endroit.
class Money {
  const Money._();

  static const String symbol = 'F';

  /// 4900 → « 4 900 F » (espace insécable étroit, comme l'usage local).
  static String format(int amount, {bool withSymbol = true}) {
    final negative = amount < 0;
    final digits = amount.abs().toString();
    final buffer = StringBuffer();

    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(digits[i]);
    }

    final formatted = '${negative ? '-' : ''}$buffer';
    return withSymbol ? '$formatted $symbol' : formatted;
  }

  /// 350 → « 350 m », 4200 → « 4,2 km »
  static String distance(int? meters) {
    if (meters == null) return '';
    if (meters < 1000) return '$meters m';
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }
}
