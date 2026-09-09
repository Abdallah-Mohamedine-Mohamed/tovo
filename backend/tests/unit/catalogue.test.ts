import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';
import { vector } from '@electric-sql/pglite-pgvector';
import type { SupabaseClient } from '@supabase/supabase-js';
import Fastify from 'fastify';
import { cataloguePage, resolveCatalogueIntent, merchantIntentAnswer, requeteSansEnseigne, type CataloguePage } from '../../src/services/catalogue.js';
import { catalogRoutes } from '../../src/routes/catalog.js';
import { EXECUTORS } from '../../src/ai/tools.js';
import { orchestrate } from '../../src/ai/orchestrator.js';

vi.mock('../../src/services/embeddings.js', () => ({ embeddingsEnabled: false, embed: vi.fn(), embedImage: vi.fn() }));
vi.mock('../../src/services/supabase.js', () => ({ anonClient: () => adapter, serviceClient: () => adapter }));
vi.mock('../../src/ai/llmClient.js', () => ({
  llmClient: () => { throw new Error('Cette demande de catalogue ne nécessite pas le modèle'); },
  LlmUnavailableError: class extends Error {},
}));

const database = new PGlite({ extensions: { vector } });
const centre = randomUUID();
const marche = randomUUID();
const garba = randomUUID();
const pouletShop = randomUUID();
const hidden = randomUUID();
const root = randomUUID();
const category = randomUUID();
const boissons = randomUUID();
const merchants = [
  { id: centre, name: "O'TAKOSS ( Centre Aéré )", is_approved: true, is_open: true },
  { id: marche, name: "O'TAKOSS ( Nouveau Marché )", is_approved: true, is_open: false },
  { id: garba, name: "GARBA D'OR", is_approved: true, is_open: true },
  { id: pouletShop, name: 'POULET', is_approved: true, is_open: true },
  { id: hidden, name: 'Invisible', is_approved: false, is_open: true },
];
const messages: Array<Record<string, unknown>> = [];

const adapter = {
  from(table: string) {
    const conditions: Array<[string, unknown]> = [];
    if (table === 'product_options') return { select: () => ({ in: async () => ({ data: [], error: null }) }) };
    if (table === 'messages') {
      const builder = {
        select() { return builder; },
        eq(key: string, value: unknown) { conditions.push([key, value]); return builder; },
        in() { return builder; },
        order() { return builder; },
        async limit(count: number) {
          return { data: messages.filter((message) => conditions.every(([key, value]) => message[key] === value)).reverse().slice(0, count), error: null };
        },
        insert(message: Record<string, unknown>) {
          const data = { ...message, id: randomUUID() };
          messages.push(data);
          return { select: () => ({ single: async () => ({ data, error: null }) }) };
        },
      };
      return builder;
    }
    const getRows = async () => {
      const result = await database.query<Record<string, unknown>>(`select * from ${table === 'merchants' ? 'merchants' : 'categories'}`);
      return result.rows.filter((row) => conditions.every(([key, value]) => row[key] === value));
    };
    const builder = {
      select() { return builder; }, eq(key: string, value: unknown) { conditions.push([key, value]); return builder; },
      order() { return builder; },
      async range(start: number, end: number) { return { data: (await getRows()).slice(start, end + 1), error: null }; },
      async maybeSingle() { return { data: (await getRows())[0] ?? null, error: null }; },
    };
    return builder;
  },
  async rpc(name: string, args: Record<string, unknown>) {
    if (name === 'catalog_products_page') {
      const result = await database.query<{ page: CataloguePage }>(
        'select catalog_products_page($1, $2, $3, $4, $5, $6) as page',
        [args.p_query, args.p_embedding, args.p_merchants, args.p_category, args.p_offset, args.p_limit]);
      return { data: result.rows[0]!.page, error: null };
    }
    if (name === 'merchant_categories') {
      const result = await database.query('select category.id, category.name, null as icon, null as image_url, count(*)::int as produits from products product join categories category on category.id = product.category_id where product.merchant_id = $1 and product.is_available group by category.id, category.name order by category.name', [args.p_merchant_id]);
      return { data: result.rows, error: null };
    }
    if (name === 'merchant_open_now') return { data: merchants.find((merchant) => merchant.id === args.p_merchant_id)?.is_open, error: null };
    throw new Error(`Unexpected RPC: ${name}`);
  },
} as unknown as SupabaseClient;

const app = Fastify();

beforeAll(async () => {
  await database.exec(readFileSync('tests/fixtures/catalogue.sql', 'utf8'));
  const migration = readFileSync('../supabase/migrations/0050_catalogue_pagine.sql', 'utf8');
  await database.exec(migration);
  await database.exec(migration);
  for (const merchant of merchants) await database.query('insert into merchants values ($1,$2,$3,$4)', [merchant.id, merchant.name, merchant.is_approved, merchant.is_open]);
  await database.query('insert into categories values ($1,$2,null,$3),($4,$5,$1,null),($6,$7,$1,null)', [root, 'Restaurants', 'restaurants-m3', category, 'Plats', boissons, 'Boissons']);
  for (let index = 0; index < 75; index++) await database.query(
    'insert into products(id,merchant_id,category_id,name,price) values ($1,$2,$3,$4,2500)',
    [randomUUID(), index % 2 === 0 ? centre : marche, category, `Poulet ${String(index).padStart(2, '0')}`]);
  for (const name of ['Garba', 'Attiéké', 'Poisson', 'Alloco', 'Attiéké poulet', 'Jus']) await database.query(
    'insert into products(id,merchant_id,category_id,name,price) values ($1,$2,$3,$4,2500)', [randomUUID(), garba, category, name]);
  for (const [name, merchant, section, available, options] of [
    ['Soda', centre, boissons, true, null], ['Tacos XL', centre, category, true, 'Boulette Poulet'],
    ['Pizza', marche, category, true, 'Boulette Poulet'], ['Poulet caché', hidden, category, true, null],
    ['Poulet épuisé', centre, category, false, null], ['Suggestion', garba, category, true, null],
  ]) await database.query('insert into products(id,merchant_id,category_id,name,price,is_available,options_text) values ($1,$2,$3,$4,2000,$5,$6)',
    [randomUUID(), merchant, section, name, available, options]);
  await app.register(catalogRoutes);
});

afterAll(async () => { await app.close(); await database.close(); });

describe('catalogue complet', () => {
  it('parcourt toutes les pages de poulet sans doublon ni plafond de 8 ou 60', async () => {
    const ids: string[] = [];
    let offset = 0;
    for (;;) {
      const page = await cataloguePage(adapter, { q: 'poulet', offset, limit: 24 });
      expect(page.total).toBe(78);
      ids.push(...page.items.map((product) => product.id));
      if (page.next_offset === null) break;
      offset = page.next_offset;
    }
    expect(ids.length).toBe(78);
    expect(new Set(ids).size).toBe(78);
  });

  it('retourne un total même après la dernière page et respecte les catégories', async () => {
    expect(await cataloguePage(adapter, { q: 'poulet', offset: 999 })).toMatchObject({ total: 78, items: [], next_offset: null });
    expect((await cataloguePage(adapter, { merchant_ids: [centre], category_id: boissons })).items.map((product) => product.name)).toEqual(['Soda']);
    expect((await cataloguePage(adapter, { q: 'poulets', category_id: root })).total).toBe(78);
  });

  it('conserve les boutiques fermées et exclut les produits indisponibles ou non approuvés', async () => {
    const page = await cataloguePage(adapter, { merchant_ids: [marche] });
    expect(page.total).toBeGreaterThan(8);
    expect(page.items.every((product) => product.merchant_open === false)).toBe(true);
    expect((await cataloguePage(adapter, { merchant_ids: [hidden] })).total).toBe(0);
  });

  it('honore tous les termes, accents et options sans pizza pour tacos boulettes', async () => {
    const page = await cataloguePage(adapter, { q: 'tacos aux boulettes' });
    expect(page.items.map((product) => product.name)).toEqual(['Tacos XL']);
    expect(page.items[0]?.requires_options).toBe(true);
    expect((await cataloguePage(adapter, { q: 'attieke poulet' })).items.map((product) => product.name)).toEqual(['Attiéké poulet']);
  });

  it.each(['Je veux manger chez Otakoss', 'Je peux voir la carte de Otakoss', 'Je voudrais commander chez Otakoss'])('ouvre une carte pour %s', async (message) => {
    const intent = await resolveCatalogueIntent(adapter, message);
    expect(intent.menu).toBe(true);
    expect(intent.merchants.map((merchant) => merchant.id).sort()).toEqual([centre, marche].sort());
  });

  it('préserve une enseigne comprise dans un message vocal', async () => {
    const answer = await EXECUTORS.rechercher_produits!({ requete: 'tacos poulet', boutique: 'Otakoss' }, { db: adapter, userId: randomUUID() });
    expect(answer.components.map((component) => component.data.id).sort()).toEqual([centre, marche].sort());
    expect(answer.components.every((component) => component.data.pending_query === 'tacos poulet')).toBe(true);
  });

  it('traite poulet et garba comme des produits malgré les noms des enseignes', async () => {
    expect((await resolveCatalogueIntent(adapter, 'Poulet')).merchants).toEqual([]);
    expect((await resolveCatalogueIntent(adapter, 'Je veux manger du poulet')).merchants).toEqual([]);
    expect((await resolveCatalogueIntent(adapter, 'Garba')).merchants).toEqual([]);
    expect((await resolveCatalogueIntent(adapter, 'chez Poulet')).merchants.map((merchant) => merchant.id)).toEqual([pouletShop]);
  });

  it.each(['Otakoss', "O'TAKOSS", 'otakos'])('ne propose que les deux agences pour %s', async (message) => {
    const intent = await resolveCatalogueIntent(adapter, message);
    const answer = await merchantIntentAnswer(adapter, intent);
    expect(answer?.components.map((component) => component.data.id).sort()).toEqual([centre, marche].sort());
  });

  it('ouvre les catégories de toute la carte, même si le modèle demande tacos', async () => {
    const context = { db: adapter, userId: randomUUID(), currentMessage: 'Otakoss centre aéré' };
    for (const name of ['rechercher_produits', 'lister_categories', 'lister_restaurants', 'boutiques_proches', 'produits_de_boutique']) {
      const result = await EXECUTORS[name]!({ requete: 'tacos', merchant_id: marche }, context);
      const sections = result.components.find((component) => component.type === 'category_grid');
      expect(sections).toBeDefined();
      expect(JSON.stringify(sections)).toContain('Boissons');
      expect(JSON.stringify(result.components)).not.toContain(marche);
    }
  });

  it('distingue carte complète et produit dans une enseigne', () => {
    expect(requeteSansEnseigne('Otakoss centre aéré', merchants)).toBe('');
    expect(requeteSansEnseigne("Montre la carte de Garba d'or", merchants)).toBe('');
    expect(requeteSansEnseigne('tacos poulet chez otakoss', merchants)).toBe('tacos poulet');
  });

  it('une enseigne absente ne déclenche pas une liste générale', async () => {
    const answer = await merchantIntentAnswer(adapter, await resolveCatalogueIntent(adapter, 'tacos chez ZZZZZ'));
    expect(answer?.components).toEqual([]);
    expect(answer?.summary).toHaveProperty('boutique_introuvable');
  });

  it('un mauvais outil ne transforme pas le produit demandé en carte générale', async () => {
    const answer = await EXECUTORS.produits_de_boutique!({ merchant_id: marche }, {
      db: adapter, userId: randomUUID(), currentMessage: 'tacos poulet chez Otakoss centre aéré',
    });
    const products = answer.components.find((component) => component.type === 'product_carousel')?.data.items as Array<Record<string, unknown>>;
    expect(products).toHaveLength(1);
    expect(products[0]).toMatchObject({ name: 'Tacos XL', merchant_id: centre, requires_options: true });
  });

  it('enchaîne poulet, enseigne et agence sans confondre la recherche précédente avec la carte', async () => {
    const conversationId = randomUUID();
    const send = (message: string) => orchestrate({ db: adapter, userId: randomUUID(), conversationId, clientMessageId: randomUUID(), message });
    expect((await send('Poulet')).content).toContain('78');
    const choice = await send('Otakoss');
    expect(choice.components.map((component) => component.data.id).sort()).toEqual([centre, marche].sort());
    const menu = await send('Centre aéré');
    expect(menu.components.find((component) => component.type === 'merchant_card')?.data).toMatchObject({ id: centre, total_products: 40 });
    expect(menu.usage.cycles).toBe(0);
    expect(messages.filter((message) => message.conversation_id === conversationId)).toHaveLength(6);
  });

  it('conserve tacos poulet lorsque le client choisit « le premier »', async () => {
    const conversationId = randomUUID();
    const send = (message: string) => orchestrate({ db: adapter, userId: randomUUID(), conversationId, clientMessageId: randomUUID(), message });
    const choices = await send('tacos poulet chez Otakoss');
    expect(choices.components[0]?.data.id).toBe(centre);
    const answer = await send('le premier');
    expect(answer.components[0]?.data.browse).toMatchObject({ query: 'tacos poulet', merchant_ids: [centre], total: 1 });
    expect(answer.usage.cycles).toBe(0);
  });

  it('comprend une réponse courte au choix des agences en conservant le produit demandé', async () => {
    const pending = { merchant_ids: [centre, marche], query: 'tacos poulet' };
    const intent = await resolveCatalogueIntent(adapter, 'Centre aéré', pending);
    expect(intent.merchants.map((merchant) => merchant.id)).toEqual([centre]);
    expect(intent.query).toBe('tacos poulet');
    expect(intent.menu).toBe(false);
    expect((await resolveCatalogueIntent(adapter, 'poulet', pending)).merchants).toEqual([]);
  });

  it('expose un aperçu honnête et un accès au catalogue par HTTP', async () => {
    const response = await app.inject('/search?q=poulet');
    expect(response.statusCode).toBe(200);
    expect(response.json().content).toContain('78');
    expect(response.json().components[0].data.items).toHaveLength(8);
    expect(response.json().components[0].data.browse).toMatchObject({ query: 'poulet', total: 78 });
    const next = await app.inject('/catalog/products?q=poulet&offset=24&limit=24');
    expect(next.json()).toMatchObject({ total: 78, offset: 24, next_offset: 48 });
    expect(next.json().items).toHaveLength(24);
    expect((await app.inject('/catalog/products?offset=-1')).statusCode).toBe(400);
    expect((await app.inject('/catalog/products?merchant_ids=invalid')).statusCode).toBe(400);
  });
});
