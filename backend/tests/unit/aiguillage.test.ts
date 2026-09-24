import { afterEach, describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';
import type { DecisionJev } from '../../src/ai/jev.js';

const generate = vi.hoisted(() => vi.fn());
vi.mock('../../src/ai/llmClient.js', () => ({
  llmClient: () => ({ model: 'test', generate }),
  fastLlmClient: () => ({ model: 'test-fast', generate }),
  llmEnabled: true,
  LlmUnavailableError: class extends Error {},
}));
vi.mock('../../src/services/dispatch.js', () => ({ queueDispatch: vi.fn(async () => undefined) }));

// Jev simulé : la décision est fixée par chaque test.
const jev = vi.hoisted(() => ({ decision: null as DecisionJev | null, actif: false, muet: false }));
vi.mock('../../src/ai/aiguillage.js', async (original) => ({
  ...(await original<typeof import('../../src/ai/aiguillage.js')>()),
  aiguillageActif: vi.fn(() => jev.actif),
  // `muet` : Jev ne répond jamais — la réponse ne doit pas l'attendre.
  consulterJev: vi.fn(() => (jev.muet ? new Promise(() => undefined) : Promise.resolve(jev.decision))),
}));

import { decider, intentionChoisie } from '../../src/ai/aiguillage.js';
import { chatRoutes } from '../../src/routes/chat.js';

const COMMANDE = '22222222-2222-4222-8222-222222222222';
const NIAMEY = { lat: 13.5137, lng: 2.1098 };
const d = (choix: DecisionJev['choix'], confiance: number, probabilites: DecisionJev['probabilites'] = {}): DecisionJev =>
  ({ choix, confiance, probabilites, ms: 300, cout: 0 });

afterEach(() => { vi.clearAllMocks(); jev.decision = null; jev.actif = false; jev.muet = false; });

describe('decider — la route selon la confiance de Jev', () => {
  it('sûr : Jev décide', () => {
    expect(decider(d('suivi', 0.93), 'ça fait une heure que j’attends')).toMatchObject({ type: 'intention', intention: 'suivi' });
  });

  it('hésite sur une ACTION : des tuiles avec ce qu’on a compris, plus « Autre chose »', () => {
    const route = decider(d('livreur', 0.55, { livreur: 0.55, suivi: 0.4, recherche: 0.05 }), 'le livreur');
    expect(route.type).toBe('clarifier');
    if (route.type !== 'clarifier') return;
    expect(route.components[0]!.data.items).toEqual([
      { label: 'Commander un livreur', value: 'intention:livreur::le livreur' },
      { label: 'Suivre ma commande', value: 'intention:suivi::le livreur' },
      { label: 'Autre chose', value: 'intention:modele::le livreur' },
    ]);
  });

  it('hésite entre pistes de catalogue : pas de tuiles, la recherche essaie', () => {
    expect(decider(d('recherche', 0.6, { recherche: 0.6, boutique: 0.35 }), 'attieke').type).toBe('habituel');
  });

  it('une demande en forme de produit, mal transcrite : la recherche, pas des tuiles hors sujet', () => {
    // Vu en vrai : « Je veux du bon à checker » (attiéké mal entendu) donnait
    // « Des idées de quoi commander » et « Suivre ma commande ».
    const perdu = d('envie', 0.45, { envie: 0.45, suivi: 0.3, social: 0.2 });
    expect(decider(perdu, 'Je veux du bon à checker.').type).toBe('habituel');
    // Une vraie hésitation sur une action garde ses tuiles.
    expect(decider(perdu, 'où en est ma commande de tout à l’heure').type).toBe('clarifier');
  });

  it('Jev éteint, en panne ou trop lent : chemin habituel', () => {
    expect(decider(null, 'pain').type).toBe('habituel');
    expect(decider({ ...d(null, 0), erreur: 'TimeoutError' }, 'pain').type).toBe('habituel');
  });

  it('recherche : aucune indication ajoutée, la recherche catalogue lit la phrase brute', async () => {
    const { indication } = await import('../../src/ai/aiguillage.js');
    expect(indication('recherche')).toBeNull();
    expect(indication('suivi')).toContain('[Aiguillage');
  });

  it('lit la tuile touchée, et refuse ce qui n’en est pas une', () => {
    expect(intentionChoisie({ action: 'quick_reply', payload: { value: 'intention:suivi::le livreur' } }))
      .toEqual({ intention: 'suivi', message: 'le livreur' });
    expect(intentionChoisie({ action: 'quick_reply', payload: { value: 'intention:pirate::x' } })).toBeNull();
    expect(intentionChoisie({ action: 'quick_reply', payload: { value: 'vider_panier' } })).toBeNull();
  });
});

function fausseBase() {
  const inserts: Array<Record<string, unknown>> = [];
  const rpc = vi.fn(async (nom: string, args?: Record<string, unknown>) => {
    if (nom === 'place_courier_order') return { data: COMMANDE, error: null };
    if (nom === 'order_tracking') return { data: { order_id: COMMANDE, type: 'courier', status: 'ready' }, error: null };
    if (nom === 'courier_city_offer') return { data: { price: 1000, callback_minutes: 7 }, error: null };
    // Trouvé exactement seulement pour « riz » : le reste du catalogue est vide.
    if (nom === 'catalog_products_page' && String(args?.p_query ?? '').includes('riz')) {
      return {
        data: {
          items: [{ id: '55555555-5555-4555-8555-555555555555', name: 'Riz parfumé 5 kg', price: 4500, merchant_name: 'Épicerie', is_available: true }],
          total: 1, offset: 0, next_offset: null, match_type: 'exact',
        },
        error: null,
      };
    }
    return { data: null, error: null };
  });
  const chaine = (table: string): unknown => new Proxy(() => undefined, {
    get: (_c, prop) => {
      if (prop === 'then') return (ok: (v: unknown) => void) => ok(table === 'conversations' ? { data: { id: 'conv-1' }, error: null } : { data: null, error: null });
      if (prop === 'insert') return (ligne: Record<string, unknown>) => { if (table === 'messages') inserts.push(ligne); return chaine(table); };
      return () => chaine(table);
    },
  });
  return { rpc, from: vi.fn((t: string) => chaine(t)), inserts };
}

async function appAvec(db: unknown) {
  const app = Fastify();
  app.decorate('requireAuth', async (request: { user?: unknown; supabase?: unknown }) => {
    request.user = { id: 'client-aiguillage' };
    request.supabase = db;
  });
  await app.register(chatRoutes);
  return app;
}

const envoyer = (app: Awaited<ReturnType<typeof appAvec>>, payload: Record<string, unknown>) =>
  app.inject({ method: 'POST', url: '/chat', payload: { client_message_id: crypto.randomUUID(), context: NIAMEY, ...payload } });

describe('POST /chat — aiguillage réel', () => {
  it('Jev comprend ce que les mots ratent : « une moto pour une course » commande un livreur', async () => {
    jev.decision = d('livreur', 0.94);
    jev.actif = true;
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await envoyer(app, { text: 'il me faut une moto pour une course' });
    expect(res.json().content).toContain('7 minutes');
    expect(db.rpc).toHaveBeenCalledWith('place_courier_order', expect.anything());
    expect(generate).not.toHaveBeenCalled();
    await app.close();
  });

  it('Jev hésite : tuiles, aucune commande passée', async () => {
    jev.decision = d('livreur', 0.55, { livreur: 0.55, suivi: 0.4 });
    jev.actif = true;
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await envoyer(app, { text: 'le livreur' });
    expect(res.json().components[0].type).toBe('quick_replies');
    expect(res.json().content).toContain('Vous voulez');
    expect(db.rpc).not.toHaveBeenCalledWith('place_courier_order', expect.anything());
    await app.close();
  });

  it('le client touche « Commander un livreur » : la commande part, sa bulle affiche le libellé', async () => {
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await envoyer(app, {
      interaction: { action: 'quick_reply', payload: { label: 'Commander un livreur', value: 'intention:livreur::le livreur' } },
    });
    expect(res.json().content).toContain('7 minutes');
    expect(db.inserts[0]).toMatchObject({ role: 'user', content: 'Commander un livreur' });
    await app.close();
  });

  it('Jev décide « suivi » : les mots ne transforment plus la phrase en recherche de livreur', async () => {
    jev.decision = d('suivi', 0.92);
    jev.actif = true;
    const db = fausseBase();
    const app = await appAvec(db);
    generate.mockResolvedValue({ text: 'Je regarde votre commande.', toolCalls: [], usage: { input: 1, output: 1, cached: 0 } });
    await envoyer(app, { text: 'je veux un livreur, il est où ?' });
    expect(db.rpc).not.toHaveBeenCalledWith('place_courier_order', expect.anything());
    const historique = JSON.stringify(generate.mock.calls[0]?.[0]);
    expect(historique).toContain('[Aiguillage : le client demande où en est sa commande');
    await app.close();
  });

  it('produit trouvé exactement : réponse SANS attendre Jev (ici, muet)', async () => {
    jev.actif = true;
    jev.muet = true;
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await envoyer(app, { text: 'du riz' });
    expect(res.json().components[0].type).toBe('product_carousel');
    expect(generate).not.toHaveBeenCalled();
    // Une seule recherche : celle faite en parallèle est réutilisée.
    expect(db.rpc.mock.calls.filter(([nom]) => nom === 'catalog_products_page')).toHaveLength(1);
    await app.close();
  });

  it('Jev éteint : les détecteurs à mots fonctionnent comme avant', async () => {
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await envoyer(app, { text: 'Je veux un livreur' });
    expect(res.json().content).toContain('7 minutes');
    await app.close();
  });
});
