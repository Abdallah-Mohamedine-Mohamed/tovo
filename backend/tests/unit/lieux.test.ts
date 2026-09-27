import { describe, expect, it } from 'vitest';
import { chargerLieux, reperer, type Lieu } from '../../src/services/lieux.js';

const l = (nom: string, genre: string, quartier: string | null, lat = 13.5, lng = 2.1): Lieu => ({
  id: `osm:${nom}`, nom, nom_normalise: nom.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim(),
  genre, quartier, lat, lng,
});
const lieux = [
  l('Yantala', 'quartier', 'Yantala', 13.52, 2.08),
  l('Talladjé', 'quartier', 'Talladjé', 13.49, 2.14),
  l('Talladjé Koado', 'quartier', 'Talladjé Koado', 13.48, 2.15),
  l('Pharmacie Nour', 'pharmacie', 'Yantala', 13.521, 2.081),
  l('Pharmacie Nour', 'pharmacie', 'Talladjé', 13.491, 2.141),
  l('Grand Marché', 'marché', 'Plateau', 13.51, 2.11),
  l('Rue du Festival', 'rue', 'Yantala'),
];

describe('repérer un lieu dans une phrase', () => {
  it('le quartier seul', () => {
    const r = reperer('Va chercher un sac chez Moussa à Yantala', lieux);
    expect(r.quartier?.nom).toBe('Yantala');
    expect(r.point).toEqual({ lat: 13.52, lng: 2.08 });
    expect(r.description).toBe('Yantala');
  });

  it('le repère dans le quartier nommé', () => {
    const r = reperer('près de la pharmacie Nour à Talladjé', lieux);
    expect(r.repere?.quartier).toBe('Talladjé');
    expect(r.description).toBe('Pharmacie Nour (Talladjé)');
    expect(r.point).toEqual({ lat: 13.491, lng: 2.141 });
  });

  it('deux lieux du même nom sans quartier : on ne devine pas', () => {
    const r = reperer('devant la pharmacie Nour', lieux);
    expect(r.repere).toBeNull();
    expect(r.point).toBeNull();
  });

  it('le nom le plus long l’emporte, et une faute passe sur un mot long', () => {
    expect(reperer('à Talladjé Koado', lieux).quartier?.nom).toBe('Talladjé Koado');
    expect(reperer('à Taladjé', lieux).quartier?.nom).toBe('Talladjé');
  });

  it('un nom fait de mots courants doit apparaître tel quel', () => {
    expect(reperer('derrière le grand marché', lieux).repere?.nom).toBe('Grand Marché');
    expect(reperer('un grand sac de riz du marché', lieux).repere).toBeNull();
  });

  it('les rues ne servent pas de repère', () => {
    expect(reperer('rue du festival', lieux).repere).toBeNull();
  });

  it('rien de connu : rien', () => {
    expect(reperer('chez mon cousin', lieux)).toEqual({ quartier: null, repere: null, point: null, description: null });
  });

  it('les vrais lieux de Niamey sont chargés (OpenStreetMap)', () => {
    const vrais = chargerLieux();
    expect(vrais.length).toBeGreaterThan(5000);
    expect(reperer('va chercher mon téléphone à Lazaret', vrais).quartier?.nom).toBe('Lazaret');
  });
});

describe('une zone que la carte ne nomme pas comme quartier', () => {
  it('« Harobanda » : le centre des lieux qui portent ce nom', async () => {
    const { chargerLieux: vrais } = await import('../../src/services/lieux.js');
    const r = reperer('Va chercher mon colis chez Moussa à Harobanda', vrais());
    expect(r.description).toBe('Harobanda');
    // Rive droite, près du pont Kennedy (≈ 13,49 N ; 2,10 E).
    expect(r.point!.lat).toBeCloseTo(13.49, 1);
    expect(r.point!.lng).toBeCloseTo(2.1, 1);
  });
});
