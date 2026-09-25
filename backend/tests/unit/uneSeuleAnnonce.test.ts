import { beforeEach, describe, expect, it, vi } from 'vitest';

// Trois appareils du même client : un iPhone qui affiche la Live Activity,
// un iPhone sans (Live Activities désactivées), un téléphone Android.
const IPHONE = 'fcm-iphone';
const IPHONE_SANS = 'fcm-iphone-sans';
const ANDROID = 'fcm-android';

const classiques: string[][] = [];
const silencieux: Array<{ token: string; data: Record<string, string> }> = [];
const alertesActivite: Array<{ statut: string; alerte: unknown }> = [];

vi.mock('../../src/services/liveActivities.js', () => ({
  updateLiveActivities: vi.fn(async (_id: string, statut: string, _livreur: unknown, alerte: unknown) => {
    alertesActivite.push({ statut, alerte });
    return new Set([IPHONE]);
  }),
}));
vi.mock('../../src/services/arrivee.js', () => ({
  estimerArrivee: vi.fn(async () => 1_790_000_000),
}));
vi.mock('../../src/services/notifications.js', () => ({
  sendPush: vi.fn(async (messages: Array<{ token: string }>) => {
    classiques.push(messages.map((m) => m.token));
    return { invalidTokens: [] };
  }),
  sendData: vi.fn(async (messages: Array<{ token: string; data: Record<string, string> }>) => {
    silencieux.push(...messages);
    return { invalidTokens: [] };
  }),
}));

const commande = {
  id: 'c1', user_id: 'u1', total: 3500, payment_method: 'cash', type: 'delivery',
  driver_id: null, placed_at: '2026-09-25T12:00:00Z',
  merchants: { name: 'Albarka Food' }, courier_details: null,
};
const tables: Record<string, unknown> = {
  orders: commande,
  profiles: { full_name: 'Awa Issoufou' },
  push_tokens: [
    { token: IPHONE, platform: 'ios' },
    { token: IPHONE_SANS, platform: 'ios' },
    { token: ANDROID, platform: 'android' },
  ],
};
const chaine = (donnees: unknown): unknown => new Proxy(() => undefined, {
  get: (_c, prop) => (prop === 'then'
    ? (ok: (v: unknown) => void) => ok({ data: donnees, error: null })
    : () => chaine(donnees)),
});
vi.mock('../../src/services/supabase.js', () => ({
  serviceClient: () => ({
    from: (table: string) => chaine(tables[table] ?? null),
    rpc: (nom: string) => chaine(nom === 'tokens_for'
      ? [{ token: IPHONE }, { token: IPHONE_SANS }, { token: ANDROID }]
      : []),
  }),
}));

import { notifierClient } from '../../src/services/orderNotifications.js';

describe('une seule annonce par appareil', () => {
  beforeEach(() => {
    classiques.length = 0;
    silencieux.length = 0;
    alertesActivite.length = 0;
  });

  it('chaque téléphone est prévenu une fois, à sa manière', async () => {
    await notifierClient('c1', 'confirmed');
    // iPhone à Live Activity : l'étape passe par elle, AVEC alerte.
    expect(alertesActivite[0]?.alerte).toMatchObject({ titre: expect.any(String), corps: expect.any(String) });
    // Android : sa notification de suivi, par message silencieux.
    expect(silencieux.map((m) => m.token)).toEqual([ANDROID]);
    expect(silencieux[0]?.data).toMatchObject({
      kind: 'suivi', order_id: 'c1', status: 'confirmed', alerte: '1',
      client: 'Awa', merchant_name: 'Albarka Food', arrivee: '1790000000',
    });
    // La notification classique : seulement l'iPhone sans Live Activity.
    expect(classiques).toEqual([[IPHONE_SANS]]);
  });

  it('une étape silencieuse met quand même le suivi Android à jour', async () => {
    await notifierClient('c1', 'preparing');
    // L'île s'ouvre quand même, avec l'étape : toutes les étapes se voient.
    expect(alertesActivite[0]?.alerte).toEqual({ titre: 'Tovo', corps: 'En cuisine' });
    expect(silencieux.map((m) => m.token)).toEqual([ANDROID]);
    expect(silencieux[0]?.data.alerte).toBe('0');
    expect(classiques).toEqual([]);
  });
});
