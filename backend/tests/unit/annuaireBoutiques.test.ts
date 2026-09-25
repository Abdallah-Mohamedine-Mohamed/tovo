import { describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';

const lignes = [
  { id: 'a', name: "O'TAKOSS", description: null, logo_url: null, address_hint: 'Centre', is_open: true, rating: 4.8, prep_time_min: 20 },
  { id: 'b', name: 'GARBA D’OR', description: null, logo_url: null, address_hint: 'Plateau', is_open: false, rating: 4.5, prep_time_min: 15 },
];
const chaine = (): unknown => new Proxy(() => undefined, {
  get: (_c, prop) => (prop === 'then'
    ? (ok: (v: unknown) => void) => ok({ data: lignes, error: null })
    : () => chaine()),
});
vi.mock('../../src/services/supabase.js', () => ({
  anonClient: () => ({ from: () => chaine() }),
  serviceClient: () => ({ from: () => chaine() }),
}));

import { catalogRoutes } from '../../src/routes/catalog.js';

describe('GET /merchants — « Explorer les boutiques »', () => {
  it('renvoie des BOUTIQUES, pas des produits', async () => {
    const app = Fastify();
    await app.register(catalogRoutes);
    const res = await app.inject({ method: 'GET', url: '/merchants' });
    expect(res.statusCode).toBe(200);
    const types = (res.json().components as Array<{ type: string }>).map((c) => c.type);
    expect(types).toEqual(['merchant_card', 'merchant_card']);
    expect(res.json().content).toBe('1 boutique ouverte en ce moment');
    await app.close();
  });
});

describe('GET /boutiques — « Explorer » au format de la page catégorie', () => {
  it('renvoie toutes les boutiques, ouvertes d’abord, sans redirection', async () => {
    const app = Fastify();
    await app.register(catalogRoutes);
    const res = await app.inject({ method: 'GET', url: '/boutiques' });
    expect(res.statusCode).toBe(200);
    const corps = res.json();
    expect(corps.mode).toBe('merchants');
    expect(corps.category.name).toBe('Toutes les boutiques');
    expect(corps.merchants.map((m: { name: string }) => m.name)).toEqual(["O'TAKOSS", 'GARBA D’OR']);
    expect(corps.merchants[0]).toHaveProperty('cover_url');
    await app.close();
  });
});
