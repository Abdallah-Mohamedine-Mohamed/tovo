import { describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';

// Base simulée : ces routes ne doivent jamais être éprouvées contre la vraie
// base (les tests d'intégration y écrivent).
vi.mock('../../src/services/dispatch.js', () => ({ queueDispatch: vi.fn() }));
vi.mock('../../src/services/payments.js', () => ({ ouvrirPaiement: vi.fn() }));

import { cartRoutes } from '../../src/routes/cart.js';
import { orderRoutes } from '../../src/routes/orders.js';

const COMMANDE = '11111111-1111-4111-8111-111111111111';

interface FausseBase {
  rpc: ReturnType<typeof vi.fn>;
  from: ReturnType<typeof vi.fn>;
  journal: string[];
}

function fausseBase(reorder: { data?: unknown; error?: { code: string; message: string } }): FausseBase {
  const journal: string[] = [];
  const rpc = vi.fn(async (nom: string) => {
    journal.push(`rpc:${nom}`);
    if (nom === 'reorder_into_cart') return { data: reorder.data ?? null, error: reorder.error ?? null };
    if (nom === 'cart_view') {
      return { data: { cart_id: 'c1', items: [{ id: 'i1', name: 'Tacos poulet', quantity: 2 }], total: 4500 }, error: null };
    }
    return { data: null, error: null };
  });
  const from = vi.fn((table: string) => ({
    delete: () => ({
      eq: async () => {
        journal.push(`delete:${table}`);
        return { error: null };
      },
    }),
  }));
  return { rpc, from, journal };
}

async function appAvec(db: unknown) {
  const app = Fastify();
  app.decorate('requireAuth', async (request: { user?: unknown; supabase?: unknown }) => {
    request.user = { id: 'client-1' };
    request.supabase = db;
  });
  await app.register(cartRoutes);
  await app.register(orderRoutes);
  return app;
}

describe('POST /cart/reorder — recommander depuis l’accueil, sans modèle', () => {
  it('remet la commande au panier et renvoie le panier', async () => {
    const db = fausseBase({ data: { repris: 2, ignores: [] } });
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/cart/reorder', payload: { order_id: COMMANDE } });
    expect(res.statusCode).toBe(200);
    expect(res.json().content).toBe('C’est dans votre panier, aux prix du jour.');
    expect(res.json().components[0].type).toBe('cart_summary');
    expect(db.rpc).toHaveBeenCalledWith('reorder_into_cart', { p_order_id: COMMANDE });
    await app.close();
  });

  it('nomme les articles devenus indisponibles au lieu de les taire', async () => {
    const app = await appAvec(fausseBase({ data: { repris: 1, ignores: ['Jus de bissap'] } }));
    const res = await app.inject({ method: 'POST', url: '/cart/reorder', payload: { order_id: COMMANDE } });
    expect(res.json().content).toContain('Plus disponible : Jus de bissap.');
    await app.close();
  });

  it('en cas de conflit de boutique, propose « Vider et recommander » sur CETTE commande', async () => {
    const app = await appAvec(fausseBase({
      error: { code: 'P0003', message: 'Votre panier contient des articles d’une autre boutique.' },
    }));
    const res = await app.inject({ method: 'POST', url: '/cart/reorder', payload: { order_id: COMMANDE } });
    expect(res.statusCode).toBe(409);
    const corps = res.json();
    // L'application lit `error` sur un statut ≥ 400.
    expect(corps.error).toContain('autre boutique');
    expect(corps.components[0].data.items).toEqual([
      { label: 'Vider et recommander', value: `vider_et_recommander:${COMMANDE}` },
      { label: 'Garder mon panier', value: 'garder_panier' },
    ]);
    await app.close();
  });

  it('avec vider, vide le panier AVANT de recommander', async () => {
    const db = fausseBase({ data: { repris: 2, ignores: [] } });
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/cart/reorder', payload: { order_id: COMMANDE, vider: true } });
    expect(res.statusCode).toBe(200);
    expect(db.journal.slice(0, 2)).toEqual(['delete:carts', 'rpc:reorder_into_cart']);
    await app.close();
  });

  it('refuse un identifiant qui n’est pas un uuid', async () => {
    const db = fausseBase({});
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/cart/reorder', payload: { order_id: 'pas-un-id' } });
    expect(res.statusCode).toBe(400);
    expect(db.rpc).not.toHaveBeenCalled();
    await app.close();
  });
});

describe('GET /orders — de quoi composer la carte « Recommander »', () => {
  it('ajoute la boutique et les articles sans changer les champs existants', async () => {
    const ligne = {
      id: COMMANDE, type: 'food', status: 'delivered', total: 4500,
      placed_at: '2026-09-20T12:00:00Z', delivered_at: '2026-09-20T12:40:00Z', merchant_id: 'm1',
      merchants: { name: 'Otakoss' },
      order_items: [{ product_name: 'Tacos poulet', quantity: 2 }],
    };
    const requete = { select: () => requete, order: () => requete, limit: async () => ({ data: [ligne], error: null }) };
    const app = await appAvec({ rpc: vi.fn(), from: vi.fn(() => requete) });
    const res = await app.inject({ method: 'GET', url: '/orders?limit=5' });
    expect(res.statusCode).toBe(200);
    expect(res.json().orders[0]).toEqual({
      id: COMMANDE, type: 'food', status: 'delivered', total: 4500,
      placed_at: '2026-09-20T12:00:00Z', delivered_at: '2026-09-20T12:40:00Z', merchant_id: 'm1',
      merchant_name: 'Otakoss',
      articles: [{ nom: 'Tacos poulet', quantite: 2 }],
    });
    await app.close();
  });
});
