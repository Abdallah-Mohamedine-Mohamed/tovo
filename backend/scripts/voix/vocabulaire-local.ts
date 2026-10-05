/**
 * LE VOCABULAIRE LOCAL (05/10) — construit à partir du catalogue, pas à la main.
 *
 *   npx tsx --env-file=.env scripts/voix/vocabulaire-local.ts
 *
 * La transcription écrivait « plat cali » pour placali, et la recherche ne
 * trouvait rien. La liste des mots donnée à la transcription était écrite à
 * la main (une quinzaine de plats) : tout plat ajouté au catalogue y manquait.
 *
 * Ce script lit TOUS les noms de produits, et demande à une IA (Gemini Pro)
 * lesquels sont des plats, aliments ou boissons dont le nom n'est pas du
 * français courant (placali, dambou, kilichi, attiéké…), en y ajoutant les
 * plats courants de Niamey absents du catalogue, et, pour chacun, comment une
 * transcription française risque de l'entendre (« plat cali »). Résultat :
 * data/vocabulaire-local.json, lu par la transcription (liste de mots), par
 * la correction après transcription, et par le cerveau.
 *
 * À relancer quand le catalogue change beaucoup (quelques centimes).
 */
import { writeFileSync } from 'node:fs';
import { serviceClient } from '../../src/services/supabase.js';

const db = serviceClient();
const noms: string[] = [];
for (let depuis = 0; ; depuis += 1000) {
  const { data, error } = await db.from('products').select('name').eq('is_available', true).range(depuis, depuis + 999);
  if (error) throw error;
  noms.push(...(data ?? []).map((p) => String(p.name)));
  if ((data?.length ?? 0) < 1000) break;
}
// Les mots des noms de produits, tels qu'écrits (avec accents), dédoublonnés sans casse.
const mots = new Map<string, string>();
for (const nom of noms) {
  for (const mot of nom.split(/[^\p{L}'’-]+/u)) {
    const cle = mot.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
    if (cle.length >= 3 && !mots.has(cle)) mots.set(cle, mot.toLowerCase());
  }
}
console.log(`${noms.length} produits, ${mots.size} mots distincts`);

const CONSIGNE = [
  'Tu aides Tovo, une application de livraison à Niamey (Niger), à reconnaître les noms de plats à la voix.',
  'On te donne tous les mots des noms de produits du catalogue.',
  'Garde SEULEMENT les noms de plats, d’aliments, d’ingrédients ou de boissons qui ne sont PAS des mots français courants : plats africains et nigériens (haoussa, zarma, peul…), ivoiriens, sénégalais, maghrébins, libanais, et mots étrangers de cuisine qu’un système de transcription française risque de mal écrire (placali, dambou, kilichi, attiéké, chawarma…).',
  'Écarte les mots français ordinaires (poulet, riz, sauce, frites), les marques, les tailles, les quantités.',
  'Ajoute aussi les plats et aliments courants de Niamey qui MANQUENT à la liste (dambou, fura, tuo, gari, fonio, massa…).',
  'Pour chaque mot, donne son écriture la plus courante, et 1 à 4 « variantes » : comment une transcription française risque de l’entendre ou de l’écrire (« plat cali », « placalie », « dans bout »). Les variantes sont en minuscules.',
  'Réponds en JSON : {"mots": [{"mot": "placali", "variantes": ["plat cali", "placalie"]}]}.',
].join('\n');

const reponse = await fetch('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent', {
  method: 'POST',
  headers: { 'content-type': 'application/json', 'x-goog-api-key': process.env.GEMINI_API_KEY! },
  body: JSON.stringify({
    systemInstruction: { parts: [{ text: CONSIGNE }] },
    contents: [{ role: 'user', parts: [{ text: [...mots.values()].join(', ') }] }],
    generationConfig: { temperature: 0, responseMimeType: 'application/json', maxOutputTokens: 16_000, thinkingConfig: { thinkingLevel: 'low' } },
  }),
});
if (!reponse.ok) throw new Error(`Gemini ${reponse.status} ${(await reponse.text()).slice(0, 300)}`);
const corps = (await reponse.json()) as { candidates?: Array<{ content?: { parts?: Array<{ text?: string; thought?: boolean }> } }> };
const texte = corps.candidates?.[0]?.content?.parts?.filter((p) => !p.thought).map((p) => p.text ?? '').join('') ?? '';
const lu = JSON.parse(texte) as { mots: Array<{ mot: string; variantes?: string[] }> };

// Nettoyage : un mot par écriture, des variantes qui ne sont pas le mot lui-même.
const sans = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim();
const vus = new Set<string>();
const vocabulaire = lu.mots
  .map((m) => ({ mot: m.mot.trim(), variantes: [...new Set((m.variantes ?? []).map((v) => v.trim().toLowerCase()))].filter((v) => v && sans(v) !== sans(m.mot)) }))
  .filter((m) => m.mot.length >= 3 && !vus.has(sans(m.mot)) && vus.add(sans(m.mot)))
  .sort((a, b) => a.mot.localeCompare(b.mot, 'fr'));

writeFileSync('data/vocabulaire-local.json', JSON.stringify({
  construit_le: new Date().toISOString().slice(0, 10),
  source: `${noms.length} produits du catalogue, triés par Gemini 3.1 Pro (scripts/voix/vocabulaire-local.ts)`,
  mots: vocabulaire,
}, null, 1));
console.log(`${vocabulaire.length} mots gardés → data/vocabulaire-local.json`);
console.log(vocabulaire.slice(0, 40).map((m) => `${m.mot}${m.variantes.length ? ` (${m.variantes.join(' / ')})` : ''}`).join('\n'));
