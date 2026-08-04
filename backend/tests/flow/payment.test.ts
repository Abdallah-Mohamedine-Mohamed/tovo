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
 * Qui peut déclarer qu'une commande est payée.
 *
 * C'est de l'argent. Un livreur qui pourrait solder la commande d'un autre,
 * ou un client qui pourrait se déclarer payé lui-même, se ferait livrer sans
 * jamais rien verser — sans qu'aucune erreur n'apparaisse nulle part.
 *
 * Ces règles vivent en base et non dans la route : la clé publiable est dans
 * l'APK, donc PostgREST est joignable sans passer par notre serveur.
 */
describe('Confirmation d’encaissement', () => {
  let client: TestUser;
  let livreur: TestUser;
  let autreLivreur: TestUser;
  let administrateur: TestUser;
  let boutiquier: TestUser;
  let merchantId: string;
  let zoneId: string;

  /** Une commande à régler par Nita, assignée au livreur. */
  async function commandeNita(driverId: string | null): Promise<string> {
    const { data, error } = await admin
      .from('orders')
      .insert({
        client_order_id: randomUUID(),
        type: 'delivery',
        user_id: client.id,
        merchant_id: merchantId,
        zone_id: zoneId,
        driver_id: driverId,
        status: 'delivering',
        dropoff_hint: 'Plateau, immeuble bleu',
        dropoff_location: 'SRID=4326;POINT(2.1098 13.5137)',
        items_total: 3000,
        delivery_fee: 500,
        total: 3500,
        payment_method: 'mobile_money',
      })
      .select('id')
      .single();
    if (error) throw error;
    return data.id as string;
  }

  beforeAll(async () => {
    zoneId = await firstZoneId();
    [client, livreur, autreLivreur, administrateur, boutiquier] = await Promise.all([
      createUser('client'),
      createUser('driver'),
      createUser('driver'),
      createUser('admin'),
      createUser('merchant'),
    ]);
    ({ merchantId } = await seedShop(boutiquier.id, zoneId));
  }, 120_000);

  afterAll(async () => {
    await admin.from('orders').delete().eq('merchant_id', merchantId);
    await cleanup();
  });

  it('le livreur assigné peut confirmer, et son nom est enregistré', async () => {
    const orderId = await commandeNita(livreur.id);

    const { data, error } = await livreur.db.rpc('confirm_payment_received', {
      p_order_id: orderId,
    });
    expect(error, error?.message).toBeNull();
    expect(data).toBe(true);

    const { data: apres } = await admin
      .from('orders')
      .select('payment_status, payment_confirmed_by, payment_confirmed_at')
      .eq('id', orderId)
      .single();

    expect(apres?.payment_status).toBe('paid');
    // Sans cette trace, un encaissement manquant ne remonte à personne.
    expect(apres?.payment_confirmed_by).toBe(livreur.id);
    expect(apres?.payment_confirmed_at).toBeTruthy();
  }, 60_000);

  it('un autre livreur ne peut pas solder la course d’un collègue', async () => {
    const orderId = await commandeNita(livreur.id);

    const { error } = await autreLivreur.db.rpc('confirm_payment_received', {
      p_order_id: orderId,
    });
    expect(error).not.toBeNull();

    const { data: apres } = await admin
      .from('orders')
      .select('payment_status')
      .eq('id', orderId)
      .single();
    expect(apres?.payment_status).toBe('pending');
  }, 60_000);

  it('le client ne peut pas se déclarer payé lui-même', async () => {
    const orderId = await commandeNita(livreur.id);

    const { error } = await client.db.rpc('confirm_payment_received', {
      p_order_id: orderId,
    });
    expect(error).not.toBeNull();
  }, 60_000);

  it('l’admin peut confirmer même sans livreur assigné', async () => {
    // Le cas qui justifie le bouton dans l'admin : le client appelle pour
    // dire qu'il a payé, et aucun livreur n'est encore sur la course.
    const orderId = await commandeNita(null);

    const { data, error } = await administrateur.db.rpc('confirm_payment_received', {
      p_order_id: orderId,
    });
    expect(error, error?.message).toBeNull();
    expect(data).toBe(true);

    const { data: apres } = await admin
      .from('orders')
      .select('payment_status, payment_confirmed_by')
      .eq('id', orderId)
      .single();
    expect(apres?.payment_status).toBe('paid');
    expect(apres?.payment_confirmed_by).toBe(administrateur.id);
  }, 60_000);

  it('confirmer deux fois ne compte qu’une fois', async () => {
    // Le livreur appuie, le réseau est lent, il rappuie. La file hors-ligne
    // peut aussi rejouer l'action après une coupure.
    const orderId = await commandeNita(livreur.id);

    const premier = await livreur.db.rpc('confirm_payment_received', { p_order_id: orderId });
    const second = await livreur.db.rpc('confirm_payment_received', { p_order_id: orderId });

    expect(premier.data).toBe(true);
    expect(second.data).toBe(false);
  }, 60_000);

  it('seul le service peut enregistrer un paiement constaté chez Nita', async () => {
    // `mark_order_paid` attribue l'encaissement à Nita, sans nom. Ouverte au
    // client, elle lui permettrait d'effacer sa dette sans laisser de trace.
    const orderId = await commandeNita(livreur.id);

    const { error } = await client.db.rpc('mark_order_paid', {
      p_order_id: orderId,
      p_reference: 'ACHATFAUX',
    });
    expect(error).not.toBeNull();

    const { data: parLeService } = await admin.rpc('mark_order_paid', {
      p_order_id: orderId,
      p_reference: 'ACHATVRAI',
    });
    expect(parLeService).toBe(true);

    const { data: apres } = await admin
      .from('orders')
      .select('payment_status, payment_ref, payment_confirmed_by')
      .eq('id', orderId)
      .single();
    expect(apres?.payment_status).toBe('paid');
    expect(apres?.payment_ref).toBe('ACHATVRAI');
    // Constaté par Nita : aucun humain à qui l'imputer.
    expect(apres?.payment_confirmed_by).toBeNull();
  }, 60_000);
});
