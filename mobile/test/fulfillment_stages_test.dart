import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/features/driver/driver_controller.dart';
import 'package:tovo/features/merchant/merchant_controller.dart';

void main() {
  test('la boutique passe de acceptée à prête sans étape supplémentaire', () {
    expect(MerchantController.etapeSuivante('pending'), 'confirmed');
    expect(MerchantController.etapeSuivante('confirmed'), 'ready');
    expect(MerchantController.etapeSuivante('ready'), isNull);
  });

  test('le livreur part en livraison puis confirme la remise', () {
    expect(DriverController.etapeSuivante('assigned'), 'delivering');
    expect(DriverController.etapeSuivante('delivering'), 'delivered');
    expect(DriverController.etapeSuivante('delivered'), isNull);
  });
}
