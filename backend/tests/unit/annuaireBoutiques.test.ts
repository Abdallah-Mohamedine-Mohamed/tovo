import { describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';

const lignes = [
  { id: 'a', name: "O'TAKOSS", description: null, logo_url: null, address_hint: 'Centre', is_open: true, rating: 4.8, prep_time_min: 20 },
  { id: 'b', name: 'GARBA D’OR', description: null, logo_url: null, address_hint: 'Plateau', is_open: false, rating: 4.5, prep_time_min: 15 },
];
// Deux catégories de l'accueil ; « Burgers » est une sous-catégorie de
// Restaurants.
const categoriesAccueil = [
  { id: 'resto', name: 'Restaurants', slug: 'restaurants-m3' },
  { id: 'marche', name: 'Marché', slug: 'kasuwa-m10' },
];
const arbre = [
  { id: 'resto', parent_id: null },
  { id: 'marche', parent_id: null },
  { id: 'burgers', parent_id: 'resto' },
];
const produits = [
  { merchant_id: 'a', category_id: 'burgers' },
  { merchant_id: 'b', category_id: 'marche' },
  { merchant_id: 'b', category_id: 'resto' },
];

// Chaque table rend ses lignes ; les produits, une seule page.
const chaine = (donnees: unknown, page = 0): unknown => new Proxy(() => undefined, {
  get: (_c, prop) => {
    if (prop === 'then') return (ok: (v: unknown) => void) => ok({ data: page > 0 ? [] : donnees, error: null });
    if (prop === 'range') return (debut: number) => chaine(donnees, debut);
    return () => chaine(donnees, page);
  },
});
const table = (nom: string) => chaine(
  nom === 'categories' ? arbre : nom === 'products' ? produits : lignes,
);
const client = () => ({
  from: table,
  rpc: (nom: string) => chaine(nom === 'browsable_categories' ? categoriesAccueil : []),
});
// vi.mock est remonté en tête de fichier : on n'y lit `client` qu'à l'appel.
vi.mock('../../src/services/supabase.js', () => ({
  anonClient: () => client(),
  serviceClient: () => client(),
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
  it('renvoie toutes les boutiques, ouvertes d’abord, avec les catégories en filtres', async () => {
    const app = Fastify();
    await app.register(catalogRoutes);
    const res = await app.inject({ method: 'GET', url: '/boutiques' });
    expect(res.statusCode).toBe(200);
    const corps = res.json();
    expect(corps.mode).toBe('merchants');
    expect(corps.category.name).toBe('Toutes les boutiques');
    expect(corps.merchants.map((m: { name: string }) => m.name)).toEqual(["O'TAKOSS", 'GARBA D’OR']);
    expect(corps.merchants[0]).toHaveProperty('cover_url');
    // Un burger range O'TAKOSS dans Restaurants (par sa sous-catégorie).
    expect(corps.merchants[0].rayons).toEqual(['Restaurants']);
    expect(corps.merchants[1].rayons.sort()).toEqual(['Marché', 'Restaurants']);
    // Les filtres, dans l'ordre de l'accueil, avec leur slug (l'icône).
    expect(corps.rayons).toEqual([
      { name: 'Restaurants', slug: 'restaurants-m3', boutiques: 2 },
      { name: 'Marché', slug: 'kasuwa-m10', boutiques: 1 },
    ]);
    await app.close();
  });
});
