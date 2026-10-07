import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/position_livreur.dart';
import 'package:tovo/features/carte/navigation.dart';

void main() {
  // Un trajet en L : 200 m vers le nord, puis 100 m vers l'est.
  const depart = (lat: 13.5300, lng: 2.0900);
  final coude = (lat: 13.5300 + 200 / 111320, lng: 2.0900);
  final arrivee = devant(coude, 90, 100);
  final trace = [depart, coude, arrivee];

  test('au départ, il reste tout le trajet (300 m), sur le trajet', () {
    final p = Progres.calculer(trace, depart)!;
    expect(p.restantM, closeTo(300, 1));
    expect(p.ecartM, closeTo(0, 0.5));
    expect(p.segment, 0);
  });

  test('à mi-chemin du premier tronçon : 200 m restants', () {
    final p = Progres.calculer(trace, devant(depart, 0, 100))!;
    expect(p.restantM, closeTo(200, 1));
  });

  test('à 30 m à côté du trajet : l’écart est mesuré, la distance suit la projection', () {
    final ici = devant(devant(depart, 0, 50), 90, 30);
    final p = Progres.calculer(trace, ici)!;
    expect(p.ecartM, closeTo(30, 1));
    expect(p.restantM, closeTo(250, 1));
  });

  test('sur le second tronçon, le premier est « parcouru »', () {
    final p = Progres.calculer(trace, devant(coude, 90, 40))!;
    expect(p.segment, 1);
    expect(p.restantM, closeTo(60, 1));
    final (parcouru, reste) = p.couper(trace);
    expect(parcouru.length, 3);
    expect(reste.length, 2);
    expect(metres(reste.last, arrivee), lessThan(0.01));
  });

  test('angles : le plus court chemin', () {
    expect(ecartAngle(350, 10), 20);
    expect(ecartAngle(10, 350), -20);
    expect(ecartAngle(0, 180).abs(), 180);
  });
}
