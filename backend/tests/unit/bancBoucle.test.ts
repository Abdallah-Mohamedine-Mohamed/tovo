import { describe, expect, it } from 'vitest';
import {
  SCENARIOS,
  cleDe,
  demandeEcrivain,
  ecrirePhrases,
  etiqueterALAveugle,
  lirePhrasesEcrites,
  memeSens,
  scenariosDuPassage,
} from '../../src/ai/banc/boucle.js';
import type { ModeleFort } from '../../src/ai/banc/modelesForts.js';

const contexte = { boutiques: ['Otakoss'], produits: ['Tacos poulet'], quartiers: ['Yantala'], dejaVues: ['Je veux un livreur'] };

describe('la boucle du banc', () => {
  it('garde les phrases bien formées, jette le reste', () => {
    const phrases = lirePhrasesEcrites({
      phrases: [
        { texte: ' Ina son abinci ', intention: 'envie', note: 'haoussa' },
        { texte: 'le premier la', intention: 'designe', avant: 'Lequel voulez-vous ?' },
        { texte: 'x', intention: 'inconnue' },
        { texte: '', intention: 'recherche' },
        { texte: 'hmm', intention: 'ambigu' },
      ],
    });
    expect(phrases).toEqual([
      { texte: 'Ina son abinci', intention: 'envie', avant: null, note: 'haoussa' },
      { texte: 'le premier la', intention: 'designe', avant: 'Lequel voulez-vous ?' },
    ]);
    expect(lirePhrasesEcrites('pas du json')).toEqual([]);
  });

  it('livreur et colis : la même course, donc pas un désaccord', () => {
    expect(memeSens('livreur', 'colis')).toBe(true);
    expect(memeSens('recherche', 'envie')).toBe(false);
    expect(memeSens('ambigu', 'ambigu')).toBe(false);
    expect(memeSens(null, 'social')).toBe(false);
  });

  it('une même phrase, au même contexte, n’entre qu’une fois', () => {
    expect(cleDe('Je veux un LIVREUR !')).toBe(cleDe('je veux un livreur'));
    expect(cleDe('Oui', 'Voulez-vous annuler ?')).not.toBe(cleDe('Oui', 'Un livreur ?'));
  });

  it('les scénarios tournent d’heure en heure : tous reviennent', () => {
    const vus = new Set<string>();
    for (let h = 0; h < 24; h++) {
      for (const s of scenariosDuPassage(new Date(Date.UTC(2026, 8, 26, h)), 2)) vus.add(s.cle);
    }
    expect(vus.size).toBe(SCENARIOS.length);
  });

  it('l’écrivain reçoit le métier réel et ce qu’il ne doit pas recopier', () => {
    const demande = demandeEcrivain(SCENARIOS[0]!, 12, contexte);
    expect(demande).toContain('Otakoss');
    expect(demande).toContain('Tacos poulet');
    expect(demande).toContain('« Je veux un livreur »');
  });

  it('le juge ne voit jamais l’étiquette de l’écrivain', async () => {
    const vu: string[] = [];
    const leJuge: ModeleFort = {
      nom: 'faux-juge',
      json: async (_s, demande) => {
        vu.push(demande);
        return { etiquettes: [{ id: 0, intention: 'social' }, { id: 1, intention: 'colis' }] };
      },
    };
    const ecrivain: ModeleFort = {
      nom: 'faux-ecrivain',
      json: async () => ({ phrases: [
        { texte: 'Je veux devenir livreur', intention: 'social' },
        { texte: 'Envoie ce sac à Lazaret', intention: 'colis' },
      ] }),
    };
    const ecrites = await ecrirePhrases(ecrivain, SCENARIOS[0]!, 2, contexte);
    const etiquettes = await etiqueterALAveugle(leJuge, ecrites);
    expect(etiquettes).toEqual(['social', 'colis']);
    // Les phrases envoyées au juge : texte et contexte, sans étiquette.
    const envoyees = JSON.parse(vu[0]!.split('\n')[1]!) as Array<Record<string, unknown>>;
    expect(envoyees).toEqual([
      { id: 0, avant: null, texte: 'Je veux devenir livreur' },
      { id: 1, avant: null, texte: 'Envoie ce sac à Lazaret' },
    ]);
  });
});
