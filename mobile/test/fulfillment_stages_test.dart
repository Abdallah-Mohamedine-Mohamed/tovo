import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/features/driver/driver_controller.dart';
import 'package:tovo/features/merchant/merchant_controller.dart';

void main() {
  test('la boutique : accepter, c’est préparer ; puis prête (29/09)', () {
    expect(MerchantController.etapeSuivante('pending'), 'preparing');
    expect(MerchantController.etapeSuivante('confirmed'), 'ready');
    expect(MerchantController.etapeSuivante('preparing'), 'ready');
    expect(MerchantController.etapeSuivante('ready'), isNull);
  });

  test('le livreur : deux gestes, récupérée puis livrée (0071)', () {
    // Récupérée, que la boutique ait suivi dans l'app ou non.
    for (final statut in [
      'pending',
      'confirmed',
      'preparing',
      'ready',
      'assigned',
    ]) {
      expect(DriverController.etapeSuivante(statut), 'delivering');
    }
    expect(DriverController.etapeSuivante('delivering'), 'delivered');
    // Une course commencée avec l'ancienne app se termine aussi.
    expect(DriverController.etapeSuivante('picked_up'), 'delivered');
    expect(DriverController.etapeSuivante('delivered'), isNull);
  });
}
