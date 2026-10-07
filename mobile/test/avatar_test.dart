import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/features/carte/avatar.dart';

/// Simule le GPS : une mesure par seconde, le moteur avancé à 15 images/s.
class Simulation {
  Simulation({bool saluer = false}) : m = MoteurAvatar(saluer: saluer);
  final MoteurAvatar m;
  double lat = 13.5297, lng = 2.0886;
  EtatAvatar? dernier;

  /// `secondes` à `vitesseMs`, vers le nord, une mesure GPS par seconde.
  void rouler(double secondes, double vitesseMs, {double precisionM = 5, double? bruitMs}) {
    for (var s = 0; s < secondes; s++) {
      lat += vitesseMs / 111320;
      m.gps((lat: lat, lng: lng), vitesseMs: bruitMs ?? vitesseMs, capDeg: vitesseMs > 0.6 ? 0 : null, precisionM: precisionM);
      for (var k = 0; k < 15; k++) {
        dernier = m.avancer(1 / 15);
      }
    }
  }
}

void main() {
  group('le moteur de l’avatar (07/10) : précis, sans va-et-vient', () {
    test('à l’ouverture il salue, puis attend', () {
      final s = Simulation(saluer: true);
      s.rouler(1, 0);
      expect(s.m.animation, AnimationAvatar.salut);
      s.rouler(2, 0);
      expect(s.m.animation, AnimationAvatar.attente);
    });

    test('il marche dès les premiers pas (1,3 m/s), en moins de 2 s', () {
      final s = Simulation();
      s.rouler(2, 1.3);
      expect(s.m.animation, AnimationAvatar.marche);
    });

    test('le bruit du GPS à l’arrêt ne le fait jamais marcher', () {
      final s = Simulation();
      for (var i = 0; i < 20; i++) {
        s.rouler(1, 0, bruitMs: i.isEven ? 0.25 : 0.05);
      }
      expect(s.m.animation, AnimationAvatar.attente);
    });

    test('une mesure imprécise (60 m) ne compte pas', () {
      final s = Simulation();
      s.rouler(5, 3, precisionM: 60);
      expect(s.m.animation, AnimationAvatar.attente);
    });

    test('à moto il court ; il freine : marche, puis arrêt', () {
      final s = Simulation();
      s.rouler(4, 9);
      expect(s.m.animation, AnimationAvatar.course);
      s.rouler(3, 1.0);
      expect(s.m.animation, AnimationAvatar.marche);
      s.rouler(4, 0);
      expect(s.m.animation, AnimationAvatar.attente);
    });

    test('autour du seuil de course, pas de va-et-vient (hystérésis)', () {
      final s = Simulation();
      s.rouler(4, 2.6);
      expect(s.m.animation, AnimationAvatar.course);
      // 2,0 m/s : sous le seuil d'entrée, au-dessus du seuil de sortie.
      s.rouler(6, 2.0);
      expect(s.m.animation, AnimationAvatar.course);
    });

    test('les pas suivent la distance : une foulée (2,25 m) = un cycle', () {
      final m = MoteurAvatar(saluer: false);
      var lat = 13.5297;
      // Démarrage, jusqu'à la marche établie.
      for (var i = 0; i < 4; i++) {
        lat += 1.35 / 111320;
        m.gps((lat: lat, lng: 2.0886), vitesseMs: 1.35, capDeg: 0);
        for (var k = 0; k < 15; k++) {
          m.avancer(1 / 15);
        }
      }
      expect(m.animation, AnimationAvatar.marche);
      // À 1,35 m/s, une foulée de 2,25 m dure 1,67 s : les 12 images défilent
      // toutes une fois, dans l'ordre.
      final vues = <int>[];
      for (var k = 0; k < 25; k++) {
        vues.add(m.avancer(1 / 15)!.image);
      }
      expect(vues.toSet().length, 12);
    });

    test('il se tourne dans le sens de la marche', () {
      final s = Simulation();
      s.rouler(3, 1.3);
      expect(s.dernier!.capDeg, closeTo(0, 1));
    });
  });

  group('la vue montrée selon la caméra', () {
    test('direction : le cap vu de la caméra, tous les 15°', () {
      expect(ImagesAvatar.directionPour(90, 0), 90);
      expect(ImagesAvatar.directionPour(90, 90), 0);
      expect(ImagesAvatar.directionPour(10, 0), 15);
      expect(ImagesAvatar.directionPour(350, 0), 345);
      expect(ImagesAvatar.directionPour(null, 0), 180, reason: 'sans cap : de face');
    });

    test('inclinaison : jamais vu de dessus (une tête), 45° sur une carte à plat', () {
      expect(ImagesAvatar.inclinaisonPour(0), 45);
      expect(ImagesAvatar.inclinaisonPour(30), 45);
      expect(ImagesAvatar.inclinaisonPour(60), 60);
    });
  });
}
