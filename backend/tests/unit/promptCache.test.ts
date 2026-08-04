import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cacheDuPrompt, oublierCache, reinitialiserCache } from '../../src/ai/promptCache.js';
import type { LlmToolDefinition } from '../../src/ai/llmClient.js';

/**
 * Le cycle de vie du cache de prompt.
 *
 * Ce cache économise 1 973 jetons par requête, mais mal géré il coûte plus
 * qu'il ne rapporte : une création à chaque tour, c'est un aller-retour de
 * plus sur le chemin de la réponse au client, et des heures de stockage
 * facturées pour des caches jamais réutilisés.
 *
 * Ces tests ne touchent pas au réseau : `fetch` est remplacé, ce qui permet
 * de vérifier exactement combien de créations ont lieu.
 */

const OUTILS: LlmToolDefinition[] = [
  { name: 'rechercher_produits', description: 'Cherche', parameters: { type: 'object' } },
];

let creations = 0;
let reponse: () => { ok: boolean; corps: Record<string, unknown> };

function creationReussie(nom = 'cachedContents/abc') {
  return () => ({
    ok: true,
    corps: { name: nom, expireTime: new Date(Date.now() + 3_600_000).toISOString() },
  });
}

beforeEach(() => {
  reinitialiserCache();
  creations = 0;
  reponse = creationReussie();

  vi.stubGlobal('fetch', async () => {
    creations++;
    const r = reponse();
    return {
      ok: r.ok,
      json: async () => r.corps,
    } as Response;
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('Cache de prompt', () => {
  it('ne crée le cache qu’une fois pour un préfixe identique', async () => {
    const a = await cacheDuPrompt('prompt', OUTILS, 'gemini-3.5-flash-lite');
    const b = await cacheDuPrompt('prompt', OUTILS, 'gemini-3.5-flash-lite');

    expect(a).toBe('cachedContents/abc');
    expect(b).toBe(a);
    expect(creations).toBe(1);
  });

  it('dix requêtes simultanées n’en créent qu’un', async () => {
    // Au coup de feu du soir, dix clients écrivent en même temps. Sans
    // regroupement, chacun créerait son cache — dix fois le coût, et neuf
    // caches aussitôt abandonnés.
    const resultats = await Promise.all(
      Array.from({ length: 10 }, () => cacheDuPrompt('prompt', OUTILS, 'modele')),
    );

    expect(new Set(resultats).size).toBe(1);
    expect(creations).toBe(1);
  });

  it('garde un cache par variante, sans qu’elles se chassent', async () => {
    // L'orchestrateur retire les outils au dernier cycle pour forcer le
    // modèle à conclure. Avec un emplacement unique, les deux variantes se
    // remplaceraient l'une l'autre à chaque tour : plus d'appels qu'avant
    // la mise en cache, et aucun gain.
    await cacheDuPrompt('prompt', OUTILS, 'modele');
    await cacheDuPrompt('prompt', [], 'modele');
    expect(creations).toBe(2);

    // Et l'on revient sur la première sans rien recréer.
    await cacheDuPrompt('prompt', OUTILS, 'modele');
    expect(creations).toBe(2);
  });

  it('repart d’un cache neuf quand le prompt change', async () => {
    // Un déploiement qui modifie une consigne doit prendre effet tout de
    // suite. Réutiliser l'ancien cache ferait obéir le modèle à la version
    // précédente pendant une heure — un décalage invisible.
    await cacheDuPrompt('prompt v1', OUTILS, 'modele');
    await cacheDuPrompt('prompt v2', OUTILS, 'modele');
    expect(creations).toBe(2);
  });

  it('repart d’un cache neuf quand le modèle change', async () => {
    await cacheDuPrompt('prompt', OUTILS, 'gemini-3.5-flash-lite');
    await cacheDuPrompt('prompt', OUTILS, 'gemini-3.5-pro');
    expect(creations).toBe(2);
  });

  it('n’insiste pas après un refus', async () => {
    // Gemini refuse les préfixes trop courts. Sans mémoire de l'échec,
    // chaque requête retenterait et ajouterait un aller-retour perdu avant
    // de répondre au client.
    reponse = () => ({ ok: false, corps: {} });

    expect(await cacheDuPrompt('court', OUTILS, 'modele')).toBeNull();
    expect(await cacheDuPrompt('court', OUTILS, 'modele')).toBeNull();
    expect(await cacheDuPrompt('court', OUTILS, 'modele')).toBeNull();

    expect(creations).toBe(1);
  });

  it('ne rend jamais un cache sur le point d’expirer', async () => {
    // Un cache utilisé à la seconde où il meurt fait échouer la requête.
    reponse = () => ({
      ok: true,
      corps: {
        name: 'cachedContents/presque-mort',
        expireTime: new Date(Date.now() + 30_000).toISOString(),
      },
    });

    expect(await cacheDuPrompt('prompt', OUTILS, 'modele')).toBeNull();
  });

  it('oublie un cache que Gemini vient de refuser', async () => {
    const nom = await cacheDuPrompt('prompt', OUTILS, 'modele');
    expect(nom).toBe('cachedContents/abc');

    // Un cache peut disparaître de leur côté avant l'heure annoncée.
    oublierCache(nom!);
    reponse = creationReussie('cachedContents/def');

    expect(await cacheDuPrompt('prompt', OUTILS, 'modele')).toBe('cachedContents/def');
    expect(creations).toBe(2);
  });
});
