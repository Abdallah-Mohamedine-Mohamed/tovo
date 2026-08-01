import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app.js';
import { dispatchOrder } from '../../src/services/dispatch.js';
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
 * Le cycle complet d'une commande : le client commande, le boutiquier
 * prépare, le dispatch trouve un livreur, le livreur livre.
 *
 * C'est le jalon de la Phase 2 — « une vraie commande passe de A à Z ».
 */
describe('Exécution — du panier à la livraison', () => {
  let app: FastifyInstance;
  let client: TestUser;
  let boutiquier: TestUser;
  let livreur: TestUser;
  let autreLivreur: TestUser;
  let opts: SeededOptions;
  let merchantId: string;
  let zoneId: string;

  const dropoff = { lat: 13.5137, lng: 2.1098 };

  function auth(user: TestUser): Record<string, string> {
    return { authorization: `Bearer ${user.accessToken}` };
  }

  async function commander(): Promise<string> {
    await admin.from('carts').delete().eq('user_id', client.id);
    await app.inject({
      method: 'POST',
      url: '/cart/items',
      headers: auth(client),
      payload: {
        product_id: opts.productId,
        quantity: 1,
        selections: [{ option_id: opts.portionOptionId, value_ids: [opts.portionSimple] }],
      },
    });

    const res = await app.inject({
      method: 'POST',
      url: '/orders',
      headers: auth(client),
      payload: {
        type: 'delivery',
        client_order_id: randomUUID(),
        dropoff_hint: 'Plateau',
        dropoff: dropoff,
        payment_method: 'cash',
      },
    });
    return res.json().components[0].data.order_id as string;
  }

  async function statut(user: TestUser, orderId: string, status: string) {
    return app.inject({
      method: 'POST',
      url: `/orders/${orderId}/status`,
      headers: auth(user),
      payload: { status },
    });
  }

  beforeAll(async () => {
    app = await buildApp();
    await app.ready();

    zoneId = await firstZoneId();
    [client, boutiquier, livreur, autreLivreur] = await Promise.all([
      createUser('client'),
      createUser('merchant'),
      createUser('driver'),
      createUser('driver'),
    ]);

    ({ merchantId } = await seedShop(boutiquier.id, zoneId));
    opts = await seedProductWithOptions(merchantId);

    // Les livreurs doivent être dans la zone de COLLECTE — celle de la
    // boutique — puisque c'est là qu'ils vont en premier.
    const { data: zonePickup } = await admin.rpc('zone_for_point', {
      p_lat: 13.529,
      p_lng: 2.087,
    });
    zoneId = (zonePickup as { id: string } | null)?.id ?? zoneId;

    for (const d of [livreur, autreLivreur]) {
      await admin
        .from('driver_profiles')
        .update({
          zone_id: zoneId,
          is_online: true,
          is_available: true,
          current_location: 'SRID=4326;POINT(2.0880 13.5285)',
          last_seen_at: new Date().toISOString(),
        })
        .eq('id', d.id);
    }
  }, 90_000);

  afterAll(async () => {
    await app.close();
    await admin.from('carts').delete().eq('user_id', client.id);
    await cleanup();
  });

  it('le boutiquier fait avancer la commande jusqu’à « prête »', async () => {
    const orderId = await commander();

    for (const etape of ['confirmed', 'preparing', 'ready']) {
      const res = await statut(boutiquier, orderId, etape);
      expect(res.statusCode, `échec sur $etape`.replace('$etape', etape)).toBe(200);
    }

    const { data } = await admin.from('orders').select('status').eq('id', orderId).single();
    expect(data?.status).toBe('ready');
  }, 40_000);

  it('un boutiquier ne peut pas déclarer une commande livrée', async () => {
    const orderId = await commander();
    await statut(boutiquier, orderId, 'confirmed');

    const res = await statut(boutiquier, orderId, 'delivered');
    expect(res.statusCode).toBe(409);
    expect(res.json().error).toContain('non autorisée');
  }, 40_000);

  it('un tiers ne peut pas toucher au statut', async () => {
    const orderId = await commander();
    const res = await statut(autreLivreur, orderId, 'confirmed');
    // 404 et non 409 : la RLS masque la commande avant que la question de la
    // transition ne se pose. Répondre 409 révélerait qu'elle existe.
    expect(res.statusCode).toBe(404);
  }, 40_000);

  it('le dispatch trouve les livreurs proches et disponibles', async () => {
    const orderId = await commander();
    await statut(boutiquier, orderId, 'confirmed');
    await statut(boutiquier, orderId, 'preparing');
    await statut(boutiquier, orderId, 'ready');

    const resultat = await dispatchOrder({ orderId });
    expect(resultat.candidates).toBeGreaterThanOrEqual(1);
    expect(resultat.reason).toBeUndefined();
  }, 40_000);

  it('un livreur hors ligne n’est pas candidat', async () => {
    await admin.from('driver_profiles').update({ is_online: false }).eq('id', livreur.id);
    await admin.from('driver_profiles').update({ is_online: false }).eq('id', autreLivreur.id);

    const orderId = await commander();
    await statut(boutiquier, orderId, 'confirmed');
    await statut(boutiquier, orderId, 'preparing');
    await statut(boutiquier, orderId, 'ready');

    const resultat = await dispatchOrder({ orderId });
    expect(resultat.reason).toBe('no_candidates');

    await admin.from('driver_profiles').update({ is_online: true }).eq('id', livreur.id);
    await admin.from('driver_profiles').update({ is_online: true }).eq('id', autreLivreur.id);
  }, 40_000);

  it('la course apparaît dans le pool du livreur, puis en disparaît', async () => {
    const orderId = await commander();
    await statut(boutiquier, orderId, 'confirmed');
    await statut(boutiquier, orderId, 'preparing');
    await statut(boutiquier, orderId, 'ready');

    const pool = await app.inject({
      method: 'GET',
      url: '/driver/pool',
      headers: auth(livreur),
    });
    expect(pool.statusCode).toBe(200);
    expect((pool.json().orders as Array<{ id: string }>).map((o) => o.id)).toContain(orderId);

    const accept = await app.inject({
      method: 'POST',
      url: `/orders/${orderId}/accept`,
      headers: auth(livreur),
    });
    expect(accept.statusCode).toBe(200);

    // Une fois prise, la course sort du pool des autres.
    const poolApres = await app.inject({
      method: 'GET',
      url: '/driver/pool',
      headers: auth(autreLivreur),
    });
    expect((poolApres.json().orders as Array<{ id: string }>).map((o) => o.id))
        .not.toContain(orderId);
  }, 60_000);

  it('deux livreurs sur la même course : le second reçoit un 409 explicite', async () => {
    const orderId = await commander();
    await statut(boutiquier, orderId, 'confirmed');
    await statut(boutiquier, orderId, 'preparing');
    await statut(boutiquier, orderId, 'ready');

    const [a, b] = await Promise.all([
      app.inject({
        method: 'POST',
        url: `/orders/${orderId}/accept`,
        headers: auth(livreur),
      }),
      app.inject({
        method: 'POST',
        url: `/orders/${orderId}/accept`,
        headers: auth(autreLivreur),
      }),
    ]);

    const codes = [a.statusCode, b.statusCode].sort();
    expect(codes).toEqual([200, 409]);

    const perdant = a.statusCode === 409 ? a : b;
    expect(perdant.json().code).toBe('ALREADY_TAKEN');
  }, 60_000);

  it('le livreur mène la course jusqu’à la livraison, et redevient disponible', async () => {
    const orderId = await commander();
    await statut(boutiquier, orderId, 'confirmed');
    await statut(boutiquier, orderId, 'preparing');
    await statut(boutiquier, orderId, 'ready');
    await app.inject({
      method: 'POST',
      url: `/orders/${orderId}/accept`,
      headers: auth(livreur),
    });

    for (const etape of ['picked_up', 'delivering', 'delivered']) {
      const res = await statut(livreur, orderId, etape);
      expect(res.statusCode, `échec sur ${etape}`).toBe(200);
    }

    const { data: profil } = await admin
      .from('driver_profiles')
      .select('is_available')
      .eq('id', livreur.id)
      .single();
    expect(profil?.is_available).toBe(true);

    // Le cash encaissé est enregistré, et distinct de la rémunération.
    const resume = await app.inject({
      method: 'GET',
      url: '/driver/summary',
      headers: auth(livreur),
    });
    const corps = resume.json();
    expect(corps.courses).toBeGreaterThanOrEqual(1);
    expect(corps.earned).toBeGreaterThan(0);
    expect(corps.cash_collected).toBeGreaterThan(corps.earned);
  }, 90_000);

  it('le ping de position répond sans corps et alimente le suivi', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/driver/location',
      headers: auth(livreur),
      payload: { lat: 13.52, lng: 2.09 },
    });
    expect(res.statusCode).toBe(204);
    expect(res.body).toBe('');

    const { data } = await admin
      .from('driver_profiles')
      .select('last_seen_at')
      .eq('id', livreur.id)
      .single();
    expect(data?.last_seen_at).not.toBeNull();
  }, 30_000);

  it('une écriture directe ne contourne pas les transitions', async () => {
    // Le vrai test du garde-fou : on ignore les routes et on écrit dans la
    // table comme le ferait n'importe qui avec la clé publishable, qui est
    // publique par construction puisqu'elle vit dans l'APK.
    const orderId = await commander();

    const boutiquierDirect = await boutiquier.db
      .from('orders')
      .update({ status: 'delivered' })
      .eq('id', orderId);
    expect(boutiquierDirect.error).not.toBeNull();

    const clientDirect = await client.db
      .from('orders')
      .update({ status: 'ready' })
      .eq('id', orderId);
    expect(clientDirect.error).not.toBeNull();

    const { data } = await admin.from('orders').select('status').eq('id', orderId).single();
    expect(data?.status).toBe('pending');

    // En revanche, le client garde le droit de renoncer.
    const annulation = await client.db
      .from('orders')
      .update({ status: 'cancelled' })
      .eq('id', orderId);
    expect(annulation.error).toBeNull();
  }, 40_000);

  it('un client ne peut pas obtenir la liste des livreurs via le dispatch', async () => {
    const orderId = await commander();
    const { error } = await client.db.rpc('dispatch_candidates', { p_order_id: orderId });
    expect(error).not.toBeNull();
  }, 40_000);
});
