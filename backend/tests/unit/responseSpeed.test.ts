import { afterEach, describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';
import { GeminiClient } from '../../src/ai/llmClient.js';
import { chatStream } from '../../src/lib/chatStream.js';
import { cacheDuPrompt } from '../../src/ai/promptCache.js';

vi.mock('../../src/ai/promptCache.js', () => ({ cacheDuPrompt: vi.fn(async () => null), oublierCache: vi.fn() }));

afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); vi.clearAllMocks(); });

describe('Réponses progressives', () => {
  it('décode des événements UTF-8 fragmentés et ne montre pas les pensées', async () => {
    const chunks = [
      { candidates: [{ content: { parts: [{ text: 'interne', thought: true }] } }] },
      { candidates: [{ content: { parts: [{ text: 'Chez **Garba' }] } }] },
      { candidates: [{ content: { parts: [{ text: " d’Or**." }] } }], usageMetadata: { candidatesTokenCount: 8 } },
    ];
    const bytes = new TextEncoder().encode(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\r\n\r\n`).join(''));
    const fetchMock = vi.fn(async () => new Response(new ReadableStream({ start(controller) {
      for (let offset = 0; offset < bytes.length; offset += 7) controller.enqueue(bytes.slice(offset, offset + 7));
      controller.close();
    } })));
    vi.stubGlobal('fetch', fetchMock);
    const received: string[] = [];
    const result = await new GeminiClient('test').generate({ system: 'test', history: [], tools: [], cachePrompt: false, onText: (text) => received.push(text) });
    expect(received).toEqual(['Chez **Garba', ' d’Or**.']);
    expect(result.text).toBe('Chez **Garba d’Or**.');
    expect(result.usage?.output).toBe(8);
    expect(fetchMock.mock.calls[0]).toBeDefined();
  });

  it('ne bloque pas la réponse sur la création du cache de prompt', async () => {
    vi.useFakeTimers();
    vi.mocked(cacheDuPrompt).mockReturnValueOnce(new Promise(() => {}));
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: 'Bonjour' }] } }] })));
    vi.stubGlobal('fetch', fetchMock);
    const pending = new GeminiClient('test').generate({ system: 'test', history: [], tools: [] });
    await vi.advanceTimersByTimeAsync(81);
    expect((await pending).text).toBe('Bonjour');
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it('conserve les identifiants et signatures des appels d’outils dans le flux', async () => {
    const chunk = { candidates: [{ content: { parts: [{
      thoughtSignature: 'signature-test',
      functionCall: { id: 'appel-test', name: 'obtenir_produit', args: { product_id: 'plat' } },
    }] } }] };
    vi.stubGlobal('fetch', vi.fn(async () => new Response(`data: ${JSON.stringify(chunk)}\n\n`)));
    const onText = vi.fn();
    const result = await new GeminiClient('test').generate({ system: 'test', history: [], tools: [], cachePrompt: false, onText });
    expect(result.toolCalls).toEqual([{ id: 'appel-test', name: 'obtenir_produit', args: { product_id: 'plat' }, signature: 'signature-test' }]);
    expect(onText).not.toHaveBeenCalled();
  });

  it('ne rejoue pas une génération coupée après le premier texte visible', async () => {
    vi.mocked(cacheDuPrompt).mockResolvedValueOnce('cachedContents/test');
    let source: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({ start(controller) {
      source = controller;
      const chunk = { candidates: [{ content: { parts: [{ text: 'Voici' }] } }] };
      controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(chunk)}\n\n`));
    } });
    const fetchMock = vi.fn(async () => new Response(stream));
    vi.stubGlobal('fetch', fetchMock);
    const received: string[] = [];
    await expect(new GeminiClient('test').generate({ system: 'test', history: [], tools: [], onText: (text) => {
      received.push(text);
      source.error(new Error('connexion interrompue'));
    } })).rejects.toThrow('connexion interrompue');
    expect(received).toEqual(['Voici']);
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it('termine le flux avec une erreur exploitable et conserve le format JSON classique', async () => {
    const app = Fastify();
    app.get('/stream', async (request, reply) => {
      const output = chatStream(reply, request.headers.accept === 'application/x-ndjson');
      output.emit({ type: 'results', components: [] });
      return output.finish({ error: 'Indisponible' }, 503);
    });
    const streamed = await app.inject({ url: '/stream', headers: { accept: 'application/x-ndjson' } });
    const events = streamed.body.trim().split('\n').map((line) => JSON.parse(line));
    expect(events.map((event) => event.type)).toEqual(['results', 'error']);
    expect(events[1].status).toBe(503);
    const classic = await app.inject({ url: '/stream' });
    expect(classic.statusCode).toBe(503);
    expect(classic.json()).toEqual({ error: 'Indisponible' });
    await app.close();
  });
});
