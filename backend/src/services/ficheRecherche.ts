import sharp from 'sharp';
import { env } from '../config/env.js';
import { viaLigneGoogle } from '../lib/ligneGoogle.js';

/**
 * FICHE DE RECHERCHE d'un produit : une description fidèle en français et les
 * mots qu'un client taperait pour le trouver, écrits par une IA d'après le
 * nom, la boutique, le rayon et la photo.
 *
 * Pourquoi : la recherche par MOTS ne lit que le nom, les variantes
 * d'écriture (`search_aliases`) et les options — jamais la description ni les
 * étiquettes. Un client qui tape « médicament contre le palu », « frigo » ou
 * « jus d'hibiscus » ne trouvait ni Artefan, ni le Réfrigérateur Icona, ni le
 * Jus de Bissap : 6 recherches sur 32 trouvaient le bon produit en tête
 * (scripts/recherche/banc-clients.ts, 19/10). Les étiquettes de la fiche
 * rejoignent donc les variantes d'écriture.
 *
 * La description, elle, s'affiche au client : elle ne dit que ce qu'écrivent
 * le nom ou l'étiquette visible. Les descriptions précédentes, écrites par une
 * IA sans garde-fou, promettaient des garnitures et des bienfaits inventés —
 * elles ne sont pas données au modèle.
 */

export interface Fiche {
  description: string;
  etiquettes: string[];
}

export interface ProduitAFicher {
  name: string;
  boutique?: string | null | undefined;
  rayon?: string | null | undefined;
  options?: string | null | undefined;
  image_url?: string | null | undefined;
}

const CONSIGNE = `Tu écris la fiche de recherche d'un article vendu sur Tovo, une application de livraison à Niamey (Niger) : plats de restaurant, boissons, courses, cosmétiques, médicaments, électronique, vêtements, services. Les clients cherchent en français courant, parfois avec des fautes, parfois avec le nom anglais ou un mot local.

Tu reçois le nom de l'article, sa boutique, son rayon, ses options et parfois sa photo. N'affirme QUE ce que disent le nom, les options et l'étiquette lisible sur la photo, ou ce que le nom désigne par définition (une bolognaise est une sauce à la viande hachée, un tchep un riz au poisson). La photo d'un plat peut n'être qu'une illustration : n'en tire ni garniture, ni accompagnement, ni goût, ni mode de cuisson (frit, gratiné, grillé) que le nom ne dit pas. N'invente aucun ingrédient, parfum, contenance, public (homme, femme, enfant), bienfait ni indication médicale, même si tu crois connaître l'article.

Rends un JSON :
- "description" : 1 ou 2 phrases en français (240 caractères au plus) qui disent ce qu'est l'article et ce qui le distingue (variante, format, contenance, dosage) quand c'est écrit. Pour un médicament : le nom, le dosage et la forme (comprimés, sirop) seulement. Ni slogan, ni qualificatif que le nom ou l'étiquette ne dit pas (« frais », « croustillant », « tendre », « rafraîchissant », « doré », « délicieux », « idéal »), ni usage suggéré (« pour vos salades », « idéal pour le petit déjeuner »), ni public (homme, femme, enfant) absent du nom ou de l'étiquette ; pas de point d'exclamation.
- "etiquettes" : 6 à 12 mots ou expressions courts, en minuscules, que des clients taperaient pour chercher CET article : sa nature en français courant et ses synonymes usuels (« frigo » pour un réfrigérateur), sa traduction s'il est nommé en anglais (ou l'inverse), la marque, la variante, le format sous ses formes usuelles (« 1,5 l », « 1500 ml »). Tu peux nommer la famille à laquelle l'article appartient quand tu en es certain (Red Bull : boisson énergisante ; Artefan : antipaludéen, paludisme ; Need for Speed : jeu de course ; bissap : hibiscus). Jamais de mot vague (« plat », « produit », « article », « repas », « qualité », « délicieux »), ni le nom de la ville ou de la boutique, ni un attribut que l'article n'a pas d'après son nom, ni le nom d'un AUTRE article voisin (un pilon n'est pas une cuisse, des nems ne sont pas des rouleaux de printemps, une omelette n'est pas un sandwich omelette) : le client qui tape ce mot veut cet autre article.`;

const SCHEMA = {
  type: 'OBJECT',
  properties: { description: { type: 'STRING' }, etiquettes: { type: 'ARRAY', items: { type: 'STRING' } } },
  required: ['description', 'etiquettes'],
};

/** La photo, réduite : l'étiquette reste lisible, l'envoi léger. */
async function photo(url: string): Promise<string | null> {
  try {
    const reponse = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    if (!reponse.ok) return null;
    const octets = Buffer.from(await reponse.arrayBuffer());
    return (await sharp(octets).resize(768, 768, { fit: 'inside' }).jpeg({ quality: 85 }).toBuffer()).toString('base64');
  } catch {
    return null;
  }
}

// Choisi le 19/10 après comparaison à l'aveugle (Flash-Lite inventait, GPT-5.5
// répondait en anglais pour 5 fois le prix).
export const MODELE_FICHE = 'gemini-3.8-flash';

export async function redigerFiche(produit: ProduitAFicher, modele = MODELE_FICHE): Promise<Fiche> {
  if (!env.GEMINI_API_KEY) throw new Error('GEMINI_API_KEY absente');
  const image = produit.image_url ? await photo(produit.image_url) : null;
  const parts: unknown[] = [{
    text: JSON.stringify({ nom: produit.name, boutique: produit.boutique, rayon: produit.rayon, options: produit.options || undefined }),
  }];
  if (image) parts.push({ inline_data: { mime_type: 'image/jpeg', data: image } });

  const reponse = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modele}:generateContent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
    signal: AbortSignal.timeout(60_000),
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: CONSIGNE }] },
      contents: [{ role: 'user', parts }],
      // Réflexion basse : 2 s au lieu de 7 pour une fiche courte (mesuré sur
      // Niger Beauté, 19/10), sans perte visible de fidélité.
      generationConfig: {
        temperature: 0.2, responseMimeType: 'application/json', responseSchema: SCHEMA,
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
  const fiche = JSON.parse(texte) as Fiche;
  return {
    description: String(fiche.description ?? '').trim(),
    etiquettes: (fiche.etiquettes ?? []).map((e) => String(e).trim().toLowerCase()).filter((e) => e.length > 1),
  };
}

/**
 * Une contenance du nom sous ses formes usuelles : « 1000 ml » → 1000 ml,
 * 1 l, 1 litre. Calculé, pas demandé à l'IA : une conversion n'a pas à être
 * devinée.
 */
export function contenances(brut: string): string[] {
  const m = brut.toLowerCase().replace(',', '.').match(/(\d+(?:\.\d+)?)\s*(ml|cl|l|g|kg)\b/);
  if (!m) return [];
  const n = Number(m[1]);
  const enMl = m[2] === 'l' ? n * 1000 : m[2] === 'cl' ? n * 10 : m[2] === 'ml' ? n : null;
  const enG = m[2] === 'kg' ? n * 1000 : m[2] === 'g' ? n : null;
  const sortie = [`${m[1]} ${m[2]}`];
  if (enMl !== null) {
    sortie.push(`${enMl} ml`);
    if (enMl >= 1000 && enMl % 500 === 0) sortie.push(`${enMl / 1000} l`, `${enMl / 1000} litre${enMl > 1000 ? 's' : ''}`);
  }
  if (enG !== null) {
    sortie.push(`${enG} g`);
    if (enG >= 1000 && enG % 500 === 0) sortie.push(`${enG / 1000} kg`);
  }
  return sortie;
}

/**
 * Les variantes d'écriture enrichies : celles déjà connues (fautes courantes,
 * relues), puis les étiquettes de la fiche et la contenance. Rien n'est
 * retiré : une variante saisie à la main reste.
 */
export function variantesAvecFiche(existantes: string | null | undefined, fiche: Fiche, nom: string): string | null {
  const termes = [
    ...String(existantes ?? '').split(';'),
    ...fiche.etiquettes,
    ...contenances(nom),
  ].map((x) => x.trim()).filter((x) => x.length > 1);
  const vus = new Set<string>();
  const uniques = termes.filter((t) => {
    const cle = t.toLowerCase();
    if (vus.has(cle)) return false;
    vus.add(cle);
    return true;
  });
  return uniques.length ? uniques.join(' ; ') : null;
}
