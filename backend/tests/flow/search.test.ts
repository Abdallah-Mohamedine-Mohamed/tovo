import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import { embed } from '../../src/services/embeddings.js';
import { indexProductsByIds } from '../../src/services/indexer.js';
import { admin, cleanup, createUser, firstZoneId, seedShop, type TestUser } from '../rls/harness.js';

/**
 * Recherche hybride, contre la vraie base et la vraie API.
 *
 * Ces tests consomment des appels Gemini — quelques centimes tout au plus,
 * mais ce sont de vrais appels. Ils vérifient la seule chose qui compte pour
 * le produit : est-ce qu'un client de Niamey trouve ce qu'il cherche.
 */
describe('Recherche hybride', () => {
  let boutiquier: TestUser;
  let client: TestUser;
  let merchantId: string;
  let idTuoZaafi: string;

  // Yantala, là où seedShop place la boutique.
  const position = { lat: 13.529, lng: 2.087 };

  const marqueur = randomUUID().slice(0, 6);

  beforeAll(async () => {
    const zoneId = await firstZoneId();
    [boutiquier, client] = await Promise.all([
      createUser('merchant'),
      createUser('client'),
    ]);
    ({ merchantId } = await seedShop(boutiquier.id, zoneId));

    // Un catalogue réaliste : des plats locaux dont les noms sont rares sur
    // le web, avec des descriptions qui portent le sens.
    const { data: crees } = await admin
      .from('products')
      .insert([
      {
        merchant_id: merchantId,
        name: `Tuo zaafi ${marqueur}`,
        description: 'Pâte de mil épaisse servie avec une sauce arachide maison',
        price: 1500,
        is_available: true,
      },
      {
        merchant_id: merchantId,
        name: `Dèguè ${marqueur}`,
        description: 'Couscous de mil au lait caillé sucré, servi frais',
        price: 800,
        is_available: true,
      },
      {
        merchant_id: merchantId,
        name: `Poulet braisé ${marqueur}`,
        description: 'Poulet grillé au feu de bois, accompagné de frites',
        price: 4500,
        is_available: true,
      },
      ])
      .select('id, name');

    idTuoZaafi = (crees ?? []).find((p) => p.name.startsWith('Tuo zaafi'))!.id as string;

    // Indexation ciblée : sans elle, la moitié sémantique est muette. On
    // n'indexe que nos produits pour ne pas dépendre de l'état global de la
    // base ni faire cinquante appels à l'API.
    const resultat = await indexProductsByIds((crees ?? []).map((p) => p.id as string));
    expect(resultat.failed).toBe(0);
  }, 180_000);

  afterAll(async () => {
    await admin.from('products').delete().eq('merchant_id', merchantId);
    await cleanup();
  });

  async function chercher(requete: string) {
    const vecteur = await embed(requete, 'query');
    const { data, error } = await client.db.rpc('search_products', {
      query_text: requete,
      query_embedding: JSON.stringify(vecteur),
      origin_lat: position.lat,
      origin_lng: position.lng,
      radius_m: 5000,
      filter_category: null,
      match_count: 8,
    });
    expect(error, `recherche « ${requete} » : ${error?.message ?? ''}`).toBeNull();
    return (data ?? []) as Array<{ name: string; price: number }>;
  }

  it('trouve par le SENS, sans le mot exact', async () => {
    // Le client ne connaît pas le nom du plat, il décrit ce qu'il veut.
    // C'est la moitié vectorielle qui doit répondre : « pâte de mil »
    // n'apparaît nulle part dans le nom du produit.
    const resultats = await chercher('pâte de mil avec de la sauce');
    expect(resultats.length).toBeGreaterThan(0);
    expect(resultats[0]?.name).toContain('Tuo zaafi');
  }, 60_000);

  it('trouve malgré une faute de frappe', async () => {
    // C'est la moitié trigramme qui répond : aucun modèle d'embedding ne
    // rattrape « tuo zafi » écrit à la va-vite sur un clavier de téléphone.
    const resultats = await chercher(`tuo zafi ${marqueur}`);
    expect(resultats.length).toBeGreaterThan(0);
    expect(resultats[0]?.name).toContain('Tuo zaafi');
  }, 60_000);

  it('trouve un plat local que le modèle ne connaît pas', async () => {
    const resultats = await chercher(`dègue ${marqueur}`);
    expect(resultats.some((r) => r.name.includes('Dèguè'))).toBe(true);
  }, 60_000);

  it('distingue les plats entre eux', async () => {
    const resultats = await chercher('poulet grillé au feu de bois');
    expect(resultats[0]?.name).toContain('Poulet');
  }, 60_000);

  it('ne renvoie rien hors du rayon', async () => {
    const vecteur = await embed('tuo zaafi', 'query');
    // Agadez, à 700 km de Niamey.
    const { data } = await client.db.rpc('search_products', {
      query_text: 'tuo zaafi',
      query_embedding: JSON.stringify(vecteur),
      origin_lat: 16.97,
      origin_lng: 7.99,
      radius_m: 5000,
      filter_category: null,
      match_count: 8,
    });
    expect(data ?? []).toHaveLength(0);
  }, 60_000);

  it('ignore les produits indisponibles', async () => {
    // Par identifiant, et non par filtre sur le nom : `%` est un caractère
    // d'échappement dans une URL, PostgREST ne le lit pas comme un joker et
    // la mise à jour ne touchait aucune ligne. Silencieusement.
    await admin.from('products').update({ is_available: false }).eq('id', idTuoZaafi);

    // Sur le nom COMPLET : `seedShop` crée aussi un « Tuo zaafi sauce
    // arachide », toujours disponible. Chercher la sous-chaîne le trouverait
    // et ferait échouer un test pourtant correct.
    const resultats = await chercher(`tuo zaafi ${marqueur}`);
    expect(resultats.map((r) => r.name)).not.toContain(`Tuo zaafi ${marqueur}`);

    await admin.from('products').update({ is_available: true }).eq('id', idTuoZaafi);
  }, 60_000);
});
