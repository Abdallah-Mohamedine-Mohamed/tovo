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
  TovoApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Map<String, String> get _headers {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
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
      _send(() => _client.get(_uri(path, query), headers: _headers));

  Future<TovoResponse> post(String path, Map<String, dynamic> body) =>
      _send(() => _client.post(_uri(path), headers: _headers, body: jsonEncode(body)));

  Future<TovoResponse> patch(String path, Map<String, dynamic> body) =>
      _send(() => _client.patch(_uri(path), headers: _headers, body: jsonEncode(body)));

  Future<TovoResponse> delete(String path) =>
      _send(() => _client.delete(_uri(path), headers: _headers));

  Future<TovoResponse> _send(Future<http.Response> Function() request) async {
    try {
      final response = await request().timeout(const Duration(seconds: 20));
      final decoded = response.body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode >= 400) {
        return TovoResponse.failure(
          // Le backend renvoie un message rédigé pour l'utilisateur sur les
          // erreurs métier (400/404/409). On l'affiche tel quel.
          message: decoded['error'] as String? ?? 'Une erreur est survenue.',
          statusCode: response.statusCode,
          components: _components(decoded),
        );
      }

      return TovoResponse.success(
        content: decoded['content'] as String? ?? '',
        components: _components(decoded),
      );
    } on Exception {
      // Coupure réseau : le cas normal à Niamey, pas l'exception.
      return TovoResponse.failure(
        message: 'Connexion perdue. Réessayez dans un instant.',
        statusCode: 0,
        components: const [],
      );
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
  });

  factory TovoResponse.success({
    required String content,
    required List<TovoComponent> components,
  }) =>
      TovoResponse._(ok: true, content: content, components: components, statusCode: 200);

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
      );

  final bool ok;
  final String content;
  final List<TovoComponent> components;
  final int statusCode;

  /// Vrai quand l'échec vient du réseau et non d'un refus du serveur : dans
  /// ce cas seulement, réessayer a du sens.
  bool get isOffline => statusCode == 0;
}
