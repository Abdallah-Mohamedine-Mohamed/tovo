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
 * L'économie d'une commande : ce que Tovo prélève, ce que la boutique
 * touche, ce que le livreur gagne.
 *
 * La propriété centrale est le FIGEAGE. Ces montants sont calculés au moment
 * où la commande passe et n'évoluent plus. Si l'admin change la commission
 * demain, les commandes d'hier gardent la leur — sans quoi la comptabilité
 * se réécrit à chaque réglage.
 */
describe('Économie des commandes', () => {
  let client: TestUser;
  let boutiquier: TestUser;
  let administrateur: TestUser;
  let opts: SeededOptions;
  let zoneId: string;

  const dropoff = { lat: 13.5137, lng: 2.1098 };

  beforeAll(async () => {
    zoneId = await firstZoneId();
    [client, boutiquier, administrateur] = await Promise.all([
      createUser('client'),
      createUser('merchant'),
      createUser('admin'),
    ]);
    const shop = await seedShop(boutiquier.id, zoneId);
    opts = await seedProductWithOptions(shop.merchantId);
  }, 60_000);

  afterAll(async () => {
    // Remettre la grille par défaut, les autres suites en dépendent.
    await admin
      .from('platform_settings')
      .update({
        commission_mode: 'percent',
        commission_percent: 30.0,
        commission_flat: 300,
        driver_pay_mode: 'flat',
        driver_pay_base: 500,
      })
      .eq('id', true);
    await cleanup();
  });

  async function commander(): Promise<string> {
    await admin.from('carts').delete().eq('user_id', client.id);
    await client.db.rpc('cart_add_item', {
      p_product_id: opts.productId,
      p_quantity: 2,
      p_selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionDouble] }],
    });
    const { data, error } = await client.db.rpc('place_delivery_order', {
      p_client_order_id: randomUUID(),
      p_dropoff_hint: 'Plateau',
      p_lat: dropoff.lat,
      p_lng: dropoff.lng,
      p_payment: 'cash',
      p_note: null,
    });
    if (error) throw error;
    return data as string;
  }

  it('commission en pourcentage : 30 % de 4400 = 1320', async () => {
    await admin
      .from('platform_settings')
      .update({ commission_mode: 'percent', commission_percent: 30.0 })
      .eq('id', true);

    const orderId = await commander();
    const { data } = await client.db
      .from('orders')
      .select('items_total, commission_amount, merchant_payout, driver_earning, delivery_fee')
      .eq('id', orderId)
      .single();

    expect(data?.items_total).toBe(4400);
    expect(data?.commission_amount).toBe(1320);
    expect(data?.merchant_payout).toBe(3080);
    // items_total = commission + payout, toujours.
    expect((data?.commission_amount ?? 0) + (data?.merchant_payout ?? 0)).toBe(4400);
  });

  it('commission au forfait : le mode change le calcul', async () => {
    await admin
      .from('platform_settings')
      .update({ commission_mode: 'flat', commission_flat: 300 })
      .eq('id', true);

    const orderId = await commander();
    const { data } = await client.db
      .from('orders')
      .select('commission_amount, merchant_payout')
      .eq('id', orderId)
      .single();

    expect(data?.commission_amount).toBe(300);
    expect(data?.merchant_payout).toBe(4100);
  });

  it('la commission ne peut pas dépasser le panier', async () => {
    await admin
      .from('platform_settings')
      .update({ commission_mode: 'flat', commission_flat: 999_999 })
      .eq('id', true);

    const orderId = await commander();
    const { data } = await client.db
      .from('orders')
      .select('items_total, commission_amount, merchant_payout')
      .eq('id', orderId)
      .single();

    expect(data?.commission_amount).toBe(data?.items_total);
    expect(data?.merchant_payout).toBe(0);
  });

  it('les montants sont figés : changer la grille ne réécrit pas le passé', async () => {
    await admin
      .from('platform_settings')
      .update({ commission_mode: 'percent', commission_percent: 10.0 })
      .eq('id', true);

    const orderId = await commander();
    const avant = await client.db
      .from('orders')
      .select('commission_amount')
      .eq('id', orderId)
      .single();
    expect(avant.data?.commission_amount).toBe(440); // 10 % de 4400

    await admin
      .from('platform_settings')
      .update({ commission_percent: 30.0 })
      .eq('id', true);

    const apres = await client.db
      .from('orders')
      .select('commission_amount')
      .eq('id', orderId)
      .single();
    expect(apres.data?.commission_amount).toBe(440);
  });

  it('rémunération livreur au forfait puis à la distance', async () => {
    await admin
      .from('platform_settings')
      .update({ driver_pay_mode: 'flat', driver_pay_base: 500 })
      .eq('id', true);

    const forfait = await commander();
    const { data: a } = await client.db
      .from('orders')
      .select('driver_earning')
      .eq('id', forfait)
      .single();
    expect(a?.driver_earning).toBe(500);

    await admin
      .from('platform_settings')
      .update({ driver_pay_mode: 'distance', driver_pay_base: 500, driver_pay_per_km: 100 })
      .eq('id', true);

    const distance = await commander();
    const { data: b } = await client.db
      .from('orders')
      .select('driver_earning')
      .eq('id', distance)
      .single();
    // Boutique et client sont à quelques kilomètres : au moins le forfait.
    expect(b?.driver_earning).toBeGreaterThanOrEqual(500);
  }, 30_000);

  it('un client ne peut pas modifier la grille, un admin le peut', async () => {
    const refus = await client.db
      .from('platform_settings')
      .update({ commission_percent: 0 })
      .eq('id', true);
    void refus;

    const { data: inchange } = await client.db
      .from('platform_settings')
      .select('commission_percent')
      .single();
    expect(Number(inchange?.commission_percent)).not.toBe(0);

    const { error } = await administrateur.db
      .from('platform_settings')
      .update({ commission_percent: 12.5 })
      .eq('id', true);
    expect(
      error,
      `mise à jour admin refusée : ${error?.code ?? '?'} ${error?.message ?? ''}`,
    ).toBeNull();
  });

  it('le résumé de journée sépare ce qui est gagné de ce qui est encaissé', async () => {
    const livreur = await createUser('driver');
    await admin.from('driver_profiles').update({ zone_id: zoneId }).eq('id', livreur.id);

    await admin
      .from('platform_settings')
      .update({ driver_pay_mode: 'flat', driver_pay_base: 500 })
      .eq('id', true);

    const orderId = await commander();
    await admin
      .from('orders')
      .update({ driver_id: livreur.id, status: 'delivering' })
      .eq('id', orderId);
    await admin.from('orders').update({ status: 'delivered' }).eq('id', orderId);

    const { data, error } = await livreur.db.rpc('driver_daily_summary');
    expect(error).toBeNull();

    const row = Array.isArray(data) ? data[0] : data;
    expect(row.courses).toBeGreaterThanOrEqual(1);
    expect(row.earned).toBeGreaterThanOrEqual(500);
    // Le cash encaissé (4900) n'est pas sa rémunération : il le reverse.
    expect(row.cash_collected).toBeGreaterThanOrEqual(4900);
    expect(row.cash_due).toBeGreaterThan(row.earned);
  }, 40_000);
});
