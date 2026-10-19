/**
 * Banc de RECHERCHE ÉCRITE sur Niger Beauté (19/10) : des phrases comme les
 * tapent les clients, en français, et le produit attendu. Mesure le rang du
 * produit dans les 10 premiers résultats — avant / après les fiches
 * (decrire.ts). Même fonction que l'app (cataloguePage, recherche
 * sémantique comprise : 1 empreinte Gemini par phrase).
 *
 *   npx tsx --env-file=.env scripts/niger-beaute/banc-recherche.ts
 */
import { createClient } from '@supabase/supabase-js';
import { cataloguePage } from '../../src/services/catalogue.js';

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const CAS: Array<[string, string]> = [
  ['gel douche gommant citron 1 litre', 'NB-476'],
  ['déodorant dove pomme', 'NB-071'],
  ['parfum lattafa asad', 'NB-1099'],
  ['eau micellaire zaron', 'NB-672'],
  ['gel douche melanine 500 ml', 'NB-455'],
  ['nettoyant visage acide kojique', 'NB-001'],
  ['eau de cologne lavande 900 ml', 'NB-511'],
  ['serviettes hygiéniques besense', 'NB-354'],
  ['crème visage ujooba', 'NB-115'],
  ['alcool eau de roche', 'NB-522'],
  ['sérum carotte françoise bedon', 'NB-663'],
  ['savon africain miel curcuma', 'NB-058'],
];

const { data: produits } = await db.from('products').select('id, legacy_id').like('legacy_id', 'niger-beaute:%');
const idDe = new Map((produits ?? []).map((p) => [String(p.legacy_id).split(':')[1], p.id as string]));
let premier = 0, top3 = 0, top10 = 0, absents = 0;
for (const [phrase, nb] of CAS) {
  const id = idDe.get(nb);
  if (!id) { absents++; console.log(`— ${phrase} : ${nb} pas dans Tovo`); continue; }
  const page = await cataloguePage(db, { q: phrase, limit: 10 } as never);
  const rang = page.items.findIndex((p) => p.id === id) + 1;
  if (rang === 1) premier++;
  if (rang >= 1 && rang <= 3) top3++;
  if (rang >= 1) top10++;
  console.log(`${rang === 1 ? '✓' : rang ? '~' : '✗'} ${phrase.padEnd(36)} ${rang ? `rang ${rang}` : 'absent du top 10'}  (1er : ${page.items[0]?.name ?? '—'})`);
}
const n = CAS.length - absents;
console.log(`\nEn tête ${premier}/${n} · top 3 ${top3}/${n} · top 10 ${top10}/${n}`);
