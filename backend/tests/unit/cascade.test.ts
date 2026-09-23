import { afterEach, describe, expect, it, vi } from 'vitest';
import type { DecisionJev, Intention } from '../../src/ai/jev.js';

const jev = vi.hoisted(() => ({ decision: null as DecisionJev | null, appels: 0 }));
vi.mock('../../src/ai/aiguillage.js', async (original) => ({
  ...(await original<typeof import('../../src/ai/aiguillage.js')>()),
  consulterJev: vi.fn(async () => { jev.appels++; return jev.decision; }),
}));
vi.mock('../../src/config/env.js', async (original) => {
  const reel = await original<typeof import('../../src/config/env.js')>();
  return { ...reel, env: { ...reel.env, CLASSIFIEUR_LOCAL: '1', CLASSIFIEUR_SEUIL: 0.8, JEV_SEUIL: 0.8 } };
});

import { creerClassifieur, installerClassifieur } from '../../src/ai/classifieur.js';
import { aiguiller } from '../../src/ai/cascade.js';

afterEach(() => { installerClassifieur(null); jev.decision = null; jev.appels = 0; });

/**
 * Vecteurs fabriqués en 3 dimensions : « livreur » vers x, « suivi » vers y,
 * « recherche » vers z. Le vectoriseur place chaque message selon ses mots.
 */
const index: Array<[number[], Intention]> = [
  [[1, 0, 0], 'livreur'], [[0.98, 0.2, 0], 'livreur'], [[0.97, 0, 0.24], 'livreur'],
  [[0, 1, 0], 'suivi'], [[0.2, 0.98, 0], 'suivi'], [[0, 0.97, 0.24], 'suivi'],
  [[0, 0, 1], 'recherche'], [[0.2, 0, 0.98], 'recherche'], [[0, 0.24, 0.97], 'recherche'],
];
const normer = (v: number[]) => { const n = Math.hypot(...v); return new Float32Array(v.map((x) => x / n)); };
const vectoriser = async (texte: string) =>
  normer(/moto|coursier/.test(texte) ? [1, 0.05, 0] : /où|attends/.test(texte) ? [0.05, 1, 0] : /livreur/.test(texte) ? [1, 1, 0] : [0, 0, 1]);
const classifieur = creerClassifieur(
  vectoriser,
  new Float32Array(index.flatMap(([v]) => [...normer(v)])),
  index.map(([, i]) => i),
  3,
);

describe('classifieur local — le vote des plus proches voisins', () => {
  it('message net : la bonne intention, avec une forte confiance', async () => {
    const d = await classifieur.classer('il me faut une moto');
    expect(d.choix).toBe('livreur');
    expect(d.confiance).toBeGreaterThan(0.8);
  });

  it('message à cheval : confiance partagée entre les deux pistes', async () => {
    const d = await classifieur.classer('le livreur');
    expect(d.confiance).toBeLessThan(0.8);
    expect(Object.keys(d.probabilites)).toEqual(expect.arrayContaining(['livreur', 'suivi']));
  });
});

describe('cascade', () => {
  it('le local est sûr : il décide, Jev n’est même pas appelé', async () => {
    installerClassifieur(classifieur);
    const a = await aiguiller('il me faut une moto pour une course');
    expect(a).toMatchObject({ source: 'local', route: { type: 'intention', intention: 'livreur' } });
    expect(jev.appels).toBe(0);
  });

  it('le local hésite : Jev tranche', async () => {
    installerClassifieur(classifieur);
    jev.decision = { choix: 'suivi', confiance: 0.95, probabilites: { suivi: 0.95 }, ms: 600, cout: 0 };
    const a = await aiguiller('le livreur');
    expect(a).toMatchObject({ source: 'jev', route: { type: 'intention', intention: 'suivi' } });
    expect(jev.appels).toBe(1);
  });

  it('le local hésite et Jev est absent : tuiles, d’après l’avis du local', async () => {
    installerClassifieur(classifieur);
    const a = await aiguiller('le livreur');
    expect(a.source).toBe('local');
    expect(a.route.type).toBe('clarifier');
  });

  it('classifieur pas encore chargé : on passe directement à Jev', async () => {
    jev.decision = { choix: 'recherche', confiance: 0.9, probabilites: { recherche: 0.9 }, ms: 700, cout: 0 };
    const a = await aiguiller('du riz');
    expect(a).toMatchObject({ source: 'jev', local: null });
  });
});
