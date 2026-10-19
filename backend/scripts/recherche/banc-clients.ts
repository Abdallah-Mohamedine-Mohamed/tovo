/**
 * Banc de recherche « comme un client » (19/10) : le client ne tape pas le nom
 * du produit, il dit ce qu'il veut (« médicament contre le palu », « frigo »,
 * « jus de baobab »). Mesure le rang du premier produit acceptable avant /
 * après les fiches de recherche (scripts/recherche/fiches.ts).
 *
 * Même fonction que l'app (cataloguePage, recherche par le sens comprise :
 * 1 empreinte Gemini par phrase). Lecture seule.
 *
 *   npx tsx --env-file=.env scripts/recherche/banc-clients.ts
 */
import { createClient } from '@supabase/supabase-js';
import { cataloguePage } from '../../src/services/catalogue.js';

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// [ce que tape le client, noms acceptables]
const CAS: Array<[string, RegExp]> = [
  ['médicament contre le palu', /artefan|bimalaril/i],
  ['sirop contre la toux', /rhinathiol/i],
  ['écouteurs iphone', /earpods/i],
  ['batterie externe pour téléphone', /power bank|batterie externe/i],
  ['frigo', /r[ée]frig[ée]rateur/i],
  ["cartouche d'encre hp", /cartridge|toner|encre/i],
  ['routeur wifi 4g', /tenda 4g/i],
  ['jeu de course ps5', /need for speed/i],
  ['boisson énergisante', /red bull|monster|xr energy|predator/i],
  ['soda au citron', /sprite/i],
  ['café soluble', /nescaf|nestcaf/i],
  ['céréales petit déjeuner', /corn flakes|muesli|flocons|c[ée]r[ée]acol/i],
  ['chocolat noir', /lindt/i],
  ['lait corporel éclaircissant vitamine c', /half cast/i],
  ['gommage visage curcuma', /turmeric/i],
  ['produit défrisant cheveux', /d[ée]fris/i],
  ['parfum dior pour femme', /dior|j'adore/i],
  ['tente pour cérémonie', /chapiteau/i],
  ['bonbonne de gaz 12 kg', /gaz \(12kg\)/i],
  ['gâteau turc à la pistache', /baklava|fistik|kunefe/i],
  ['riz au poisson sénégalais', /tchep/i],
  ['brochettes de viande épicée', /tukunya|toukounya|suya/i],
  ['plat mexicain', /fajitas|qu[ée]sadillas|taco/i],
  ['bubble tea', /boba|th[ée] au lait/i],
  ['boisson maltée', /maltina/i],
  ['jus de baobab', /pain de singe/i],
  ["jus d'hibiscus", /bissap/i],
  ['pâtes à la viande hachée', /bolognaise|spaghetti.*(boeuf|viande)/i],
  ['foufou', /igname pil|foutou/i],
  ['location de tables pour mariage', /table/i],
  ['gel douche gommant citron 1 litre', /kiss beauty.*lemon|lemon.*scrub/i],
  ['crème pour les mains', /hand cream|cr[èe]me.*mains/i],
];

let premier = 0, top3 = 0, top10 = 0;
for (const [phrase, attendu] of CAS) {
  const page = await cataloguePage(db, { q: phrase, limit: 10 } as never);
  const rang = page.items.findIndex((p) => attendu.test(String(p.name))) + 1;
  if (rang === 1) premier++;
  if (rang >= 1 && rang <= 3) top3++;
  if (rang >= 1) top10++;
  console.log(`${rang === 1 ? '✓' : rang ? '~' : '✗'} ${phrase.padEnd(40)} ${rang ? `rang ${rang}` : 'absent du top 10'}  (1er : ${String(page.items[0]?.name ?? '—').slice(0, 50)})`);
}
console.log(`\nEn tête ${premier}/${CAS.length} · top 3 ${top3}/${CAS.length} · top 10 ${top10}/${CAS.length}`);
