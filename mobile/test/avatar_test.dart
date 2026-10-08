import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/position_livreur.dart';
import 'package:tovo/features/carte/avatar.dart';

/// Simule le GPS : une mesure par seconde, le moteur avancé à 15 images/s.
class Simulation {
  Simulation({bool saluer = false}) : m = MoteurAvatar(saluer: saluer);
  final MoteurAvatar m;
  double lat = 13.5297, lng = 2.0886;
  EtatAvatar? dernier;
  DateTime instant = DateTime(2026, 10, 7, 19);

  /// `secondes` à `vitesseMs`, vers le nord, une mesure GPS par seconde.
  void rouler(
    double secondes,
    double vitesseMs, {
    double precisionM = 5,
    double? bruitMs,
  }) {
    for (var s = 0; s < secondes; s++) {
      lat += vitesseMs / 111320;
      instant = instant.add(const Duration(seconds: 1));
      m.gps(
        (lat: lat, lng: lng),
        vitesseMs: bruitMs ?? vitesseMs,
        capDeg: vitesseMs > 0.6 ? 0 : null,
        precisionM: precisionM,
        instant: instant,
      );
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

  group('sur un vrai téléphone (essai du 07/10)', () {
    test(
      'iPhone : vitesse du GPS indisponible (−1) — il marche quand même, d’après son déplacement',
      () {
        final m = MoteurAvatar(saluer: false);
        var t = DateTime(2026, 10, 7, 19);
        var lat = 13.5297;
        for (var s = 0; s < 6; s++) {
          lat += 1.4 / 111320;
          t = t.add(const Duration(seconds: 1));
          m.gps(
            (lat: lat, lng: 2.0886),
            vitesseMs: -1,
            capDeg: -1,
            precisionM: 5,
            instant: t,
          );
          for (var k = 0; k < 15; k++) {
            m.avancer(1 / 15);
          }
        }
        expect(m.animation, AnimationAvatar.marche);
        expect(m.avancer(0)!.capDeg, closeTo(0, 2), reason: 'vers le nord');
      },
    );

    test(
      'en voiture à 50 km/h, le GPS dit 0,2 m/s : il court quand même (essai du 08/10)',
      () {
        final m = MoteurAvatar(saluer: false);
        var t = DateTime(2026, 10, 8, 16, 35);
        var lat = 13.5297;
        for (var s = 0; s < 6; s++) {
          lat += 14 / 111320; // 14 m/s = 50 km/h
          t = t.add(const Duration(seconds: 1));
          m.gps(
            (lat: lat, lng: 2.0886),
            vitesseMs: 0.2,
            capDeg: 13,
            precisionM: 2,
            instant: t,
          );
          for (var k = 0; k < 15; k++) {
            m.avancer(1 / 15);
          }
        }
        expect(m.animation, AnimationAvatar.course);
        expect(m.vitesse, greaterThan(10));
      },
    );

    test(
      'à l’arrêt, le GPS qui tremble de 6 m ne fait ni marcher, ni tourner, ni bouger l’avatar',
      () {
        final m = MoteurAvatar(saluer: false);
        var t = DateTime(2026, 10, 7, 19);
        const sauts = [
          (6.0, 0.0),
          (-4.0, 5.0),
          (3.0, -6.0),
          (-6.0, -2.0),
          (5.0, 4.0),
          (0.0, 6.0),
        ];
        final depart = (lat: 13.5297, lng: 2.0886);
        for (var i = 0; i < 30; i++) {
          final (dn, de) = sauts[i % sauts.length];
          t = t.add(const Duration(seconds: 1));
          m.gps(
            (lat: depart.lat + dn / 111320, lng: depart.lng + de / 108000),
            vitesseMs: -1,
            precisionM: 8,
            instant: t,
          );
          for (var k = 0; k < 15; k++) {
            m.avancer(1 / 15);
          }
        }
        expect(m.animation, AnimationAvatar.attente);
        expect(
          m.avancer(0)!.capDeg,
          isNull,
          reason: 'pas de cap inventé : la caméra ne tourne pas',
        );
        expect(metres(m.position!, depart), lessThan(8));
      },
    );
  });

  group('la vue montrée selon la caméra', () {
    test('direction : le cap vu de la caméra, tous les 15°', () {
      expect(ImagesAvatar.directionPour(90, 0), 90);
      expect(ImagesAvatar.directionPour(90, 90), 0);
      expect(ImagesAvatar.directionPour(10, 0), 15);
      expect(ImagesAvatar.directionPour(350, 0), 345);
      expect(
        ImagesAvatar.directionPour(null, 0),
        180,
        reason: 'sans cap : de face',
      );
    });

    test(
      'inclinaison : jamais vu de dessus (une tête), 45° sur une carte à plat',
      () {
        expect(ImagesAvatar.inclinaisonPour(0), 45);
        expect(ImagesAvatar.inclinaisonPour(30), 45);
        expect(ImagesAvatar.inclinaisonPour(60), 60);
      },
    );
  });
}
