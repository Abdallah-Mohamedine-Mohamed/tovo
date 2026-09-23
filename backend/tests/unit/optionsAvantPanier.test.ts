import { describe, expect, it, vi } from 'vitest';
import { EXECUTORS } from '../../src/ai/tools.js';

const TACOS = '44444444-4444-4444-8444-444444444444';
const OPTION = '55555555-5555-4555-8555-555555555555';
const VALEUR = '66666666-6666-4666-8666-666666666666';

/**
 * Base simulée. `optionnelles` : le tacos bowl n'a QUE des options
 * facultatives — c'est le cas qui passait sans rien demander.
 */
function fausseBase(nbOptions: number) {
  const rpc = vi.fn(async (nom: string) => (nom === 'cart_view'
    ? { data: { cart_id: 'c1', items: [{ id: 'i1', name: 'Tacos Bowl', quantity: 1 }], total: 3500 }, error: null }
    : { data: null, error: null }));
  const resultats: Record<string, unknown> = {
    products: { data: { id: TACOS, name: 'Tacos Bowl', price: 3500, is_available: true, merchant_id: 'm1', merchants: { name: 'Otakoss' } }, error: null },
    product_options: nbOptions === 0
      ? { data: [], count: 0, error: null }
      : {
          count: nbOptions,
          error: null,
          data: [{
            id: OPTION, name: 'Viande', is_required: false, min_select: 0, max_select: 2, sort_order: 1,
            product_option_values: [{ id: VALEUR, name: 'Poulet', price_delta: 0, is_available: true, sort_order: 1 }],
          }],
        },
  };
  const chaine = (table: string): unknown => new Proxy(() => undefined, {
    get: (_c, prop) => prop === 'then'
      ? (ok: (v: unknown) => void) => ok(resultats[table] ?? { data: null, error: null })
      : () => chaine(table),
  });
  return { rpc, from: vi.fn((t: string) => chaine(t)) };
}

const ajouter = EXECUTORS.ajouter_au_panier!;

describe('ajouter_au_panier — jamais sans les options', () => {
  it('tacos bowl à options (même facultatives), sans choix : montre la carte, n’ajoute rien', async () => {
    const db = fausseBase(3);
    const r = await ajouter({ product_id: TACOS, quantite: 1 }, { db, userId: 'u1' } as never);
    expect(db.rpc).not.toHaveBeenCalledWith('cart_add_item', expect.anything());
    expect(r.components.map((c) => c.type)).toContain('option_selector');
    expect(r.summary).toMatchObject({ ajoute: false });
  });

  it('avec les choix du client : ajoute', async () => {
    const db = fausseBase(3);
    await ajouter({ product_id: TACOS, quantite: 1, selections: [{ option_id: OPTION, value_ids: [VALEUR] }] }, { db, userId: 'u1' } as never);
    expect(db.rpc).toHaveBeenCalledWith('cart_add_item', expect.objectContaining({ p_product_id: TACOS }));
  });

  it('produit sans option : ajoute directement', async () => {
    const db = fausseBase(0);
    await ajouter({ product_id: TACOS, quantite: 1 }, { db, userId: 'u1' } as never);
    expect(db.rpc).toHaveBeenCalledWith('cart_add_item', expect.objectContaining({ p_product_id: TACOS }));
  });
});
