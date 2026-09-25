import { beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Les colis ne prévenaient aucun livreur (25/09) : le dispatch ne lisait que
 * l'ancienne colonne driver_profiles.fcm_token, vide, et ne gardait que les
 * livreurs à position fraîche de moins de deux minutes.
 */
const sendPush = vi.hoisted(() => vi.fn(async (messages: unknown[]) => ({ sent: messages.length, invalidTokens: [] as string[] })));
const etat = vi.hoisted(() => ({
  candidats: [] as Array<{ driver_id: string; full_name: string; fcm_token: string | null; distance_m: number }>,
  profils: [] as Array<{ id: string; zone_id: string | null }>,
  jetons: [] as Array<{ token: string; user_id: string }>,
  commande: { id: 'c1', status: 'ready', driver_id: null, type: 'courier', total: 1000, dropoff_hint: 'À voir avec le client', zone_id: 'z1' } as Record<string, unknown>,
}));

vi.mock('../../src/services/notifications.js', () => ({ sendPush }));
vi.mock('../../src/services/supabase.js', () => ({
  serviceClient: () => ({
    rpc: async () => ({ data: etat.candidats, error: null }),
    from: (table: string) => {
      const filtres: Array<(ligne: Record<string, unknown>) => boolean> = [];
      const chaine = {
        select: () => chaine,
        update: () => chaine,
        delete: () => chaine,
        eq: (col: string, val: unknown) => { filtres.push((l) => l[col] === undefined || l[col] === val); return chaine; },
        in: (col: string, vals: unknown[]) => { filtres.push((l) => vals.includes(l[col])); return chaine; },
        gt: () => chaine,
        maybeSingle: async () => ({ data: table === 'orders' ? etat.commande : null }),
        then: (resoudre: (v: unknown) => unknown) => {
          const source = table === 'driver_profiles' ? etat.profils : table === 'push_tokens' ? etat.jetons : [];
          return Promise.resolve({ data: (source as Record<string, unknown>[]).filter((l) => filtres.every((f) => f(l))), error: null }).then(resoudre);
        },
      };
      return chaine;
    },
  }),
}));

import { dispatchOrder } from '../../src/services/dispatch.js';

describe('dispatch — prévenir les livreurs', () => {
  beforeEach(() => {
    sendPush.mockClear();
    etat.candidats = [];
    etat.profils = [];
    etat.jetons = [];
  });

  it('un colis sans livreur proche connu prévient ceux de la zone, par push_tokens', async () => {
    etat.profils = [{ id: 'l1', zone_id: 'z1' }, { id: 'l2', zone_id: null }, { id: 'l3', zone_id: 'autre' }];
    etat.jetons = [{ token: 'jeton-l1', user_id: 'l1' }, { token: 'jeton-l2', user_id: 'l2' }, { token: 'jeton-l3', user_id: 'l3' }];

    const resultat = await dispatchOrder({ orderId: 'c1' });

    const envoyes = (sendPush.mock.calls[0]![0] as Array<{ token: string; title: string }>);
    expect(envoyes.map((m) => m.token).sort()).toEqual(['jeton-l1', 'jeton-l2']);
    expect(envoyes[0]!.title).toBe('Nouvelle course de colis');
    expect(resultat.notified).toBe(2);
  });

  it('un candidat proche sans fcm_token reçoit quand même, par push_tokens', async () => {
    etat.candidats = [{ driver_id: 'l1', full_name: 'Moussa', fcm_token: null, distance_m: 300 }];
    etat.jetons = [{ token: 'jeton-l1', user_id: 'l1' }];

    await dispatchOrder({ orderId: 'c1' });

    expect((sendPush.mock.calls[0]![0] as Array<{ token: string }>).map((m) => m.token)).toEqual(['jeton-l1']);
  });

  it('personne en ligne : rien n’est envoyé, et on le dit', async () => {
    const resultat = await dispatchOrder({ orderId: 'c1' });
    expect(sendPush).not.toHaveBeenCalled();
    expect(resultat.reason).toBe('no_candidates');
  });
});
