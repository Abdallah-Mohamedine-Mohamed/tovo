import { describe, expect, it, vi } from 'vitest';

const embed = vi.hoisted(() => vi.fn(async () => Array(1536).fill(0.1)));
vi.mock('../../src/services/embeddings.js', async (original) => ({
  ...(await original<typeof import('../../src/services/embeddings.js')>()),
  embed,
  embedImage: vi.fn(),
}));

// Un produit renommé reçoit sa fiche de recherche (IA) : simulée ici.
const redigerFiche = vi.hoisted(() => vi.fn(async () => ({ description: 'Attiéké au poulet.', etiquettes: ['attieke'] })));
vi.mock('../../src/services/ficheRecherche.js', async (original) => ({
  ...(await original<typeof import('../../src/services/ficheRecherche.js')>()),
  redigerFiche,
}));

const PRODUIT = { id: '77777777-7777-4777-8777-777777777777', name: 'Attiéké poulet', description: 'Semoule de manioc', image_description: null, tags: null };
const base = vi.hoisted(() => ({ tags: null as string[] | null, source: null as string | null, ecritures: [] as Array<Record<string, unknown>> }));
vi.mock('../../src/services/supabase.js', () => {
  const chaine = (): unknown => new Proxy(() => undefined, {
    get: (_c, prop) => {
      if (prop === 'then') return (ok: (v: unknown) => void) => ok({ data: base.source === null ? [] : [{ id: PRODUIT.id, embedding_source: base.source }], error: null });
      if (prop === 'update') return (valeurs: Record<string, unknown>) => { base.ecritures.push(valeurs); return chaine(); };
      if (prop === 'select') return (colonnes: string) => (colonnes.startsWith('id, name')
        ? { in: async () => ({ data: [{ ...PRODUIT, tags: base.tags }], error: null }) }
        : chaine());
      return () => chaine();
    },
  });
  return { serviceClient: () => ({ from: () => chaine() }) };
});

import { indexProductsByIds } from '../../src/services/indexer.js';
import { texteIndexable } from '../../src/services/embeddings.js';

describe('indexeur — pas d’embedding recalculé pour rien', () => {
  it('texte inchangé (prix, variantes…) : aucun appel à Google, seule la date bouge', async () => {
    base.source = texteIndexable(PRODUIT);
    base.ecritures = [];
    embed.mockClear();
    redigerFiche.mockClear();
    const r = await indexProductsByIds([PRODUIT.id]);
    expect(embed).not.toHaveBeenCalled();
    expect(redigerFiche).not.toHaveBeenCalled();
    expect(r.indexed).toBe(1);
    expect(base.ecritures[0]).toEqual({ embedded_at: expect.any(String) });
  });

  it('texte modifié : l’embedding est bien recalculé', async () => {
    base.source = 'ancien nom du produit';
    base.ecritures = [];
    embed.mockClear();
    redigerFiche.mockClear();
    await indexProductsByIds([PRODUIT.id]);
    expect(embed).toHaveBeenCalledTimes(1);
    // Renommé : sa fiche est réécrite, mais la description du commerçant reste.
    expect(redigerFiche).toHaveBeenCalledTimes(1);
    expect(base.ecritures[0]).toMatchObject({ description: 'Semoule de manioc', tags: ['attieke'] });
  });

  it('nouveau produit chargé avec ses étiquettes : sa fiche n’est pas réécrite', async () => {
    base.source = null;
    base.tags = ['gel douche'];
    redigerFiche.mockClear();
    await indexProductsByIds([PRODUIT.id]);
    expect(redigerFiche).not.toHaveBeenCalled();
    base.tags = null;
  });

  it('nouveau produit sans étiquettes (ajouté depuis l’app) : il reçoit sa fiche', async () => {
    base.source = null;
    base.tags = null;
    redigerFiche.mockClear();
    await indexProductsByIds([PRODUIT.id]);
    expect(redigerFiche).toHaveBeenCalledTimes(1);
  });
});
