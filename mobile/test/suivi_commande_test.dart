import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/suivi_commande.dart';

/// Le suivi Android dit la même chose que la Live Activity de l'iPhone.
void main() {
  EtapeSuivi e(Map<String, dynamic> d) => EtapeSuivi.depuisMessage(d);

  test('le prénom du client : au début et à la fin de la course seulement', () {
    expect(
      e({'status': 'confirmed', 'client': 'Awa'}).phrase,
      'Awa, votre commande est confirmée',
    );
    expect(
      e({'status': 'preparing', 'client': 'Awa'}).phrase,
      'Votre repas se prépare',
    );
    expect(
      e({'status': 'delivered', 'client': 'Awa'}).phrase,
      'Bon appétit, Awa !',
    );
  });

  test('sans prénom, la phrase s’en passe proprement', () {
    expect(e({'status': 'confirmed'}).phrase, 'Votre commande est confirmée');
    expect(e({'status': 'delivered'}).phrase, 'Bon appétit !');
  });

  test('le livreur est nommé ; « Votre livreur » à défaut', () {
    expect(
      e({'status': 'picked_up', 'client': 'Awa', 'driver': 'Moussa'}).phrase,
      'Moussa arrive avec votre commande',
    );
    expect(
      e({'status': 'assigned'}).phrase,
      'Votre livreur va chercher votre commande',
    );
  });

  test('colis : des étapes en mots simples', () {
    final colis = {'type': 'courier', 'client': 'Awa'};
    expect(e({...colis, 'status': 'ready'}).etape, 'Recherche d’un livreur');
    expect(e({...colis, 'status': 'assigned'}).etape, 'Livreur en chemin');
    expect(e({...colis, 'status': 'picked_up'}).etape, 'Colis récupéré');
    expect(e({...colis, 'status': 'picked_up'}).phrase, 'Colis récupéré !');
    expect(e({...colis, 'status': 'delivering'}).etape, 'Colis en route');
    expect(e({...colis, 'status': 'delivered'}).etape, 'Colis livré');
    expect(
      e({...colis, 'status': 'assigned', 'mode': 'recuperer'}).etape,
      'Vers votre colis',
    );
  });

  test('segments et illustrations suivent la course', () {
    expect(e({'status': 'pending'}).index, 0);
    expect(e({'status': 'preparing'}).index, 1);
    expect(e({'status': 'delivering'}).index, 2);
    expect(e({'status': 'delivered'}).index, 3);
    expect(e({'status': 'delivering'}).image, 'scooter');
    expect(e({'status': 'cancelled'}).image, 'annule');
    expect(e({'status': 'delivered'}).fini, isTrue);
  });

  test('seuls les messages de suivi sont pris en compte', () {
    expect(SuiviAndroid.concerne({'kind': 'suivi', 'order_id': 'c1'}), isTrue);
    expect(
      SuiviAndroid.concerne({'kind': 'order_status', 'order_id': 'c1'}),
      isFalse,
    );
    expect(SuiviAndroid.concerne({'kind': 'suivi'}), isFalse);
  });
}
