/**
 * Banc de recherche, étape 1 : des requêtes MAL ÉCRITES dont on connaît la
 * cible (un produit ou une enseigne du vrai catalogue).
 *
 *   npm run recherche:generer
 *
 * Deux sources, volontairement indépendantes :
 *   - « gemini »   : comment un client de Niamey écrirait ce nom (phonétique,
 *                    écriture locale, SMS, lettres oubliées) ;
 *   - « frappe »   : une faute de frappe tirée au hasard par programme
 *                    (lettre sautée, doublée, inversée, voisine au clavier).
 *                    Aucune IA : c'est le contrôle qui empêche de s'auto-évaluer
 *                    avec les variantes qu'on ajoutera ensuite au catalogue.
 *
 * Lecture seule sur la base. Écrit scripts/recherche/requetes.json.
 */
import { writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { llmClient } from '../../src/ai/llmClient.js';
import { normaliserIntention } from '../../src/ai/intents.js';

const MAX_PRODUITS = Number(process.argv[2] ?? 400);
const client = llmClient();
if (!client) throw new Error('GEMINI_API_KEY absente.');

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const [p, m] = await Promise.all([
  db.from('products').select('name, merchants!inner(is_approved)').eq('is_available', true).eq('merchants.is_approved', true).limit(5000),
  db.from('merchants').select('name').eq('is_approved', true),
]);
if (p.error) throw p.error;
if (m.error) throw m.error;

// Graine fixe : relancer donne les mêmes requêtes « frappe », et donc des
// mesures comparables avant / après.
let graine = 20260923;
const hasard = () => ((graine = (graine * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const melanger = <T>(t: T[]) => t.map((x) => [hasard(), x] as const).sort((a, b) => a[0] - b[0]).map(([, x]) => x);

const produits = melanger([...new Set((p.data ?? []).map((x) => x.name.trim()))]).slice(0, MAX_PRODUITS);
const boutiques = [...new Set((m.data ?? []).map((x) => x.name.trim()))];
console.log(`${produits.length} produits, ${boutiques.length} enseignes.`);

export interface Requete { requete: string; cible: string; type: 'produit' | 'boutique'; source: 'gemini' | 'frappe' }

// --- Fautes de frappe tirées au hasard -----------------------------------
const VOISINES: Record<string, string> = {
  a: 'zqs', z: 'aes', e: 'zrd', r: 'etf', t: 'ryg', y: 'tuh', u: 'yij', i: 'uok', o: 'ipl', p: 'om',
  q: 'asw', s: 'qdz', d: 'sfe', f: 'dgr', g: 'fht', h: 'gjy', j: 'hku', k: 'jli', l: 'kmo', m: 'lp',
  w: 'xq', x: 'wcs', c: 'xvd', v: 'cbf', b: 'vng', n: 'bhj',
};
function fauteDeFrappe(nom: string): string {
  const mots = normaliserIntention(nom).split(' ');
  // Le mot le plus long : c'est lui qui porte le nom (« attieke », « doukounou »).
  const i = mots.reduce((best, mot, k) => (mot.length > mots[best]!.length ? k : best), 0);
  const mot = mots[i]!;
  if (mot.length < 4) return mots.join(' ');
  const pos = 1 + Math.floor(hasard() * (mot.length - 2));
  const c = mot[pos]!;
  const genre = Math.floor(hasard() * 4);
  const fautif = genre === 0 ? mot.slice(0, pos) + mot.slice(pos + 1) // lettre sautée
    : genre === 1 ? mot.slice(0, pos) + c + mot.slice(pos) // lettre doublée
    : genre === 2 ? mot.slice(0, pos - 1) + c + mot[pos - 1] + mot.slice(pos + 1) // inversion
    : mot.slice(0, pos) + (VOISINES[c]?.[Math.floor(hasard() * 3)] ?? c) + mot.slice(pos + 1); // touche voisine
  mots[i] = fautif;
  return mots.join(' ');
}

const requetes: Requete[] = [
  ...produits.map((cible) => ({ requete: fauteDeFrappe(cible), cible, type: 'produit' as const, source: 'frappe' as const })),
  ...boutiques.map((cible) => ({ requete: fauteDeFrappe(cible.replace(/\([^)]*\)/g, '')), cible, type: 'boutique' as const, source: 'frappe' as const })),
].filter((r) => normaliserIntention(r.requete) !== normaliserIntention(r.cible));

// --- Écritures de clients, par Gemini -------------------------------------
async function viaGemini(noms: string[], type: 'produit' | 'boutique'): Promise<Requete[]> {
  const consigne = [
    `Voici des noms de ${type === 'produit' ? 'produits et plats' : 'boutiques et restaurants'} vendus sur Tovo, à Niamey (Niger).`,
    'Pour CHACUN, écris 4 façons dont un client pourrait le taper dans la barre de recherche, MAL écrit :',
    '- orthographe phonétique ou locale (attiéké → atieke, atchéké ; kilichi → kilishi ; O\'Takoss → otacos),',
    '- lettres oubliées ou doublées, accents absents, mots collés ou coupés,',
    '- style SMS ou abréviation, ou seulement le mot principal mal écrit.',
    'Jamais le nom exact. Garde le sens : le client cherche bien CE produit.',
    '',
    ...noms.map((n, i) => `${i + 1}. ${n}`),
  ].join('\n');
  try {
    const reponse = await client!.generate({
      system: 'Tu produis uniquement le JSON demandé.',
      history: [{ role: 'user', content: consigne }],
      tools: [],
      cachePrompt: false,
      responseSchema: {
        type: 'OBJECT',
        properties: {
          resultats: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: { numero: { type: 'INTEGER' }, requetes: { type: 'ARRAY', items: { type: 'STRING' } } },
              required: ['numero', 'requetes'],
            },
          },
        },
        required: ['resultats'],
      },
    });
    const { resultats } = JSON.parse(reponse.text) as { resultats: Array<{ numero: number; requetes: string[] }> };
    return resultats.flatMap(({ numero, requetes: rs }) => {
      const cible = noms[numero - 1];
      if (!cible) return [];
      return rs.filter((r) => typeof r === 'string' && r.trim())
        .map((requete) => ({ requete: requete.trim(), cible, type, source: 'gemini' as const }));
    });
  } catch (cause) {
    console.log(`  ✗ lot ${type} : ${cause instanceof Error ? cause.message : cause}`);
    return [];
  }
}

const lots: Array<[string[], 'produit' | 'boutique']> = [];
for (let i = 0; i < produits.length; i += 10) lots.push([produits.slice(i, i + 10), 'produit']);
for (let i = 0; i < boutiques.length; i += 10) lots.push([boutiques.slice(i, i + 10), 'boutique']);
let faits = 0;
for (let i = 0; i < lots.length; i += 4) {
  const r = await Promise.all(lots.slice(i, i + 4).map(([noms, type]) => viaGemini(noms, type)));
  requetes.push(...r.flat());
  faits += r.length;
  process.stdout.write(`\r${faits}/${lots.length} lots Gemini`);
}
console.log('');

// Une requête identique au nom n'est pas une faute : on l'écarte.
const utiles = requetes.filter((r) => normaliserIntention(r.requete) !== normaliserIntention(r.cible));
writeFileSync('scripts/recherche/requetes.json', JSON.stringify(utiles, null, 1));
const compte = (f: (r: Requete) => boolean) => utiles.filter(f).length;
console.log(`${utiles.length} requêtes : produits ${compte((r) => r.type === 'produit')} (gemini ${compte((r) => r.type === 'produit' && r.source === 'gemini')}, frappe ${compte((r) => r.type === 'produit' && r.source === 'frappe')}), enseignes ${compte((r) => r.type === 'boutique')}.`);
