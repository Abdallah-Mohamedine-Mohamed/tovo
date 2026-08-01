import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import {
  admin,
  cleanup,
  createUser,
  firstZoneId,
  seedOrder,
  seedShop,
  type TestUser,
} from './harness.js';

describe('RLS — commandes', () => {
  let client: TestUser;
  let autreClient: TestUser;
  let boutiquier: TestUser;
  let livreur: TestUser;
  let zoneId: string;
  let merchantId: string;
  let orderId: string;

  beforeAll(async () => {
    zoneId = await firstZoneId();
    [client, autreClient, boutiquier, livreur] = await Promise.all([
      createUser('client'),
      createUser('client'),
      createUser('merchant'),
      createUser('driver'),
    ]);

    ({ merchantId } = await seedShop(boutiquier.id, zoneId));
    await admin.from('driver_profiles').update({ zone_id: zoneId }).eq('id', livreur.id);

    orderId = await seedOrder({ userId: client.id, merchantId, zoneId });
  }, 60_000);

  afterAll(cleanup);

  it('le client voit sa commande', async () => {
    const { data } = await client.db.from('orders').select('id, total').eq('id', orderId);
    expect(data).toHaveLength(1);
    expect(data?.[0]?.total).toBe(3500);
  });

  it("un autre client ne voit pas la commande", async () => {
    const { data } = await autreClient.db.from('orders').select('id').eq('id', orderId);
    expect(data).toHaveLength(0);
  });

  it('le boutiquier voit les commandes de sa boutique', async () => {
    const { data } = await boutiquier.db.from('orders').select('id').eq('id', orderId);
    expect(data).toHaveLength(1);
  });

  it('le livreur voit le pool ouvert de sa zone', async () => {
    const { data } = await livreur.db.from('orders').select('id').eq('id', orderId);
    expect(data).toHaveLength(1);
  });

  it("le livreur ne voit plus le pool d'une autre zone", async () => {
    const { data: zones } = await admin
      .from('delivery_zones')
      .select('id')
      .neq('id', zoneId)
      .limit(1);
    const autreZone = zones?.[0]?.id as string | undefined;
    expect(autreZone).toBeDefined();

    await admin.from('driver_profiles').update({ zone_id: autreZone }).eq('id', livreur.id);
    const { data } = await livreur.db.from('orders').select('id').eq('id', orderId);
    expect(data).toHaveLength(0);

    await admin.from('driver_profiles').update({ zone_id: zoneId }).eq('id', livreur.id);
  });

  it("un client ne peut pas créer une commande au nom d'un autre", async () => {
    const { error } = await client.db.from('orders').insert({
      client_order_id: randomUUID(),
      type: 'delivery',
      user_id: autreClient.id,
      merchant_id: merchantId,
      zone_id: zoneId,
      dropoff_hint: 'Plateau',
      dropoff_location: 'SRID=4326;POINT(2.1098 13.5137)',
      total: 1000,
    });
    expect(error).not.toBeNull();
  });

  it('le même client_order_id ne crée pas deux commandes', async () => {
    const idem = randomUUID();
    const payload = {
      client_order_id: idem,
      type: 'delivery' as const,
      user_id: client.id,
      merchant_id: merchantId,
      zone_id: zoneId,
      dropoff_hint: 'Plateau',
      dropoff_location: 'SRID=4326;POINT(2.1098 13.5137)',
      items_total: 1000,
      total: 1000,
    };

    const first = await client.db.from('orders').insert(payload);
    expect(first.error).toBeNull();

    const second = await client.db.from('orders').insert(payload);
    expect(second.error).not.toBeNull();
    expect(second.error?.code).toBe('23505'); // violation d'unicité
  });

  it("l'attribution de course est atomique : un seul livreur gagne", async () => {
    const disputee = await seedOrder({ userId: client.id, merchantId, zoneId });
    const secondLivreur = await createUser('driver');
    await admin.from('driver_profiles').update({ zone_id: zoneId }).eq('id', secondLivreur.id);

    const [a, b] = await Promise.all([
      livreur.db.rpc('accept_order', { target_order: disputee }),
      secondLivreur.db.rpc('accept_order', { target_order: disputee }),
    ]);

    const gagnants = [a.data, b.data].filter((won) => won === true);
    expect(gagnants).toHaveLength(1);
  }, 30_000);

  it("le contenu d'une commande n'est pas lisible par un tiers", async () => {
    // Le piège : une policy qui vérifie que la commande EXISTE au lieu de
    // vérifier qu'elle m'appartient laisse fuiter ce que les autres commandent.
    await admin.from('order_items').insert({
      order_id: orderId,
      product_name: 'Tuo zaafi sauce arachide',
      unit_price: 1500,
      quantity: 2,
      line_total: 3000,
    });

    const proprietaire = await client.db
      .from('order_items')
      .select('product_name')
      .eq('order_id', orderId);
    expect(proprietaire.data).toHaveLength(1);

    const tiers = await autreClient.db
      .from('order_items')
      .select('product_name')
      .eq('order_id', orderId);
    expect(tiers.data ?? []).toHaveLength(0);

    const histoireTiers = await autreClient.db
      .from('order_status_history')
      .select('status')
      .eq('order_id', orderId);
    expect(histoireTiers.data ?? []).toHaveLength(0);
  });

  it("l'historique de statut est écrit automatiquement", async () => {
    const { data } = await client.db
      .from('order_status_history')
      .select('status')
      .eq('order_id', orderId);
    expect(data?.length).toBeGreaterThanOrEqual(1);
  });
});
