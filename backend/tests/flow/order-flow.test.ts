import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
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
 * Le flux de commande de bout en bout, sans IA et sans HTTP : on exerce
 * directement les fonctions Postgres, là où vivent l'atomicité et le calcul
 * des prix. Si ces tests passent, les routes REST ne feront que les
 * enrober.
 *
 * Point de vigilance principal : aucun montant ne doit jamais provenir du
 * client.
 */
describe('Flux de commande — panier et passage de commande', () => {
  let client: TestUser;
  let boutiquier: TestUser;
  let autreBoutiquier: TestUser;
  let opts: SeededOptions;
  let merchantId: string;
  let autreProduitId: string;

  // Plateau — couvert par une zone du seed, frais de livraison 500 XOF.
  const dropoff = { lat: 13.5137, lng: 2.1098 };

  beforeAll(async () => {
    const zoneId = await firstZoneId();
    [client, boutiquier, autreBoutiquier] = await Promise.all([
      createUser('client'),
      createUser('merchant'),
      createUser('merchant'),
    ]);

    ({ merchantId } = await seedShop(boutiquier.id, zoneId));
    opts = await seedProductWithOptions(merchantId);

    const autre = await seedShop(autreBoutiquier.id, zoneId);
    autreProduitId = autre.productId;
  }, 60_000);

  afterAll(cleanup);

  async function viderLePanier(): Promise<void> {
    await admin.from('carts').delete().eq('user_id', client.id);
  }

  it('le prix unitaire intègre les suppléments d\'options', async () => {
    await viderLePanier();

    const { error } = await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 2,
      p_selections: [
        { option_id: opts.portionOptionId, value_ids: [opts.portionDouble] },
        { option_id: opts.sauceOptionId, value_ids: [opts.sauceArachide] },
      ],
    });
    expect(error).toBeNull();

    const { data } = await client.db.rpc('cart_view', {
      p_lat: dropoff.lat,
      p_lng: dropoff.lng,
    });

    // 1500 de base + 700 pour la portion double = 2200, ×2 = 4400
    expect(data.items).toHaveLength(1);
    expect(data.items[0].unit_price).toBe(2200);
    expect(data.items[0].line_total).toBe(4400);
    expect(data.items_total).toBe(4400);
    expect(data.delivery_fee).toBe(500);
    expect(data.total).toBe(4900);
    expect(data.can_checkout).toBe(true);
    expect(data.items[0].selections_label).toContain('Double');
  });

  it('une option obligatoire manquante est refusée', async () => {
    await viderLePanier();

    const { error } = await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 1,
      p_selections: [],
    });
    expect(error).not.toBeNull();
    expect(error?.message).toContain('obligatoire');
  });

  it("une option qui n'appartient pas au produit est refusée", async () => {
    await viderLePanier();

    const { data: autreValeur } = await admin
      .from('product_option_values')
      .select('id')
      .neq('option_id', opts.portionOptionId)
      .neq('option_id', opts.sauceOptionId)
      .limit(1);

    if (!autreValeur?.[0]) return; // pas d'autre option en base, rien à vérifier

    const { error } = await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 1,
      p_selections: [{ option_id: opts.portionOptionId, value_ids: [autreValeur[0].id] }],
    });
    expect(error).not.toBeNull();
  });

  it('le panier reste mono-boutique', async () => {
    await viderLePanier();

    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 1,
      p_selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionSimple] }],
    });

    const { error } = await client.db.rpc('cart_add_item', {
      p_product_id: autreProduitId,
      p_quantity: 1,
      p_selections: [],
    });

    expect(error).not.toBeNull();
    expect(error?.message).toContain('autre boutique');
  });

  it('deux ajouts identiques incrémentent la même ligne', async () => {
    await viderLePanier();

    const selections = [
      { option_id: opts.portionOptionId, value_ids: [opts.portionSimple] },
    ];
    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 1,
      p_selections: selections,
    });
    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 2,
      p_selections: selections,
    });

    const { data } = await client.db.rpc('cart_view', { p_lat: null, p_lng: null });
    expect(data.items).toHaveLength(1);
    expect(data.items[0].quantity).toBe(3);
  });

  it('passer commande crée la commande, ses lignes, et vide le panier', async () => {
    await viderLePanier();

    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 2,
      p_selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionDouble] }],
    });

    const clientOrderId = randomUUID();
    const { data: orderId, error } = await client.db.rpc('place_delivery_order', {
      p_client_order_id: clientOrderId,
      p_dropoff_hint: 'Plateau, immeuble bleu',
      p_lat: dropoff.lat,
      p_lng: dropoff.lng,
      p_payment: 'cash',
      p_note: null,
    });

    expect(error).toBeNull();
    expect(orderId).toBeTruthy();

    const { data: order } = await client.db
      .from('orders')
      .select('total, items_total, delivery_fee, status, merchant_id, zone_id')
      .eq('id', orderId)
      .single();

    expect(order?.items_total).toBe(4400);
    expect(order?.delivery_fee).toBe(500);
    expect(order?.total).toBe(4900);
    expect(order?.status).toBe('pending');
    expect(order?.merchant_id).toBe(merchantId);
    expect(order?.zone_id).not.toBeNull();

    const { data: items } = await client.db
      .from('order_items')
      .select('product_name, quantity, line_total, selections_label')
      .eq('order_id', orderId);
    expect(items).toHaveLength(1);
    expect(items?.[0]?.line_total).toBe(4400);
    expect(items?.[0]?.selections_label).toContain('Double');

    // Le panier a disparu, pas seulement ses lignes.
    const { data: cart } = await client.db.rpc('cart_view', { p_lat: null, p_lng: null });
    expect(cart.cart_id).toBeNull();
  });

  it('rejouer le même client_order_id ne crée pas de seconde commande', async () => {
    await viderLePanier();

    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 1,
      p_selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionSimple] }],
    });

    const clientOrderId = randomUUID();
    const args = {
      p_client_order_id: clientOrderId,
      p_dropoff_hint: 'Plateau',
      p_lat: dropoff.lat,
      p_lng: dropoff.lng,
      p_payment: 'cash' as const,
      p_note: null,
    };

    const first = await client.db.rpc('place_delivery_order', args);
    const second = await client.db.rpc('place_delivery_order', args);

    expect(first.error).toBeNull();
    expect(second.error).toBeNull();
    expect(second.data).toBe(first.data);

    const { count } = await client.db
      .from('orders')
      .select('id', { count: 'exact', head: true })
      .eq('client_order_id', clientOrderId);
    expect(count).toBe(1);
  });

  it('commander avec un panier vide échoue', async () => {
    await viderLePanier();

    const { error } = await client.db.rpc('place_delivery_order', {
      p_client_order_id: randomUUID(),
      p_dropoff_hint: 'Plateau',
      p_lat: dropoff.lat,
      p_lng: dropoff.lng,
      p_payment: 'cash',
      p_note: null,
    });
    expect(error).not.toBeNull();
  });

  it('une course coursier se crée sans panier ni boutique', async () => {
    const { data: orderId, error } = await client.db.rpc('place_courier_order', {
      p_client_order_id: randomUUID(),
      p_pickup_hint: 'Plateau, boutique Issa',
      p_pickup_lat: 13.5137,
      p_pickup_lng: 2.1098,
      p_dropoff_hint: 'Yantala, face à la station',
      p_dropoff_lat: 13.529,
      p_dropoff_lng: 2.087,
      p_parcel: 'medium',
      p_payment: 'cash',
      p_scheduled_for: null,
      p_parcel_note: 'Documents',
    });

    expect(error).toBeNull();

    const { data: order } = await client.db
      .from('orders')
      .select('type, merchant_id, total, items_total')
      .eq('id', orderId)
      .single();

    expect(order?.type).toBe('courier');
    expect(order?.merchant_id).toBeNull();
    expect(order?.items_total).toBe(0);
    expect(order?.total).toBeGreaterThan(1000);

    const { data: details } = await client.db
      .from('courier_details')
      .select('parcel, distance_m, pickup_hint')
      .eq('order_id', orderId)
      .single();

    expect(details?.parcel).toBe('medium');
    expect(details?.distance_m).toBeGreaterThan(0);
  });

  it('order_tracking renvoie une charge utile complète', async () => {
    await viderLePanier();

    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 1,
      p_selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionSimple] }],
    });

    const { data: orderId } = await client.db.rpc('place_delivery_order', {
      p_client_order_id: randomUUID(),
      p_dropoff_hint: 'Plateau',
      p_lat: dropoff.lat,
      p_lng: dropoff.lng,
      p_payment: 'cash',
      p_note: null,
    });

    const { data, error } = await client.db.rpc('order_tracking', { p_order_id: orderId });

    expect(error).toBeNull();
    expect(data.order_id).toBe(orderId);
    expect(data.type).toBe('delivery');
    expect(data.status).toBe('pending');
    expect(data.driver).toBeNull();
    expect(data.dropoff.lat).toBeCloseTo(dropoff.lat, 3);
    expect(data.items).toHaveLength(1);
    expect(data.history.length).toBeGreaterThanOrEqual(1);
  });

  it("la grille tarifaire est pilotée par l'admin, pas par le client", async () => {
    const administrateur = await createUser('admin');

    // La grille doit être lisible par tous — le client affiche une estimation
    // avant de commander.
    const lecture = await client.db.from('platform_settings').select('courier_base').single();
    expect(
      lecture.error,
      `lecture de pricing_settings refusée : ${lecture.error?.code ?? '?'} ${lecture.error?.message ?? ''}`,
    ).toBeNull();
    expect(lecture.data?.courier_base).toBe(1000);

    // Un client ne modifie rien.
    await client.db.from('platform_settings').update({ courier_base: 1 }).eq('id', true);
    const apresTentative = await client.db
      .from('platform_settings')
      .select('courier_base')
      .single();
    expect(apresTentative.data?.courier_base).toBe(1000);

    // L'admin, si. Et le changement se répercute sur le prix calculé.
    const { error } = await administrateur.db
      .from('platform_settings')
      .update({ courier_base: 2000 })
      .eq('id', true);
    expect(
      error,
      `mise à jour admin refusée : ${error?.code ?? '?'} ${error?.message ?? ''}`,
    ).toBeNull();

    const { data: prix } = await client.db.rpc('courier_price', {
      p_distance_m: 0,
      p_parcel: 'small',
    });
    expect(prix).toBe(2000);

    await admin.from('platform_settings').update({ courier_base: 1000 }).eq('id', true);
  }, 30_000);

  it("un tiers n'obtient rien via order_tracking", async () => {
    const intrus = await createUser('client');

    await viderLePanier();
    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 1,
      p_selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionSimple] }],
    });
    const { data: orderId } = await client.db.rpc('place_delivery_order', {
      p_client_order_id: randomUUID(),
      p_dropoff_hint: 'Plateau',
      p_lat: dropoff.lat,
      p_lng: dropoff.lng,
      p_payment: 'cash',
      p_note: null,
    });

    const { data } = await intrus.db.rpc('order_tracking', { p_order_id: orderId });
    expect(data).toBeNull();
  }, 30_000);
});
