import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../components/registry.dart';
import 'config.dart';

/// Client du backend Tovo.
///
/// Toutes les réponses métier suivent la même enveloppe — `content` +
/// `components` — que la source soit une route REST ou, plus tard,
/// l'orchestrateur IA. L'app ne fait pas la différence, et c'est exactement
/// ce que le contrat UI garantit.
class TovoApi {
  TovoApi({
    http.Client? client,
    FutureOr<String?> Function()? tokenProvider,
    Future<bool> Function()? onRenouveler,
  })  : _client = client ?? http.Client(),
        _token = tokenProvider ?? _tokenDepuisSupabase,
        // Un jeton fourni de l'extérieur appartient à l'appelant : le
        // renouveler auprès de Supabase, que les tests n'initialisent pas,
        // planterait au lieu d'aider. D'où le renouvellement injectable, sans
        // quoi le second essai sur 401 ne serait vérifiable nulle part.
        _renouveler =
            onRenouveler ?? (tokenProvider == null ? _renouvelerSupabase : null);

  final http.Client _client;

  final Future<bool> Function()? _renouveler;

  /// Injectable : sans cela, tester la file hors ligne exigerait d'initialiser
  /// Supabase, ce qui transformerait un test unitaire en test d'intégration.
  final FutureOr<String?> Function() _token;

  /// Le jeton d'accès, rafraîchi s'il est sur le point d'expirer.
  ///
  /// Il ne vit qu'une heure. Supabase le renouvelle tout seul — au moyen d'un
  /// minuteur, qui ne tourne PAS pendant que le téléphone dort. Au réveil, la
  /// session en mémoire porte donc un jeton périmé, et la première requête
  /// partait avec : le backend répondait « session invalide » à quelqu'un qui
  /// était pourtant bel et bien connecté, au moment précis où il commandait.
  ///
  /// La marge de soixante secondes couvre le trajet réseau : un jeton valide
  /// à l'envoi peut expirer avant d'arriver.
  ///
  /// Publique parce que les lectures directes à Supabase — `AuthGate` lit le
  /// rôle sans passer par le backend — souffrent exactement du même jeton
  /// périmé, et échouaient au réveil de l'appareil.
  static Future<String?> jetonFrais() => _tokenDepuisSupabase();

  static Future<String?> _tokenDepuisSupabase() async {
    final auth = Supabase.instance.client.auth;
    final session = auth.currentSession;
    if (session == null) return null;

    final expire = session.expiresAt;
    final bientot = expire != null &&
        DateTime.now().toUtc().add(const Duration(seconds: 60)).isAfter(
              DateTime.fromMillisecondsSinceEpoch(expire * 1000, isUtc: true),
            );
    if (!bientot) return session.accessToken;

    try {
      final rafraichie = await auth.refreshSession();
      return rafraichie.session?.accessToken ?? session.accessToken;
    } on AuthException {
      // Le jeton de rafraîchissement est mort : rien ne le ressuscitera, et
      // réessayer indéfiniment enfermerait l'utilisateur sur un écran qui
      // refuse tout. La déconnexion ramène `AuthGate` à l'écran de connexion,
      // qui lui est une action possible.
      await auth.signOut();
      return null;
    } on Exception {
      // Réseau muet : on tente le jeton en main. S'il est périmé, le 401
      // ci-dessous provoquera un second essai.
      return session.accessToken;
    }
  }

  Future<Map<String, String>> get _headers async {
    final token = await _token();
    return {
      'content-type': 'application/json',
      'x-tovo-contract': '${TovoConfig.contractVersion}',
      if (token != null) 'authorization': 'Bearer $token',
    };
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse(TovoConfig.apiBaseUrl);
    return base.replace(
      path: path,
      queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
    );
  }

  Future<TovoResponse> get(String path, {Map<String, dynamic>? query}) =>
      _send(() async => _client.get(_uri(path, query), headers: await _headers));

  Future<TovoResponse> post(String path, Map<String, dynamic> body) => _send(
      () async => _client.post(_uri(path), headers: await _headers, body: jsonEncode(body)));

  Future<TovoResponse> patch(String path, Map<String, dynamic> body) => _send(
      () async => _client.patch(_uri(path), headers: await _headers, body: jsonEncode(body)));

  Future<TovoResponse> delete(String path) =>
      _send(() async => _client.delete(_uri(path), headers: await _headers));

  /// Envoie, avec un second essai sur coupure réseau.
  ///
  /// Rejouer est SÛR ici : le corps de la requête est construit avant
  /// l'appel, donc un réessai renvoie le même `client_message_id` et la même
  /// commande. Le backend reconnaît le rejeu et ne refacture pas le modèle.
  ///
  /// Sans ça, une seule coupure d'une seconde — le quotidien d'un réseau
  /// mobile à Niamey — affichait « Connexion perdue » et laissait le client
  /// appuyer une deuxième fois lui-même.
  Future<TovoResponse> _send(Future<http.Response> Function() request) async {
    var jetonRenouvele = false;

    for (var essai = 1; ; essai++) {
      final resultat = await _tenter(request);

      // Un 401 après vérification de l'expiration veut dire que le jeton est
      // mort pendant le trajet — horloge décalée, requête lente. Le
      // renouveler et rejouer une fois évite d'annoncer « session expirée » à
      // quelqu'un qu'un simple aller-retour aurait reconnecté. Une seule
      // fois : si le second échoue aussi, la session est réellement perdue.
      final renouveler = _renouveler;
      if (resultat != null &&
          resultat.statusCode == 401 &&
          renouveler != null &&
          !jetonRenouvele) {
        jetonRenouvele = true;
        if (await renouveler()) continue;
      }

      if (resultat != null) return resultat;

      if (essai >= 2) {
        return TovoResponse.failure(
          message: 'Connexion perdue. Réessayez dans un instant.',
          statusCode: 0,
          components: const [],
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Renouvelle la session de force. Vrai si un nouveau jeton est en main.
  static Future<bool> _renouvelerSupabase() async {
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession == null) return false;
    try {
      return (await auth.refreshSession()).session != null;
    } on AuthException {
      // Refus net du serveur : la session est perdue pour de bon. On
      // déconnecte pour que l'écran de connexion reprenne la main, plutôt que
      // de laisser l'app buter sur des 401 qu'aucun geste ne résoudra.
      await auth.signOut();
      return false;
    } on Exception {
      return false;
    }
  }

  /// Un essai. Renvoie `null` si le réseau a lâché — donc s'il vaut la peine
  /// de recommencer. Une réponse du serveur, même en erreur, est un
  /// résultat : la rejouer donnerait exactement la même chose.
  Future<TovoResponse?> _tenter(Future<http.Response> Function() request) async {
    try {
      // 30 s et non 20 : une conversation demande au modèle de choisir un
      // outil, de l'exécuter et de rédiger. Mesuré à 3,5 s depuis une bonne
      // connexion — le reste est la marge du réseau mobile.
      final response = await request().timeout(const Duration(seconds: 30));
      // Un corps illisible vient du serveur, pas du réseau : le dire
      // « connexion perdue » enverrait chercher la panne au mauvais endroit,
      // et rejouer ne changerait rien.
      Map<String, dynamic> decoded;
      try {
        decoded = response.body.isEmpty
            ? const <String, dynamic>{}
            : jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        return TovoResponse.failure(
          message: 'Réponse inattendue du serveur.',
          statusCode: response.statusCode,
          components: const [],
        );
      }

      if (response.statusCode >= 400) {
        return TovoResponse.failure(
          // Le backend renvoie un message rédigé pour l'utilisateur sur les
          // erreurs métier (400/404/409). On l'affiche tel quel.
          //
          // `content` en second recours : une route qui répond par une
          // enveloppe complète — texte ET boutons — n'a pas de clé `error`.
          // Le conflit de panier le faisait, et l'écran montrait « Une
          // erreur est survenue » suivi de deux boutons dont rien
          // n'expliquait l'objet.
          message: (decoded['error'] as String?) ??
              (decoded['content'] as String?) ??
              'Une erreur est survenue.',
          statusCode: response.statusCode,
          components: _components(decoded),
        );
      }

      return TovoResponse.success(
        content: decoded['content'] as String? ?? '',
        components: _components(decoded),
        raw: decoded,
      );
    } on Exception {
      // Coupure réseau : le cas normal à Niamey, pas l'exception.
      // `null` demande un nouvel essai à l'appelant.
      return null;
    }
  }

  static List<TovoComponent> _components(Map<String, dynamic> body) {
    final raw = body['components'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(TovoComponent.fromJson)
        .where((c) => c.type.isNotEmpty)
        .toList(growable: false);
  }
}

class TovoResponse {
  const TovoResponse._({
    required this.ok,
    required this.content,
    required this.components,
    required this.statusCode,
    required this.raw,
  });

  factory TovoResponse.success({
    required String content,
    required List<TovoComponent> components,
    Map<String, dynamic> raw = const {},
  }) =>
      TovoResponse._(
        ok: true,
        content: content,
        components: components,
        statusCode: 200,
        raw: raw,
      );

  factory TovoResponse.failure({
    required String message,
    required int statusCode,
    required List<TovoComponent> components,
  }) =>
      TovoResponse._(
        ok: false,
        content: message,
        components: components,
        statusCode: statusCode,
        raw: const {},
      );

  final bool ok;
  final String content;
  final List<TovoComponent> components;
  final int statusCode;

  /// Corps décodé tel quel.
  ///
  /// Toutes les routes ne renvoient pas l'enveloppe du contrat : les listes
  /// destinées aux apps livreur et boutiquier (`/orders`, `/driver/pool`,
  /// `/driver/summary`) sont des lectures brutes, pas des éléments du fil
  /// conversationnel. Les forcer dans des composants serait déformer le
  /// contrat pour rien.
  final Map<String, dynamic> raw;

  /// Liste d'objets sous une clé donnée, vide si absente ou mal typée.
  List<Map<String, dynamic>> list(String key) {
    final valeur = raw[key];
    if (valeur is! List) return const [];
    return valeur.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  /// Vrai quand l'échec vient du réseau et non d'un refus du serveur : dans
  /// ce cas seulement, réessayer a du sens.
  bool get isOffline => statusCode == 0;
}
