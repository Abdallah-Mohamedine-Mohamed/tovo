import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/features/merchant/merchant_controller.dart';

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
  });

  tearDownAll(() => Supabase.instance.dispose());

  test(
    'les événements simultanés ne déclenchent pas une rafale de lectures',
    () async {
      final first = Completer<http.Response>();
      final second = Completer<http.Response>();
      var calls = 0;
      final api = TovoApi(
        tokenProvider: () => null,
        client: MockClient((request) {
          if (request.url.path != '/merchant/orders') {
            return Future.value(http.Response('{}', 200));
          }
          calls++;
          return calls == 1 ? first.future : second.future;
        }),
      );
      final controller = MerchantController(api: api)
        ..boutique = {'id': 'merchant-one'};

      final initial = controller.actualiserCommandes();
      controller.actualiserCommandes();
      controller.actualiserCommandes();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);

      first.complete(
        http.Response(
          jsonEncode({
            'orders': [
              {'id': 'order-one', 'status': 'pending'},
            ],
          }),
          200,
        ),
      );
      await initial;
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);

      second.complete(
        http.Response(
          jsonEncode({
            'orders': [
              {'id': 'order-one', 'status': 'confirmed'},
            ],
          }),
          200,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.commandes.single['status'], 'confirmed');
      controller.dispose();
    },
  );
}
