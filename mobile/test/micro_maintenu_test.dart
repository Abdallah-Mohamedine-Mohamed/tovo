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
import 'package:tovo/core/api.dart';
import 'package:tovo/core/panier.dart';
import 'package:tovo/core/read_cache.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/chat/chat_screen.dart';

/// Le micro maintenu, comme sur WhatsApp (27/10). Dans son propre fichier :
/// l'enregistreur du téléphone est libéré quand l'écran de conversation est
/// détruit, et les canaux simulés ne savent pas en recréer un second dans
/// le même fichier de tests.
http.Response jsonResponse(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const categoryBody = {'components': []};

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
          // Flux de son, pour les enregistreurs qui l'écoutent : une
          // seconde de PCM 16 kHz, comme si le client avait parlé.
          messenger.setMockStreamHandler(
            EventChannel(
              'com.llfbandit.record/eventsRecord/${arguments['recorderId']}',
            ),
            MockStreamHandler.inline(
              onListen: (_, sink) => sink.success(Uint8List(32000)),
            ),
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
    // Le panier est partagé par toute l'appli : on repart de zéro.
    PanierEnDirect.instance.vider();
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

  // Comme sur WhatsApp (27/10) : on maintient le micro, on parle, on relâche
  // et ça part. Glisser vers la gauche avant de relâcher annule. Un seul
  // écran pour les deux gestes, comme un client qui annule puis recommence
  // (l'écran détruit entre deux tests libère l'enregistreur du téléphone).
  testWidgets('micro maintenu : glisser annule, relâcher envoie', (
    tester,
  ) async {
    final sent = <Map<String, dynamic>>[];
    var transcriptions = 0;
    final api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        if (request.url.path == '/transcriptions') {
          transcriptions++;
          return jsonResponse({'transcript': 'Un gaz de 12 kg'});
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

    /// Pose le doigt sur le micro, attend l'écoute, et parle un moment.
    Future<TestGesture> maintenir() async {
      final doigt = await tester.startGesture(
        tester.getCenter(find.byTooltip('Parler à Tovo')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      // L'écoute démarre en asynchrone (autorisation, enregistreur).
      final ecoute = find.text('Relâchez pour envoyer · ← annuler');
      for (var i = 0; i < 40 && ecoute.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(ecoute, findsOneWidget);
      // Sous 0,7 s, le vocal serait « trop court ».
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 900)),
      );
      return doigt;
    }

    // 1. Glisser à gauche, relâcher : rien ne part.
    var doigt = await maintenir();
    await doigt.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(find.text('Relâchez pour annuler'), findsOneWidget);
    await tester.runAsync(() async {
      await doigt.up();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(transcriptions, 0);
    expect(find.byTooltip('Parler à Tovo'), findsOneWidget);

    // 2. Maintenir, relâcher : la transcription part.
    doigt = await maintenir();
    await tester.runAsync(() async {
      await doigt.up();
      for (var i = 0; i < 50 && transcriptions == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    for (var i = 0; i < 20 && sent.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(transcriptions, 1);
    expect(sent.single['text'], 'Un gaz de 12 kg');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
