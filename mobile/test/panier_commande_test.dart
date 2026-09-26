import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/cart_summary.dart';

Future<List<TovoInteraction>> _afficher(
  WidgetTester tester, {
  bool commande = false,
}) async {
  final gestes = <TovoInteraction>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CartSummary(
            component: TovoComponent(
              type: 'cart_summary',
              data: {
                'merchant_name': "O'takoss (centre aéré)",
                'items': [
                  {
                    'item_id': 'i1',
                    'product_name': 'Tacos bowl',
                    'quantity': 2,
                    'line_total': 12600,
                  },
                ],
                'items_total': 12600,
                'delivery_fee': 0,
                'total': 12600,
                'can_checkout': true,
                'commande_passee': ?(commande ? true : null),
              },
            ),
            onInteraction: gestes.add,
          ),
        ),
      ),
    ),
  );
  return gestes;
}

void main() {
  testWidgets('un panier à commander propose « Commander »', (tester) async {
    await _afficher(tester);
    expect(find.textContaining('Commander'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  // Capture du 26/09 : « Commander — 12 600 F » restait au-dessus du suivi
  // de la commande que ce panier venait de passer.
  testWidgets('un panier commandé ne propose plus rien', (tester) async {
    await _afficher(tester, commande: true);
    expect(find.textContaining('Commander'), findsNothing);
    expect(find.byKey(const Key('panier-commande')), findsOneWidget);
    expect(find.text('Commande passée'), findsOneWidget);
    // Plus de + / − : on ne modifie pas une commande partie.
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.text('× 2'), findsOneWidget);
  });
}
