/**
 * Variantes d'écriture de chaque produit et de chaque enseigne du catalogue :
 * comment un client de Niamey les tape (attiéké → atieke, atchéké ;
 * O'Takoss → otacos, o takos). Stockées dans `search_aliases` (migration
 * 0056), cherchées exactement comme le nom.
 *
 *   npm run recherche:variantes             → écrit scripts/recherche/variantes.json (à relire)
 *   npm run recherche:variantes -- --apply  → écrit aussi en base
 *
 * Une variante est une AUTRE ÉCRITURE du même nom, jamais un synonyme ni un
 * autre plat : « pizza » n'est pas une variante de « Pizza Crevette », et
 * « riz » ne l'est pas de « Attiéké ». Sinon on ferait apparaître des
 * produits que le client n'a pas demandés.
 */
import { writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { llmClient } from '../../src/ai/llmClient.js';
import { normaliserIntention } from '../../src/ai/intents.js';

const appliquer = process.argv.includes('--apply');
const client = llmClient();
if (!client) throw new Error('GEMINI_API_KEY absente.');
const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const [p, m] = await Promise.all([
  db.from('products').select('name, merchants!inner(is_approved)').eq('merchants.is_approved', true).limit(10000),
  db.from('merchants').select('name').eq('is_approved', true),
]);
if (p.error) throw p.error;
if (m.error) throw m.error;
const produits = [...new Set((p.data ?? []).map((x) => x.name.trim()))];
const boutiques = [...new Set((m.data ?? []).map((x) => x.name.trim()))];
console.log(`${produits.length} noms de produits, ${boutiques.length} enseignes.`);

interface Variantes { type: 'produit' | 'boutique'; nom: string; variantes: string[] }

async function lot(noms: string[], type: Variantes['type']): Promise<Variantes[]> {
  const consigne = [
    `Noms de ${type === 'produit' ? 'produits et plats' : 'boutiques et restaurants'} vendus sur Tovo, à Niamey (Niger).`,
    'Pour CHACUN, donne 6 à 10 AUTRES ÉCRITURES qu’un client pourrait taper pour le même nom :',
    '- orthographe phonétique ou locale (attiéké → atieke, atchéké, attieke ; kilichi → kilishi ; tchapalo → chapalo),',
    '- fautes fréquentes : lettres doublées ou manquantes, accents absents, mots collés ou séparés,',
    '- pour une enseigne : le nom sans ponctuation, sans le quartier entre parenthèses, en abrégé.',
    'INTERDIT : synonymes, traductions, noms d’autres plats, mots génériques seuls (pizza, riz, jus, menu, poulet).',
    'Si le nom est déjà un mot français courant sans difficulté, donne peu de variantes (fautes de frappe seulement).',
    '',
    ...noms.map((n, i) => `${i + 1}. ${n}`),
  ].join('\n');
  for (let essai = 0; essai < 2; essai++) {
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
                properties: { numero: { type: 'INTEGER' }, variantes: { type: 'ARRAY', items: { type: 'STRING' } } },
                required: ['numero', 'variantes'],
              },
            },
          },
          required: ['resultats'],
        },
      });
      const { resultats } = JSON.parse(reponse.text) as { resultats: Array<{ numero: number; variantes: string[] }> };
      return resultats.flatMap(({ numero, variantes }) => {
        const nom = noms[numero - 1];
        if (!nom) return [];
        const propre = normaliserIntention(nom);
        // Pas de doublon du nom lui-même, rien de trop court pour être sûr.
        const uniques = [...new Set(variantes.map((v) => v.trim()).filter((v) => v.length >= 3))]
          .filter((v) => normaliserIntention(v) !== propre && !v.includes(';'));
        return [{ type, nom, variantes: uniques.slice(0, 10) }];
      });
    } catch {
      // Nouvel essai ; au second échec, le lot est simplement sauté.
    }
  }
  console.log(`\n  ✗ lot ${type} sauté (${noms[0]}…)`);
  return [];
}

const lots: Array<[string[], Variantes['type']]> = [];
for (let i = 0; i < produits.length; i += 10) lots.push([produits.slice(i, i + 10), 'produit']);
for (let i = 0; i < boutiques.length; i += 10) lots.push([boutiques.slice(i, i + 10), 'boutique']);

const toutes: Variantes[] = [];
for (let i = 0; i < lots.length; i += 4) {
  const r = await Promise.all(lots.slice(i, i + 4).map(([noms, type]) => lot(noms, type)));
  toutes.push(...r.flat());
  process.stdout.write(`\r${Math.min(i + 4, lots.length)}/${lots.length} lots`);
}
console.log('');
writeFileSync('scripts/recherche/variantes.json', JSON.stringify(toutes, null, 1));
console.log(`${toutes.length} noms enrichis (${toutes.reduce((s, v) => s + v.variantes.length, 0)} variantes) → scripts/recherche/variantes.json`);

if (!appliquer) {
  console.log('Relisez le fichier, puis relancez avec --apply pour écrire en base.');
  process.exit(0);
}

let ecrits = 0;
for (const v of toutes) {
  const { error } = await db.from(v.type === 'produit' ? 'products' : 'merchants')
    .update({ search_aliases: v.variantes.join(' ; ') })
    .eq('name', v.nom);
  if (error) {
    if (error.code === '42703') throw new Error('Colonne search_aliases absente : passez d’abord la migration 0056.');
    console.log(`  ✗ ${v.nom} : ${error.message}`);
  } else ecrits++;
}
console.log(`${ecrits}/${toutes.length} noms mis à jour en base.`);
