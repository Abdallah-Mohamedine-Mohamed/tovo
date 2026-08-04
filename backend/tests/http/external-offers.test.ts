import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app.js';
import { embed } from '../../src/services/embeddings.js';
import { admin as service, cleanup, createUser, type TestUser } from '../rls/harness.js';

/**
 * Le comparateur hybride, côté offres externes.
 *
 * Les partenaires sont commandables, les offres externes seulement
 * consultables. Le mécanisme existait depuis le début dans `compare_prices`,
 * mais la table restait vide : rien ne l'alimentait, donc le client ne voyait
 * jamais que la moitié de la comparaison promise.
 */
describe('API — offres externes', () => {
  let app: FastifyInstance;
  let administrateur: TestUser;
  let client: TestUser;
  let offerId: string;

  const auth = (u: TestUser) => ({ authorization: `Bearer ${u.accessToken}` });
  const position = { lat: 13.5137, lng: 2.1098 };

  beforeAll(async () => {
    app = await buildApp();
    await app.ready();
    [administrateur, client] = await Promise.all([createUser('admin'), createUser('client')]);
  }, 120_000);

  afterAll(async () => {
    if (offerId) await service.from('external_offers').delete().eq('id', offerId);
    await app.close();
    await cleanup();
  });

  it('un client ne peut pas publier de prix concurrent', async () => {
    // Ces prix s'affichent à tous : les laisser écrire par n'importe qui
    // permettrait d'inventer des prix pour discréditer une boutique.
    const res = await app.inject({
      method: 'POST',
      url: '/admin/external-offers',
      headers: auth(client),
      payload: { source: 'jumia', title: 'Ventilateur', price: 15000 },
    });
    expect(res.statusCode).toBe(403);
  }, 60_000);

  it('l’admin enregistre une offre, et elle est indexée', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/admin/external-offers',
      headers: auth(administrateur),
      payload: {
        source: 'Jumia Niger',
        title: 'Ventilateur brasseur d’air 16 pouces',
        price: 18500,
        source_url: 'https://www.jumia.ne/exemple-ventilateur',
        valid_days: 30,
      },
    });

    expect(res.statusCode).toBe(201);
    offerId = res.json().offer_id;

    const { data } = await service
      .from('external_offers')
      .select('embedded_at, expires_at, created_by')
      .eq('id', offerId)
      .single();

    // Sans embedding, `compare_prices` ne la remonterait jamais — et rien
    // n'aurait signalé l'anomalie.
    expect(data?.embedded_at).toBeTruthy();
    expect(data?.created_by).toBe(administrateur.id);

    // Trente jours, pas vingt-quatre heures : un prix relevé à la main ne
    // doit pas disparaître avant d'avoir servi.
    const jours = (new Date(data!.expires_at as string).getTime() - Date.now()) / 86_400_000;
    expect(jours).toBeGreaterThan(25);
  }, 120_000);

  it('elle ressort dans une comparaison de prix, non commandable', async () => {
    const vecteur = await embed('ventilateur', 'query');
    const { data, error } = await client.db.rpc('compare_prices', {
      query_embedding: JSON.stringify(vecteur),
      origin_lat: position.lat,
      origin_lng: position.lng,
      radius_m: 8000,
      match_count: 10,
    });
    expect(error, error?.message).toBeNull();

    const lignes = (data ?? []) as Array<Record<string, unknown>>;
    const notre = lignes.find((l) => l.ref_id === offerId);

    expect(notre, 'l’offre externe doit apparaître dans la comparaison').toBeTruthy();
    expect(notre?.source_kind).toBe('external');
    // Le point du comparateur hybride : consultable, jamais commandable.
    // L'UI affiche « Voir » et non « Commander » sur cette base.
    expect(notre?.is_orderable).toBe(false);
    expect(notre?.source_url).toContain('jumia.ne');
  }, 120_000);

  it('changer le titre réindexe l’offre', async () => {
    // Sans réindexation, l'offre continuerait de remonter sur l'ancien
    // libellé : une erreur silencieuse, invisible dans l'admin.
    const { data: avant } = await service
      .from('external_offers')
      .select('embedded_at')
      .eq('id', offerId)
      .single();

    const res = await app.inject({
      method: 'PATCH',
      url: `/admin/external-offers/${offerId}`,
      headers: auth(administrateur),
      payload: { title: 'Climatiseur mobile 9000 BTU', price: 250000 },
    });
    expect(res.statusCode).toBe(200);

    const { data: apres } = await service
      .from('external_offers')
      .select('embedded_at, price')
      .eq('id', offerId)
      .single();

    expect(apres?.price).toBe(250000);
    expect(new Date(apres!.embedded_at as string).getTime()).toBeGreaterThan(
      new Date(avant!.embedded_at as string).getTime(),
    );
  }, 120_000);

  it('l’admin peut la retirer', async () => {
    const res = await app.inject({
      method: 'DELETE',
      url: `/admin/external-offers/${offerId}`,
      headers: auth(administrateur),
    });
    expect(res.statusCode).toBe(200);

    const { count } = await service
      .from('external_offers')
      .select('*', { count: 'exact', head: true })
      .eq('id', offerId);
    expect(count).toBe(0);
  }, 60_000);
});
