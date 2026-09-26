import { describe, expect, it } from 'vitest';
import {
  comprendre,
  lireDecision,
  lireReglage,
  messagePourCerveau,
  type Essai,
} from '../../src/ai/decideur.js';
import { routeDuCerveau } from '../../src/ai/aiguillage.js';
import type { Intention } from '../../src/ai/jev.js';

/** Un faux modèle : répond `intention` au bout de `ms`, ou échoue. */
function modele(intention: Intention | Error, ms: number, sur = true): Essai & { appels: number } {
  const essai = Object.assign(
    (_m: string, signal: AbortSignal) => new Promise<{ intention: Intention; sur: boolean }>((ok, ko) => {
      essai.appels++;
      const t = setTimeout(() => (intention instanceof Error ? ko(intention) : ok({ intention, sur })), ms);
      signal.addEventListener('abort', () => { clearTimeout(t); ko(new Error('abandonné')); });
    }),
    { appels: 0 },
  );
  return essai;
}

describe('le cerveau', () => {
  it('le principal répond vite : personne d’autre n’est dérangé', async () => {
    const principal = modele('recherche', 5);
    const relance = modele('social', 5);
    const d = await comprendre('du riz', {}, { essais: [['principal', principal], ['relance', relance]], relanceMs: 100 });
    expect(d).toMatchObject({ intention: 'recherche', modele: 'principal', relance: false });
    expect(relance.appels).toBe(0);
  });

  it('le principal traîne : la relance part, la première réponse gagne', async () => {
    const d = await comprendre('du riz', {}, {
      essais: [['principal', modele('recherche', 300)], ['relance', modele('recherche', 10)]],
      relanceMs: 20,
    });
    expect(d).toMatchObject({ intention: 'recherche', modele: 'relance', relance: true });
    expect(d.ms).toBeLessThan(200);
  });

  it('le principal tombe en panne : le suivant part AUSSITÔT, sans attendre la relance', async () => {
    const d = await comprendre('un livreur', {}, {
      essais: [['principal', modele(new Error('503'), 5)], ['relance', modele('livreur', 5)]],
      relanceMs: 5_000,
    });
    expect(d).toMatchObject({ intention: 'livreur', modele: 'relance' });
    expect(d.ms).toBeLessThan(500);
    expect(d.erreurs[0]).toContain('503');
  });

  it('tous en panne : pas de décision, le chemin habituel reprend', async () => {
    const d = await comprendre('bonjour', {}, {
      essais: [['a', modele(new Error('panne a'), 5)], ['b', modele(new Error('panne b'), 5)]],
    });
    expect(d.intention).toBeNull();
    expect(d.erreurs).toHaveLength(2);
  });

  it('personne ne répond à temps : pas de décision au bout du délai maximal', async () => {
    const d = await comprendre('bonjour', {}, {
      essais: [['lent', modele('social', 5_000)]],
      relanceMs: 10,
      delaiMaxMs: 50,
    });
    expect(d.intention).toBeNull();
    expect(d.ms).toBeLessThan(1_000);
  });

  it('lit le dernier message de Tovo : ce à quoi le client répond', () => {
    expect(messagePourCerveau('Yantala.', { avant: 'Où le livreur doit-il récupérer le colis ?' }))
      .toBe('Dernier message de Tovo : « Où le livreur doit-il récupérer le colis ? »\nMessage du client : « Yantala. »');
    expect(messagePourCerveau('du riz')).toBe('du riz');
  });

  it('lit la réponse du modèle, et rejette une intention inventée', () => {
    expect(lireDecision('{"intention":"colis","sur":false}')).toEqual({ intention: 'colis', sur: false });
    expect(lireDecision('```json\n{"intention":"suivi"}\n```')).toEqual({ intention: 'suivi', sur: true });
    expect(lireDecision('{"intention":"pizza"}')).toBeNull();
    expect(lireDecision('Here is the JSON requested:')).toBeNull();
  });

  it('lit le réglage « modèle:réflexion »', () => {
    expect(lireReglage('gemini-3.1-flash-lite:aucune')).toEqual(['gemini-3.1-flash-lite', 'aucune']);
    expect(lireReglage('gemini-3.8-flash')).toEqual(['gemini-3.8-flash', 'low']);
  });
});

describe('la route décidée par le cerveau', () => {
  const decision = (intention: Intention | null, sur: boolean) =>
    ({ intention, sur, modele: 'm', ms: 800, relance: false, erreurs: [] });

  it('sûr : sa route', () => {
    expect(routeDuCerveau(decision('livreur', true), 'Je veux un livreur'))
      .toMatchObject({ type: 'intention', intention: 'livreur' });
  });

  it('pas sûr sur une ACTION : des tuiles, avec l’autre lecture et « Autre chose »', () => {
    const route = routeDuCerveau(decision('annuler', false), 'Annule le coca');
    expect(route.type).toBe('clarifier');
    const tuiles = route.type === 'clarifier' ? (route.components[0]!.data.items as Array<{ label: string }>) : [];
    expect(tuiles.map((t) => t.label)).toEqual(['Annuler ma commande', 'Choisir parmi ce que je vois', 'Autre chose']);
  });

  it('pas sûr sur une recherche : rien à confirmer, la recherche montre déjà', () => {
    expect(routeDuCerveau(decision('recherche', false), 'Montre'))
      .toMatchObject({ type: 'intention', intention: 'recherche' });
  });

  it('pas de décision : le chemin habituel', () => {
    expect(routeDuCerveau(decision(null, false), 'bonjour')).toMatchObject({ type: 'habituel' });
  });
});
