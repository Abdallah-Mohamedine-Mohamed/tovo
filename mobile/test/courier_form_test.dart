import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/components/widgets/courier_form.dart';
import 'package:tovo/core/theme.dart';

Future<List<TovoInteraction>> _afficher(
  WidgetTester tester,
  Map<String, dynamic> data,
) async {
  final gestes = <TovoInteraction>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CourierForm(
            component: TovoComponent(type: 'courier_form', data: data),
            onInteraction: gestes.add,
          ),
        ),
      ),
    ),
  );
  return gestes;
}

Future<void> _commander(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Commander un livreur'));
  await tester.tap(find.text('Commander un livreur'));
  await tester.pump();
}

const _client = {'lat': 13.51, 'lng': 2.11};

void main() {
  testWidgets('un seul geste : chez moi, espèces par défaut', (tester) async {
    final gestes = await _afficher(tester, {
      'pickup': {..._client, 'hint': 'Ma position actuelle'},
      'estimate': {'price': 1000, 'flat': true},
      'callback_minutes': 7,
    });

    expect(find.text('Récupérer à'), findsOneWidget);
    expect(find.text('Ma position'), findsOneWidget);
    expect(find.text('Où l’apporter ?'), findsOneWidget);
    expect(find.text('Course en ville'), findsOneWidget);
    // Le délai n'est plus dit sur la carte : la phrase de Tovo le dit.
    expect(find.textContaining('7 minutes'), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await _commander(tester);

    expect(gestes, hasLength(1));
    expect(gestes.single.action, 'submit_courier');
    final p = gestes.single.payload;
    expect(p['pickup'], containsPair('lat', 13.51));
    expect(p['payment_method'], 'cash');
    expect(p.containsKey('mode'), isFalse);
    expect(p.containsKey('dropoff'), isFalse);

    // En attente du serveur : bouton bloqué, pas de second livreur.
    expect(find.text('Je commande le livreur…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('commandée : la carte s’efface, le suivi prend le relais', (
    tester,
  ) async {
    await _afficher(tester, {
      'pickup': _client,
      'callback_minutes': 7,
      'utilise': true,
    });
    expect(find.text('Commander un livreur'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.textContaining('Livreur commandé'), findsNothing);
  });

  testWidgets('ancienne carte : la destination et le destinataire repris', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {
      'pickup': _client,
      'dropoff': {'hint': 'Harobanda'},
      'dropoff_contact': '90123456',
    });

    expect(find.text('Harobanda'), findsOneWidget);
    expect(find.text('90123456'), findsOneWidget);

    await _commander(tester);
    expect(gestes.single.payload['dropoff_hint'], 'Harobanda');
    expect(gestes.single.payload['dropoff_contact'], '90123456');
  });

  testWidgets(
    '« aller chercher » : le lieu et le numéro repris, livré chez moi',
    (tester) async {
      final gestes = await _afficher(tester, {
        'mode': 'recuperer',
        'pickup': {'hint': 'Chez Awa, Yantala'},
        'pickup_contact': '90 12 34 56',
        'dropoff': {..._client, 'hint': 'Chez vous'},
        'estimate': {'price': 1000, 'flat': true},
      });

      expect(find.text('Chez Awa, Yantala'), findsOneWidget);
      expect(find.text('90 12 34 56'), findsOneWidget);
      expect(find.text('Ma position'), findsOneWidget);

      await _commander(tester);
      final p = gestes.single.payload;
      expect(p['mode'], 'recuperer');
      expect(p['pickup'], containsPair('hint', 'Chez Awa, Yantala'));
      expect(p['pickup_contact'], '90 12 34 56');
      // Livré chez le client : sa position est l'arrivée.
      expect(p['dropoff'], {'lat': 13.51, 'lng': 2.11});
    },
  );

  testWidgets('Harobanda → Banifandou : le trajet exact, et la consigne', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {
      'mode': 'deposer',
      'pickup': {
        'chez_moi': false,
        'hint': 'Harobanda',
        'lat': 13.49,
        'lng': 2.10,
      },
      'dropoff': {
        'chez_moi': false,
        'hint': 'Banifandou',
        'lat': 13.54,
        'lng': 2.14,
      },
      'position': _client,
      'consigne': 'Sonner au portail bleu',
      'estimate': {'price': 2750, 'distance_m': 6814},
    });

    expect(find.text('Harobanda'), findsOneWidget);
    expect(find.text('Banifandou'), findsOneWidget);
    expect(find.text('Pour le livreur'), findsOneWidget);
    expect(find.text('Sonner au portail bleu'), findsOneWidget);
    expect(find.textContaining('Course ·'), findsOneWidget);
    expect(find.text(Money.format(2750)), findsOneWidget);

    await _commander(tester);
    final p = gestes.single.payload;
    expect(p.containsKey('mode'), isFalse);
    expect(p['pickup'], {'lat': 13.49, 'lng': 2.10, 'hint': 'Harobanda'});
    expect(p['dropoff'], {'lat': 13.54, 'lng': 2.14});
    expect(p['dropoff_hint'], 'Banifandou');
    expect(p['parcel_note'], 'Sonner au portail bleu');
  });

  testWidgets(
    'un départ que l’on ne sait pas situer : le livreur est cherché près du '
    'client, et aucune distance fausse',
    (tester) async {
      final gestes = await _afficher(tester, {
        'pickup': {'chez_moi': false, 'hint': 'Chez Moussa'},
        'dropoff': {
          'chez_moi': false,
          'hint': 'Banifandou',
          'lat': 13.54,
          'lng': 2.14,
        },
        'position': _client,
      });
      await _commander(tester);
      final p = gestes.single.payload;
      expect(p['pickup'], {'lat': 13.51, 'lng': 2.11, 'hint': 'Chez Moussa'});
      expect(p.containsKey('dropoff'), isFalse);
      expect(p['dropoff_hint'], 'Banifandou');
    },
  );

  testWidgets(
    'ma position : le quartier sur la même ligne, lu par le livreur',
    (tester) async {
      final gestes = await _afficher(tester, {
        'mode': 'recuperer',
        'pickup': {
          'chez_moi': false,
          'hint': 'Bobiel',
          'lat': 13.55,
          'lng': 2.09,
        },
        'dropoff': {
          ..._client,
          'chez_moi': true,
          'hint': 'Chez le client',
          'quartier': 'Niamey 2000',
        },
        'position': _client,
      });
      expect(find.text('Ma position · Niamey 2000'), findsOneWidget);
      expect(find.textContaining('Chez moi'), findsNothing);
      await _commander(tester);
      expect(
        gestes.single.payload['dropoff_hint'],
        'Position du client · Niamey 2000',
      );
    },
  );

  testWidgets('avec un devis, modifier un lieu ne change pas le prix', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {
      'pickup': _client,
      'dropoff': {
        'chez_moi': false,
        'hint': 'Banifandou',
        'lat': 13.54,
        'lng': 2.14,
      },
      'estimate': {'price': 2750, 'distance_m': 6814, 'devis': 'devis-1'},
    });
    expect(find.text(Money.format(2750)), findsOneWidget);

    // Le client change l'arrivée : le prix affiché reste celui du devis.
    // Le second « Modifier » : celui de l'arrivée.
    await tester.tap(find.widgetWithText(TextButton, 'Modifier').at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Koira Kano');
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();
    expect(find.text('Koira Kano'), findsOneWidget);
    expect(find.text(Money.format(2750)), findsOneWidget);
    expect(find.text('Prix calculé à la commande'), findsNothing);

    await _commander(tester);
    expect(gestes.single.payload['devis'], 'devis-1');
    expect(gestes.single.payload['dropoff_hint'], 'Koira Kano');
  });

  testWidgets('la consigne s’ajoute d’un geste et part avec la course', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {'pickup': _client});
    expect(find.text('Aucune consigne'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Ajouter').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Appeler en arrivant');
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();

    expect(find.text('Appeler en arrivant'), findsOneWidget);
    await _commander(tester);
    expect(gestes.single.payload['parcel_note'], 'Appeler en arrivant');
  });

  testWidgets('Nita : choisi d’un toucher, le numéro avant de commander', (
    tester,
  ) async {
    await _afficher(tester, {'pickup': _client, 'mobile_money': true});
    expect(find.text('Espèces'), findsOneWidget);
    await tester.tap(find.text('Nita'));
    await tester.pump();
    final bouton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Commander un livreur'),
    );
    expect(bouton.onPressed, isNull);
    // Le numéro retenu se lit en arrière-plan (1 s au plus).
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('sans position, « Ma position » est proposé', (tester) async {
    await _afficher(tester, const {});
    // La position est cherchée d'office, sans geste du client…
    expect(find.text('Recherche…'), findsOneWidget);
    // Le GPS est absent du banc d'essai : la recherche échoue pour de vrai.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    // … et si elle est introuvable, le bouton reste là, sans message.
    expect(find.text('Me localiser'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    final bouton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Commander un livreur'),
    );
    expect(bouton.onPressed, isNull);
  });

  // Une ancienne conversation peut porter une carte « auto » (avant D1).
  testWidgets('ancienne carte « auto » : commandée sans second geste', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {
      'auto': true,
      'pickup': {..._client, 'hint': 'Ma position actuelle'},
      'callback_minutes': 7,
    });
    await tester.pump();
    expect(gestes.single.action, 'submit_courier');
    expect(find.text('Je commande le livreur…'), findsOneWidget);
  });

  // Le résultat vient de l'écran, qui a la réponse du serveur : la carte
  // reçoit `utilise` (confirmé) ou `echec` (pas partie).
  testWidgets('échec : la carte le dit, le bouton revient ; confirmée : elle '
      's’efface', (tester) async {
    final data = <String, dynamic>{'pickup': _client, 'callback_minutes': 7};
    late StateSetter reconstruire;
    final gestes = <TovoInteraction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              reconstruire = setState;
              return SingleChildScrollView(
                child: CourierForm(
                  component: TovoComponent(
                    type: 'courier_form',
                    data: {...data},
                  ),
                  onInteraction: gestes.add,
                ),
              );
            },
          ),
        ),
      ),
    );
    await _commander(tester);
    expect(gestes, hasLength(1));

    reconstruire(() => data['echec'] = 1);
    await tester.pump();
    expect(find.byKey(const Key('livreur-echec')), findsOneWidget);
    expect(find.text('Commander un livreur'), findsOneWidget);
    expect(gestes, hasLength(1));

    await _commander(tester);
    expect(gestes, hasLength(2));
    expect(find.byKey(const Key('livreur-echec')), findsNothing);
    reconstruire(() => data['utilise'] = true);
    await tester.pump();
    expect(find.text('Commander un livreur'), findsNothing);
  });

  testWidgets('« aller chercher » attend toujours le geste du client', (
    tester,
  ) async {
    final gestes = await _afficher(tester, {
      'auto': true,
      'mode': 'recuperer',
      'dropoff': _client,
    });
    await tester.pump();
    // Il faut d'abord dire où aller chercher : rien ne part tout seul.
    expect(gestes, isEmpty);
    expect(find.text('Où aller chercher ?'), findsOneWidget);
    final bouton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Commander un livreur'),
    );
    expect(bouton.onPressed, isNull);
  });

  testWidgets('même bouton que « Commander » sur la fiche produit', (
    tester,
  ) async {
    await _afficher(tester, {'pickup': _client});
    final bouton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Commander un livreur'),
    );
    expect(bouton.style!.backgroundColor!.resolve({}), TovoTheme.teal);
    expect(bouton.style!.foregroundColor!.resolve({}), Colors.white);
  });
}
