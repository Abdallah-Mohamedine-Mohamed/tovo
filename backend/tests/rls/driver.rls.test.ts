import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  admin,
  cleanup,
  createUser,
  firstZoneId,
  seedOrder,
  seedShop,
  type TestUser,
} from './harness.js';

/**
 * Le point sensible : le suivi live. La mini-carte de order_tracking s'abonne
 * à driver_locations en Realtime. Les policies vérifiées ici sont exactement
 * celles qui s'appliquent au flux Realtime — si un client peut lire la
 * position d'un livreur qui n'est pas le sien en SQL, il le peut aussi en
 * temps réel.
 */
describe('RLS — livreur, position et cash', () => {
  let client: TestUser;
  let curieux: TestUser;
  let livreur: TestUser;
  let boutiquier: TestUser;
  let orderId: string;

  beforeAll(async () => {
    const zoneId = await firstZoneId();
    [client, curieux, livreur, boutiquier] = await Promise.all([
      createUser('client'),
      createUser('client'),
      createUser('driver'),
      createUser('merchant'),
    ]);

    const { merchantId } = await seedShop(boutiquier.id, zoneId);
    await admin.from('driver_profiles').update({ zone_id: zoneId }).eq('id', livreur.id);

    orderId = await seedOrder({ userId: client.id, merchantId, zoneId, status: 'assigned' });
    await admin.from('orders').update({ driver_id: livreur.id }).eq('id', orderId);

    await admin.from('driver_locations').insert({
      driver_id: livreur.id,
      order_id: orderId,
      location: 'SRID=4326;POINT(2.1000 13.5200)',
    });
  }, 60_000);

  afterAll(cleanup);

  it('le client suit la position du livreur de SA commande', async () => {
    const { data } = await client.db
      .from('driver_locations')
      .select('id')
      .eq('order_id', orderId);
    expect(data?.length).toBeGreaterThanOrEqual(1);
  });

  it("un autre client ne voit pas cette position", async () => {
    const { data } = await curieux.db
      .from('driver_locations')
      .select('id')
      .eq('order_id', orderId);
    expect(data).toHaveLength(0);
  });

  it('la position cesse d\'être visible une fois la commande livrée', async () => {
    await admin.from('orders').update({ status: 'delivered' }).eq('id', orderId);

    const { data } = await client.db
      .from('driver_locations')
      .select('id')
      .eq('order_id', orderId);
    expect(data).toHaveLength(0);

    await admin.from('orders').update({ status: 'assigned' }).eq('id', orderId);
  });

  it('le client voit le profil du livreur pendant la course, pas après', async () => {
    const pendant = await client.db.from('driver_profiles').select('id').eq('id', livreur.id);
    expect(pendant.data).toHaveLength(1);

    await admin.from('orders').update({ status: 'delivered' }).eq('id', orderId);
    const apres = await client.db.from('driver_profiles').select('id').eq('id', livreur.id);
    expect(apres.data).toHaveLength(0);

    await admin.from('orders').update({ status: 'assigned' }).eq('id', orderId);
  });

  it("un client ne peut pas lister tous les livreurs", async () => {
    const { data } = await curieux.db.from('driver_profiles').select('id');
    expect(data ?? []).toHaveLength(0);
  });

  it('la collecte cash est écrite automatiquement à la livraison', async () => {
    const livre = await seedOrder({
      userId: client.id,
      merchantId: (await admin.from('orders').select('merchant_id').eq('id', orderId).single())
        .data?.merchant_id as string,
      zoneId: await firstZoneId(),
      status: 'delivering',
    });
    await admin.from('orders').update({ driver_id: livreur.id }).eq('id', livre);
    await admin.from('orders').update({ status: 'delivered' }).eq('id', livre);

    const { data } = await admin
      .from('driver_cash_ledger')
      .select('amount, entry_type')
      .eq('order_id', livre);

    expect(data).toHaveLength(1);
    expect(data?.[0]?.entry_type).toBe('collection');
    expect(data?.[0]?.amount).toBe(3500);
  });

  it('le livreur lit son solde du jour, pas celui des autres', async () => {
    const { data } = await livreur.db.rpc('driver_daily_balance');
    expect(Array.isArray(data)).toBe(true);

    const autre = await createUser('driver');
    const { data: vuParAutre } = await autre.db
      .from('driver_cash_ledger')
      .select('id')
      .eq('driver_id', livreur.id);
    expect(vuParAutre ?? []).toHaveLength(0);
  }, 30_000);
});
