import { describe, expect, it } from 'vitest';
import { reperesDuTrajet } from '../../src/routes/carte.js';
import type { Lieu } from '../../src/services/lieux.js';

const lieu = (nom: string, genre: string, lat: number, lng: number): Lieu =>
  ({ id: nom, nom, nom_normalise: nom.toLowerCase(), genre, quartier: null, lat, lng });

describe('les repères proches du trajet (carte des commerces, 07/10)', () => {
  // Un trajet nord-sud d'environ 1,1 km.
  const trajet = [{ lat: 13.520, lng: 2.100 }, { lat: 13.530, lng: 2.100 }];

  it('seulement ceux qui sont près du trajet, marchés et ronds-points d’abord, au plus 3', () => {
    const lieux = [
      lieu('Station Loin', 'station-service', 13.525, 2.110),       // ~1 km du trajet : non
      lieu('Station Près', 'station-service', 13.5262, 2.1003),     // ~30 m : oui, après le marché
      lieu('Marché Près', 'marché', 13.5235, 2.1004),               // ~40 m : en premier
      lieu('Rond point Milieu', 'rue', 13.5285, 2.0999),            // ~10 m : oui
      lieu('École Près', 'école', 13.524, 2.1001),                  // pas un repère retenu
      lieu('Gare au Départ', 'gare', 13.5203, 2.1001),              // sur le départ : non
    ];
    const noms = reperesDuTrajet(trajet, lieux).map((r) => r.nom);
    expect(noms.slice(0, 2).sort()).toEqual(['Marché Près', 'Rond point Milieu']);
    expect(noms).toContain('Station Près');
    expect(noms).not.toContain('Station Loin');
    expect(noms).not.toContain('École Près');
    expect(noms).not.toContain('Gare au Départ');
    expect(noms.length).toBeLessThanOrEqual(3);
  });

  it('deux repères à moins de 250 m l’un de l’autre : un seul', () => {
    const lieux = [lieu('Marché A', 'marché', 13.525, 2.1003), lieu('Marché B', 'marché', 13.5255, 2.1003)];
    expect(reperesDuTrajet(trajet, lieux)).toHaveLength(1);
  });
});
