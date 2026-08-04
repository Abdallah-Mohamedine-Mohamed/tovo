import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../../src/app.js';
import { indexProductsByIds } from '../../src/services/indexer.js';
import {
  admin,
  cleanup,
  createUser,
  firstZoneId,
  seedShop,
  type TestUser,
} from '../rls/harness.js';

/**
 * Le fil conversationnel, de bout en bout.
 *
 * Vraie base, vrai modèle, vrais embeddings. C'est le seul test qui répond à
 * la question qui compte : est-ce qu'un habitant de Niamey peut commander en
 * écrivant ce qu'il veut manger.
 *
 * Ces tests consomment des appels Gemini. Quelques centimes.
 */
describe('Conversation', () => {
  let app: FastifyInstance;
  let client: TestUser;
  let boutiquier: TestUser;
  let merchantId: string;
  let conversationId: string | undefined;
  let idTuoZaafi: string;

  const marqueur = randomUUID().slice(0, 6);
  const position = { lat: 13.529, lng: 2.087 };

  function auth(user: TestUser): Record<string, string> {
    return { authorization: `Bearer ${user.accessToken}` };
  }

  async function parler(payload: Record<string, unknown>) {
    const res = await app.inject({
      method: 'POST',
      url: '/chat',
      headers: auth(client),
      payload: {
        client_message_id: randomUUID(),
        conversation_id: conversationId,
        context: position,
        ...payload,
      },
    });
    if (res.statusCode === 200) {
      conversationId = res.json().conversation_id as string;
    }
    return res;
  }

  beforeAll(async () => {
    app = await buildApp();
    await app.ready();

    const zoneId = await firstZoneId();
    [client, boutiquier] = await Promise.all([
      createUser('client'),
      createUser('merchant'),
    ]);
    ({ merchantId } = await seedShop(boutiquier.id, zoneId));

    const { data: crees } = await admin
      .from('products')
      .insert([
        {
          merchant_id: merchantId,
          name: `Tuo zaafi ${marqueur}`,
          description: 'Pâte de mil épaisse, sauce arachide maison',
          price: 1500,
          is_available: true,
        },
        {
          merchant_id: merchantId,
          name: `Fura ${marqueur}`,
          description: 'Boule de mil au lait caillé, boisson traditionnelle',
          price: 500,
          is_available: true,
        },
      ])
      .select('id, name');

    const tuo = (crees ?? []).find((p) => p.name.startsWith('Tuo zaafi'))!;
    idTuoZaafi = tuo.id as string;

    await admin.from('product_options').insert({
      product_id: tuo.id,
      name: 'Portion',
      is_required: true,
      min_select: 1,
      max_select: 1,
    });
    const { data: option } = await admin
      .from('product_options')
      .select('id')
      .eq('product_id', tuo.id)
      .single();
    await admin.from('product_option_values').insert([
      { option_id: option!.id, name: 'Simple', price_delta: 0 },
      { option_id: option!.id, name: 'Double', price_delta: 700 },
    ]);

    // Seulement NOS produits : indexer toute la file d'attente de la base
    // ferait cinquante appels Gemini et dépasserait le délai du hook.
    await indexProductsByIds((crees ?? []).map((p) => p.id as string));
  }, 180_000);

  afterAll(async () => {
    await app.close();
    await admin.from('products').delete().eq('merchant_id', merchantId);
    await cleanup();
  });

  it('répond à une demande en langage naturel avec de vrais produits', async () => {
    const res = await parler({ text: 'je veux manger du tuo zaafi' });

    expect(res.statusCode, res.body.slice(0, 300)).toBe(200);
    const corps = res.json();

    expect(corps.contract_version).toBe(1);
    expect(typeof corps.content).toBe('string');
    expect(Array.isArray(corps.components)).toBe(true);

    // Le modèle a dû appeler un outil : sans ça, aucun composant.
    const carrousel = corps.components.find(
      (c: { type: string }) => c.type === 'product_carousel',
    );
    expect(carrousel, `aucun carrousel dans : ${JSON.stringify(corps.components)}`)
      .toBeDefined();

    const noms = carrousel.data.items.map((i: { name: string }) => i.name);
    expect(noms.some((n: string) => n.includes('Tuo zaafi'))).toBe(true);
  }, 90_000);

  it('ne cite que des identifiants qui existent réellement', async () => {
    const res = await parler({ text: 'et qu’est-ce que vous avez à boire ?' });
    expect(res.statusCode).toBe(200);

    const corps = res.json();
    const ids: string[] = [];
    const collecter = (v: unknown): void => {
      if (Array.isArray(v)) return v.forEach(collecter);
      if (v && typeof v === 'object') {
        for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
          if (typeof val === 'string' && (k === 'id' || k.endsWith('_id'))) ids.push(val);
          else collecter(val);
        }
      }
    };
    collecter(corps.components);

    const uuids = ids.filter((i) =>
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(i),
    );

    // Chaque identifiant sorti du fil doit correspondre à une ligne réelle.
    // C'est la promesse « l'IA n'invente rien », vérifiée contre la base.
    //
    // Une requête par table, et non par identifiant : 4 allers-retours au
    // lieu de 4×N vers une base distante.
    if (uuids.length === 0) return;

    const connus = new Set<string>();
    for (const table of ['products', 'categories', 'merchants', 'product_options']) {
      const { data } = await admin.from(table).select('id').in('id', uuids);
      for (const ligne of data ?? []) connus.add(ligne.id as string);
    }

    const inventes = uuids.filter((id) => !connus.has(id));
    expect(inventes, `identifiants absents de la base : ${inventes.join(', ')}`).toEqual([]);
  }, 90_000);

  it('propose les options avant de permettre l’ajout au panier', async () => {
    const res = await parler({
      interaction: { action: 'select_product', payload: { product_id: idTuoZaafi } },
    });

    expect(res.statusCode).toBe(200);
    const corps = res.json();

    const selecteur = corps.components.find(
      (c: { type: string }) => c.type === 'option_selector',
    );
    expect(selecteur, `attendu option_selector, reçu ${JSON.stringify(corps.components.map((c: {type:string}) => c.type))}`)
      .toBeDefined();
    expect(selecteur.data.options[0].required).toBe(true);
  }, 90_000);

  it('rejoue une requête identique sans rappeler le modèle', async () => {
    const idMessage = randomUUID();
    const payload = {
      client_message_id: idMessage,
      conversation_id: conversationId,
      context: position,
      text: 'montre-moi les catégories',
    };

    const premier = await app.inject({
      method: 'POST',
      url: '/chat',
      headers: auth(client),
      payload,
    });
    expect(premier.statusCode).toBe(200);

    const compter = async () => {
      const { count } = await admin
        .from('messages')
        .select('id', { count: 'exact', head: true })
        .eq('conversation_id', conversationId!);
      return count ?? 0;
    };

    const avant = await compter();

    const second = await app.inject({
      method: 'POST',
      url: '/chat',
      headers: auth(client),
      payload,
    });

    expect(second.statusCode).toBe(200);
    expect(second.json().content).toBe(premier.json().content);
    // Compter les messages plutôt que chronométrer : une durée dépend du
    // réseau et rendrait le test instable. Ce qu'on veut prouver, c'est
    // qu'aucun nouveau tour n'a été créé — donc que le modèle n'a pas été
    // rappelé ni facturé.
    expect(await compter()).toBe(avant);
  }, 120_000);

  it('exige une authentification', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/chat',
      payload: { client_message_id: randomUUID(), text: 'bonjour' },
    });
    expect(res.statusCode).toBe(401);
  });

  it('refuse un corps qui mélange texte et interaction', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/chat',
      headers: auth(client),
      payload: {
        client_message_id: randomUUID(),
        text: 'bonjour',
        interaction: { action: 'open_cart', payload: {} },
      },
    });
    expect(res.statusCode).toBe(400);
  });

  it('refuse un corps qui mélange parole et texte', async () => {
    // Un seul canal par tour : deux demandes dans le même message
    // laisseraient le modèle arbitrer, et il choisirait au hasard.
    const res = await app.inject({
      method: 'POST',
      url: '/chat',
      headers: auth(client),
      payload: {
        client_message_id: randomUUID(),
        text: 'bonjour',
        audio: { mime: 'audio/mp4', data: 'AAAA' },
      },
    });
    expect(res.statusCode).toBe(400);
  });

  it('refuse un enregistrement démesuré', async () => {
    // Dix minutes d'audio se factureraient au prix fort et mettraient une
    // éternité à revenir. L'app coupe à 60 s ; ce plafond arrête ce qui ne
    // vient pas d'elle.
    const res = await app.inject({
      method: 'POST',
      url: '/chat',
      headers: auth(client),
      payload: {
        client_message_id: randomUUID(),
        audio: { mime: 'audio/mp4', data: 'A'.repeat(700_001) },
      },
    });
    expect(res.statusCode).toBe(400);
  });

  it('refuse un format audio que le modèle ne lit pas', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/chat',
      headers: auth(client),
      payload: {
        client_message_id: randomUUID(),
        audio: { mime: 'audio/amr', data: 'AAAA' },
      },
    });
    expect(res.statusCode).toBe(400);
  });
});
