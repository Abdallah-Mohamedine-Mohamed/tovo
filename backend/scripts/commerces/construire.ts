/**
 * Construit l'annuaire des commerces de Niamey qui ne sont PAS sur Tovo
 * (data/commerces-niamey.json), lu par services/commerces.ts.
 *
 *   npx tsx scripts/commerces/construire.ts <overture-niamey.json>
 *
 * Deux sources :
 *  - Overture Maps (extraire-overture.mjs) : surtout des pages Facebook de
 *    commerces, souvent avec un téléphone. Fiabilité inégale : on ne garde
 *    que confidence ≥ 0,5 et les types utiles ;
 *  - OpenStreetMap (data/lieux-niamey.json) : supermarchés, marchés et
 *    restaurants, sans téléphone mais rarement inventés.
 *
 * Écartés volontairement : salons de coiffure et de beauté (des services,
 * pas des produits), bureaux. Les pharmacies, d'abord écartées, sont
 * incluses depuis le 01/10.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { normaliserIntention } from '../../src/ai/intents.js';
import type { TypeCommerce } from '../../src/services/commerces.js';

interface Overture {
  id: string; nom: string | null; categorie: string | null; detail: string | null;
  confidence: number; phones: string[] | null; adresse: string | null; lat: number; lng: number;
}
interface Lieu { id: string; nom: string; genre: string; quartier: string | null; lat: number; lng: number }

const FIABILITE_MIN = 0.5;

// L'ordre compte : le premier qui correspond l'emporte.
const TYPES: Array<[TypeCommerce, RegExp]> = [
  ['pharmacie', /pharmacy|drug_store|drugstore/],
  ['boucherie', /butcher|meat_shop|meat/],
  ['boulangerie', /bakery|patisserie|pastry/],
  ['beaute', /beauty_supply|cosmetic|perfume|personal_care_and_beauty_store/],
  ['electronique', /electronics_store|mobile_phone_store|computer_store|electronic_equipment/],
  ['vetements', /clothing|fashion|shoe_store|apparel|lingerie|fabric_store/],
  ['quincaillerie', /hardware_store|home_improvement|lighting_store|building_supply/],
  ['marche', /farmers_market|public_market/],
  ['supermarche', /supermarket|grocery|convenience_store|warehouse_club|department_store|food_and_beverage_store|cheese_shop|hypermarket/],
  ['restaurant', /restaurant|fast_food|eatery|food_court|ice_cream|^cafe/],
  ['boutique', /^shopping|shopping_mall|general_store|specialty_store|home_goods_store/],
];
const EXCLUS = /salon|barber|spa|clinic|hospital|office|agency|service/;

// Le nom dément souvent la catégorie d'Overture (« Restaurant La Corniche »
// rangé en épicerie, « … Services & Consulting » en supermarché) : il passe
// devant.
// « Pharmacie des Produits Vétérinaires » ne vend pas de paracétamol.
const NOM_PAS_UN_COMMERCE = /\b(services?|consulting|consultants?|agence|cabinet|immobili\w*|ong|association|transit|transport|voyages?|assurances?|banque|clinique|ecole|institut|hotel|residence|veterinaires?)\b/;
const NOM_RESTAURANT = /\b(restaurant|resto|maquis|grill|grillade|brasserie|snack|fast food|pizzeria|cafeteria|lounge)\b/;

function typeOverture(p: Overture): TypeCommerce | null {
  const texte = `${p.detail ?? ''} ${p.categorie ?? ''}`;
  const nom = normaliserIntention(p.nom ?? '');
  if (EXCLUS.test(p.detail ?? '') || NOM_PAS_UN_COMMERCE.test(nom)) return null;
  if (NOM_RESTAURANT.test(nom)) return 'restaurant';
  return TYPES.find(([, motif]) => motif.test(texte))?.[0] ?? null;
}

/** « +227 20 73 61 60 » → { affiche: « 20 73 61 60 », appel: « +22720736160 » }. */
function telephone(brut: string | undefined): { affiche: string; appel: string } | null {
  let chiffres = (brut ?? '').replace(/\D/g, '');
  if (chiffres.startsWith('00227')) chiffres = chiffres.slice(5);
  if (chiffres.startsWith('227') && chiffres.length === 11) chiffres = chiffres.slice(3);
  if (chiffres.length !== 8) return null;
  return { affiche: chiffres.replace(/(\d{2})(?=\d)/g, '$1 '), appel: `+227${chiffres}` };
}

/** Une vraie adresse, pas une boîte postale, un lien ou « Niamey ». */
function adresse(brut: string | null, nom: string): string | null {
  const a = (brut ?? '').replace(/\s+/g, ' ').replace(/(,\s*(niamey|niger))+\s*$/i, '').trim();
  if (a.length < 4 || /^(b\.?p\.?|bp\d)|https?:|^niamey$|^niger$|^\d+$/i.test(a) || a.length > 80) return null;
  // L'adresse qui répète le nom (« Falla cosmetique ») n'apprend rien.
  if (normaliserIntention(nom).includes(normaliserIntention(a))) return null;
  return a;
}

const metres = (a: { lat: number; lng: number }, b: { lat: number; lng: number }) =>
  Math.hypot((a.lat - b.lat) * 111_000, (a.lng - b.lng) * 108_000);

const overture = JSON.parse(readFileSync(process.argv[2] ?? 'overture-niamey.json', 'utf8')) as Overture[];
const lieux = (JSON.parse(readFileSync('data/lieux-niamey.json', 'utf8')) as { lieux: Lieu[] }).lieux;
const quartiers = lieux.filter((l) => l.genre === 'quartier');
const quartierDe = (p: { lat: number; lng: number }) => {
  let meilleur: Lieu | null = null;
  let d = 2500;
  for (const q of quartiers) {
    const dq = metres(p, q);
    if (dq < d) { d = dq; meilleur = q; }
  }
  return meilleur?.nom ?? null;
};

const commerces = [];
for (const p of overture) {
  if (!p.nom || p.confidence < FIABILITE_MIN) continue;
  const type = typeOverture(p);
  if (!type) continue;
  const tel = telephone(p.phones?.[0]);
  commerces.push({
    id: `ovt:${p.id}`, nom: p.nom.replace(/\s+/g, ' ').trim(), nom_normalise: normaliserIntention(p.nom),
    type, adresse: adresse(p.adresse, p.nom), quartier: quartierDe(p),
    telephone: tel?.affiche ?? null, telephone_appel: tel?.appel ?? null,
    lat: Number(p.lat), lng: Number(p.lng), fiabilite: Math.round(p.confidence * 100) / 100, source: 'overture',
  });
}

const GENRES_OSM: Record<string, TypeCommerce> = {
  'supermarché': 'supermarche', 'marché': 'marche', restaurant: 'restaurant',
  // Incluses le 01/10 à la demande de l'équipe (« c'est très important »).
  pharmacie: 'pharmacie',
};
for (const l of lieux) {
  const type = GENRES_OSM[l.genre];
  if (!type || !l.nom) continue;
  const n = normaliserIntention(l.nom);
  if (NOM_PAS_UN_COMMERCE.test(n)) continue;
  // Déjà connu par Overture (souvent avec un téléphone) : on garde celui-là.
  if (commerces.some((c) => c.nom_normalise === n && metres(c, l) < 400)) continue;
  commerces.push({
    id: `osm:${l.id}`, nom: l.nom, nom_normalise: n, type, adresse: null, quartier: l.quartier ?? quartierDe(l),
    telephone: null, telephone_appel: null, lat: l.lat, lng: l.lng, fiabilite: 0.8, source: 'osm',
  });
}

// Les ajouts à la main (data/commerces-ajouts.json) : ce que l'équipe connaît
// et que personne n'a publié (« le vendeur de merguez de la place Toumo »).
const ajouts = (JSON.parse(readFileSync('data/commerces-ajouts.json', 'utf8')) as {
  commerces: Array<{ nom: string } & Record<string, unknown>>;
}).commerces;
for (const a of ajouts) {
  const { note: _note, ...commerce } = a;
  commerces.push({ ...commerce, nom_normalise: normaliserIntention(a.nom) } as (typeof commerces)[number]);
}

writeFileSync('data/commerces-niamey.json', JSON.stringify({
  source: 'Overture Maps Foundation (CDLA Permissive 2.0) ; © les contributeurs d’OpenStreetMap (ODbL) ; ajouts Tovo',
  construit_le: new Date().toISOString(),
  commerces,
}));
const parType: Record<string, number> = {};
for (const c of commerces) parType[c.type] = (parType[c.type] ?? 0) + 1;
console.log(`${commerces.length} commerces → data/commerces-niamey.json`, parType,
  `avec téléphone : ${commerces.filter((c) => c.telephone).length}`);
