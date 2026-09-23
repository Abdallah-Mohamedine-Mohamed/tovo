import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/features/chat/conversation_chrome.dart';

void main() {
  testWidgets('Envoyer envoie, au lieu de replier la box', (tester) async {
    final saisie = TextEditingController();
    var envois = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ConversationComposer(
              controller: saisie,
              onSend: () => envois++,
              onCamera: () {},
              onGallery: () {},
              onVoice: () {},
              onRemovePhoto: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Écrire un message'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Du riz');
    await tester.pump();

    // Un vrai doigt : l'écran se redessine entre le toucher et le relâcher.
    // C'est dans cet intervalle que l'ancienne box se repliait et que le
    // bouton disparaissait sous le doigt.
    final doigt = await tester.startGesture(
      tester.getCenter(find.byTooltip('Envoyer')),
    );
    await tester.pump(const Duration(milliseconds: 80));
    await doigt.up();
    await tester.pumpAndSettle();

    expect(envois, 1);
  });

  testWidgets('taper à côté range le clavier mais garde la box', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox.expand()),
              ConversationComposer(
                controller: TextEditingController(),
                onSend: () {},
                onCamera: () {},
                onGallery: () {},
                onVoice: () {},
                onRemovePhoto: () {},
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Écrire un message'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('après une réponse, la box revient ouverte en mode écrit', (
    tester,
  ) async {
    var ecrit = false;
    Widget box() => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ConversationComposer(
            // Clé changeante : l'écran recrée la box après chaque réponse.
            key: UniqueKey(),
            controller: TextEditingController(),
            onSend: () {},
            onCamera: () {},
            onGallery: () {},
            onVoice: () {},
            onRemovePhoto: () {},
            ecrit: ecrit,
            onEcrit: (valeur) => ecrit = valeur,
          ),
        ),
      ),
    );

    await tester.pumpWidget(box());
    await tester.tap(find.byTooltip('Écrire un message'));
    await tester.pumpAndSettle();
    expect(ecrit, isTrue);

    await tester.pumpWidget(box());
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // Le micro de la box ramène au mode vocal.
    await tester.tap(find.byTooltip('Parler à Tovo'));
    await tester.pumpAndSettle();
    expect(ecrit, isFalse);
  });
}
