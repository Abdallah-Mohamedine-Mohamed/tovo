import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/commerces_hors_tovo.dart';

void main() {
  testWidgets('commerces hors Tovo : livreur d’abord, numéro ensuite (01/10)', (
    tester,
  ) async {
    final gestes = <TovoInteraction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CommercesHorsTovo(
              component: TovoComponent(
                type: 'commerces_hors_tovo',
                data: {
                  'items': [
                    {
                      'id': 'ovt:1',
                      'nom': 'Haddad Khalil Super Market',
                      'type': 'Supermarché',
                      'icone': 'supermarche',
                      'adresse': 'Rue du Commerce, Plateau',
                      'distance_m': 1200,
                      'telephone': '20 73 61 60',
                      'telephone_appel': '+22720736160',
                      'livreur': {
                        'label': 'Envoyer un livreur chez Haddad Khalil Super Market',
                        'value': 'hors-tovo-oui:Acheter de la pommade|+22720736160',
                      },
                    },
                    {
                      'id': 'osm:2',
                      'nom': 'Marché de Yantala',
                      'type': 'Marché',
                      'icone': 'marche',
                      'adresse': null,
                      'distance_m': null,
                      'telephone': null,
                      'livreur': {
                        'label': 'Envoyer un livreur chez Marché de Yantala',
                        'value': 'hors-tovo-oui:Acheter du riz',
                      },
                    },
                  ],
                  'note': 'Commerces hors Tovo, d’après des informations publiques.',
                },
              ),
              onInteraction: gestes.add,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Haddad Khalil Super Market'), findsOneWidget);
    expect(find.text('Supermarché · Rue du Commerce, Plateau · 1,2 km'), findsOneWidget);
    // Un livreur pour chacun ; un numéro seulement quand il est connu.
    expect(find.text('Envoyer un livreur'), findsNWidgets(2));
    expect(find.text('20 73 61 60'), findsOneWidget);
    expect(find.textContaining('informations publiques'), findsOneWidget);

    await tester.tap(find.text('Envoyer un livreur').first);
    expect(gestes.last.action, 'quick_reply');
    expect(
      gestes.last.payload['value'],
      'hors-tovo-oui:Acheter de la pommade|+22720736160',
    );

    await tester.tap(find.text('20 73 61 60'));
    expect(gestes.last.action, 'call_phone');
    expect(gestes.last.payload['phone'], '+22720736160');
  });
}
