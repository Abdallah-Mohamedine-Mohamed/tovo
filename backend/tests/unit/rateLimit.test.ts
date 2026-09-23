import { beforeEach, describe, expect, it, vi } from 'vitest';

// Sans Redis : on éprouve le repli mémoire, celui du développement et des pannes.
vi.mock('../../src/services/queue.js', () => ({ redisConnexion: () => null }));

import { LIMITES, consommer, messageLimite, viderMemoireLimites } from '../../src/services/rateLimit.js';

// Début d'une journée UTC, pour que les fenêtres tombent juste.
const T0 = Date.UTC(2026, 8, 23, 0, 0, 0);

describe('limite de débit', () => {
  beforeEach(() => viderMemoireLimites());

  it('laisse passer jusqu’au plafond à la minute, puis refuse jusqu’à la fin de la minute', async () => {
    const max = LIMITES.chat[0]!.max;
    for (let i = 0; i < max; i++) {
      expect((await consommer('chat', 'u1', T0 + i)).ok).toBe(true);
    }
    const refus = await consommer('chat', 'u1', T0 + 10_000);
    expect(refus).toEqual({ ok: false, reessayerDans: 50 });
  });

  it('repart à zéro à la minute suivante', async () => {
    const max = LIMITES.chat[0]!.max;
    for (let i = 0; i <= max; i++) await consommer('chat', 'u1', T0);
    expect((await consommer('chat', 'u1', T0 + 60_000)).ok).toBe(true);
  });

  it('plafonne la journée même en restant sous la limite à la minute', async () => {
    const jour = LIMITES.chat[1]!.max;
    // Dix messages par minute : jamais bloqué à la minute.
    for (let i = 0; i < jour; i++) {
      const verdict = await consommer('chat', 'u1', T0 + Math.floor(i / 10) * 60_000);
      expect(verdict.ok, `message ${i + 1}`).toBe(true);
    }
    const refus = await consommer('chat', 'u1', T0 + 12 * 3_600_000);
    expect(refus.ok).toBe(false);
    if (!refus.ok) {
      // Minuit UTC suivant : douze heures plus tard.
      expect(refus.reessayerDans).toBe(12 * 3_600);
      expect(messageLimite(refus.reessayerDans)).toContain('aujourd’hui');
    }
  });

  it('sépare les utilisateurs et les actions', async () => {
    const max = LIMITES.chat[0]!.max;
    for (let i = 0; i <= max; i++) await consommer('chat', 'u1', T0);
    expect((await consommer('chat', 'u1', T0)).ok).toBe(false);
    expect((await consommer('chat', 'u2', T0)).ok).toBe(true);
    expect((await consommer('transcription', 'u1', T0)).ok).toBe(true);
  });

  it('compte les appels refusés : marteler ne raccourcit pas l’attente', async () => {
    const max = LIMITES.transcription[0]!.max;
    for (let i = 0; i < max + 20; i++) await consommer('transcription', 'u1', T0);
    const refus = await consommer('transcription', 'u1', T0 + 59_000);
    expect(refus).toEqual({ ok: false, reessayerDans: 1 });
  });

  it('parle de patience pour une rafale, de demain pour la journée', () => {
    expect(messageLimite(30)).toContain('une minute');
    expect(messageLimite(5_000)).toContain('demain');
  });
});
