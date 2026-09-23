import { afterEach, describe, expect, it, vi } from 'vitest';
import { classerIntention } from '../../src/ai/jev.js';

afterEach(() => vi.unstubAllGlobals());

const options = { cle: 'cle-test', modele: 'typesafe/jev-1.13' };

describe('Jev — lecture de la décision', () => {
  it('lit le choix, la confiance et le coût au format OpenRouter', async () => {
    const fetch = vi.fn(async () => new Response(JSON.stringify({
      answers: { intention: { type: 'choice', choice: 'livreur', confidence: 0.93, probabilities: {} } },
      usage: { cost: 0.00002 },
    }), { status: 200 }));
    vi.stubGlobal('fetch', fetch);

    const d = await classerIntention('Je veux un livreur', options);
    expect(d).toMatchObject({ choix: 'livreur', confiance: 0.93, cout: 0.00002 });
    const corps = JSON.parse((fetch.mock.calls[0] as unknown as [string, RequestInit])[1].body as string);
    expect(corps).toMatchObject({ model: 'typesafe/jev-1.13', state: { message: 'Je veux un livreur' } });
    expect(corps.questions.intention.type).toBe('choice');
  });

  it('une panne ou un refus ne lève jamais : la réponse au client n’en dépend pas', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('réseau coupé'); }));
    expect(await classerIntention('pain', options)).toMatchObject({ choix: null, erreur: expect.stringContaining('réseau') });

    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ error: { message: 'crédit épuisé' } }), { status: 402 })));
    expect(await classerIntention('pain', options)).toMatchObject({ choix: null, erreur: '402 crédit épuisé' });
  });
});
