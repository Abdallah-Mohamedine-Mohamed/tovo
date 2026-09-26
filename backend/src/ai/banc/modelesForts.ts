import { env } from '../../config/env.js';

/**
 * Les modèles FORTS de la boucle du banc : lents, chers à l'unité, mais
 * seulement sur quelques dizaines de phrases par passage. Ils ne répondent
 * jamais à un client : ils écrivent des phrases d'examen et les corrigent.
 *
 * Deux familles différentes (Google et OpenAI) : une étiquette n'est gardée
 * que si les deux sont d'accord sans s'être vues. Un seul modèle finirait par
 * graver ses propres erreurs dans l'examen.
 */

export interface ModeleFort {
  nom: string;
  /** Réponse JSON du modèle, déjà décodée. */
  json(systeme: string, demande: string): Promise<unknown>;
}

function extraireJson(texte: string): unknown {
  const debut = texte.search(/[[{]/);
  if (debut < 0) throw new Error('réponse sans JSON');
  const brut = texte.slice(debut).replace(/```\s*$/, '').trim();
  return JSON.parse(brut);
}

export function gemini(modele: string): ModeleFort {
  return {
    nom: modele,
    async json(systeme, demande) {
      const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY! },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: systeme }] },
          contents: [{ role: 'user', parts: [{ text: demande }] }],
          generationConfig: {
            maxOutputTokens: 32_000,
            responseMimeType: 'application/json',
            temperature: 1,
            thinkingConfig: { thinkingLevel: 'high' },
          },
        }),
        signal: AbortSignal.timeout(300_000),
      });
      const corps = (await r.json()) as {
        candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>;
        error?: { message?: string };
      };
      if (!r.ok) throw new Error(`${modele} ${r.status} ${corps.error?.message ?? ''}`);
      return extraireJson(corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '');
    },
  };
}

export function openai(modele: string): ModeleFort {
  return {
    nom: modele,
    async json(systeme, demande) {
      const r = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENAI_API_KEY}` },
        body: JSON.stringify({
          model: modele,
          messages: [{ role: 'system', content: systeme }, { role: 'user', content: demande }],
          response_format: { type: 'json_object' },
          reasoning_effort: 'high',
        }),
        signal: AbortSignal.timeout(300_000),
      });
      const corps = (await r.json()) as { choices?: Array<{ message?: { content?: string } }>; error?: { message?: string } };
      if (!r.ok) throw new Error(`${modele} ${r.status} ${corps.error?.message ?? ''}`);
      return extraireJson(corps.choices?.[0]?.message?.content ?? '');
    },
  };
}

/** L'écrivain et le juge, réglables par l'environnement. */
export function ecrivain(): ModeleFort {
  return gemini(process.env.BANC_ECRIVAIN ?? 'gemini-3.1-pro-preview');
}

export function juge(): ModeleFort {
  return openai(process.env.BANC_JUGE ?? 'gpt-5.5');
}
