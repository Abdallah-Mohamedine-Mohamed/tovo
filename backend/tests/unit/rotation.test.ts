import { describe, expect, it } from 'vitest';
import type { FastifyRequest } from 'fastify';
import { graineDuJour, rotationPonderee } from '../../src/services/rotation.js';

const enseignes = Array.from({ length: 12 }, (_, i) => ({ id: `m${i}`, is_open: i !== 3 && i !== 7 }));
const aucune = new Map<string, number>();

describe('la rotation des enseignes', () => {
  it('les ouvertes d’abord, toujours', () => {
    for (const graine of ['2026-09-26:', '2026-09-27:', '2026-09-28:a']) {
      const ordre = rotationPonderee(enseignes, { commandes: aucune, graine });
      expect(ordre.slice(-2).map((e) => e.id).sort()).toEqual(['m3', 'm7']);
    }
  });

  it('le même ordre toute la journée pour un même client', () => {
    const a = rotationPonderee(enseignes, { commandes: aucune, graine: '2026-09-26:client' });
    const b = rotationPonderee(enseignes, { commandes: aucune, graine: '2026-09-26:client' });
    expect(a.map((e) => e.id)).toEqual(b.map((e) => e.id));
  });

  it('un autre jour, un autre ordre : pas toujours les mêmes en tête', () => {
    const tetes = new Set(
      ['20', '21', '22', '23', '24', '25', '26'].map(
        (j) => rotationPonderee(enseignes, { commandes: aucune, graine: `2026-09-${j}:c` })[0]!.id,
      ),
    );
    expect(tetes.size).toBeGreaterThan(2);
  });

  it('une boutique très commandée est plus souvent en tête, sans y être abonnée', () => {
    const commandes = new Map([['m5', 200]]);
    let enTete = 0;
    for (let j = 0; j < 200; j++) {
      if (rotationPonderee(enseignes, { commandes, graine: `jour-${j}:c` })[0]!.id === 'm5') enTete++;
    }
    // Sans poids, ~1 fois sur 10 ; avec, nettement plus — mais pas toujours.
    expect(enTete).toBeGreaterThan(40);
    expect(enTete).toBeLessThan(200);
  });

  it('la graine : le jour à Niamey, et le client s’il est connecté', () => {
    const jeton = `x.${Buffer.from(JSON.stringify({ sub: 'client-42' })).toString('base64url')}.y`;
    const avec = { headers: { authorization: `Bearer ${jeton}` } } as unknown as FastifyRequest;
    const sans = { headers: {} } as unknown as FastifyRequest;
    // 23 h 30 UTC = 0 h 30 à Niamey : déjà le lendemain.
    const tard = new Date('2026-09-26T23:30:00Z');
    expect(graineDuJour(avec, tard)).toBe('2026-09-27:client-42');
    expect(graineDuJour(sans, tard)).toBe('2026-09-27:');
  });
});
