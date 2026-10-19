/**
 * Banc de recherche « comme un client » : le client ne tape pas le nom du
 * produit, il dit ce qu'il veut (« médicament contre le palu », « frigo »,
 * « bonbonne de gaz 12 kg »). Même fonction que l'app (cataloguePage,
 * recherche par le sens comprise : 1 empreinte Gemini par phrase, quelques
 * centimes). Lecture seule.
 *
 *   npx tsx --env-file=.env scripts/recherche/banc-clients.ts
 *
 * Durci le 19/10 (revue externe) : la grille acceptait un produit dès qu'un
 * mot de son nom collait — `/table/` aurait accepté le « Sel de table » pour
 * des tables de location, `/dior/` un Dior pour homme. Désormais chaque cas
 * dit :
 *   - `bon`    : ce QU'EST un produit acceptable, lu dans son NOM ;
 *   - `exige`  : les contraintes du client (marque, contenance, public), lues
 *                dans le nom ou les variantes d'écriture — toutes requises ;
 *   - `refuse` : un voisin qui ne convient pas (lu dans le nom) ; s'il sort en
 *                tête, c'est compté comme FAUX EN TÊTE ;
 *   - `absent` : aucune offre adaptée n'est en vente. Réussi si aucun piège
 *                (`refuse`) n'est dans les 3 premiers — mieux vaut rien qu'un
 *                voisin.
 *
 * Trois lots, jamais mélangés dans un score :
 *   - `reglage` : les phrases sur lesquelles on a travaillé ;
 *   - `pieges`  : mauvaise contenance, mauvais public, produit absent ;
 *   - `temoin`  : écrit le 19/10 d'après le catalogue, SANS avoir regardé les
 *                 réponses du moteur. On ne règle jamais rien d'après lui : il
 *                 dit si un réglage se généralise. Le modifier pour le faire
 *                 passer lui ôte toute valeur.
 *
 * Un avant/après n'a de sens qu'à catalogue constant : relancer les deux
 * versions le même jour, sans chargement entre les deux.
 */
import { createClient } from '@supabase/supabase-js';
import { cataloguePage } from '../../src/services/catalogue.js';

const db = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type Lot = 'reglage' | 'pieges' | 'temoin';
interface Cas {
  phrase: string;
  bon?: RegExp;
  exige?: RegExp[];
  refuse?: RegExp;
  absent?: true;
}

const HP = /\bhp\b|\bcf\d|\bce\d|\bw1\d/i;

const LOTS: Record<Lot, Cas[]> = {
  reglage: [
    { phrase: 'médicament contre le palu', bon: /artefan|bimalaril|coartem|art[ée]m/i },
    { phrase: 'sirop contre la toux', bon: /rhinathiol|sirop.*toux|toux.*sirop/i },
    { phrase: 'écouteurs iphone', bon: /earpods|[ée]couteurs?/i, exige: [/iphone|lightning|apple/i], refuse: /chargeur/i },
    { phrase: 'batterie externe pour téléphone', bon: /power ?bank|batterie externe/i, refuse: /voiture/i },
    { phrase: 'frigo', bon: /r[ée]frig[ée]rateur|frigo/i },
    { phrase: "cartouche d'encre hp", bon: /toner|cartouche|cartridge|encre/i, exige: [HP], refuse: /cleansing|spf|visage/i },
    { phrase: 'routeur wifi 4g', bon: /routeur|router|mobile wifi|mifi/i, exige: [/4g/i] },
    { phrase: 'jeu de course ps5', bon: /need for speed|gran turismo|forza|\bf1\b|crew/i, exige: [/ps5/i] },
    { phrase: 'boisson énergisante', bon: /red bull|monster|3x energy|xr energy|predator|energy drink|boisson [ée]nergisante/i, refuse: /barre|biscuit/i },
    { phrase: 'soda au citron', bon: /sprite|7 ?up|citron|lemon/i, refuse: /savon|gel|douche|th[ée]/i },
    { phrase: 'café soluble', bon: /nescaf|nestcaf|caf[ée] soluble/i },
    { phrase: 'céréales petit déjeuner', bon: /corn flakes|muesli|flocons|c[ée]r[ée]acol|golden morn|c[ée]r[ée]ales|p[ée]tales/i },
    { phrase: 'chocolat noir', bon: /chocolat|lindt/i, exige: [/noir|dark/i], refuse: /biscuit|cuiller|cookie/i },
    { phrase: 'lait corporel éclaircissant vitamine c', bon: /lait|lotion/i, exige: [/vitamin|power c|vit\.? ?c/i, /[ée]claircis|clarif|whiten|white/i] },
    { phrase: 'gommage visage curcuma', bon: /scrub|gommage|exfolia/i, exige: [/turmeric|curcuma/i] },
    { phrase: 'produit défrisant cheveux', bon: /d[ée]fris|relaxer|relax/i },
    { phrase: 'parfum dior pour femme', bon: /dior/i, exige: [/femme|women|\bf\b|j'adore|miss dior/i], refuse: /homme|\bmen\b/i },
    { phrase: 'tente pour cérémonie', absent: true, refuse: /savon|ch[aâ]teau|shampo|parfum/i },
    { phrase: 'bonbonne de gaz 12 kg', bon: /gaz/i, exige: [/12 ?kg/i], refuse: /6 ?kg|cuisini/i },
    { phrase: 'gâteau turc à la pistache', bon: /baklava|fistik|k[uü]nefe/i },
    { phrase: 'riz au poisson sénégalais', bon: /tchep|thieb|ceebu/i },
    { phrase: 'brochettes de viande épicée', bon: /tukunya|toukounya|suya|brochette/i },
    { phrase: 'plat mexicain', bon: /fajitas|qu[ée]sadilla|burrito|nachos|enchilada|huevos rancheros/i },
    { phrase: 'bubble tea', bon: /boba|bubble|th[ée] au lait/i },
    { phrase: 'boisson maltée', bon: /maltina|malta|malt/i },
    { phrase: 'jus de baobab', bon: /baobab|pain de singe/i, exige: [/jus|boisson/i] },
    { phrase: "jus d'hibiscus", bon: /bissap|hibiscus|fol[ée]r[ée]/i },
    { phrase: 'pâtes à la viande hachée', bon: /bolognaise|spaghetti|p[âa]tes|macaroni|lasagne/i, exige: [/bolognaise|viande|boeuf|b(oe|œ)uf|hach/i], refuse: /nems|pizza|burger/i },
    { phrase: 'foufou', bon: /foufou|foutou|igname pil|fufu/i },
    { phrase: 'location de tables pour mariage', absent: true, refuse: /sel de table|[ée]dulcorant|support|r[ée]frig[ée]rateur/i },
    { phrase: 'gel douche gommant citron 1 litre', bon: /gel douche|shower gel/i, exige: [/lemon|citron/i, /1 ?l\b|1000 ?ml|litre/i] },
    { phrase: 'crème pour les mains', bon: /cr[èe]me|lait|lotion/i, exige: [/mains|hand/i], refuse: /savon|seife|soap/i },
  ],
  pieges: [
    { phrase: 'gaz 6 kg', bon: /gaz/i, exige: [/6 ?kg/i], refuse: /12 ?kg|cuisini/i },
    { phrase: 'parfum pour homme', bon: /parfum|eau de toilette|eau de parfum|perfum/i, exige: [/homme|\bmen\b|\bh\b/i], refuse: /femme|\bf$|women/i },
    { phrase: 'chargeur samsung', bon: /chargeur|charger/i, exige: [/samsung/i], refuse: /iphone|xiaomi/i },
    { phrase: 'chargeur iphone', bon: /chargeur|charger/i, exige: [/iphone|lightning|apple/i], refuse: /samsung|xiaomi/i },
    { phrase: 'toner visage', bon: /toner|tonique|lotion/i, exige: [/visage|face|cleansing|peau|skin/i], refuse: /44a|106a|85a|ink|cartouche/i },
    { phrase: 'huile de cuisine 5 litres', bon: /huile/i, exige: [/5 ?l\b|5 litres?/i], refuse: /argan|ricin|coco|carotte|mono[iï]|karit|corps|cheveux/i },
    { phrase: 'shampoing pour bébé', bon: /shampo/i, exige: [/baby|b[ée]b[ée]/i] },
    { phrase: 'eau minérale', bon: /eau min[ée]rale|eau 0|bouteille d'eau|^eau\b/i, refuse: /parfum|toilette|cologne/i },
    { phrase: 'couches pour bébé', absent: true, refuse: /shampo|savon|gel|lotion|huile/i },
    { phrase: 'paracétamol', absent: true, refuse: /artefan|bimalaril|rhinathiol|vitamine/i },
    { phrase: 'coca zéro', absent: true, refuse: /^coca(?!.*z[ée]ro)/i },
  ],
  temoin: [
    { phrase: 'déodorant pour homme', bon: /d[ée]odorant|deo\b/i, exige: [/homme|\bmen\b/i] },
    { phrase: "huile d'argan pour cheveux", bon: /huile|shampo|bain/i, exige: [/argan/i] },
    { phrase: 'savon noir africain', bon: /savon/i, exige: [/africain/i] },
    { phrase: 'écouteurs sans fil samsung', bon: /buds|[ée]couteur/i, exige: [/samsung|galaxy/i] },
    { phrase: 'sucre en poudre', bon: /sucre/i, exige: [/poudre|glace/i], refuse: /p[ée]tales|sucrerie/i },
    { phrase: 'hamburger au fromage', bon: /burger/i, exige: [/cheese|fromage/i] },
    { phrase: 'pizza végétarienne', bon: /pizza/i, exige: [/v[ée]g[ée]tarien/i] },
    { phrase: 'riz au gras', bon: /riz/i, exige: [/gras/i] },
    { phrase: 'shampoing antipelliculaire', bon: /shampo/i, exige: [/pellicul|dandruff|sulfur/i] },
    { phrase: 'lait clarifiant pour le corps', bon: /lait|lotion/i, exige: [/clarif|[ée]claircis/i] },
    { phrase: 'eau de cologne', bon: /cologne/i },
    { phrase: 'chargeur rapide xiaomi', bon: /chargeur|charger/i, exige: [/xiaomi/i] },
    { phrase: 'huile de coco', bon: /huile/i, exige: [/coco/i] },
    { phrase: 'thé au lait taro', bon: /th[ée] au lait/i, exige: [/taro/i] },
    { phrase: 'boisson gazeuse', bon: /coca|fanta|sprite|soda|gazeu/i, refuse: /\bgaz\b.*kg/i },
    { phrase: 'crème au beurre de karité', bon: /cr[èe]me|lait|lotion|huile|beurre|shampo/i, exige: [/karit/i] },
    { phrase: 'eau de parfum 100 ml', bon: /eau de parfum/i, exige: [/100 ?ml/i] },
    { phrase: 'gel douche pour homme', bon: /gel douche|shower gel/i, exige: [/homme|\bmen\b/i] },
    { phrase: 'riz basmati 1 kg', bon: /riz/i, exige: [/basmati/i, /1 ?kg/i] },
    { phrase: 'pizza au poulet', bon: /pizza/i, exige: [/poulet|chicken/i] },
  ],
};

interface Produit { id: string; name: string }

async function variantes(ids: string[]): Promise<Map<string, string>> {
  if (ids.length === 0) return new Map();
  const { data } = await db.from('products').select('id, search_aliases').in('id', ids);
  return new Map((data ?? []).map((l) => [String(l.id), String(l.search_aliases ?? '')]));
}

function convient(cas: Cas, p: Produit, alias: string): boolean {
  if (!cas.bon?.test(p.name)) return false;
  if (cas.refuse?.test(p.name)) return false;
  const texte = `${p.name} ; ${alias}`;
  return (cas.exige ?? []).every((r) => r.test(texte));
}

for (const [lot, cas] of Object.entries(LOTS) as Array<[Lot, Cas[]]>) {
  console.log(`\n=== ${lot} (${cas.length}) ===`);
  let enTete = 0, top3 = 0, top10 = 0, fauxEnTete = 0, avecOffre = 0, honnetes = 0, sansOffre = 0;
  for (const c of cas) {
    const page = await cataloguePage(db, { q: c.phrase, limit: 10 } as never);
    const items = page.items as unknown as Produit[];
    const alias = await variantes(items.map((p) => String(p.id)));
    const premier = String(items[0]?.name ?? '—').slice(0, 48);
    if (c.absent) {
      sansOffre++;
      const piege = items.slice(0, 3).find((p) => c.refuse?.test(p.name));
      if (!piege) honnetes++;
      console.log(`${piege ? '✗' : '✓'} ${c.phrase.padEnd(40)} sans offre : ${piege ? `piège montré (${piege.name.slice(0, 40)})` : items.length ? `pas de piège (1er : ${premier})` : 'rien montré'}`);
      continue;
    }
    avecOffre++;
    const rang = items.findIndex((p) => convient(c, p, alias.get(String(p.id)) ?? '')) + 1;
    const faux = items[0] ? c.refuse?.test(items[0].name) === true : false;
    if (rang === 1) enTete++;
    if (rang >= 1 && rang <= 3) top3++;
    if (rang >= 1) top10++;
    if (faux) fauxEnTete++;
    console.log(`${rang === 1 ? '✓' : rang ? '~' : '✗'} ${c.phrase.padEnd(40)} ${rang ? `rang ${rang}` : 'absent du top 10'}${faux ? '  FAUX EN TÊTE' : ''}  (1er : ${premier})`);
  }
  console.log(`→ ${lot} : en tête ${enTete}/${avecOffre} · top 3 ${top3}/${avecOffre} · top 10 ${top10}/${avecOffre} · faux en tête ${fauxEnTete}`
    + (sansOffre ? ` · sans offre honnêtes ${honnetes}/${sansOffre}` : ''));
}
