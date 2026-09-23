import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/features/driver/driver_controller.dart';
import 'package:tovo/features/driver/sync_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/geolocator'),
          (call) async =>
              call.method == 'isLocationServiceEnabled' ? false : null,
        );
  });

  tearDownAll(() => Supabase.instance.dispose());

  test('la course apparaît sans attendre le résumé des gains', () async {
    SharedPreferences.setMockInitialValues({});
    final summary = Completer<http.Response>();
    final api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/driver/summary') return summary.future;
        final body = switch (path) {
          '/orders' => {
            'orders': [
              {'id': 'order-one', 'status': 'assigned'},
            ],
          },
          '/orders/order-one' => {
            'components': [
              {
                'type': 'order_tracking',
                'data': {'order_id': 'order-one', 'status': 'assigned'},
              },
            ],
          },
          _ => <String, dynamic>{},
        };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    final queue = SyncQueue(
      api: api,
      prefs: await SharedPreferences.getInstance(),
    );
    await queue.load();
    final controller = DriverController(api: api, queue: queue);

    final refresh = controller.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.course?['status'], 'assigned');
    expect(controller.chargement, isFalse);

    summary.complete(
      http.Response(jsonEncode({'courses': 2, 'earned': 5000}), 200),
    );
    await refresh;
    expect(controller.resume['courses'], 2);
    controller.dispose();
  });

  test(
    'un échec de chargement ne se fait pas passer pour aucune course',
    () async {
      SharedPreferences.setMockInitialValues({});
      final api = TovoApi(
        tokenProvider: () => null,
        client: MockClient(
          (request) async => request.url.path == '/orders'
              ? http.Response('{"error":"service indisponible"}', 503)
              : http.Response('{}', 200),
        ),
      );
      final queue = SyncQueue(
        api: api,
        prefs: await SharedPreferences.getInstance(),
      );
      await queue.load();
      final controller = DriverController(api: api, queue: queue);

      await controller.refresh();

      expect(controller.erreur, contains('Impossible de vérifier les courses'));
      expect(controller.pool, isEmpty);
      controller.dispose();
    },
  );
}
