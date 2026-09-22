import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/features/chat/assistant_activity_dock.dart';

void main() {
  Future<void> showDock(
    WidgetTester tester,
    AssistantActivity activity, {
    VoidCallback? onPrimary,
    VoidCallback? onCancel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                AssistantActivityDock(
                  activity: activity,
                  onPrimary: onPrimary,
                  onCancel: onCancel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('le vocal indique écoute, arrêt et annulation', (tester) async {
    var stops = 0;
    var cancels = 0;
    await showDock(
      tester,
      AssistantActivity.listening,
      onPrimary: () => stops++,
      onCancel: () => cancels++,
    );
    expect(find.text('Je vous écoute'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('Arrêter et transcrire'));
    await tester.tap(find.byTooltip('Annuler le vocal'));
    expect(stops, 1);
    expect(cancels, 1);
  });

  testWidgets('la transcription se distingue de la recherche', (tester) async {
    await showDock(tester, AssistantActivity.transcribing);
    expect(find.text('Transcription…'), findsOneWidget);
    await showDock(tester, AssistantActivity.searching);
    expect(find.text('Je cherche…'), findsOneWidget);
    await showDock(tester, AssistantActivity.answering);
    expect(find.text('La réponse arrive…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
