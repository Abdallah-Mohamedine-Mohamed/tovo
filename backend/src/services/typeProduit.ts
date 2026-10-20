import { env } from '../config/env.js';
import { viaLigneGoogle } from '../lib/ligneGoogle.js';
import { normaliserIntention } from '../ai/intents.js';

/**
 * Le TYPE d'un produit : ce qu'il EST, pas ce qu'il contient.
 *
 * La recherche par mots sait quels mots porte un produit, pas ce qu'il est :
 * pour « chocolat noir », « Biscuits Cuillers… Chocolat Noir » valait le
 * Lindt ; pour « crème pour les mains », le savon « Baléa Crème Seife »
 * valait le lait Corps & Mains ; pour « pâtes à la viande hachée », les
 * « Nems viande » passaient devant la bolognaise (banc-clients, 19/10).
 *
 * Chaque produit reçoit donc 1 à 3 types (colonne `type_produit`, migration
 * 0086), écrits par l'IA d'après le nom, la boutique, le rayon et la fiche :
 * « biscuit » ; « chocolat » ; « savon ». Puis `classerParType` fait passer
 * devant les produits dont la phrase du client NOMME le type. Il ne fait que
 * réordonner : aucun produit n'est retiré, et rien ne bouge quand la phrase
 * ne nomme aucun type (une faute de frappe, un nom de marque).
 */

const CONSIGNE = `Pour chaque article vendu sur Tovo (application de livraison à Niamey : restaurants, courses, cosmétiques, médicaments, électronique), donne ses "types" : 1 à 3 noms communs en français, au singulier, en minuscules, qui disent CE QU'EST l'article, du plus précis au plus général, en finissant par le mot courant qu'un client emploierait pour cette sorte d'article.

Le type est la nature de l'objet, jamais un ingrédient, un parfum, une saveur, une marque, une zone du corps, un usage ni une qualité. Un nom peut contenir un mot trompeur : des « Biscuits au chocolat noir » sont des biscuits, pas du chocolat ; un « savon crème » est un savon ; une « pizza poulet » est une pizza ; un nom étranger se traduit (Seife = savon, shower gel = gel douche, hand cream = crème pour les mains).

Exemples de forme : « Lindt Excellence Noir 99 % » → ["tablette de chocolat", "chocolat"] ; « Spaghetti bolognaise » → ["spaghetti", "pâtes"] ; « Lait corps et mains » → ["lait corporel", "crème"] ; « Shampooing crème au karité » → ["shampooing"] ; « Artefan 20/120 » → ["antipaludéen", "médicament"] ; « Gani Gaz (12kg) » → ["bouteille de gaz", "gaz"].

Rends un JSON : une liste d'objets {"id", "types"}, un par article reçu, dans le même ordre.`;

const SCHEMA = {
  type: 'ARRAY',
  items: {
    type: 'OBJECT',
    properties: { id: { type: 'STRING' }, types: { type: 'ARRAY', items: { type: 'STRING' } } },
    required: ['id', 'types'],
  },
};

export interface ProduitATyper {
  id: string;
  name: string;
  boutique?: string | null | undefined;
  rayon?: string | null | undefined;
  description?: string | null | undefined;
}

export const MODELE_TYPE = 'gemini-3.8-flash';

/** Les types de quelques produits (25 au plus), en un appel. */
export async function typesDesProduits(produits: ProduitATyper[], modele = MODELE_TYPE): Promise<Map<string, string[]>> {
  if (!env.GEMINI_API_KEY) throw new Error('GEMINI_API_KEY absente');
  if (produits.length === 0) return new Map();
  const reponse = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
    signal: AbortSignal.timeout(90_000),
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: CONSIGNE }] },
      contents: [{
        role: 'user',
        parts: [{
          text: JSON.stringify(produits.map((p) => ({
            id: p.id, nom: p.name, boutique: p.boutique ?? undefined, rayon: p.rayon ?? undefined,
            description: p.description ? p.description.slice(0, 240) : undefined,
          }))),
        }],
      }],
      generationConfig: {
        temperature: 0.1, responseMimeType: 'application/json', responseSchema: SCHEMA,
        thinkingConfig: { thinkingLevel: 'low' },
      },
    }),
    ...viaLigneGoogle,
  });
  const json = await reponse.json() as {
    candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }>;
    error?: { message: string };
  };
  if (json.error) throw new Error(json.error.message);
  const texte = (json.candidates?.[0]?.content?.parts ?? []).filter((p) => !p.thought).map((p) => p.text ?? '').join('');
  const lignes = JSON.parse(texte) as Array<{ id: string; types: string[] }>;
  const attendus = new Set(produits.map((p) => p.id));
  return new Map(lignes
    .filter((l) => attendus.has(l.id))
    .map((l) => [l.id, nettoyerTypes(l.types)] as const)
    .filter(([, types]) => types.length > 0));
}

export function nettoyerTypes(types: unknown[]): string[] {
  return [...new Set(types.map((t) => String(t).trim().toLowerCase()).filter((t) => t.length > 1))].slice(0, 3);
}

/** Les mots d'un texte, normalisés et au singulier (« crèmes » → « creme »). */
function mots(texte: string): string[] {
  return normaliserIntention(texte).split(' ').filter(Boolean).map((m) => m.replace(/(?<=..)[sx]$/, ''));
}

/**
 * Deux mots désignent-ils la même chose ? Égaux, ou — pour les mots longs
 * (6 lettres et plus), même initiale — à une lettre près : « shampoing » et
 * « shampooing », « foufou » et « foutou » (banc-clients, 20/10). Les mots
 * courts restent exacts : « savon » n'est pas « salon ».
 */
function memeMot(a: string, b: string): boolean {
  if (a === b) return true;
  if (a.length < 6 || b.length < 6 || a[0] !== b[0] || Math.abs(a.length - b.length) > 1) return false;
  let i = 0, j = 0, ecarts = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue; }
    if (++ecarts > 1) return false;
    if (a.length > b.length) i++;
    else if (b.length > a.length) j++;
    else { i++; j++; }
  }
  return ecarts + (a.length - i) + (b.length - j) <= 1;
}

/** Où la phrase nomme-t-elle l'un de ces types ? Rang du premier mot, ou null. */
export function positionDuType(phrase: string[], types: readonly string[]): number | null {
  let meilleure: number | null = null;
  for (const type of types) {
    const t = mots(type);
    if (t.length === 0) continue;
    for (let i = 0; i + t.length <= phrase.length; i++) {
      if (t.every((m, j) => memeMot(phrase[i + j]!, m))) {
        if (meilleure === null || i < meilleure) meilleure = i;
        break;
      }
    }
  }
  return meilleure;
}

/**
 * Les produits dont la phrase nomme le type passent devant, dans l'ordre où
 * la phrase les nomme (« biscuits au chocolat » : le biscuit d'abord ;
 * « chocolat noir » : le chocolat). Les autres suivent, dans leur ordre.
 * Tri stable ; rien n'est retiré.
 */
export function classerParType<T extends { id: unknown }>(requete: string, items: T[], types: ReadonlyMap<string, readonly string[]>): T[] {
  if (items.length < 2 || types.size === 0) return items;
  const phrase = mots(requete);
  const position = new Map(items.map((item) => [item, positionDuType(phrase, types.get(String(item.id)) ?? [])]));
  if (![...position.values()].some((p) => p !== null)) return items;
  const rang = (item: T) => position.get(item) ?? Number.MAX_SAFE_INTEGER;
  return [...items].sort((a, b) => rang(a) - rang(b));
}
