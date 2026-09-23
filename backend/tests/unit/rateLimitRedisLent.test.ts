import { describe, expect, it, vi } from 'vitest';

// Connexion Redis « ready » mais morte en silence : les commandes partent et
// ne reviennent jamais. C'est ce qui a bloqué les vocaux en production.
const redisMort = {
  status: 'ready',
  multi: () => {
    const transaction = {
      incr: () => transaction,
      expire: () => transaction,
      exec: () => new Promise(() => undefined),
    };
    return transaction;
  },
};
let redis: unknown = redisMort;
vi.mock('../../src/services/queue.js', () => ({ redisConnexion: () => redis }));

import { consommer, viderMemoireLimites } from '../../src/services/rateLimit.js';

describe('limite de débit — Redis ne doit jamais bloquer une requête', () => {
  it('connexion morte : répond en moins d’une demi-seconde, en mémoire', async () => {
    viderMemoireLimites();
    redis = redisMort;
    const debut = Date.now();
    expect(await consommer('transcription', 'client-1')).toEqual({ ok: true });
    expect(Date.now() - debut).toBeLessThan(500);
  });

  it('la limite tient toujours pendant la panne', async () => {
    viderMemoireLimites();
    redis = redisMort;
    const maintenant = 1_000_000_020_000;
    for (let i = 0; i < 12; i++) expect((await consommer('transcription', 'c2', maintenant)).ok).toBe(true);
    expect((await consommer('transcription', 'c2', maintenant)).ok).toBe(false);
  });

  it('reconnexion en cours : n’essaie même pas Redis', async () => {
    viderMemoireLimites();
    const multi = vi.fn();
    redis = { status: 'reconnecting', multi };
    expect(await consommer('chat', 'c3')).toEqual({ ok: true });
    expect(multi).not.toHaveBeenCalled();
  });
});
