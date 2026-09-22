import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/viewport_reveal.dart';

void main() {
  testWidgets('réserve sa place et ne révèle le bloc qu’au défilement', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(height: 800),
                ViewportReveal(
                  child: SizedBox(height: 80, child: Text('Produit visible')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final block = find.byType(ViewportReveal);
    final opacity = find.descendant(of: block, matching: find.byType(Opacity));
    expect(tester.getSize(block).height, 80);
    expect(tester.widget<Opacity>(opacity).opacity, 0);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -600),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.widget<Opacity>(opacity).opacity, 1);
    expect(tester.getSize(block).height, 80);
  });
}
