import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app.js';
import {
  admin,
  cleanup,
  createUser,
  firstZoneId,
  seedProductWithOptions,
  seedShop,
  type SeededOptions,
  type TestUser,
} from '../rls/harness.js';

/**
 * Le parcours complet par HTTP, sans IA : catégories → produit → options →
 * panier → commande → suivi.
 *
 * Ces routes renvoient déjà les composants du contrat. En Phase 4,
 * l'orchestrateur produira les mêmes ; ces tests continueront de passer.
 * C'est tout l'intérêt d'avoir contractualisé avant de brancher le modèle.
 */
describe('API — parcours de commande', () => {
  let app: FastifyInstance;
  let client: TestUser;
  let boutiquier: TestUser;
  let opts: SeededOptions;
  let categoryId: string;

  const dropoff = { lat: 13.5137, lng: 2.1098 };

  function auth(user: TestUser): Record<string, string> {
    return { authorization: `Bearer ${user.accessToken}` };
  }

  beforeAll(async () => {
    app = await buildApp();
    await app.ready();

    const zoneId = await firstZoneId();
    [client, boutiquier] = await Promise.all([createUser('client'), createUser('merchant')]);

    const shop = await seedShop(boutiquier.id, zoneId);
    opts = await seedProductWithOptions(shop.merchantId);

    const { data: categorie } = await admin
      .from('categories')
      .select('id')
      .eq('slug', 'repas')
      .single();
    categoryId = categorie!.id as string;

    await admin
      .from('products')
      .update({ category_id: categoryId })
      .eq('id', opts.productId);
  }, 60_000);

  afterAll(async () => {
    await app.close();
    await admin.from('carts').delete().eq('user_id', client.id);
    await cleanup();
  });

  it('GET /health annonce la version du contrat', async () => {
    const res = await app.inject({ method: 'GET', url: '/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ status: 'ok', contract: 1 });
  });

  it('GET /categories renvoie un category_grid', async () => {
    const res = await app.inject({ method: 'GET', url: '/categories' });
    expect(res.statusCode).toBe(200);

    const body = res.json();
    expect(body.contract_version).toBe(1);
    expect(body.components[0].type).toBe('category_grid');
    expect(body.components[0].data.items.length).toBeGreaterThan(0);
  });

  it('GET /products/:id renvoie un option_selector quand le produit a des options', async () => {
    const res = await app.inject({ method: 'GET', url: `/products/${opts.productId}` });
    expect(res.statusCode).toBe(200);

    const composant = res.json().components[0];
    expect(composant.type).toBe('option_selector');
    expect(composant.data.base_price).toBe(1500);

    const portion = composant.data.options.find(
      (o: { name: string }) => o.name === 'Portion',
    );
    expect(portion.required).toBe(true);
    expect(portion.values).toHaveLength(2);
  });

  it('le panier exige une authentification', async () => {
    const res = await app.inject({ method: 'GET', url: '/cart' });
    expect(res.statusCode).toBe(401);
  });

  it('POST /cart/items ajoute et renvoie un cart_summary', async () => {
    await admin.from('carts').delete().eq('user_id', client.id);

    const res = await app.inject({
      method: 'POST',
      url: '/cart/items',
      headers: auth(client),
      payload: {
        product_id: opts.productId,
        quantity: 2,
        selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionDouble] }],
        lat: dropoff.lat,
        lng: dropoff.lng,
      },
    });

    expect(res.statusCode).toBe(200);
    const composant = res.json().components[0];
    expect(composant.type).toBe('cart_summary');
    expect(composant.data.items_total).toBe(4400);
    expect(composant.data.delivery_fee).toBe(500);
    expect(composant.data.total).toBe(4900);
    expect(composant.data.checkout_label).toContain('4900');
    expect(composant.data.can_checkout).toBe(true);
  });

  it('une option obligatoire manquante donne un 400, pas un 500', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/cart/items',
      headers: auth(client),
      payload: { product_id: opts.productId, quantity: 1, selections: [] },
    });

    expect(res.statusCode).toBe(400);
    expect(res.json().error).toContain('obligatoire');
  });

  it('un montant envoyé par le client est ignoré', async () => {
    await admin.from('carts').delete().eq('user_id', client.id);

    const res = await app.inject({
      method: 'POST',
      url: '/cart/items',
      headers: auth(client),
      payload: {
        product_id: opts.productId,
        quantity: 1,
        selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionSimple] }],
        // Champs hostiles : ils n'existent dans aucun schéma et ne doivent
        // avoir aucun effet.
        unit_price: 1,
        total: 1,
        price: 1,
      },
    });

    expect(res.statusCode).toBe(200);
    expect(res.json().components[0].data.items_total).toBe(1500);
  });

  it('PATCH puis DELETE mettent le panier à jour', async () => {
    const cart = await app.inject({
      method: 'GET',
      url: `/cart?lat=${dropoff.lat}&lng=${dropoff.lng}`,
      headers: auth(client),
    });
    const itemId = cart.json().components[0].data.items[0].item_id;

    const patch = await app.inject({
      method: 'PATCH',
      url: `/cart/items/${itemId}`,
      headers: auth(client),
      payload: { quantity: 3, lat: dropoff.lat, lng: dropoff.lng },
    });
    expect(patch.statusCode).toBe(200);
    expect(patch.json().components[0].data.items[0].quantity).toBe(3);

    const del = await app.inject({
      method: 'DELETE',
      url: `/cart/items/${itemId}`,
      headers: auth(client),
    });
    expect(del.statusCode).toBe(200);
    expect(del.json().components).toHaveLength(0);
  });

  it('POST /orders crée la commande et renvoie un order_tracking', async () => {
    await admin.from('carts').delete().eq('user_id', client.id);
    await app.inject({
      method: 'POST',
      url: '/cart/items',
      headers: auth(client),
      payload: {
        product_id: opts.productId,
        quantity: 2,
        selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionDouble] }],
      },
    });

    const clientOrderId = randomUUID();
    const payload = {
      type: 'delivery',
      client_order_id: clientOrderId,
      dropoff_hint: 'Plateau, immeuble bleu',
      dropoff: dropoff,
      payment_method: 'cash',
    };

    const res = await app.inject({
      method: 'POST',
      url: '/orders',
      headers: auth(client),
      payload,
    });

    expect(res.statusCode).toBe(201);
    const composant = res.json().components[0];
    expect(composant.type).toBe('order_tracking');
    expect(composant.data.status).toBe('pending');
    expect(composant.data.status_label).toBeTruthy();
    expect(composant.data.steps.length).toBeGreaterThan(0);
    expect(composant.data.realtime.orders_channel).toContain('orders:');
    // Pas de livreur assigné : pas de canal de position à écouter.
    expect(composant.data.realtime.driver_channel).toBeNull();
    expect(composant.data.total).toBe(4900);

    // Rejeu de la même requête : même commande, pas une seconde.
    const rejeu = await app.inject({
      method: 'POST',
      url: '/orders',
      headers: auth(client),
      payload,
    });
    expect(rejeu.statusCode).toBe(201);
    expect(rejeu.json().components[0].data.order_id).toBe(composant.data.order_id);
  }, 30_000);

  it('une course coursier passe sans panier', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/orders',
      headers: auth(client),
      payload: {
        type: 'courier',
        client_order_id: randomUUID(),
        pickup_hint: 'Plateau, boutique Issa',
        pickup: { lat: 13.5137, lng: 2.1098 },
        dropoff_hint: 'Yantala',
        dropoff: { lat: 13.529, lng: 2.087 },
        parcel: 'medium',
        payment_method: 'cash',
      },
    });

    expect(res.statusCode).toBe(201);
    const data = res.json().components[0].data;
    expect(data.type).toBe('courier');
    expect(data.pickup).not.toBeNull();
    expect(data.total).toBeGreaterThan(1000);
  });

  it("la commande d'un tiers renvoie 404, pas 403", async () => {
    const intrus = await createUser('client');

    const liste = await app.inject({ method: 'GET', url: '/orders', headers: auth(client) });
    const orderId = liste.json().orders[0].id;

    const res = await app.inject({
      method: 'GET',
      url: `/orders/${orderId}`,
      headers: auth(intrus),
    });

    // 404 et non 403 : distinguer les deux renseignerait un curieux sur ce
    // qui existe.
    expect(res.statusCode).toBe(404);
  }, 30_000);

  it('un identifiant mal formé est rejeté avant la base', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/orders/pas-un-uuid',
      headers: auth(client),
    });
    expect(res.statusCode).toBe(400);
  });
});
