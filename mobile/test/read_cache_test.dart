import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/read_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(TovoReadCache.clearPrivateCaches);

  test(
    'retrouve le contenu après recréation sans exposer un autre compte',
    () async {
      final first = TovoReadCache('alice');
      await first.write('/conversations/1', {
        'messages': [
          {'content': 'Deux tacos'},
        ],
      });
      expect(await TovoReadCache('alice').read('/conversations/1'), isNotNull);
      expect(await TovoReadCache('bob').read('/conversations/1'), isNull);
      await TovoReadCache.clearPrivateCaches();
      expect(await TovoReadCache('alice').read('/conversations/1'), isNull);
      await first.write('/conversations/1', {'content': 'réponse tardive'});
      expect(await TovoReadCache('alice').read('/conversations/1'), isNull);
    },
  );

  test(
    'un cache expiré ne réapparaît pas et les paramètres isolent les pages',
    () async {
      SharedPreferences.setMockInitialValues({
        'tovo.read.v1.alice': jsonEncode({
          '/categories': {
            'at': DateTime.now()
                .subtract(const Duration(days: 2))
                .millisecondsSinceEpoch,
            'body': {'content': 'ancien'},
          },
        }),
      });
      expect(await TovoReadCache('alice').read('/categories'), isNull);
      expect(
        TovoReadCache.key('/catalog/products', {'q': 'poulet', 'offset': 0}),
        TovoReadCache.key('/catalog/products', {'offset': 0, 'q': 'poulet'}),
      );
      expect(
        TovoReadCache.key('/catalog/products', {'q': 'poulet'}),
        isNot(TovoReadCache.key('/catalog/products', {'q': 'pizza'})),
      );
    },
  );

  test(
    'regroupe les lectures simultanées sans mettre le panier en cache',
    () async {
      final waiting = Completer<http.Response>();
      var calls = 0;
      final api = TovoApi(
        tokenProvider: () => null,
        cache: TovoReadCache('alice'),
        client: MockClient((_) {
          calls++;
          return waiting.future;
        }),
      );
      final first = api.get('/categories');
      final second = api.get('/categories');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      waiting.complete(http.Response('{"content":"catégories"}', 200));
      expect((await first).content, (await second).content);
      await api.remember('/cart', {'total': 1000});
      expect(await api.cachedGet('/cart'), isNull);
    },
  );

  test('ne rejoue pas une mutation quand le réseau coupe', () async {
    var calls = 0;
    final api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((_) async {
        calls++;
        throw http.ClientException('coupure');
      }),
    );
    expect((await api.post('/cart/items', {'product_id': 'one'})).ok, isFalse);
    expect(calls, 1);
  });
}
