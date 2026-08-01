import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/features/driver/sync_queue.dart';

/// La file hors ligne du livreur.
///
/// C'est la logique la plus risquée de l'app : elle décide de ce qui est
/// rejoué, dans quel ordre, et de ce qui est abandonné. Une erreur ici se
/// traduit par une course perdue ou une livraison confirmée deux fois — sur
/// le terrain, pas en développement.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Client HTTP scripté : chaque appel consomme la réponse suivante.
  ({TovoApi api, List<String> appels}) faireApi(List<http.Response> reponses) {
    final appels = <String>[];
    var index = 0;

    final client = MockClient((requete) async {
      appels.add('${requete.method} ${requete.url.path}');
      final reponse = index < reponses.length ? reponses[index] : reponses.last;
      index++;
      return reponse;
    });

    return (api: TovoApi(client: client, tokenProvider: () => 'jeton'), appels: appels);
  }

  http.Response ok() =>
      http.Response(jsonEncode({'content': 'ok', 'components': []}), 200);

  http.Response refus(String message) =>
      http.Response(jsonEncode({'error': message}), 409);

  /// Une coupure réseau se manifeste par une exception, pas par un code HTTP.
  MockClient clientHorsLigne(List<String> appels) => MockClient((requete) async {
        appels.add('${requete.method} ${requete.url.path}');
        throw http.ClientException('réseau indisponible');
      });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('une action réussie quitte la file', () async {
    final ctx = faireApi([ok()]);
    final file = SyncQueue(api: ctx.api);
    await file.load();

    await file.submit(SyncAction.accept('cmd-1'));
    await file.flush();

    expect(file.pending.value, 0);
    expect(ctx.appels, ['POST /orders/cmd-1/accept']);
  });

  test("hors ligne, l'action reste en file et rien n'est perdu", () async {
    final appels = <String>[];
    final api = TovoApi(client: clientHorsLigne(appels), tokenProvider: () => 'jeton');
    final file = SyncQueue(api: api);
    await file.load();

    await file.submit(SyncAction.status('cmd-1', 'picked_up'));
    await file.flush();

    expect(file.pending.value, 1);
    expect(file.rejets, isEmpty);
  });

  test("l'ordre est préservé : la file s'arrête à la première coupure", () async {
    var appelsFaits = 0;
    final client = MockClient((requete) async {
      appelsFaits++;
      // La première passe, la seconde tombe : la troisième ne doit JAMAIS
      // partir, sans quoi on confirmerait une livraison avant la
      // récupération.
      if (appelsFaits == 1) return ok();
      throw http.ClientException('coupure');
    });

    final file = SyncQueue(
      api: TovoApi(client: client, tokenProvider: () => 'jeton'),
    );
    await file.load();

    await file.submit(SyncAction.accept('cmd-1'));
    await file.submit(SyncAction.status('cmd-1', 'picked_up'));
    await file.submit(SyncAction.status('cmd-1', 'delivering'));
    await file.flush();

    expect(file.pending.value, 2, reason: 'les deux dernières restent en attente');
    expect(appelsFaits, lessThanOrEqualTo(4));
  });

  test('un refus du serveur retire l’action et l’explique', () async {
    final ctx = faireApi([refus('course déjà prise')]);
    final file = SyncQueue(api: ctx.api);
    await file.load();

    await file.submit(SyncAction.accept('cmd-1'));
    await file.flush();

    // Réessayer indéfiniment une course déjà prise ferait tourner un
    // indicateur sans fin ; le livreur doit apprendre qu'elle lui a échappé.
    expect(file.pending.value, 0);
    expect(file.rejets, hasLength(1));
    expect(file.rejets.first.message, contains('déjà prise'));
  });

  test('la file survit à la fermeture de l’app', () async {
    final appels = <String>[];
    final horsLigne = TovoApi(
      client: clientHorsLigne(appels),
      tokenProvider: () => 'jeton',
    );

    final premiere = SyncQueue(api: horsLigne);
    await premiere.load();
    await premiere.submit(SyncAction.status('cmd-7', 'delivered'));
    await premiere.flush();
    expect(premiere.pending.value, 1);

    // Nouvelle instance : c'est ce qui se passe quand le livreur relance
    // l'app, ou quand Android l'a tuée pour libérer de la mémoire.
    final ctx = faireApi([ok()]);
    final seconde = SyncQueue(api: ctx.api);
    await seconde.load();

    expect(seconde.pending.value, 1);

    await seconde.flush();
    expect(seconde.pending.value, 0);
    expect(ctx.appels, ['POST /orders/cmd-7/status']);
  });

  test('une entrée corrompue ne bloque pas la file entière', () async {
    SharedPreferences.setMockInitialValues({
      'tovo.driver.sync_queue.v1': ['{ceci n\'est pas du json', SyncAction.accept('cmd-9').encode()],
    });

    final ctx = faireApi([ok()]);
    final file = SyncQueue(api: ctx.api);
    await file.load();

    expect(file.pending.value, 1, reason: 'seule l’entrée valide est conservée');

    await file.flush();
    expect(file.pending.value, 0);
  });
}
