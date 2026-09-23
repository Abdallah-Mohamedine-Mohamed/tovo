import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/marque.dart';
import 'package:tovo/core/theme.dart';
import 'package:tovo/features/auth/auth_screen.dart';
import 'package:tovo/features/auth/name_screen.dart';

void main() {
  testWidgets('la connexion client présente un formulaire sobre', (
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

    expect(find.text('Bienvenue sur Tovo'), findsOneWidget);
    expect(find.byType(FondAnime), findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      TovoTheme.canvas,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).autofillHints,
      contains(AutofillHints.telephoneNumber),
    );

    await tester.tap(find.text('Recevoir un code'));
    await tester.pump();
    expect(find.text('Numéro incomplet.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('auth-phone')),
      '+2279012345',
    );
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
