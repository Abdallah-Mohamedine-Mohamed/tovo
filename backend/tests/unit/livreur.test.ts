import { afterEach, describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';

const generate = vi.hoisted(() => vi.fn());
vi.mock('../../src/ai/llmClient.js', () => ({
  llmClient: () => ({ model: 'test', generate }),
  fastLlmClient: () => ({ model: 'test-fast', generate }),
  llmEnabled: true,
  LlmUnavailableError: class extends Error {},
}));
const queueDispatch = vi.hoisted(() => vi.fn(async () => undefined));
vi.mock('../../src/services/dispatch.js', () => ({ queueDispatch }));
vi.mock('../../src/services/orderNotifications.js', () => ({
  notifierBoutique: vi.fn(async () => undefined),
  notifierLivreursCommandeRecue: vi.fn(async () => undefined),
  // L'annulation prévient le client (et son Live Activity iOS).
  notifierClient: vi.fn(async () => undefined),
}));
vi.mock('../../src/services/payments.js', () => ({ ouvrirPaiement: vi.fn() }));

import { demandeUnLivreur } from '../../src/services/livreur.js';
import { chatRoutes } from '../../src/routes/chat.js';
import { orderRoutes } from '../../src/routes/orders.js';

const COMMANDE = '22222222-2222-4222-8222-222222222222';
const MESSAGE = '33333333-3333-4333-8333-333333333333';
const NIAMEY = { lat: 13.5137, lng: 2.1098 };

afterEach(() => vi.clearAllMocks());

/**
 * Base simulée : chaque requête `from(table)…` se résout selon la table,
 * chaque `rpc` selon son nom. Jamais la vraie base.
 */
function fausseBase(options: { courseEnCours?: boolean } = {}) {
  const rpc = vi.fn(async (nom: string) => {
    if (nom === 'place_courier_order') return { data: COMMANDE, error: null };
    if (nom === 'order_tracking') return { data: { order_id: COMMANDE, type: 'courier', status: 'ready' }, error: null };
    if (nom === 'courier_city_offer') return { data: { price: 1000, callback_minutes: 7 }, error: null };
    return { data: null, error: null };
  });
  const resultat = (table: string) => {
    if (table === 'conversations') return { data: { id: 'conv-1' }, error: null };
    if (table === 'orders') return { data: options.courseEnCours ? { id: COMMANDE } : null, error: null };
    return { data: null, error: null };
  };
  const chaine = (table: string): unknown => new Proxy(() => undefined, {
    get: (_cible, prop) => prop === 'then'
      ? (resoudre: (v: unknown) => void) => resoudre(resultat(table))
      : () => chaine(table),
  });
  return { rpc, from: vi.fn((table: string) => chaine(table)) };
}

async function appAvec(db: unknown) {
  const app = Fastify();
  app.decorate('requireAuth', async (request: { user?: unknown; supabase?: unknown }) => {
    request.user = { id: 'client-livreur' };
    request.supabase = db;
  });
  await app.register(chatRoutes);
  await app.register(orderRoutes);
  return app;
}

describe('« je veux un livreur » : la phrase', () => {
  it('reconnaît une demande de livreur', () => {
    for (const phrase of ['Je veux un livreur', 'envoie-moi un coursier', 'Un livreur svp', 'j’ai besoin d’un livreur vite', 'un livreur']) {
      expect(demandeUnLivreur(phrase), phrase).toBe(true);
    }
  });

  it('ne confond pas avec le livreur d’une commande en cours, ni un emploi', () => {
    for (const phrase of ['Où est mon livreur ?', 'appelle le livreur', 'le numéro du livreur', 'je veux devenir livreur', 'vous recrutez des livreurs ?']) {
      expect(demandeUnLivreur(phrase), phrase).toBe(false);
    }
  });
});

describe('POST /chat — un livreur sans formulaire', () => {
  it('passe la commande depuis la position, sans modèle, et annonce l’appel', async () => {
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/chat', payload: {
      client_message_id: MESSAGE, text: 'Je veux un livreur', context: NIAMEY,
    } });
    expect(res.statusCode).toBe(200);
    expect(res.json().content).toContain('Un livreur vous appelle dans les **7 minutes**');
    expect(res.json().components[0].type).toBe('order_tracking');
    expect(db.rpc).toHaveBeenCalledWith('place_courier_order', expect.objectContaining({
      p_client_order_id: MESSAGE, p_pickup_lat: NIAMEY.lat, p_pickup_lng: NIAMEY.lng,
      p_dropoff_lat: null, p_dropoff_lng: null,
    }));
    expect(queueDispatch).toHaveBeenCalledWith(COMMANDE);
    expect(generate).not.toHaveBeenCalled();
    await app.close();
  });

  it('une course déjà en route : on la montre, on n’en crée pas une seconde', async () => {
    const db = fausseBase({ courseEnCours: true });
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/chat', payload: {
      client_message_id: MESSAGE, text: 'je veux un livreur', context: NIAMEY,
    } });
    expect(res.json().content).toContain('déjà en route');
    expect(db.rpc).not.toHaveBeenCalledWith('place_courier_order', expect.anything());
    await app.close();
  });

  it('sans position connue, montre la carte au lieu de commander', async () => {
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/chat', payload: {
      client_message_id: MESSAGE, text: 'Je veux un livreur',
    } });
    expect(res.json().components[0].type).toBe('courier_form');
    // La carte prend la position d'elle-même : plus de « Touchez Ma position ».
    expect(res.json().content).not.toContain('Ma position');
    // Le client a déjà tout dit : la carte commandera d'elle-même dès qu'elle
    // aura la position, sans lui faire toucher un bouton de plus.
    expect(res.json().components[0].data.auto).toBe(true);
    expect(db.rpc).not.toHaveBeenCalledWith('place_courier_order', expect.anything());
    await app.close();
  });

  it('« envoyer un colis » : une carte pré-remplie, sans question', async () => {
    const app = await appAvec(fausseBase());
    const res = await app.inject({ method: 'POST', url: '/chat', payload: {
      client_message_id: MESSAGE, text: 'Je veux envoyer un colis', context: NIAMEY,
    } });
    const carte = res.json().components[0];
    expect(carte.type).toBe('courier_form');
    expect(carte.data.pickup).toMatchObject({ lat: NIAMEY.lat, lng: NIAMEY.lng });
    expect(carte.data.estimate).toEqual({ price: 1000, flat: true });
    expect(carte.data.callback_minutes).toBe(7);
    // Un colis peut avoir des détails à ajouter : le client garde le bouton.
    expect(carte.data.auto).toBeUndefined();
    expect(res.json().content).not.toMatch(/taille|destinataire|point de départ/i);
    expect(generate).not.toHaveBeenCalled();
    await app.close();
  });
});

describe('les deux sortes de livreur', () => {
  it('« va chercher » se reconnaît, et ne commande jamais un livreur chez moi', async () => {
    const { demandeDeRecuperation, demandeUnLivreur, lieuDeRecuperation } = await import('../../src/ai/intents.js');
    expect(demandeDeRecuperation('Va chercher un colis chez Moussa, à Harobanda')).toBe(true);
    expect(demandeDeRecuperation('récupère mon paquet au marché')).toBe(true);
    expect(demandeDeRecuperation('apporte-moi le document')).toBe(true);
    expect(demandeDeRecuperation('Je veux envoyer un colis')).toBe(false);
    // Sinon, la commande directe « viens chez moi » partait.
    expect(demandeUnLivreur('Je veux un livreur pour aller chercher mon colis')).toBe(false);
    expect(lieuDeRecuperation('Va chercher un colis chez Moussa, à Harobanda')).toBe('Chez Moussa, à Harobanda');
  });

  it('« va chercher mon colis chez Moussa au 90 12 34 56 » : la carte, lieu et numéro remplis', async () => {
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/chat', payload: {
      client_message_id: MESSAGE, context: NIAMEY,
      text: 'Va chercher mon colis chez Moussa au 90 12 34 56',
    } });
    const carte = res.json().components[0];
    expect(carte.type).toBe('courier_form');
    expect(carte.data.mode).toBe('recuperer');
    expect(carte.data.pickup.hint).toBe('Chez Moussa');
    expect(carte.data.pickup_contact).toBe('90 12 34 56');
    // L'arrivée : chez le client.
    expect(carte.data.dropoff).toMatchObject({ lat: NIAMEY.lat, lng: NIAMEY.lng });
    expect(res.json().content).toContain('apporte');
    expect(db.rpc).not.toHaveBeenCalledWith('place_courier_order', expect.anything());
    await app.close();
  });
});

describe('POST /orders/:id/cancel — le bouton Annuler', () => {
  it('annule et le dit simplement', async () => {
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: `/orders/${COMMANDE}/cancel` });
    expect(res.statusCode).toBe(200);
    expect(res.json().content).toBe('C’est annulé. Aucun livreur ne viendra.');
    expect(db.rpc).toHaveBeenCalledWith('cancel_my_order', { p_order_id: COMMANDE, p_motif: null });
    await app.close();
  });

  it('un refus de la base est lu tel quel, pas une erreur', async () => {
    const db = fausseBase();
    db.rpc.mockImplementationOnce(async () => ({
      data: 'Votre livreur est déjà en route. Appelez-le pour convenir de la suite.', error: null,
    }));
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: `/orders/${COMMANDE}/cancel` });
    expect(res.statusCode).toBe(200);
    expect(res.json().content).toContain('déjà en route');
    await app.close();
  });
});

describe('POST /orders — un colis sans destination', () => {
  it('seule la prise en charge est requise', async () => {
    const db = fausseBase();
    const app = await appAvec(db);
    const res = await app.inject({ method: 'POST', url: '/orders', payload: {
      type: 'courier', client_order_id: COMMANDE, pickup: NIAMEY, dropoff_contact: '',
    } });
    expect(res.statusCode).toBe(201);
    expect(db.rpc).toHaveBeenCalledWith('place_courier_order', expect.objectContaining({
      p_dropoff_lat: null, p_dropoff_lng: null, p_dropoff_contact: null, p_pickup_hint: null,
    }));
    expect(res.json().content).toContain('7 minutes');
    await app.close();
  });

  it('sans position de départ, refuse', async () => {
    const app = await appAvec(fausseBase());
    const res = await app.inject({ method: 'POST', url: '/orders', payload: {
      type: 'courier', client_order_id: COMMANDE,
    } });
    expect(res.statusCode).toBe(400);
    await app.close();
  });
});
