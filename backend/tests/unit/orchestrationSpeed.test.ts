import { expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { orchestrate } from '../../src/ai/orchestrator.js';
import { llmClient } from '../../src/ai/llmClient.js';

vi.mock('../../src/ai/llmClient.js', () => ({ llmClient: vi.fn(), LlmUnavailableError: class extends Error {} }));
vi.mock('../../src/ai/systemPrompt.js', () => ({ SYSTEM_PROMPT: 'test', contexteUtilisateur: () => '' }));
vi.mock('../../src/services/catalogue.js', () => ({
  resolveCatalogueIntent: vi.fn(async () => undefined),
  merchantIntentAnswer: vi.fn(),
  cataloguePage: vi.fn(async () => ({ items: [], total: 0, offset: 0, next_offset: null, match_type: 'exact' })),
  searchAnswer: vi.fn(),
}));
vi.mock('../../src/ai/tools.js', () => ({
  TOOL_DEFINITIONS: [{ name: 'obtenir_produit' }, { name: 'ajouter_au_panier' }],
  EXECUTORS: {
    obtenir_produit: async () => ({ summary: { id: 'plat' }, components: [{ type: 'product_card', data: { id: 'plat', name: 'Poulet', price: 2500 } }] }),
    ajouter_au_panier: async () => ({ summary: { id: 'panier' }, components: [{ type: 'cart_summary', data: { id: 'panier', items: [] } }] }),
    rechercher_produits: async () => ({ summary: { items: [] }, components: [] }),
  },
}));

it('publie les composants vérifiés sans couper les appels dépendants nécessaires', async () => {
  const calls: Record<string, unknown>[] = [];
  const generate = vi.fn(async (request) => {
    calls.push(request);
    if (calls.length === 1) return { text: '', toolCalls: [{ name: 'obtenir_produit', args: { product_id: 'plat' } }] };
    if (calls.length === 2) return { text: '', toolCalls: [{ name: 'ajouter_au_panier', args: { product_id: 'plat' } }] };
    request.onText?.('Le panier est prêt.');
    return { text: 'Le panier est prêt.', toolCalls: [] };
  });
  vi.mocked(llmClient).mockReturnValue({ generate } as never);
  const builder: Record<string, unknown> = {};
  for (const method of ['select', 'eq', 'in', 'order', 'insert']) builder[method] = () => builder;
  builder.limit = async () => ({ data: [] });
  builder.single = async () => ({ data: { id: 'message' } });
  const db = { from: () => builder } as unknown as SupabaseClient;
  const events: Record<string, unknown>[] = [];
  const response = await orchestrate({ db, userId: 'client', conversationId: 'conversation',
    clientMessageId: 'message', message: 'Ajoute le produit demandé à mon panier', onEvent: (event) => events.push(event) });
  expect(generate).toHaveBeenCalledTimes(3);
  expect(calls[1]?.tools).not.toEqual([]);
  expect(calls[2]?.tools).toEqual([]);
  expect(events.map((event) => event.type)).toEqual(['text_start', 'results', 'text_start', 'results', 'text_start', 'text']);
  expect(response.components[0]?.type).toBe('cart_summary');
  expect(response.content).toBe('Le panier est prêt.');
});

it('retire les premières cartes dès que la recherche affinée ne trouve rien', async () => {
  const generate = vi.fn()
    .mockResolvedValueOnce({ text: '', toolCalls: [{ name: 'obtenir_produit', args: {} }] })
    .mockResolvedValueOnce({ text: '', toolCalls: [{ name: 'rechercher_produits', args: {} }] })
    .mockImplementationOnce(async (request) => {
      request.onText?.('Aucun produit ne correspond à cette précision.');
      return { text: 'Aucun produit ne correspond à cette précision.', toolCalls: [] };
    });
  vi.mocked(llmClient).mockReturnValue({ generate } as never);
  const builder: Record<string, unknown> = {};
  for (const method of ['select', 'eq', 'in', 'order', 'insert']) builder[method] = () => builder;
  builder.limit = async () => ({ data: [] });
  builder.single = async () => ({ data: { id: 'message' } });
  const db = { from: () => builder } as unknown as SupabaseClient;
  const events: Record<string, unknown>[] = [];
  const response = await orchestrate({ db, userId: 'client', conversationId: 'conversation',
    clientMessageId: 'message', message: 'Je veux le produit avec cette option', onEvent: (event) => events.push(event) });
  const results = events.filter((event) => event.type === 'results');
  expect(results).toHaveLength(2);
  expect(results[0]?.components).toHaveLength(1);
  expect(results[1]?.components).toEqual([]);
  expect(response.components).toEqual([]);
  expect(events.indexOf(results[1]!)).toBeLessThan(events.findIndex((event) => event.type === 'text'));
});

it('ne rappelle pas le modèle quand un outil fournit déjà la réponse finale', async () => {
  const generate = vi.fn(async () => ({
    text: '',
    toolCalls: [{ name: 'rechercher_produits', args: { requete: 'poulet' } }],
  }));
  vi.mocked(llmClient).mockReturnValue({ generate } as never);
  const builder: Record<string, unknown> = {};
  for (const method of ['select', 'eq', 'in', 'order', 'insert']) builder[method] = () => builder;
  builder.limit = async () => ({ data: [] });
  builder.single = async () => ({ data: { id: 'message' } });
  const db = { from: () => builder } as unknown as SupabaseClient;

  const original = (await import('../../src/ai/tools.js')).EXECUTORS.rechercher_produits;
  (await import('../../src/ai/tools.js')).EXECUTORS.rechercher_produits = async () => ({
    content: 'Voici les produits.',
    summary: { resultats: 2 },
    components: [],
  });
  try {
    const response = await orchestrate({
      db, userId: 'client', conversationId: 'conversation',
      clientMessageId: 'message', message: 'Ajoute cette sélection à ma commande',
    });
    expect(generate).toHaveBeenCalledTimes(1);
    expect(response.content).toBe('Voici les produits.');
    expect(response.usage.cycles).toBe(1);
  } finally {
    (await import('../../src/ai/tools.js')).EXECUTORS.rechercher_produits = original!;
  }
});
