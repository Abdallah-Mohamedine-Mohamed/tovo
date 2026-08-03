import { env } from '../config/env.js';

/**
 * Abstraction du modèle de langage.
 *
 * Le briefing exige que le modèle soit remplaçable « en une ligne ». Ce
 * fichier est cette ligne : le reste du code d'orchestration ne connaît que
 * les types ci-dessous, jamais le format de Gemini.
 *
 * Appel direct à l'API REST plutôt qu'un SDK : le function calling tient en
 * une trentaine de lignes, et une dépendance de moins sur un backend qui
 * tourne sur un conteneur Railway vaut mieux qu'un confort marginal.
 */

export interface LlmToolDefinition {
  name: string;
  description: string;
  /** Schéma JSON des paramètres, au format OpenAPI restreint de Gemini. */
  parameters: Record<string, unknown>;
}

export interface LlmToolCall {
  name: string;
  args: Record<string, unknown>;
  /**
   * État opaque du fournisseur, à restituer tel quel.
   *
   * Les modèles Gemini 3 joignent une `thought_signature` à chaque appel
   * d'outil et refusent la requête suivante si elle n'est pas renvoyée avec
   * l'appel rejoué. L'orchestrateur n'a pas à savoir ce que c'est : il la
   * transporte, point. Un autre fournisseur laissera ce champ vide.
   */
  signature?: string;
}

export interface LlmTurn {
  role: 'user' | 'model' | 'tool';
  /** Texte, ou résultat d'outil sérialisé selon le rôle. */
  content: string;
  toolName?: string;
  toolCalls?: LlmToolCall[];
}

export interface LlmResponse {
  text: string;
  toolCalls: LlmToolCall[];
  /** Tokens consommés, pour le suivi de coût. */
  usage?: { input: number; output: number };
}

export interface LlmRequest {
  system: string;
  history: LlmTurn[];
  tools: LlmToolDefinition[];
}

export interface LlmClient {
  readonly model: string;
  generate(request: LlmRequest): Promise<LlmResponse>;
}

export class LlmUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'LlmUnavailableError';
  }
}

// ---------------------------------------------------------------------
// Gemini
// ---------------------------------------------------------------------

interface GeminiPart {
  text?: string;
  thoughtSignature?: string;
  functionCall?: { name: string; args?: Record<string, unknown> };
  functionResponse?: { name: string; response: Record<string, unknown> };
}

interface GeminiContent {
  role: 'user' | 'model';
  parts: GeminiPart[];
}

function versGemini(history: LlmTurn[]): GeminiContent[] {
  return history.map((tour) => {
    if (tour.role === 'tool') {
      // Un résultat d'outil se présente à Gemini comme un tour « user »
      // contenant une functionResponse — c'est sa convention, pas la nôtre.
      return {
        role: 'user' as const,
        parts: [
          {
            functionResponse: {
              name: tour.toolName ?? 'inconnu',
              response: { result: safeParse(tour.content) },
            },
          },
        ],
      };
    }

    if (tour.toolCalls?.length) {
      return {
        role: 'model' as const,
        parts: tour.toolCalls.map((appel) => ({
          functionCall: { name: appel.name, args: appel.args },
          ...(appel.signature ? { thoughtSignature: appel.signature } : {}),
        })),
      };
    }

    return {
      role: tour.role === 'model' ? ('model' as const) : ('user' as const),
      parts: [{ text: tour.content }],
    };
  });
}

function safeParse(brut: string): unknown {
  try {
    return JSON.parse(brut);
  } catch {
    return brut;
  }
}

export class GeminiClient implements LlmClient {
  constructor(
    private readonly apiKey: string,
    readonly model: string = env.GEMINI_MODEL,
  ) {}

  async generate({ system, history, tools }: LlmRequest): Promise<LlmResponse> {
    const url =
      `https://generativelanguage.googleapis.com/v1beta/models/${this.model}:generateContent`;

    const corps = {
      systemInstruction: { parts: [{ text: system }] },
      contents: versGemini(history),
      tools: tools.length > 0
        ? [{ functionDeclarations: tools.map((t) => ({
            name: t.name,
            description: t.description,
            parameters: t.parameters,
          })) }]
        : undefined,
      generationConfig: {
        temperature: 0.3,
        maxOutputTokens: 1024,
        // Budget de réflexion volontairement bas. Choisir un outil parmi
        // douze et rédiger une phrase courte ne demande pas de raisonnement
        // profond ; sur Gemini 3, la réflexion consomme à la fois du temps
        // et le budget de sortie.
        thinkingConfig: { thinkingBudget: 128 },
      },
    };

    // Le client attend sur un réseau nigérien : au-delà de 25 s, mieux vaut
    // un message d'erreur clair qu'un écran qui tourne.
    const controleur = new AbortController();
    const delai = setTimeout(() => controleur.abort(), 25_000);

    try {
      const reponse = await fetch(url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': this.apiKey,
        },
        body: JSON.stringify(corps),
        signal: controleur.signal,
      });

      if (!reponse.ok) {
        const detail = await reponse.text().catch(() => '');
        throw new LlmUnavailableError(
          `Gemini a répondu ${reponse.status}${detail ? ` : ${detail.slice(0, 200)}` : ''}`,
        );
      }

      const json = (await reponse.json()) as {
        candidates?: Array<{ content?: { parts?: GeminiPart[] } }>;
        usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number };
      };

      const parts = json.candidates?.[0]?.content?.parts ?? [];

      return {
        text: parts
          .map((p) => p.text ?? '')
          .join('')
          .trim(),
        toolCalls: parts
          .filter((p) => p.functionCall)
          .map((p) => ({
            name: p.functionCall!.name,
            args: p.functionCall!.args ?? {},
            ...(p.thoughtSignature ? { signature: p.thoughtSignature } : {}),
          })),
        usage: {
          input: json.usageMetadata?.promptTokenCount ?? 0,
          output: json.usageMetadata?.candidatesTokenCount ?? 0,
        },
      };
    } catch (cause) {
      if (cause instanceof LlmUnavailableError) throw cause;
      if (cause instanceof Error && cause.name === 'AbortError') {
        throw new LlmUnavailableError('Le modèle met trop de temps à répondre.');
      }
      throw new LlmUnavailableError(
        cause instanceof Error ? cause.message : 'Modèle injoignable',
      );
    } finally {
      clearTimeout(delai);
    }
  }
}

let client: LlmClient | null = null;

/**
 * Le client courant, ou `null` si aucune clé n'est configurée.
 *
 * Changer de fournisseur se fait ici : une classe qui implémente
 * `LlmClient`, et rien d'autre à modifier dans l'orchestrateur ni les outils.
 */
export function llmClient(): LlmClient | null {
  if (!env.GEMINI_API_KEY) return null;
  client ??= new GeminiClient(env.GEMINI_API_KEY);
  return client;
}

export const llmEnabled = Boolean(env.GEMINI_API_KEY);
