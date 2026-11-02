import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tovo/core/api.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/profil/profil_screen.dart';
import 'package:tovo/features/profil/supprimer_compte_screen.dart';

/// « Mon profil » (02/11) : nom modifiable, adresses, aide, et la
/// suppression du compte exigée par Apple et Google.
///
///   flutter test test/profil_test.dart --dart-define=TOVO_RENDER_PREVIEW=true
void main() {
  final apercu = GlobalKey();
  final requetes = <http.Request>[];
  late TovoApi api;

  setUpAll(() async {
    final geist = FontLoader('Geist');
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      geist.addFont(rootBundle.load('assets/fonts/Geist-$g.ttf'));
    }
    await geist.load();
    final polices = FontLoader(TovoTheme.fontFamily);
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      polices.addFont(rootBundle.load('assets/fonts/DMSans-$g.ttf'));
    }
    await polices.load();
    final icones = FontLoader('MaterialIcons');
    icones.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icones.load();
  });

  setUp(() {
    requetes.clear();
    api = TovoApi(
      tokenProvider: () => null,
      client: MockClient((request) async {
        requetes.add(request);
        final Object corps = switch (request.url.path) {
          '/me' when request.method == 'GET' => {
            'full_name': 'Abdallah',
            'phone': '22796123456',
            'role': 'client',
          },
          '/me' => {'full_name': 'Abdallah Mohamed'},
          '/addresses' => {
            'addresses': [
              {
                'id': 'a1',
                'label': 'Maison',
                'text_hint': 'Plateau, derrière la pharmacie Renaissance',
                'is_default': true,
              },
              {
                'id': 'a2',
                'label': 'Bureau',
                'text_hint': 'Koira Kano, rue de l’ambassade',
                'is_default': false,
              },
            ],
          },
          _ => <String, dynamic>{},
        };
        return http.Response(
          jsonEncode(corps),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });

  Future<void> ouvrir(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: TovoTheme.client(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: true,
            padding: const EdgeInsets.only(top: 44),
          ),
          child: RepaintBoundary(key: apercu, child: child!),
        ),
        home: ProfilScreen(api: api),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capturer(WidgetTester tester, String nom) async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await tester.runAsync(() async {
      final limite =
          apercu.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await limite.toImage(pixelRatio: 2);
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/profil-$nom.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('le profil montre le client, ses adresses et l’aide', (
    tester,
  ) async {
    await ouvrir(tester);
    expect(find.text('Abdallah'), findsWidgets);
    expect(find.text('+227 96 12 34 56'), findsWidgets);
    expect(find.text('Principale'), findsOneWidget);
    expect(find.text('Bureau'), findsOneWidget);
    expect(find.text('+227 76 76 20 20'), findsOneWidget);
    expect(find.text('Supprimer mon compte'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capturer(tester, '1-profil');
  });

  testWidgets('changer son nom l’envoie au serveur', (tester) async {
    await ouvrir(tester);
    await tester.tap(find.byKey(const ValueKey('ligne-nom')));
    await tester.pumpAndSettle();
    await capturer(tester, '2-nom');
    await tester.enterText(
      find.byKey(const ValueKey('champ-nom')),
      'Abdallah Mohamed',
    );
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    final envoi = requetes.singleWhere(
      (r) => r.method == 'PATCH' && r.url.path == '/me',
    );
    expect(jsonDecode(envoi.body), {'full_name': 'Abdallah Mohamed'});
    expect(find.text('Abdallah Mohamed'), findsWidgets);
  });

  testWidgets('supprimer le compte : on lit ce qui disparaît, puis le code', (
    tester,
  ) async {
    await ouvrir(tester);
    await tester.tap(find.byKey(const ValueKey('supprimer-compte')));
    await tester.pumpAndSettle();
    expect(find.byType(SupprimerCompteScreen), findsOneWidget);
    expect(find.text('Supprimer votre compte ?'), findsOneWidget);
    expect(find.text('Recevoir le code de confirmation'), findsOneWidget);
    // Rien n'est supprimé sans le code : aucun appel DELETE à ce stade.
    expect(requetes.where((r) => r.method == 'DELETE'), isEmpty);
    expect(tester.takeException(), isNull);
    await capturer(tester, '3-supprimer');
  });
}
