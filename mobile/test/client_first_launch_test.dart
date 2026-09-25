import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/marque.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/auth/anneau_tovo.dart';
import 'package:tovo/features/auth/auth_screen.dart';
import 'package:tovo/features/auth/name_screen.dart';
import 'package:tovo/features/auth/phone_country.dart';

/// Les écrans d'entrée : le numéro, le code, le nom.
///
///   flutter test test/client_first_launch_test.dart \
///     --dart-define=TOVO_RENDER_PREVIEW=true
void main() {
  final apercu = GlobalKey();

  setUpAll(() async {
    final geist = FontLoader('Geist');
    for (final g in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      geist.addFont(rootBundle.load('assets/fonts/Geist-$g.ttf'));
    }
    await geist.load();
    final systeme = FontLoader('CupertinoSystemText');
    for (final nom in ['arial.ttf', 'arialbd.ttf']) {
      final fichier = File('${Platform.environment['WINDIR']}/Fonts/$nom');
      systeme.addFont(
        fichier.existsSync()
            ? fichier.readAsBytes().then(ByteData.sublistView)
            : rootBundle.load('assets/fonts/Geist-Regular.ttf'),
      );
    }
    await systeme.load();
    final icones = FontLoader('MaterialIcons');
    icones.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icones.load();
  });

  // Animations réduites : l'anneau ne tourne pas, pumpAndSettle aboutit.
  Widget app(Widget home, {bool animations = false}) => MaterialApp(
    theme: TovoTheme.client(),
    debugShowCheckedModeBanner: false,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: !animations),
      child: RepaintBoundary(key: apercu, child: child!),
    ),
    home: home,
  );

  testWidgets('l’anneau tourne, le logo au centre reste immobile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(const AuthScreen(titre: 'Tovo', sousTitre: ''), animations: true),
    );
    await tester.pump(const Duration(seconds: 10));
    final rotation = tester.widget<RotationTransition>(
      find.descendant(
        of: find.byType(AnneauTovo),
        matching: find.byType(RotationTransition),
      ),
    );
    // Dix secondes sur un tour de quarante : un quart de tour.
    expect(rotation.turns.value, closeTo(0.25, 0.01));
    expect(
      find.ancestor(
        of: find.bySemanticsLabel('Tovo'),
        matching: find.byType(RotationTransition),
      ),
      findsNothing,
    );
    // L'écran quitté, le ticker s'arrête avec lui.
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> capturer(WidgetTester tester, String nom) async {
    if (!const bool.fromEnvironment('TOVO_RENDER_PREVIEW')) return;
    await tester.runAsync(() async {
      // Laisse le temps aux images (anneau, logo) d'être décodées.
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final limite =
          apercu.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await limite.toImage(pixelRatio: 2);
      final octets = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/design-review').create(recursive: true);
      await File(
        'build/design-review/entree-$nom.png',
      ).writeAsBytes(octets!.buffer.asUint8List());
      image.dispose();
    });
  }

  test('l’indicatif reste séparé du numéro local', () {
    final niger = phoneCountries.first;
    final france = phoneCountries.firstWhere(
      (country) => country.isoCode == 'FR',
    );
    expect(niger.fullNumber('90 12 34 56'), '+22790123456');
    expect(niger.accepts('90123456'), isTrue);
    expect(niger.accepts('9012345'), isFalse);
    expect(france.fullNumber('0612345678'), '+33612345678');
  });

  testWidgets('l’accueil : l’anneau, « Bienvenue », le numéro, « Continuer »', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(const AuthScreen(titre: 'Tovo', sousTitre: '')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnneauTovo), findsOneWidget);
    expect(find.text('Bienvenue'), findsOneWidget);
    expect(
      find.text('Commençons par votre numéro de téléphone.'),
      findsOneWidget,
    );
    expect(find.byType(FondAnime), findsNothing);
    // Pas de canal à choisir : ni WhatsApp, ni SMS à l'écran.
    expect(find.textContaining('WhatsApp'), findsNothing);
    expect(find.textContaining('SMS'), findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      TovoTheme.canvas,
    );
    final champ = tester.widget<TextField>(
      find.byKey(const ValueKey('auth-phone')),
    );
    expect(
      champ.autofillHints,
      contains(AutofillHints.telephoneNumberNational),
    );
    expect(champ.controller!.text, '');
    expect(
      (champ.decoration!.enabledBorder! as OutlineInputBorder).borderSide,
      BorderSide.none,
    );
    expect(find.text('+227'), findsOneWidget);
    await capturer(tester, '1-numero');

    await tester.tap(find.text('Continuer'));
    await tester.pump();
    expect(find.text('Numéro incomplet.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('auth-phone')), '9012345');
    await tester.pump();
    expect(find.text('Numéro incomplet.'), findsNothing);
    await tester.tap(find.text('Continuer'));
    await tester.pump();
    expect(find.text('Numéro incomplet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('petit écran, clavier ouvert : le champ passe avant l’anneau', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(const AuthScreen(titre: 'Tovo', sousTitre: '')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AnneauTovo), findsOneWidget);

    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.byType(AnneauTovo), findsNothing);
    await tester.ensureVisible(find.text('Continuer'));
    await tester.tap(find.text('Continuer'));
    await tester.pump();
    expect(find.text('Numéro incomplet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('le pays se recherche dans une feuille et change l’indicatif', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(const AuthScreen(titre: 'Tovo', sousTitre: '')),
    );

    await tester.tap(find.byKey(const ValueKey('auth-country')));
    await tester.pumpAndSettle();
    expect(find.text('Choisir un pays'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('auth-country-search')),
      'cote',
    );
    await tester.pumpAndSettle();
    expect(find.text('Côte d’Ivoire'), findsOneWidget);
    await tester.tap(find.text('Côte d’Ivoire'));
    await tester.pumpAndSettle();

    expect(find.text('Choisir un pays'), findsNothing);
    expect(find.text('+225'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('auth-phone')))
          .controller!
          .text,
      '',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('les apps livreur et boutique gardent leur nom', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(const AuthScreen(titre: 'Tovo Livreur', sousTitre: '')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue'), findsOneWidget);
    expect(
      find.text('Connectez-vous à Tovo Livreur avec votre numéro.'),
      findsOneWidget,
    );
  });

  testWidgets('le code : six cases, pas de bouton, retour au numéro', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(
        const AuthScreen(
          titre: 'Tovo',
          sousTitre: '',
          codeDejaEnvoyeA: '90123456',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Entrez le code'), findsOneWidget);
    expect(find.textContaining('+227 90 12 34 56'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Renvoyer le code dans 42 s'), findsOneWidget);
    final champ = tester.widget<TextField>(
      find.byKey(const ValueKey('auth-code')),
    );
    expect(champ.autofillHints, contains(AutofillHints.oneTimeCode));
    await capturer(tester, '2-code-vide');

    // Quatre chiffres : pas encore de vérification (elle part au sixième).
    await tester.enterText(find.byKey(const ValueKey('auth-code')), '4827');
    await tester.pump();
    for (final c in ['4', '8', '2', '7']) {
      expect(find.text(c), findsOneWidget);
    }
    await capturer(tester, '2-code-saisie');

    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();
    expect(find.text('Bienvenue'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('auth-phone')))
          .controller!
          .text,
      '90123456',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('le nom : salué dans l’anneau à mesure qu’on l’écrit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(DemandeDeNom(onEnregistre: () {})));
    await tester.pumpAndSettle();

    expect(find.text('Comment vous\nappelez-vous ?'), findsOneWidget);
    expect(find.text('Bonjour'), findsOneWidget);
    expect(find.byType(MarqueTovo), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).autofillHints,
      contains(AutofillHints.name),
    );
    await capturer(tester, '3-nom-vide');

    await tester.tap(find.text('Continuer'));
    await tester.pump();
    expect(find.text('Indiquez votre nom.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'amina issoufou');
    await tester.pumpAndSettle();
    expect(find.text('Indiquez votre nom.'), findsNothing);
    expect(find.text('Bonjour,'), findsOneWidget);
    expect(find.text('Amina'), findsOneWidget);
    await capturer(tester, '3-nom-amina');
    expect(tester.takeException(), isNull);
  });

  testWidgets('petit écran : un long nom tient sans débordement', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(DemandeDeNom(onEnregistre: () {})));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'Abdourahamane-Mahamadou Seydou',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
