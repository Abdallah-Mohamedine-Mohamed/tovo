import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/marque.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/auth/auth_screen.dart';
import 'package:tovo/features/auth/name_screen.dart';
import 'package:tovo/features/auth/phone_country.dart';

void main() {
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

  testWidgets('la connexion client présente Tovo avant le formulaire', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: TovoTheme.client(),
        home: const AuthScreen(
          titre: 'Tovo',
          sousTitre: 'Retrouvez vos commandes et suivez vos livraisons.',
        ),
      ),
    );

    expect(find.text('Tout commence par une envie.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(FondAnime), findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      TovoTheme.canvas,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).autofillHints,
      contains(AutofillHints.telephoneNumberNational),
    );
    expect(find.text('+227'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    final decoration = tester
        .widget<TextField>(find.byType(TextField))
        .decoration!;
    expect(
      (decoration.enabledBorder! as OutlineInputBorder).borderSide,
      BorderSide.none,
    );

    await tester.tap(find.text('Recevoir un code'));
    await tester.pump();
    expect(find.text('Numéro incomplet.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('auth-phone')), '9012345');
    await tester.tap(find.text('Recevoir un code'));
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
      MaterialApp(
        theme: TovoTheme.client(),
        home: const AuthScreen(titre: 'Tovo', sousTitre: ''),
      ),
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
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('la première ouverture illustre Tovo sans cacher la connexion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: TovoTheme.client(),
        home: const AuthScreen(
          titre: 'Tovo',
          sousTitre: 'Retrouvez vos commandes et suivez vos livraisons.',
        ),
      ),
    );

    expect(tester.getSize(find.byType(Scaffold)).height, 844);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Tout commence par une envie.'), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    await tester.ensureVisible(find.text('Recevoir un code'));
    await tester.tap(find.text('Recevoir un code'));
    await tester.pump();
    expect(find.text('Numéro incomplet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('le nom explique son utilité sans écran de marque', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: TovoTheme.client(),
        home: DemandeDeNom(onEnregistre: () {}),
      ),
    );

    expect(find.text('Votre nom'), findsOneWidget);
    expect(find.byType(MarqueTovo), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).autofillHints,
      contains(AutofillHints.name),
    );

    await tester.tap(find.text('Continuer'));
    await tester.pump();
    expect(find.text('Indiquez votre nom.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
