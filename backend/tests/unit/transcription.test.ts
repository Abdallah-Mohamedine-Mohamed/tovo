import { afterEach, describe, expect, it, vi } from 'vitest';
import Fastify from 'fastify';
import { transcribe } from '../../src/services/transcription.js';
import { chatRoutes } from '../../src/routes/chat.js';

const generate = vi.hoisted(() => vi.fn());
vi.mock('../../src/ai/llmClient.js', () => ({
  llmClient: () => ({ model: 'test', generate }), llmEnabled: true,
  LlmUnavailableError: class extends Error {},
}));

afterEach(() => vi.clearAllMocks());

describe('Transcription avant envoi', () => {
  it('renvoie les paroles, pas une réponse commerciale', async () => {
    generate.mockResolvedValue({ text: JSON.stringify({ text: ' Deux tacos sans piment chez Otakoss. ' }), toolCalls: [] });
    expect(await transcribe({ mime: 'audio/mp4', data: 'YXVkaW8=' })).toBe('Deux tacos sans piment chez Otakoss.');
    expect(generate.mock.calls[0]?.[0]).toMatchObject({ tools: [], cachePrompt: false, history: [{ audio: { mime: 'audio/mp4', data: 'YXVkaW8=' } }] });
  });

  it('refuse une sortie non structurée plutôt que de créer un faux message', async () => {
    generate.mockResolvedValue({ text: 'Voici votre poulet', toolCalls: [] });
    await expect(transcribe({ mime: 'audio/mp4', data: 'YXVkaW8=' })).rejects.toThrow();
  });

  it('ne crée ni conversation ni commande et traite le silence', async () => {
    const app = Fastify();
    app.decorate('requireAuth', async () => {});
    await app.register(chatRoutes);
    generate.mockResolvedValue({ text: JSON.stringify({ text: 'Je veux manger' }), toolCalls: [] });
    const response = await app.inject({ method: 'POST', url: '/transcriptions', payload: { audio: { mime: 'audio/mp4', data: 'YXVkaW8=' } } });
    expect(response.json()).toEqual({ transcript: 'Je veux manger' });
    generate.mockResolvedValue({ text: JSON.stringify({ text: '' }), toolCalls: [] });
    expect((await app.inject({ method: 'POST', url: '/transcriptions', payload: { audio: { mime: 'audio/mp4', data: 'YXVkaW8=' } } })).statusCode).toBe(422);
    expect((await app.inject({ method: 'POST', url: '/transcriptions', payload: { audio: { mime: 'text/plain', data: 'x' } } })).statusCode).toBe(400);
    await app.close();
  });

  it('exige une authentification avant de solliciter le modèle', async () => {
    const app = Fastify();
    app.decorate('requireAuth', async (_request: unknown, reply: import('fastify').FastifyReply) => reply.code(401).send({ error: 'refusé' }));
    await app.register(chatRoutes);
    expect((await app.inject({ method: 'POST', url: '/transcriptions', payload: { audio: { mime: 'audio/mp4', data: 'YXVkaW8=' } } })).statusCode).toBe(401);
    expect(generate).not.toHaveBeenCalled();
    await app.close();
  });
});
