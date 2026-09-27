import 'package:flutter_test/flutter_test.dart';
import 'package:tovo/core/position_livreur.dart';

void main() {
  test('lit un point PostGIS (EWKB, SRID 4326) tel que Realtime l’envoie', () {
    // POINT(2.1098 13.5137), SRID 4326, petit-boutiste.
    const ewkb = '0101000020E610000070CE88D2DEE0004010E9B7AF03072B40';
    final p = lirePoint(ewkb)!;
    expect(p.lng, closeTo(2.1098, 1e-4));
    expect(p.lat, closeTo(13.5137, 1e-4));
  });

  test('lit aussi GeoJSON et {lat, lng} ; refuse le reste', () {
    expect(
      lirePoint({
        'type': 'Point',
        'coordinates': [2.1, 13.5],
      }),
      (lat: 13.5, lng: 2.1),
    );
    expect(lirePoint({'lat': 13.5, 'lng': 2.1}), (lat: 13.5, lng: 2.1));
    expect(lirePoint('pas un point'), isNull);
    expect(lirePoint(null), isNull);
  });

  test('le cap : vers l’est, 90° ; vers le nord, 0°', () {
    const a = (lat: 13.5, lng: 2.1);
    expect(cap(a, (lat: 13.5, lng: 2.11)), closeTo(90, 1));
    expect(cap(a, (lat: 13.51, lng: 2.1)), closeTo(0, 1));
  });

  test('la moto glisse d’une position à la suivante, sans sauter', () {
    final moto = MotoAnimee();
    final t0 = DateTime(2026, 9, 27, 12);
    moto.recevoir((lat: 13.500, lng: 2.100), maintenant: t0);
    final t1 = t0.add(const Duration(seconds: 5));
    moto.recevoir((lat: 13.500, lng: 2.110), maintenant: t1);
    // À mi-chemin du temps écoulé : à mi-chemin de la route.
    final milieu = moto.position(t1.add(const Duration(milliseconds: 2500)))!;
    expect(milieu.lng, closeTo(2.105, 1e-6));
    expect(moto.enMouvement(t1.add(const Duration(seconds: 1))), isTrue);
    // Arrivée : posée sur la dernière position reçue.
    expect(moto.position(t1.add(const Duration(seconds: 6)))!.lng, 2.110);
    // Cap : vers l'est.
    expect(moto.capDegres, closeTo(90, 1));
  });

  test(
    'un saut aberrant (GPS perdu) : posée directement, sans traverser la ville',
    () {
      final moto = MotoAnimee();
      final t0 = DateTime(2026, 9, 27, 12);
      moto.recevoir((lat: 13.50, lng: 2.10), maintenant: t0);
      final t1 = t0.add(const Duration(seconds: 5));
      moto.recevoir((lat: 13.60, lng: 2.20), maintenant: t1);
      expect(
        moto.position(t1.add(const Duration(milliseconds: 100)))!.lat,
        13.60,
      );
    },
  );

  test('décode le tracé Google et ne garde que ce qui reste à faire', () {
    // L'exemple de la documentation Google.
    final trace = decoderPolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(trace, hasLength(3));
    expect(trace.first, (lat: 38.5, lng: -120.2));
    expect(trace.last.lat, closeTo(43.252, 1e-5));

    const ligne = [
      (lat: 13.500, lng: 2.100),
      (lat: 13.505, lng: 2.100),
      (lat: 13.510, lng: 2.100),
    ];
    // Entre le 1er et le 2e point : le 1er est derrière lui, oublié.
    final reste = resteDuTrace(ligne, (lat: 13.503, lng: 2.100));
    expect(reste.first, (lat: 13.503, lng: 2.100));
    expect(reste.skip(1), [ligne[1], ligne[2]]);
  });

  test('le tracé mesuré projette le GPS sur la rue et suit les virages', () {
    // Un « L » : 1,1 km vers le nord, puis vers l'est.
    final trace = TraceMesure(const [
      (lat: 13.500, lng: 2.100),
      (lat: 13.510, lng: 2.100),
      (lat: 13.510, lng: 2.110),
    ]);
    expect(trace.longueur, greaterThan(2000));
    // Un GPS un peu à côté de la première rue : projeté dessus.
    final p = trace.projeter((lat: 13.505, lng: 2.1001));
    expect(p.ecart, lessThan(15));
    expect(p.d, closeTo(553, 5));
    // À mi-chemin de la distance totale : dans le virage, pas en diagonale.
    final milieu = trace.pointA(trace.longueur / 2);
    expect(milieu.lat == 13.510 || milieu.lng == 2.100, isTrue);
    expect(trace.depuis(p.d).first.lat, closeTo(13.505, 1e-6));
    expect(trace.depuis(p.d).last, (lat: 13.510, lng: 2.110));
  });

  test('immobile : garde son dernier cap', () {
    final moto = MotoAnimee();
    final t0 = DateTime(2026, 9, 27, 12);
    moto.recevoir((lat: 13.500, lng: 2.100), maintenant: t0);
    moto.recevoir((
      lat: 13.500,
      lng: 2.110,
    ), maintenant: t0.add(const Duration(seconds: 5)));
    moto.recevoir((
      lat: 13.500,
      lng: 2.110,
    ), maintenant: t0.add(const Duration(seconds: 10)));
    expect(moto.capDegres, closeTo(90, 1));
  });
}
