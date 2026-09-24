import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/driver/driver_controller.dart';
import 'package:tovo/features/driver/driver_home.dart';
import 'package:tovo/features/driver/sync_queue.dart';

/// Revue visuelle de l'appli livreur : chaque état clé, rendu en image.
///
///   flutter test test/driver_design_review_test.dart \
///     --dart-define=TOVO_RENDER_PREVIEW=true
///
/// Les images vont dans build/design-review/livreur-*.png. Sans le drapeau,
/// les états sont seulement rendus et vérifiés (aucune erreur d'affichage).
class _Controleur extends DriverController {
  _Controleur({required super.api, required super.queue})
    : super(db: Supabase.instance.client);

  bool enLigne = true;

  @override
  bool get online => enLigne;

  // L'état est posé par le test : rien à charger.
  @override
  Future<void> start() async {}

  @override
  Future<void> refresh({bool silencieux = false}) async {}
}

void main() {
  final apercu = GlobalKey();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final polices = FontLoader(TovoTheme.fontFamily);
    for (final graisse in [
      'Regular',
      'Medium',
      'SemiBold',
      'Bold',
      'ExtraBold',
    ]) {
      polices.addFont(rootBundle.load('assets/fonts/DMSans-$graisse.ttf'));
    }
    await polices.load();
    final icones = FontLoader('MaterialIcons');
    icones.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icones.load();
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

  Future<_Controleur> controleur() async {
    final api = TovoApi(tokenProvider: () => null);
    final file = SyncQueue(
      api: api,
      prefs: await SharedPreferences.getInstance(),
    );
    return _Controleur(api: api, queue: file)
      ..resume = const {
        'courses': 4,
        'earned': 2600,
        'cash_collected': 18500,
        'cash_due': 15900,
      };
  }

  Future<void> afficher(WidgetTester tester, _Controleur c, String nom) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TovoTheme.build(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: RepaintBoundary(key: apercu, child: child!),
        ),
        home: DriverHome(
          api: TovoApi(tokenProvider: () => null),
          controleur: c,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await tester.runAsync(() async {
      final limite =
          apercu.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await limite.toImage(pixelRatio: 2);
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/livreur-$nom.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('hors ligne', (tester) async {
    final c = await controleur()
      ..enLigne = false;
    await afficher(tester, c, '1-hors-ligne');
  });

  testWidgets('en ligne, courses proposées', (tester) async {
    final c = await controleur()
      ..pool = [
        {
          'id': 'a',
          'type': 'delivery',
          'status': 'ready',
          'total': 4500,
          'driver_earning': 500,
          'dropoff_hint': 'Bobiel, porte bleue',
          'merchant_name': "GARBA D'OR",
          'distance_m': 850,
          'attente_min': 3,
          'can_accept': true,
        },
        {
          'id': 'b',
          'type': 'courier',
          'status': 'ready',
          'total': 1000,
          'driver_earning': 700,
          'dropoff_hint': 'Chez le client',
          'mode': 'recuperer',
          'pickup_hint': 'Chez Moussa, Harobanda',
          'distance_m': 1400,
          'attente_min': 1,
          'can_accept': true,
        },
        {
          'id': 'c',
          'type': 'delivery',
          'status': 'preparing',
          'total': 7000,
          'driver_earning': 600,
          'dropoff_hint': 'Yantala, près du marché',
          'merchant_name': 'DABALI EXPRESS',
          'distance_m': 2300,
          'attente_min': 6,
          'can_accept': false,
        },
      ];
    await afficher(tester, c, '2-courses-proposees');
  });

  testWidgets('en course : repas', (tester) async {
    final c = await controleur()
      ..course = {
        'order_id': 'a',
        'type': 'delivery',
        'status': 'assigned',
        'total': 4500,
        'payment_method': 'cash',
        'merchant_name': "GARBA D'OR",
        'merchant': {
          'name': "GARBA D'OR",
          'phone': '+22790000001',
          'hint': 'Bobiel, station Kachallah',
          'lat': 13.54,
          'lng': 2.1,
        },
        'client': {'name': 'Aïcha', 'phone': '+22790000002'},
        'dropoff': {'hint': 'Bobiel, porte bleue', 'lat': 13.55, 'lng': 2.11},
        'items': [
          {'product_name': 'Attieke Poulet', 'quantity': 1, 'line_total': 3000},
          {'product_name': 'Bissap', 'quantity': 2, 'line_total': 1000},
        ],
      };
    await afficher(tester, c, '3-course-repas');
  });

  testWidgets('en course : colis, venir chez le client', (tester) async {
    final c = await controleur()
      ..course = {
        'order_id': 'b',
        'type': 'courier',
        'mode': 'deposer',
        'status': 'assigned',
        'total': 1000,
        'payment_method': 'cash',
        'client': {'name': 'Aïcha', 'phone': '+22790000002'},
        'pickup': {'hint': 'Position du client', 'lat': 13.54, 'lng': 2.1},
        'dropoff': {'hint': 'À voir avec le client'},
      };
    await afficher(tester, c, '4-course-colis-deposer');
  });

  testWidgets('en course : colis, aller chercher', (tester) async {
    final c = await controleur()
      ..course = {
        'order_id': 'c',
        'type': 'courier',
        'mode': 'recuperer',
        'status': 'assigned',
        'total': 1000,
        'payment_method': 'cash',
        'client': {'name': 'Aïcha', 'phone': '+22790000002'},
        'pickup': {'hint': 'Chez Moussa, Harobanda', 'contact': '90 12 34 56'},
        'dropoff': {'hint': 'Chez le client', 'lat': 13.54, 'lng': 2.1},
      };
    await afficher(tester, c, '5-course-colis-recuperer');
  });
}
