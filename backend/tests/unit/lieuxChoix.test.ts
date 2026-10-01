import { describe, expect, it } from 'vitest';
import { join } from 'node:path';
import { autourDe, chargerLieux, rechercherLieux } from '../../src/services/lieux.js';

// Les vraies données de Niamey (OpenStreetMap), pas un jeu inventé.
const lieux = chargerLieux(join(process.cwd(), 'data', 'lieux-niamey.json'));

describe('choisir où livrer : chercher un lieu', () => {
  it('trouve un quartier dès les premières lettres, avant ses repères', () => {
    const r = rechercherLieux('tallad', lieux);
    expect(r.length).toBeGreaterThan(0);
    expect(r[0]!.genre).toMatch(/quartier|village/);
    expect(r[0]!.nom.toLowerCase()).toContain('tall');
  });

  it('ignore accents et majuscules', () => {
    expect(rechercherLieux('YANTALA', lieux)[0]?.nom.toLowerCase()).toContain('yantala');
  });

  it('rien pour une seule lettre', () => {
    expect(rechercherLieux('t', lieux)).toEqual([]);
  });

  it('pas de doublon : même nom, même quartier', () => {
    const r = rechercherLieux('marche', lieux, 20);
    const cles = r.map((l) => `${l.nom}|${l.quartier}`);
    expect(new Set(cles).size).toBe(cles.length);
  });
});

describe('choisir où livrer : nommer l’endroit de l’épingle', () => {
  it('au pied d’un repère connu : ce repère, et son quartier', () => {
    const marche = lieux.find((l) => l.genre === 'marché')!;
    const a = autourDe({ lat: marche.lat + 0.0003, lng: marche.lng }, lieux);
    expect(a.repere).not.toBeNull();
    expect(a.distanceRepereM).toBeLessThanOrEqual(250);
    expect(a.quartier).not.toBeNull();
  });

  it('en plein désert : ni repère ni quartier', () => {
    const a = autourDe({ lat: 14.9, lng: 1.2 }, lieux);
    expect(a.repere).toBeNull();
    expect(a.quartier).toBeNull();
  });
});
