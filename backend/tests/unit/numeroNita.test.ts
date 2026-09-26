import { beforeEach, describe, expect, it, vi } from 'vitest';

// Le compte du client : un numéro FRANÇAIS, que Nita ne connaît pas.
const PROFIL = { phone: '33612345678' };
const achats: Array<{ phoneClient: string }> = [];

vi.mock('../../src/services/nita.js', async (origine) => {
  const vrai = await origine<typeof import('../../src/services/nita.js')>();
  return {
    ...vrai,
    creerAchat: vi.fn(async (demande: { phoneClient: string }) => {
      achats.push(demande);
      return { codeAchat: 'NT-123', montant: 3500 };
    }),
  };
});
vi.mock('../../src/services/orderNotifications.js', () => ({ notifierBoutique: vi.fn() }));

const chaine = (donnees: unknown): unknown => new Proxy(() => undefined, {
  get: (_c, prop) => (prop === 'then'
    ? (ok: (v: unknown) => void) => ok({ data: donnees, error: null })
    : () => chaine(donnees)),
});
vi.mock('../../src/services/supabase.js', () => ({
  serviceClient: () => ({
    from: (table: string) => chaine(table === 'profiles'
      ? PROFIL
      : { id: 'c1', total: 3500, merchant_id: 'm1', type: 'delivery', user_id: 'u1' }),
  }),
}));

import { ouvrirPaiement } from '../../src/services/payments.js';

describe('le numéro qui paie par Nita', () => {
  beforeEach(() => {
    achats.length = 0;
  });

  it('l’achat est créé sur le numéro Nita choisi, pas sur celui du compte', async () => {
    await ouvrirPaiement('c1', { adresseIp: '127.0.0.1' }, '90123456');
    expect(achats[0]?.phoneClient).toBe('0022790123456');
  });

  it('sans numéro choisi, le numéro du compte comme avant', async () => {
    await ouvrirPaiement('c1', { adresseIp: '127.0.0.1' });
    expect(achats[0]?.phoneClient).toBe('0033612345678');
  });
});
