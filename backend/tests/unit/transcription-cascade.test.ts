import { afterEach, describe, expect, it, vi } from 'vitest';

// Clés présentes pour les deux services, secours au bout de 100 ms.
vi.mock('../../src/config/env.js', () => ({
  env: {
    TRANSCRIPTION_MAI_VIA: 'openrouter',
    OPENROUTER_API_KEY: 'or',
    OPENAI_API_KEY: 'oa',
    AZURE_SPEECH_KEY: undefined,
    AZURE_SPEECH_REGION: 'eastus',
    TRANSCRIPTION_SECOURS_MS: 100,
  },
}));
// Pas de ffmpeg dans les tests : la conversion est simulée.
vi.mock('../../src/services/conversionAudio.js', () => ({
  enWav: async () => ({ mime: 'audio/wav', data: 'd2F2' }),
}));
vi.mock('../../src/ai/llmClient.js', () => ({
  fastLlmClient: () => ({ generate: async () => ({ text: JSON.stringify({ text: 'par Gemini' }) }) }),
  LlmUnavailableError: class extends Error {},
}));

const { transcrire } = await import('../../src/services/transcription.js');

const audio = { mime: 'audio/mp4', data: 'YWFj' };
const pause = (ms: number) => new Promise((ok) => setTimeout(ok, ms));
const json = (corps: unknown, statut = 200) =>
  new Response(JSON.stringify(corps), { status: statut, headers: { 'content-type': 'application/json' } });

/** Simule OpenRouter (MAI) et OpenAI, chacun avec son délai et sa réponse. */
function services(mai: { ms: number; reponse: Response }, openai: { ms: number; texte: string }) {
  const appels: string[] = [];
  vi.stubGlobal('fetch', async (url: string, init: RequestInit) => {
    const signal = init.signal;
    if (url.includes('openrouter.ai')) {
      appels.push('mai');
      const corps = JSON.parse(String(init.body)) as { input_audio: { format: string } };
      // MAI reçoit le son CONVERTI : il refuse l'AAC.
      expect(corps.input_audio.format).toBe('wav');
      await pause(mai.ms);
      signal?.throwIfAborted();
      return mai.reponse;
    }
    appels.push('openai');
    await pause(openai.ms);
    signal?.throwIfAborted();
    return json({ text: openai.texte });
  });
  return appels;
}

afterEach(() => vi.unstubAllGlobals());

describe('transcription : MAI d’abord, un filet seulement si besoin', () => {
  it('MAI répond vite : OpenAI n’est jamais appelé (et jamais payé)', async () => {
    const appels = services({ ms: 20, reponse: json({ text: 'Je veux attiéké chez Garba d’Or.' }) }, { ms: 10, texte: 'x' });
    const r = await transcrire(audio, ['attiéké']);
    expect(r).toEqual({ texte: 'Je veux attiéké chez Garba d’Or.', fournisseur: 'mai-openrouter' });
    expect(appels).toEqual(['mai']);
  });

  it('MAI échoue : OpenAI prend le relais tout de suite, sans attendre le délai', async () => {
    const appels = services(
      { ms: 5, reponse: json({ error: { message: 'Provider returned 400' } }, 400) },
      { ms: 10, texte: 'Je veux du poulet.' },
    );
    const debut = performance.now();
    const r = await transcrire(audio);
    expect(r.fournisseur).toBe('openai');
    expect(appels).toEqual(['mai', 'openai']);
    expect(performance.now() - debut).toBeLessThan(90);
  });

  it('MAI traîne : OpenAI part au bout du délai, le premier texte gagne', async () => {
    services({ ms: 400, reponse: json({ text: 'trop tard' }) }, { ms: 20, texte: 'Je veux un livreur.' });
    expect(await transcrire(audio)).toEqual({ texte: 'Je veux un livreur.', fournisseur: 'openai' });
  });

  it('MAI rend du vide : ce n’est pas une réponse, OpenAI est interrogé', async () => {
    services({ ms: 5, reponse: json({ text: '   ' }) }, { ms: 5, texte: 'Annule ma commande.' });
    expect((await transcrire(audio)).fournisseur).toBe('openai');
  });

  it('tout échoue : Gemini, l’ancien chemin, répond encore', async () => {
    vi.stubGlobal('fetch', async () => json({ error: { message: 'panne' } }, 503));
    expect(await transcrire(audio)).toEqual({ texte: 'par Gemini', fournisseur: 'gemini' });
  });
});
