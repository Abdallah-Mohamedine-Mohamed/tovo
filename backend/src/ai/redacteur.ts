import { env } from '../config/env.js';
import { viaLigneGoogle } from '../lib/ligneGoogle.js';
import type { Component } from '../components/builders.js';
import { Faits, verifierTexte } from './verificateur.js';

/**
 * Le RÉDACTEUR (02/10) : aucune phrase adressée au client n'est écrite par du
 * code. Les chemins rapides trouvent vite (produits, commerces, pharmacies,
 * panier, livreur…) ; la phrase, elle, est rédigée par une IA à partir du
 * message EXACT du client et de ce qui a été trouvé.
 *
 * Pourquoi : les phrases à trous du code répondaient à côté — « Tovo ne
 * propose pas encore de bien manger des merguez », « 1278 produits
 * correspondent » à « Tu es sourd ? ». Les clients diront des milliers de
 * phrases différentes : on ne les corrige pas une par une.
 *
 * Le modèle est celui du cerveau (Flash-Lite, sans réflexion, ~0,5–1 s). Le
 * vérificateur anti-invention passe sur sa phrase : aucun nom, prix, nombre
 * ou durée qui ne vienne des faits. S'il ne répond pas à temps, ou invente,
 * la phrase prévue sert de secours.
 */

const CONSIGNE = [
  'Tu es Tovo, l’assistant d’une application de livraison à Niamey (Niger) : repas, courses, colis, livreurs.',
  'Tu écris UNE réponse courte (1 ou 2 phrases) au dernier message du client : français simple, chaleureux, vouvoiement.',
  '',
  'Sous ta phrase, l’application affiche déjà les cartes (produits, boutiques, commerces, boutons) : ne les énumère pas, présente-les en une phrase.',
  'Tu reçois : le message du client, ce que Tovo a trouvé (faits), et le SENS de la réponse prévue.',
  'Garde ce sens (une question reste une question, une confirmation reste une confirmation, une absence reste une absence),',
  'mais écris avec tes propres mots, en répondant à ce que le client a vraiment dit.',
  '',
  'Règles strictes :',
  '- N’invente RIEN : aucun nom, prix, nombre, distance, durée, horaire ou promesse absent des faits.',
  '- Ne recopie pas la phrase du client, et ne reprends pas ses mots parasites (« bien », « svp », « je voudrais »).',
  '- Ne donne un nombre de résultats que s’il aide vraiment le client.',
  '- Si le message du client n’a rien à voir avec les cartes trouvées (une remarque, une plainte, une blague), réponds d’abord à ce qu’il a dit.',
  '- Pas de liste, pas de titre ; **gras** seulement pour un nom de produit, de boutique ou de commerce présent dans les faits.',
  '- Pas de question si la réponse prévue n’en pose pas.',
].join('\n');

/** Ce que les cartes montrent, en bref : les noms suffisent au rédacteur. */
function resumeCartes(composants: Component[]): unknown[] {
  return composants.slice(0, 4).map((c) => {
    const d = c.data as Record<string, unknown>;
    const items = Array.isArray(d.items) ? (d.items as Array<Record<string, unknown>>).slice(0, 6) : [];
    return {
      type: c.type,
      ...(d.name ? { nom: d.name } : {}),
      ...(items.length ? { elements: items.map((i) => i.name ?? i.nom ?? i.label ?? i.title).filter(Boolean) } : {}),
      ...(typeof d.total === 'number' ? { total: d.total } : {}),
    };
  });
}

export interface ARediger {
  /** Le message exact du client. */
  message: string;
  /** La phrase prévue par le code : son SENS, et le secours. */
  prevue: string;
  /** Ce que l'outil a trouvé (résumé). */
  faits?: unknown;
  composants?: Component[];
  /** Le dernier message de Tovo, s'il y en a un (le client y répond peut-être). */
  avant?: string | null;
}

/**
 * La phrase pour le client. Jamais d'erreur : en cas de panne, de délai ou
 * d'invention, la phrase prévue.
 */
export async function rediger(r: ARediger, delaiMs = 2500): Promise<string> {
  const prevue = r.prevue.trim();
  if (env.REDACTEUR === '0' || !env.GEMINI_API_KEY || !r.message.trim()) return prevue;
  const faits = new Faits();
  faits.ajouter(r.faits);
  faits.ajouter(prevue);
  faits.ajouter(r.message);
  for (const c of r.composants ?? []) faits.ajouter(c.data);

  const entree = JSON.stringify({
    ...(r.avant ? { dernier_message_de_tovo: r.avant.slice(0, 400) } : {}),
    message_du_client: r.message.slice(0, 1000),
    sens_de_la_reponse_prevue: prevue.slice(0, 600),
    faits: r.faits ?? null,
    cartes_affichees: resumeCartes(r.composants ?? []),
  }).slice(0, 6000);

  try {
    const reponse = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${env.REDACTEUR_MODELE}:generateContent`,
      {
        method: 'POST',
        ...viaLigneGoogle,
        headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: CONSIGNE }] },
          contents: [{ role: 'user', parts: [{ text: entree }] }],
          generationConfig: { temperature: 0.4, maxOutputTokens: 300, thinkingConfig: { thinkingBudget: 0 } },
        }),
        signal: AbortSignal.timeout(delaiMs),
      },
    );
    if (!reponse.ok) return prevue;
    const corps = (await reponse.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }> };
    const texte = (corps.candidates?.[0]?.content?.parts ?? []).filter((p) => !p.thought).map((p) => p.text ?? '').join('').trim();
    if (!texte) return prevue;
    const verifie = verifierTexte(texte, faits);
    // Une phrase inventée retirée : si rien ne reste, la phrase prévue.
    return verifie.texte || prevue;
  } catch {
    return prevue;
  }
}
