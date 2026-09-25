import { describe, expect, it } from 'vitest';
import { distanceKm, heureArrivee, lirePoint, minutesRestantes } from '../../src/services/arrivee.js';

// Deux points de Niamey : le Grand Marché et le Plateau (~2,6 km).
const marche = { lat: 13.5137, lng: 2.1125 };
const plateau = { lat: 13.5320, lng: 2.0960 };

/** Un point comme PostgREST le renvoie : EWKB hexadécimal, SRID 4326. */
function ewkb(p: { lat: number; lng: number }): string {
  const b = Buffer.alloc(25);
  b.writeUInt8(1, 0);
  b.writeUInt32LE(0x20000001, 1);
  b.writeUInt32LE(4326, 5);
  b.writeDoubleLE(p.lng, 9);
  b.writeDoubleLE(p.lat, 17);
  return b.toString('hex').toUpperCase();
}

describe('arrivée — « Arrivée vers 14:35 »', () => {
  it('lit un point PostGIS (EWKB) ou GeoJSON', () => {
    expect(lirePoint(ewkb(marche))).toEqual(marche);
    expect(lirePoint({ type: 'Point', coordinates: [2.0960, 13.5320] })).toEqual(plateau);
    expect(lirePoint(null)).toBeNull();
    expect(lirePoint('pas un point')).toBeNull();
  });

  it('mesure la distance à vol d’oiseau', () => {
    expect(distanceKm(marche, plateau)).toBeGreaterThan(2.4);
    expect(distanceKm(marche, plateau)).toBeLessThan(2.9);
  });

  it('aucune heure tant qu’aucun livreur n’est en route', () => {
    for (const statut of ['pending', 'confirmed', 'preparing', 'ready']) {
      expect(minutesRestantes({ statut, colis: false, mode: 'deposer', livreur: plateau, depart: marche, arrivee: plateau })).toBeNull();
    }
  });

  it('repas, livreur assigné : rejoindre la boutique, récupérer, livrer', () => {
    const m = minutesRestantes({ statut: 'assigned', colis: false, mode: 'deposer', livreur: plateau, depart: marche, arrivee: plateau })!;
    // Deux fois 2,6 km à 22 km/h (+35 %) ≈ 2 × 9,5 min, plus 3 min sur place.
    expect(m).toBeGreaterThan(18);
    expect(m).toBeLessThan(26);
  });

  it('colis « déposer » : l’arrivée, c’est le livreur qui vient chez le client', () => {
    const m = minutesRestantes({ statut: 'assigned', colis: true, mode: 'deposer', livreur: plateau, depart: marche, arrivee: plateau })!;
    expect(m).toBeGreaterThan(7);
    expect(m).toBeLessThan(13);
  });

  it('en route : du livreur jusqu’au client ; position inconnue : du départ', () => {
    const avecPosition = minutesRestantes({ statut: 'delivering', colis: false, mode: 'deposer', livreur: plateau, depart: marche, arrivee: plateau })!;
    expect(avecPosition).toBeLessThan(1);
    const sansPosition = minutesRestantes({ statut: 'picked_up', colis: false, mode: 'deposer', livreur: null, depart: marche, arrivee: plateau })!;
    expect(sansPosition).toBeGreaterThan(7);
  });

  it('sans positions, pas d’heure inventée', () => {
    expect(minutesRestantes({ statut: 'picked_up', colis: false, mode: 'deposer', livreur: null, depart: null, arrivee: null })).toBeNull();
  });

  it('arrondit aux 5 minutes SUPÉRIEURES (une marge, pas une promesse)', () => {
    const t0 = Date.UTC(2026, 8, 25, 13, 21, 30);
    // 13:21:30 + 11 min = 13:32:30 → 13:35.
    expect(heureArrivee(11, t0)).toBe(Date.UTC(2026, 8, 25, 13, 35) / 1000);
    // Déjà rond : reste tel quel.
    expect(heureArrivee(8.5, t0)).toBe(Date.UTC(2026, 8, 25, 13, 30) / 1000);
  });
});
