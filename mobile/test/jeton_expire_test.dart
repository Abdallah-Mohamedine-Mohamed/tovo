import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tovo/core/api.dart';

/// Le jeton d'accès expire au bout d'une heure, et le minuteur qui le
/// renouvelle ne tourne pas pendant que le téléphone dort. Au réveil, la
/// première requête partait avec un jeton mort : le backend répondait
/// « session invalide » à quelqu'un de parfaitement connecté, au moment précis
/// où il passait commande.
void main() {
  test('un 401 déclenche un renouvellement et un second essai', () async {
    final jetonsVus = <String>[];
    var courant = 'vieux';
    var renouvellements = 0;

    final client = MockClient((requete) async {
      jetonsVus.add(requete.headers['authorization'] ?? '');
      // Le serveur n'accepte que le jeton renouvelé.
      if (courant != 'neuf') {
        return http.Response(jsonEncode({'error': 'session invalide'}), 401);
      }
      return http.Response(jsonEncode({'content': 'ok'}), 200);
    });

    final api = TovoApi(
      client: client,
      tokenProvider: () => courant,
      onRenouveler: () async {
        renouvellements++;
        courant = 'neuf';
        return true;
      },
    );

    final reponse = await api.get('/orders');

    expect(reponse.ok, isTrue, reason: 'le second essai devait aboutir');
    expect(renouvellements, 1);
    expect(jetonsVus, ['Bearer vieux', 'Bearer neuf'],
        reason: 'le second essai doit porter le NOUVEAU jeton, '
            'sinon renouveler ne sert à rien');
  });

  test('un renouvellement impossible ne boucle pas', () async {
    var appels = 0;
    final client = MockClient((_) async {
      appels++;
      return http.Response(jsonEncode({'error': 'session invalide'}), 401);
    });

    final api = TovoApi(
      client: client,
      tokenProvider: () => 'mort',
      // Jeton de rafraîchissement révoqué : rien ne le ressuscitera.
      onRenouveler: () async => false,
    );

    final reponse = await api.get('/orders');

    expect(reponse.ok, isFalse);
    expect(appels, 1, reason: 'un renouvellement refusé ne doit pas être rejoué');
  });

  test('un 401 persistant s’arrête après un seul second essai', () async {
    var appels = 0;
    final client = MockClient((_) async {
      appels++;
      return http.Response(jsonEncode({'error': 'session invalide'}), 401);
    });

    final api = TovoApi(
      client: client,
      tokenProvider: () => 'jeton',
      // Le renouvellement réussit, mais le serveur refuse quand même : sans
      // garde-fou, les deux se relanceraient sans fin.
      onRenouveler: () async => true,
    );

    final reponse = await api.get('/orders');

    expect(reponse.ok, isFalse);
    expect(appels, 2);
  });

  test('un jeton fourni de l’extérieur ne touche jamais à Supabase', () async {
    // Sans injection, un 401 appellerait Supabase, que les tests
    // n'initialisent pas : la levée serait un plantage, pas un échec lisible.
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'error': 'refusé'}), 401),
    );
    final api = TovoApi(client: client, tokenProvider: () => 'jeton');

    final reponse = await api.get('/orders');
    expect(reponse.statusCode, 401);
  });
}
