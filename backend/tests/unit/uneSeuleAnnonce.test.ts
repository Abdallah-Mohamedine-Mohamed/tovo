import { beforeEach, describe, expect, it, vi } from 'vitest';

// Deux appareils du même client : un iPhone qui affiche la Live Activity,
// et un téléphone Android.
const IPHONE = 'fcm-iphone';
const ANDROID = 'fcm-android';

const envoisClassiques: string[][] = [];
const alertesActivite: Array<{ statut: string; alerte: unknown }> = [];

vi.mock('../../src/services/liveActivities.js', () => ({
  updateLiveActivities: vi.fn(async (_id: string, statut: string, _livreur: unknown, alerte: unknown) => {
    alertesActivite.push({ statut, alerte });
    return new Set([IPHONE]);
  }),
}));
vi.mock('../../src/services/notifications.js', () => ({
  sendPush: vi.fn(async (messages: Array<{ token: string }>) => {
    envoisClassiques.push(messages.map((m) => m.token));
    return { invalidTokens: [] };
  }),
}));

const commande = {
  id: 'c1', user_id: 'u1', total: 3500, payment_method: 'cash', type: 'delivery',
  driver_id: null, merchants: { name: 'Albarka Food' }, courier_details: null,
};
const chaine = (donnees: unknown): unknown => new Proxy(() => undefined, {
  get: (_c, prop) => (prop === 'then'
    ? (ok: (v: unknown) => void) => ok({ data: donnees, error: null })
    : () => chaine(donnees)),
});
vi.mock('../../src/services/supabase.js', () => ({
  serviceClient: () => ({
    from: () => chaine(commande),
    rpc: (nom: string) => chaine(nom === 'tokens_for' ? [{ token: IPHONE }, { token: ANDROID }] : []),
  }),
}));

import { notifierClient } from '../../src/services/orderNotifications.js';

describe('une seule annonce par appareil', () => {
  beforeEach(() => {
    envoisClassiques.length = 0;
    alertesActivite.length = 0;
  });

  it('l’iPhone est prévenu par sa Live Activity, Android par une notification', async () => {
    await notifierClient('c1', 'confirmed');
    // L'étape passe par la Live Activity, AVEC une alerte : l'île s'ouvre.
    expect(alertesActivite).toHaveLength(1);
    expect(alertesActivite[0]?.alerte).toMatchObject({ titre: expect.any(String), corps: expect.any(String) });
    // La notification classique ne part que vers l'appareil sans activité.
    expect(envoisClassiques).toEqual([[ANDROID]]);
  });
});
