import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tovo/components/register_all.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/read_cache.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/catalog/catalog_screen.dart';
import 'package:tovo/features/catalog/product_screen.dart';
import 'package:tovo/features/chat/chat_screen.dart';

http.Response jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const categoryBody = {
  'components': [
    {
      'type': 'category_grid',
      'data': {
        'items': [
          {
            'id': 'restaurants',
            'name': 'Restaurants',
            'slug': 'restaurants-m3',
          },
        ],
      },
    },
  ],
};

Map<String, dynamic> history(String id, String content) => {
  'conversation_id': id,
  'messages': [
    {'role': 'assistant', 'content': content, 'components': []},
  ],
};

class ProgressiveClient extends http.BaseClient {
  final events = StreamController<List<int>>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/chat') {
      return http.StreamedResponse(
        events.stream,
        200,
        headers: {'content-type': 'application/x-ndjson'},
      );
    }
    final body = request.url.path == '/categories' ? categoryBody : {};
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  void emit(Map<String, dynamic> event) =>
      events.add(utf8.encode('${jsonEncode(event)}\n'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await TovoReadCache.clearPrivateCaches();
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-only',
      debug: false,
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async => call.method == 'isLocationServiceEnabled' ? false : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async {
        final arguments = (call.arguments as Map?) ?? {};
        if (arguments['recorderId'] is String) {
          messenger.setMockMethodCallHandler(
            MethodChannel(
              'com.llfbandit.record/events/${arguments['recorderId']}',
            ),
            (_) async => null,
          );
        }
        if (call.method == 'hasPermission') return true;
        if (call.method == 'start') {
          File(
            arguments['path'] as String,
          ).writeAsBytesSync(List.filled(4096, 1));
        }
        return null;
      },
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    registerTovoComponents();
  });

  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      MaterialApp(theme: TovoTheme.client(), home: screen),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
  }

  Future<void> newConversation(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Mes conversations'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Nouvelle conversation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'historique local visible sans attendre les commandes, puis nouveau fil protégé',
    (tester) async {
      final pendingHistory = Completer<http.Response>();
      final pendingOrders = Completer<http.Response>();
      final api = TovoApi(
        cache: TovoReadCache('alice'),
        tokenProvider: () => null,
        client: MockClient(
          (request) async => switch (request.url.path) {
            '/conversations/last' => pendingHistory.future,
            '/orders' => pendingOrders.future,
            '/categories' => jsonResponse(categoryBody),
            _ => jsonResponse({}),
          },
        ),
      );
      await api.remember(
        '/conversations/last',
        history('ancien', 'Ma discussion conservée'),
      );
      await api.remember('/categories', categoryBody);
      await open(tester, ChatScreen(api: api));
      expect(find.text('Ma discussion conservée'), findsOneWidget);
      expect(pendingOrders.isCompleted, isFalse);
      await newConversation(tester);
      pendingHistory.complete(
        jsonResponse(history('ancien', 'Réponse tardive à ignorer')),
      );
      pendingOrders.complete(jsonResponse({'orders': []}));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Réponse tardive à ignorer'), findsNothing);
      expect(find.text('Ma discussion conservée'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'un produit connu apparaît avant son prix et ses options vérifiés',
    (tester) async {
      final pending = Completer<http.Response>();
      final api = TovoApi(
        tokenProvider: () => null,
        client: MockClient((_) => pending.future),
      );
      await open(
        tester,
        ProductScreen(
          api: api,
          productId: 'plat',
          initialProduct: const {
            'id': 'plat',
            'name': 'Poulet déjà choisi',
            'price': 2000,
          },
        ),
      );
      expect(find.text('Poulet déjà choisi'), findsOneWidget);
      expect(find.text('Ajouter au panier'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending.complete(
        jsonResponse({
          'components': [
            {
              'type': 'product_card',
              'data': {
                'id': 'plat',
                'name': 'Poulet déjà choisi',
                'price': 2500,
                'actions': ['add_to_cart'],
              },
            },
          ],
        }),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Ajouter au panier'), findsOneWidget);
      expect(find.text(Money.format(2500)), findsWidgets);
    },
  );

  testWidgets('la carte en cache reste consultable pendant son actualisation', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var catalogReads = 0;
    final api = TovoApi(
      cache: TovoReadCache('catalog-cache'),
      tokenProvider: () => null,
      client: MockClient((request) {
        if (request.url.path != '/catalog/products') {
          return Future.value(jsonResponse({}));
        }
        catalogReads++;
        if (catalogReads == 1) return pending.future;
        return Future.value(
          jsonResponse({
            'items': [
              {'id': 'plat', 'name': 'Poulet actualisé', 'price': 2600},
            ],
            'total': 1,
          }),
        );
      }),
    );
    SharedPreferences.setMockInitialValues({
      'tovo.read.v1.catalog-cache': jsonEncode({
        TovoReadCache.key('/catalog/products', {
          'q': '',
          'offset': 0,
          'limit': 24,
          'merchant_id': 'restaurant',
        }): {
          'at': DateTime.now().millisecondsSinceEpoch,
          'body': {
            'items': [
              {'id': 'plat', 'name': 'Poulet mémorisé', 'price': 2500},
            ],
            'total': 1,
            'categories': [],
          },
        },
      }),
    });
    await open(tester, CatalogScreen(api: api, merchantId: 'restaurant'));
    expect(
      api.cache!.peek(
        TovoReadCache.key('/catalog/products', {
          'q': '',
          'offset': 0,
          'limit': 24,
          'merchant_id': 'restaurant',
        }),
      ),
      isNotNull,
    );
    expect(find.text('Poulet mémorisé'), findsOneWidget);
    expect(pending.isCompleted, isFalse);
    pending.complete(http.Response('{"error":"Réseau indisponible"}', 503));
    await tester.pump();
    await tester.pump();
    expect(find.text('Poulet mémorisé'), findsOneWidget);
    await tester.ensureVisible(find.text('Réessayer'));
    await tester.tap(find.text('Réessayer'));
    await tester.pump();
    await tester.pump();
    expect(catalogReads, 2);
    expect(find.text('Poulet actualisé'), findsOneWidget);
  });

  testWidgets(
    'le résultat progressif apparaît, mais ne fuit pas dans un nouveau fil',
    (tester) async {
      final client = ProgressiveClient();
      await open(
        tester,
        ChatScreen(
          api: TovoApi(client: client, tokenProvider: () => null),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Cherche du poulet');
      await tester.pump();
      await tester.tap(find.byTooltip('Envoyer'));
      await tester.pump();
      client.emit({'type': 'conversation', 'conversation_id': 'courante'});
      client.emit({'type': 'text', 'text': 'Voici une réponse progressive'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Voici une réponse progressive'), findsOneWidget);
      await newConversation(tester);
      client.emit({
        'type': 'done',
        'status': 200,
        'conversation_id': 'courante',
        'content': 'Fin de l’ancien échange',
        'components': [],
      });
      await client.events.close();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Fin de l’ancien échange'), findsNothing);
      expect(find.text('Voici une réponse progressive'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'le vocal part après transcription et reste visible dans la conversation',
    (tester) async {
      final sent = <Map<String, dynamic>>[];
      var transcriptionCount = 0;
      final api = TovoApi(
        tokenProvider: () => null,
        client: MockClient((request) async {
          if (request.url.path == '/transcriptions') {
            transcriptionCount++;
            return jsonResponse({'transcript': 'Je veux du poulet'});
          }
          if (request.url.path == '/chat') {
            sent.add(jsonDecode(request.body) as Map<String, dynamic>);
            return jsonResponse({'content': 'Bien reçu', 'components': []});
          }
          return jsonResponse(
            request.url.path == '/categories' ? categoryBody : {},
          );
        }),
      );
      await open(tester, ChatScreen(api: api));
      await tester.tap(find.byTooltip('Parler à Tovo'));
      await tester.pump();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 850)),
      );
      await tester.pump();
      expect(find.byTooltip('Arrêter et transcrire'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Arrêter et transcrire'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      await tester.pump();
      expect(transcriptionCount, 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(sent.single['text'], 'Je veux du poulet');
      expect(sent.single.containsKey('audio'), isFalse);
      expect(find.text('Je veux du poulet'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
