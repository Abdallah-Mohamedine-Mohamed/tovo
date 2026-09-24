import { afterEach, describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';

vi.mock('../../src/ai/llmClient.js', () => ({
  llmClient: () => null, fastLlmClient: () => null, llmEnabled: true, LlmUnavailableError: class extends Error {},
}));

import { chatRoutes } from '../../src/routes/chat.js';

const chaine = (): unknown => new Proxy(() => undefined, {
  get: (_c, prop) => (prop === 'then'
    ? (ok: (v: unknown) => void) => ok({ data: [{ name: "O'TAKOSS ( Centre Aéré )" }, { name: 'BOBA' }], error: null })
    : () => chaine()),
});

async function app() {
  const a = Fastify();
  a.decorate('requireAuth', async (request: { user?: unknown; supabase?: unknown }) => {
    request.user = { id: `voix-${Math.random()}` };
    request.supabase = { from: () => chaine() };
  });
  await a.register(chatRoutes);
  return a;
}

afterEach(() => vi.unstubAllGlobals());

describe('POST /transcriptions/session — jeton de voix en direct', () => {
  it('délivre un jeton verrouillé : modèle, français + haoussa, vocabulaire du catalogue', async () => {
    const fetch = vi.fn(async () => new Response(JSON.stringify({ name: 'auth_tokens/abc' }), { status: 200 }));
    vi.stubGlobal('fetch', fetch);
    const a = await app();
    const res = await a.inject({ method: 'POST', url: '/transcriptions/session' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ jeton: 'auth_tokens/abc', modele: 'models/gemini-3.5-transcribe-live' });

    const [url, init] = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toContain('/v1alpha/auth_tokens');
    const corps = JSON.parse(init.body as string);
    expect(corps.uses).toBe(1);
    expect(corps.bidiGenerateContentSetup.inputAudioTranscription.languageCodes).toEqual(['fr-FR', 'ha-NG']);
    // Enseigne sans son quartier, et les plats locaux.
    expect(corps.bidiGenerateContentSetup.inputAudioTranscription.customVocabulary).toEqual(expect.arrayContaining(["O'TAKOSS", 'attiéké']));
    // La clé ne part jamais au téléphone.
    expect(JSON.stringify(res.json())).not.toContain(process.env.GEMINI_API_KEY ?? '§§');
    await a.close();
  });

  it('Google refuse : 503, l’app bascule sur la transcription classique', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{}', { status: 500 })));
    const a = await app();
    const res = await a.inject({ method: 'POST', url: '/transcriptions/session' });
    expect(res.statusCode).toBe(503);
    await a.close();
  });
});
