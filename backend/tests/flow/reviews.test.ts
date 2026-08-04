import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import {
  admin,
  cleanup,
  createUser,
  firstZoneId,
  seedShop,
  type TestUser,
} from '../rls/harness.js';

/**
 * Les avis, et ce qu'ils valent.
 *
 * La note d'une boutique est le premier chiffre que regarde un client : elle
 * décide de son chiffre d'affaires. Un avis qu'on peut déposer sans avoir
 * commandé n'est pas un avis, c'est une arme — pour un concurrent comme pour
 * un boutiquier qui s'auto-note.
 *
 * Les garanties sont en base et non dans la route, parce que la clé
 * publiable est dans l'APK : PostgREST est joignable sans passer par nous.
 */
describe('Avis vérifiés', () => {
  let client: TestUser;
  let intrus: TestUser;
  let boutiquier: TestUser;
  let livreur: TestUser;
  let merchantId: string;
  let autreMerchantId: string;
  let zoneId: string;

  async function commande(statut: string): Promise<string> {
    const { data, error } = await admin
      .from('orders')
      .insert({
        client_order_id: randomUUID(),
        type: 'delivery',
        user_id: client.id,
        merchant_id: merchantId,
        zone_id: zoneId,
        driver_id: livreur.id,
        status: statut,
        dropoff_hint: 'Plateau, immeuble bleu',
        dropoff_location: 'SRID=4326;POINT(2.1098 13.5137)',
        items_total: 3000,
        delivery_fee: 500,
        total: 3500,
        payment_method: 'cash',
        ...(statut === 'delivered' ? { delivered_at: new Date().toISOString() } : {}),
      })
      .select('id')
      .single();
    if (error) throw error;
    return data.id as string;
  }

  beforeAll(async () => {
    zoneId = await firstZoneId();
    [client, intrus, boutiquier, livreur] = await Promise.all([
      createUser('client'),
      createUser('client'),
      createUser('merchant'),
      createUser('driver'),
    ]);
    ({ merchantId } = await seedShop(boutiquier.id, zoneId));

    const autre = await createUser('merchant');
    ({ merchantId: autreMerchantId } = await seedShop(autre.id, zoneId));
  }, 180_000);

  afterAll(async () => {
    await admin.from('orders').delete().in('merchant_id', [merchantId, autreMerchantId]);
    await cleanup();
  });

  it('un client peut noter sa commande livrée', async () => {
    const orderId = await commande('delivered');

    const { error } = await client.db.from('reviews').insert({
      order_id: orderId,
      user_id: client.id,
      rating: 4,
      comment: 'Rapide et bien emballé.',
    });
    expect(error, error?.message).toBeNull();
  }, 60_000);

  it('la note de la boutique suit les avis reçus', async () => {
    // Sans recalcul, les 77 boutiques migrées resteraient à 5,0 pour
    // toujours et la note n'apprendrait rien à personne.
    const { data } = await admin
      .from('merchants')
      .select('rating, rating_count')
      .eq('id', merchantId)
      .single();

    expect(data?.rating_count).toBeGreaterThan(0);
    expect(Number(data?.rating)).toBe(4);
  }, 60_000);

  it('on ne note pas une commande qu’on n’a pas passée', async () => {
    // Sinon un concurrent moissonne les identifiants de commande et coule
    // une boutique à coups de une étoile.
    const orderId = await commande('delivered');

    const { error } = await intrus.db.from('reviews').insert({
      order_id: orderId,
      user_id: intrus.id,
      rating: 1,
      comment: 'Jamais commandé ici.',
    });
    expect(error).not.toBeNull();
  }, 60_000);

  it('on ne note pas avant d’être livré', async () => {
    const orderId = await commande('preparing');

    const { error } = await client.db.from('reviews').insert({
      order_id: orderId,
      user_id: client.id,
      rating: 5,
    });
    expect(error).not.toBeNull();
  }, 60_000);

  it('la boutique notée est celle de la commande, pas celle qu’on désigne', async () => {
    // La faille la plus discrète : une commande livrée bien réelle, mais un
    // `merchant_id` pointant ailleurs. Une seule commande suffirait alors à
    // noter toute la plateforme.
    const orderId = await commande('delivered');

    const { error } = await client.db.from('reviews').insert({
      order_id: orderId,
      user_id: client.id,
      merchant_id: autreMerchantId,
      rating: 1,
    });
    expect(error, error?.message).toBeNull();

    const { data } = await admin
      .from('reviews')
      .select('merchant_id')
      .eq('order_id', orderId)
      .single();
    expect(data?.merchant_id).toBe(merchantId);

    // Et la boutique visée n'a rien reçu.
    const { data: epargnee } = await admin
      .from('merchants')
      .select('rating_count')
      .eq('id', autreMerchantId)
      .single();
    expect(epargnee?.rating_count).toBe(0);
  }, 60_000);

  it('corriger son avis remplace la note au lieu d’en ajouter une', async () => {
    const orderId = await commande('delivered');

    await client.db.from('reviews').insert({ order_id: orderId, user_id: client.id, rating: 2 });
    const { error } = await client.db
      .from('reviews')
      .update({ rating: 5 })
      .eq('order_id', orderId)
      .eq('user_id', client.id);
    expect(error, error?.message).toBeNull();

    const { count } = await admin
      .from('reviews')
      .select('*', { count: 'exact', head: true })
      .eq('order_id', orderId);
    expect(count).toBe(1);
  }, 60_000);
});
