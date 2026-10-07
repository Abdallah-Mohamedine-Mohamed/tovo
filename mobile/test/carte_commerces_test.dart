import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/components/registry.dart';
import 'package:tovo/features/carte/carte_commerces.dart';

void main() {
  test('la carte des commerces lit les positions, les partenaires Tovo d’abord', () {
    const c = TovoComponent(type: 'commerces_hors_tovo', data: {
      'items': [
        {
          'nom': 'Second Life Africa', 'type': 'Vêtements', 'quartier': 'Yantala Haut',
          'lat': 13.5417, 'lng': 2.0907, 'distance_m': 1400, 'telephone_appel': '+22770737378',
          'livreur': {'label': 'Envoyer un livreur', 'value': 'hors-tovo-oui:Acheter'},
        },
        // Sans position : pas sur la carte.
        {'nom': 'Sans position', 'type': 'Vêtements'},
      ],
      'boutiques_tovo': [
        {'id': 'b1', 'nom': 'BAAKLINI', 'ouverte': true, 'lat': 13.5219, 'lng': 2.0962, 'distance_m': 1190},
      ],
    });
    final liste = CarteCommerces.depuisComposant(c);
    expect(liste.map((x) => x.nom), ['BAAKLINI', 'Second Life Africa']);
    expect(liste.first.tovo, isTrue);
    expect(liste.first.idBoutique, 'b1');
    expect(liste.first.sousTitre, 'Sur Tovo · ouverte');
    final s = liste.last;
    expect(s.sousTitre, 'Vêtements · Yantala Haut');
    expect(s.position.lat, 13.5417);
    expect(s.telephone, '+22770737378');
    expect(s.livreur?['value'], 'hors-tovo-oui:Acheter');
  });

  test('sans aucune position, rien sur la carte (le bouton ne s’affiche pas)', () {
    const c = TovoComponent(type: 'commerces_hors_tovo', data: {
      'items': [{'nom': 'Ancien format', 'distance_m': 300}],
    });
    expect(CarteCommerces.depuisComposant(c), isEmpty);
  });
}
