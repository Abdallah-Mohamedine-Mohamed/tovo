import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app.js';
import { admin, cleanup, createUser, type TestUser } from '../rls/harness.js';

/**
 * Adresses enregistrées.
 *
 * À Niamey l'adresse postale n'existe pas : on se repère par des indices
 * (« Yantala, derrière la pharmacie Al Nour »). Retaper cet indice à chaque
 * commande était la friction quotidienne la plus évitable de l'application.
 */
describe('API — adresses', () => {
  let app: FastifyInstance;
  let client: TestUser;
  let voisin: TestUser;

  const auth = (u: TestUser) => ({ authorization: `Bearer ${u.accessToken}` });

  beforeAll(async () => {
    app = await buildApp();
    await app.ready();
    [client, voisin] = await Promise.all([createUser('client'), createUser('client')]);
  }, 120_000);

  afterAll(async () => {
    await app.close();
    await cleanup();
  });

  it('exige une authentification', async () => {
    const res = await app.inject({ method: 'GET', url: '/addresses' });
    expect(res.statusCode).toBe(401);
  });

  it('la première adresse devient celle par défaut sans qu’on le demande', async () => {
    // Sinon le client en enregistre une et rien ne se pré-remplit à la
    // commande suivante : le gain de l'enregistrement est perdu.
    const res = await app.inject({
      method: 'POST',
      url: '/addresses',
      headers: auth(client),
      payload: {
        label: 'Maison',
        text_hint: 'Yantala, derrière la pharmacie Al Nour',
        lat: 13.529,
        lng: 2.087,
        is_default: false,
      },
    });
    expect(res.statusCode).toBe(201);

    const liste = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    const adresses = liste.json().addresses as Array<Record<string, unknown>>;
    expect(adresses).toHaveLength(1);
    expect(adresses[0]?.is_default).toBe(true);
    expect(adresses[0]?.label).toBe('Maison');
    // Le repère écrit compte autant que les coordonnées : c'est lui que le
    // livreur lit quand le GPS le pose au milieu du quartier.
    expect(adresses[0]?.text_hint).toContain('Al Nour');
  }, 60_000);

  it('renvoie des coordonnées exploitables, pas du WKB', async () => {
    const liste = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    const premiere = (liste.json().addresses as Array<Record<string, number>>)[0]!;

    expect(premiere.lat).toBeCloseTo(13.529, 3);
    expect(premiere.lng).toBeCloseTo(2.087, 3);
  }, 60_000);

  it('une seule adresse par défaut à la fois', async () => {
    // Deux adresses par défaut feraient livrer au hasard de l'ordre des
    // lignes, sans que le client comprenne pourquoi.
    await app.inject({
      method: 'POST',
      url: '/addresses',
      headers: auth(client),
      payload: {
        label: 'Bureau',
        text_hint: 'Plateau, immeuble bleu',
        lat: 13.5137,
        lng: 2.1098,
        is_default: true,
      },
    });

    const liste = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    const adresses = liste.json().addresses as Array<Record<string, unknown>>;

    expect(adresses.filter((a) => a.is_default)).toHaveLength(1);
    // Et celle par défaut arrive en tête, pour être proposée en premier.
    expect(adresses[0]?.label).toBe('Bureau');
  }, 60_000);

  it('changer d’adresse par défaut retire l’ancienne', async () => {
    const liste = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    const maison = (liste.json().addresses as Array<Record<string, unknown>>).find(
      (a) => a.label === 'Maison',
    )!;

    const res = await app.inject({
      method: 'POST',
      url: `/addresses/${maison.id}/default`,
      headers: auth(client),
    });
    expect(res.statusCode).toBe(200);

    const apres = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    const adresses = apres.json().addresses as Array<Record<string, unknown>>;
    expect(adresses.filter((a) => a.is_default)).toHaveLength(1);
    expect(adresses[0]?.label).toBe('Maison');
  }, 60_000);

  it('les adresses d’un client ne sont pas celles d’un autre', async () => {
    const res = await app.inject({ method: 'GET', url: '/addresses', headers: auth(voisin) });
    expect(res.json().addresses).toHaveLength(0);
  }, 60_000);

  it('un voisin ne peut pas supprimer une adresse qui n’est pas la sienne', async () => {
    const liste = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    const cible = (liste.json().addresses as Array<Record<string, unknown>>)[0]!;

    // La RLS ne renvoie pas d'erreur : elle ne voit simplement aucune ligne
    // à supprimer. C'est le nombre d'adresses restantes qui fait foi.
    await app.inject({
      method: 'DELETE',
      url: `/addresses/${cible.id}`,
      headers: auth(voisin),
    });

    const { count } = await admin
      .from('addresses')
      .select('*', { count: 'exact', head: true })
      .eq('id', cible.id as string);
    expect(count).toBe(1);
  }, 60_000);

  it('le propriétaire peut supprimer la sienne', async () => {
    const liste = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    const cible = (liste.json().addresses as Array<Record<string, unknown>>)[0]!;

    const res = await app.inject({
      method: 'DELETE',
      url: `/addresses/${cible.id}`,
      headers: auth(client),
    });
    expect(res.statusCode).toBe(200);

    const apres = await app.inject({ method: 'GET', url: '/addresses', headers: auth(client) });
    expect(apres.json().addresses).toHaveLength(1);
  }, 60_000);
});
