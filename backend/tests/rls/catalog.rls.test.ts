import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { admin, anonymous, cleanup, createUser, firstZoneId, seedShop, type TestUser } from './harness.js';

describe('RLS — catalogue et profils', () => {
  let boutiquier: TestUser;
  let autreBoutiquier: TestUser;
  let client: TestUser;
  let merchantId: string;
  let productId: string;

  beforeAll(async () => {
    const zoneId = await firstZoneId();
    [boutiquier, autreBoutiquier, client] = await Promise.all([
      createUser('merchant'),
      createUser('merchant'),
      createUser('client'),
    ]);
    ({ merchantId, productId } = await seedShop(boutiquier.id, zoneId));
  }, 60_000);

  afterAll(cleanup);

  it('le catalogue approuvé est lisible sans authentification', async () => {
    const { data } = await anonymous().from('products').select('id, name').eq('id', productId);
    expect(data).toHaveLength(1);
  });

  it("une boutique non approuvée reste invisible aux autres", async () => {
    const { data: cachee } = await admin
      .from('merchants')
      .insert({
        owner_id: boutiquier.id,
        name: 'Boutique en attente',
        address_hint: 'Talladjé',
        location: 'SRID=4326;POINT(2.0980 13.4830)',
        is_approved: false,
      })
      .select('id')
      .single();

    const { data: vueParClient } = await client.db
      .from('merchants')
      .select('id')
      .eq('id', cachee!.id);
    expect(vueParClient).toHaveLength(0);

    // Le propriétaire, lui, voit sa boutique en attente.
    const { data: vueParProprietaire } = await boutiquier.db
      .from('merchants')
      .select('id')
      .eq('id', cachee!.id);
    expect(vueParProprietaire).toHaveLength(1);
  });

  it('un boutiquier ne peut pas modifier le produit d\'un autre', async () => {
    const { error } = await autreBoutiquier.db
      .from('products')
      .update({ price: 1 })
      .eq('id', productId);

    const { data: apres } = await anonymous().from('products').select('price').eq('id', productId);
    // Selon la politique, l'update est refusé ou ne touche aucune ligne.
    // Dans les deux cas, le prix ne doit pas avoir bougé.
    expect(apres?.[0]?.price).toBe(1500);
    void error;
  });

  it('un boutiquier modifie bien son propre produit', async () => {
    const { error } = await boutiquier.db
      .from('products')
      .update({ price: 1800 })
      .eq('id', productId);
    expect(error).toBeNull();

    const { data } = await anonymous().from('products').select('price').eq('id', productId);
    expect(data?.[0]?.price).toBe(1800);
  });

  it("un client ne peut pas créer de boutique à son nom", async () => {
    const { error } = await client.db.from('merchants').insert({
      owner_id: client.id,
      name: 'Fausse boutique',
      address_hint: 'Plateau',
      location: 'SRID=4326;POINT(2.1098 13.5137)',
      is_approved: true,
    });
    // La policy autorise owner_id = auth.uid(), mais is_approved doit rester
    // sous contrôle admin : la boutique ne doit pas apparaître au public.
    void error;
    const { data } = await anonymous().from('merchants').select('id').eq('owner_id', client.id);
    expect(data ?? []).toHaveLength(0);
  });

  it("un utilisateur ne peut pas se promouvoir admin", async () => {
    const { error } = await client.db
      .from('profiles')
      .update({ role: 'admin' })
      .eq('id', client.id);
    expect(error).not.toBeNull();

    const { data } = await admin.from('profiles').select('role').eq('id', client.id).single();
    expect(data?.role).toBe('client');
  });

  it("un utilisateur ne lit pas le profil d'un autre", async () => {
    const { data } = await client.db.from('profiles').select('id').eq('id', boutiquier.id);
    expect(data).toHaveLength(0);
  });

  it('le panier est strictement privé', async () => {
    const { data: cart } = await client.db
      .from('carts')
      .insert({ user_id: client.id, merchant_id: merchantId })
      .select('id')
      .single();
    expect(cart?.id).toBeDefined();

    const { data: vuParAutre } = await boutiquier.db.from('carts').select('id').eq('id', cart!.id);
    expect(vuParAutre).toHaveLength(0);
  });
});
