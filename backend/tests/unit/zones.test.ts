import { describe, expect, it } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { filtreDeZone } from '../../src/services/zones.js';

const NIAMEY = 'e8b627f4-dd34-46a8-9e24-0cab5facf34c';
const YANTALA = 'f3d7d335-f6e9-451c-bd47-fa81a1004da1';
const PLATEAU = '934c8011-0000-0000-0000-000000000000';

function faux(rpc: () => Promise<{ data: unknown; error: unknown }>) {
  return { rpc } as unknown as SupabaseClient;
}

describe('zones — un livreur de la ville sert ses quartiers (0063)', () => {
  it('une commande de Yantala atteint le livreur rattaché à « Niamey »', async () => {
    // Constaté le 25/09 : Maison Grill (Yantala) n'arrivait jamais au seul
    // livreur en ligne, rattaché à la ville entière.
    const couvre = await filtreDeZone(
      faux(async () => ({ data: [YANTALA, NIAMEY], error: null })),
      YANTALA,
    );
    expect(couvre(NIAMEY)).toBe(true);
    expect(couvre(YANTALA)).toBe(true);
    expect(couvre(null)).toBe(true);
    // Un autre quartier ne couvre pas Yantala.
    expect(couvre(PLATEAU)).toBe(false);
  });

  it('sans la migration, retombe sur l’égalité au lieu de ne prévenir personne', async () => {
    const couvre = await filtreDeZone(
      faux(async () => ({ data: null, error: { message: 'function not found' } })),
      YANTALA,
    );
    expect(couvre(YANTALA)).toBe(true);
    expect(couvre(NIAMEY)).toBe(false);
  });

  it('une commande sans zone reste visible de tous', async () => {
    const couvre = await filtreDeZone(
      faux(async () => {
        throw new Error('ne doit pas être appelé');
      }),
      null,
    );
    expect(couvre(PLATEAU)).toBe(true);
  });
});
