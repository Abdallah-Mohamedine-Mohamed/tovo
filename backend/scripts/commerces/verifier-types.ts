/**
 * VÉRIFIER LE TYPE DE CHAQUE COMMERCE DE L'ANNUAIRE (05/10).
 *
 *   npx tsx --env-file=.env scripts/commerces/verifier-types.ts
 *
 * Les catégories d'Overture Maps sont souvent fausses : « Elegance meuble »,
 * « Boucherie plateau », « Intima Boutique » étaient rangés parmi les
 * supermarchés, et Tovo les proposait à qui cherchait un supermarché.
 *
 * Une IA (Gemini 3.1 Pro) relit le NOM de chaque commerce et dit son type le
 * plus probable. On ne corrige que quand le nom contredit clairement le type
 * actuel ; un nom qui ne dit rien (« Ets Baba Ahmed ») garde le sien.
 *
 * Les corrections vont dans data/commerces-types.json (par identifiant), et
 * non dans l'annuaire lui-même : reconstruire l'annuaire depuis ses sources
 * (construire.ts) ne les perd pas. chargerCommerces les applique.
 */
import { readFileSync, writeFileSync } from 'node:fs';

const TYPES = ['supermarche', 'marche', 'boucherie', 'boulangerie', 'beaute', 'electronique', 'vetements',
  'quincaillerie', 'restaurant', 'grillades', 'pharmacie', 'boutique'] as const;

const annuaire = JSON.parse(readFileSync('data/commerces-niamey.json', 'utf8')) as { commerces: Array<{ id: string; nom: string; type: string }> };
// Relu le 05/10 : un premier passage rangeait les « Alimentation générale »
// (des épiceries) et les « Dépôts » pharmaceutiques en « boutique ». D'où le
// type ACTUEL donné à l'IA, à garder tant que le nom ne le contredit pas, et
// les usages de Niamey.
const CONSIGNE = [
  'Tu vérifies le type de commerces de Niamey (Niger), d’après leur NOM, en connaissant les usages locaux.',
  `Types possibles : ${TYPES.join(', ')}. « boutique » = commerce général ou spécialisé hors de ces types (meubles, articles divers…).`,
  'On te donne pour chacun son type ACTUEL. Garde-le (réponds « garder ») tant que le nom ne le CONTREDIT PAS clairement. Ne propose un autre type que si le nom le dit sans ambiguïté.',
  'Usages de Niamey : une « Alimentation » ou « Alimentation générale » est une épicerie → supermarche ; un « Dépôt » rangé en pharmacie est un dépôt pharmaceutique → pharmacie ; une « Boucherie » → boucherie ; un « Marché » → marche ; « Grill », « Méchoui », « Brochettes », « Kilichi » → grillades.',
  'Exemples : « Elegance meuble » (supermarche) → boutique ; « Boucherie plateau » (supermarche) → boucherie ; « Ets Baba Ahmed » (supermarche) → garder ; « Maison Économique » (pharmacie) → garder.',
  'Réponds en JSON : {"types": {"<id>": "<type ou garder>"}}.',
].join('\n');

const corrections: Record<string, { type: string; avant: string; nom: string }> = {};
const lot = 120;
for (let i = 0; i < annuaire.commerces.length; i += lot) {
  const morceau = annuaire.commerces.slice(i, i + lot);
  const reponse = await fetch('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY! },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: CONSIGNE }] },
      contents: [{ role: 'user', parts: [{ text: morceau.map((c) => `${c.id} : ${c.nom} (${c.type})`).join('\n') }] }],
      generationConfig: { temperature: 0, responseMimeType: 'application/json', maxOutputTokens: 16_000, thinkingConfig: { thinkingLevel: 'low' } },
    }),
  });
  if (!reponse.ok) throw new Error(`Gemini ${reponse.status} ${(await reponse.text()).slice(0, 200)}`);
  const corps = (await reponse.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }> };
  const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
  const { types } = JSON.parse(texte) as { types: Record<string, string> };
  for (const c of morceau) {
    const nouveau = types[c.id];
    if (nouveau && nouveau !== 'garder' && (TYPES as readonly string[]).includes(nouveau) && nouveau !== c.type) {
      corrections[c.id] = { type: nouveau, avant: c.type, nom: c.nom };
    }
  }
  console.log(`${Math.min(i + lot, annuaire.commerces.length)} / ${annuaire.commerces.length} vérifiés`);
}

writeFileSync('data/commerces-types.json', JSON.stringify({
  verifie_le: new Date().toISOString().slice(0, 10),
  source: 'scripts/commerces/verifier-types.ts (Gemini 3.1 Pro, d’après le nom)',
  corrections,
}, null, 1));
console.log(`${Object.keys(corrections).length} corrections → data/commerces-types.json`);
for (const c of Object.values(corrections)) console.log(`  ${c.nom} : ${c.avant} → ${c.type}`);
