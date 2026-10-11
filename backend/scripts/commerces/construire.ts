/**
 * Construit l'annuaire des commerces de Niamey qui ne sont PAS sur Tovo
 * (data/commerces-niamey.json), lu par services/commerces.ts.
 *
 *   node scripts/commerces/extraire-overture.mjs   → overture-niamey.json
 *   node scripts/commerces/extraire-osm.mjs        → osm-boutiques-niamey.json
 *   npx tsx scripts/commerces/construire.ts overture-niamey.json osm-boutiques-niamey.json
 *
 * Trois sources :
 *  - Overture Maps : surtout des pages Facebook de commerces, souvent avec un
 *    téléphone. Fiabilité inégale : on ne garde que confidence ≥ 0,5 ;
 *  - OpenStreetMap, les lieux (data/lieux-niamey.json) : supermarchés,
 *    marchés, restaurants, pharmacies ;
 *  - OpenStreetMap, les BOUTIQUES (shop=*, ajoutées le 11/10) : 699 boutiques
 *    nommées, dont aucune n'était reprise — vêtements, alimentation,
 *    téléphones, boulangeries, librairies…
 *
 * Chaque commerce a un TYPE (son icône, son rayon) et, quand on le sait, une
 * CATÉGORIE fine (services/commerces.ts, CATEGORIES) : un atelier de couture
 * n'est pas un prêt-à-porter. Le NOM passe avant ce que dit la source
 * (« Restaurant La Corniche » rangé en épicerie, « Pharmacie Concorde »
 * rangée en santé).
 *
 * Écartés volontairement : les services (salons de coiffure et de beauté,
 * garages, agences de voyage, photocopie, pressing, loterie…), les bureaux,
 * les institutions. Les kiosques et les boutiques sans type (shop=yes) ne
 * sont repris que si leur nom dit ce qu'ils vendent.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { normaliserIntention } from '../../src/ai/intents.js';
import { categorie, type TypeCommerce } from '../../src/services/commerces.js';

interface Overture {
  id: string; nom: string | null; categorie: string | null; detail: string | null;
  confidence: number; phones: string[] | null; adresse: string | null; lat: number; lng: number;
}
interface Lieu { id: string; nom: string; genre: string; quartier: string | null; lat: number; lng: number }
interface BoutiqueOsm { id: string; nom: string; shop: string; lat: number; lng: number }

const FIABILITE_MIN = 0.5;

/** Un type seul, ou une catégorie fine (qui porte son type). */
type Classe = { type: TypeCommerce; categorie?: string };
const classe = (cle: string): Classe => {
  const c = categorie(cle);
  return c ? { type: c.type, categorie: c.slug } : { type: cle as TypeCommerce };
};

// LE NOM D'ABORD (11/10) : ce qu'il dit l'emporte sur la source. L'ordre
// compte : le plus précis avant le plus général.
const PAR_LE_NOM: Array<[RegExp, string]> = [
  [/\bpharmacie\b/, 'pharmacie'],
  [/\b(couture|couturiere?|tailleur|retouches?)\b/, 'couture'],
  [/\bfrip\w*/, 'friperie'],
  [/\b(chaussures?|cordonnerie)\b/, 'chaussures'],
  [/\b(tissus?|pagnes?|bazin|wax|mercerie)\b/, 'tissus'],
  [/\b(bijou\w*|joaill\w*|horlogerie)\b/, 'bijouterie'],
  [/\b(pret a porter|fashion|boutique de vetements|vetements)\b/, 'pret-a-porter'],
  [/\b(informatique|computers?|ordinateurs?)\b/, 'informatique'],
  [/\b(solaire|solar)\b/, 'solaire'],
  [/\belectromenager\b/, 'electromenager'],
  [/\b(telecoms?|telephon\w*|phones?|mobiles?|gsm)\b/, 'telephones'],
  [/\belectroni\w*/, 'electronique'],
  [/\b(parfum\w*|encens)\b/, 'parfumerie'],
  [/\b(cosmeti\w*|beaute)\b/, 'beaute'],
  [/\b(librairie|papeterie)\b/, 'librairie'],
  [/\b(meubles?|mobilier|ameublement)\b/, 'meubles'],
  [/\bgaz\b/, 'gaz'],
  [/\bpieces? (auto|moto|detachees?|de rechange)\b/, 'pieces-auto'],
  [/\b(optique|opticien|lunetterie)\b/, 'optique'],
  [/\bfleur(s|iste)\b/, 'fleuriste'],
  [/\bpatisserie\b/, 'patisserie'],
  [/\bboulangerie\b/, 'boulangerie'],
  [/\bpoissonn?erie\b/, 'poissonnerie'],
  [/\bboucherie\b/, 'boucherie'],
  [/\bmateriaux\b/, 'materiaux'],
  [/\bquincaillerie\b/, 'quincaillerie'],
  [/\bgrossiste\b/, 'grossiste'],
  [/\b(alimentation|superette|epicerie)\b/, 'alimentation'],
  [/\b(super ?market|supermarche|hypermarche)\b/, 'supermarche'],
  [/\bcentre commercial\b/, 'centre-commercial'],
];
const parLeNom = (nom: string): Classe | null => {
  const trouve = PAR_LE_NOM.find(([motif]) => motif.test(nom));
  return trouve ? classe(trouve[1]) : null;
};

// Overture : sa catégorie (detail, puis la catégorie large). Le premier qui
// correspond l'emporte.
const PAR_OVERTURE: Array<[RegExp, string]> = [
  [/pharmacy|drug_store|drugstore/, 'pharmacie'],
  [/sewing|tailor/, 'couture'],
  [/shoe_store/, 'chaussures'],
  [/fabric_store/, 'tissus'],
  [/jewelry|watch_store/, 'bijouterie'],
  [/clothing|fashion|apparel|lingerie/, 'pret-a-porter'],
  [/mobile_phone_store/, 'telephones'],
  [/computer_store/, 'informatique'],
  [/electronics_store|electronic_equipment/, 'electronique'],
  [/auto_parts|vehicle_parts/, 'pieces-auto'],
  [/furniture_store|home_goods_store/, 'meubles'],
  [/building_supply/, 'materiaux'],
  [/hardware|home_improvement|lighting_store/, 'quincaillerie'],
  [/bookstore|books_music/, 'librairie'],
  [/butcher|meat_shop|meat/, 'boucherie'],
  [/seafood|fish_market/, 'poissonnerie'],
  [/patisserie|pastry/, 'patisserie'],
  [/bakery/, 'boulangerie'],
  [/perfume/, 'parfumerie'],
  [/beauty_supply|cosmetic|personal_care_and_beauty_store/, 'beaute'],
  [/farmers_market|public_market/, 'marche'],
  [/grocery|convenience_store|food_and_beverage_store|cheese_shop/, 'alimentation'],
  [/warehouse_club/, 'grossiste'],
  [/department_store|shopping_mall/, 'centre-commercial'],
  [/supermarket|hypermarket/, 'supermarche'],
  [/restaurant|fast_food|eatery|food_court|ice_cream|^cafe/, 'restaurant'],
  [/optical|optician|eyewear/, 'optique'],
  [/florist|flower/, 'fleuriste'],
  [/^shopping|general_store|specialty_store|sporting_goods|souvenir|toy_store|gift_shop/, 'boutique'],
];
const EXCLUS = /salon|barber|spa|clinic|hospital|office|agency|service|repair|rental|dealer/;

// OSM : shop=* → catégorie ou type. null : un service, écarté. Absent : on
// ne sait pas (kiosque, shop=yes) — repris seulement si le nom le dit.
const PAR_OSM: Record<string, string | null> = {
  supermarket: 'supermarche', convenience: 'alimentation', general: 'alimentation', grocery: 'alimentation',
  beverages: 'alimentation', water: 'alimentation', dairy: 'alimentation', frozen_food: 'alimentation', deli: 'alimentation',
  cheese: 'alimentation', coffee: 'alimentation', health_food: 'alimentation', wholesale: 'grossiste',
  department_store: 'centre-commercial', mall: 'centre-commercial',
  bakery: 'boulangerie', pastry: 'patisserie', confectionery: 'patisserie', chocolate: 'patisserie', 'chocolate;pastry': 'patisserie',
  butcher: 'boucherie', seafood: 'poissonnerie', greengrocer: 'marche', farm: 'marche',
  clothes: 'pret-a-porter', boutique: 'pret-a-porter', fashion: 'pret-a-porter', bag: 'pret-a-porter', fashion_accessories: 'pret-a-porter',
  tailor: 'couture', sewing: 'tissus', fabric: 'tissus', shoes: 'chaussures', jewelry: 'bijouterie', watches: 'bijouterie',
  second_hand: 'friperie',
  mobile_phone: 'telephones', telecommunication: 'telephones', electronics: 'electronique', radiotechnics: 'electronique',
  computer: 'informatique', appliance: 'electromenager', energy: 'solaire',
  hardware: 'quincaillerie', doityourself: 'quincaillerie', paint: 'quincaillerie', electrical: 'quincaillerie', trade: 'quincaillerie',
  building_materials: 'materiaux',
  cosmetics: 'beaute', chemist: 'beaute', perfumery: 'parfumerie',
  books: 'librairie', stationery: 'librairie', furniture: 'meubles', interior_decoration: 'meubles', houseware: 'meubles', kitchen: 'meubles',
  gas: 'gaz', car_parts: 'pieces-auto', motorcycle: 'pieces-auto', tyres: 'pieces-auto', optician: 'optique',
  florist: 'fleuriste', garden_centre: 'fleuriste',
  variety_store: 'boutique', gift: 'boutique', toys: 'boutique', sports: 'boutique', baby_goods: 'boutique', art: 'boutique',
  frame: 'boutique', medical_supply: 'boutique', fishing: 'boutique', nutrition_supplements: 'boutique',
  hairdresser: null, beauty: null, travel_agency: null, copyshop: null, car_repair: null, motorcycle_repair: null, lottery: null,
  ticket: null, dry_cleaning: null, laundry: null, money_lender: null, car: null, photo: null, photo_studio: null,
  funeral_directors: null, vacant: null, security: null, estate_agent: null, charity: null, erotic: null, video: null,
  model: null, anime: null, outpost: null, fuel: null, tobacco: null,
};

// Le nom dément la source : un service ou une institution.
// « Pharmacie des Produits Vétérinaires » ne vend pas de paracétamol.
const NOM_PAS_UN_COMMERCE = /\b(services?|consulting|consultants?|agence|cabinet|immobili\w*|ong|association|transit|transport|voyages?|assurances?|banque|clinique|ecole|institut|hotel|residence|veterinaires?)\b/;
const NOM_RESTAURANT = /\b(restaurant|resto|maquis|grill|grillade|brasserie|snack|fast food|pizzeria|cafeteria|lounge)\b/;

function classeOverture(p: Overture): Classe | null {
  const nom = normaliserIntention(p.nom ?? '');
  if (EXCLUS.test(p.detail ?? '') && !parLeNom(nom)) return null;
  if (NOM_PAS_UN_COMMERCE.test(nom)) return null;
  if (NOM_RESTAURANT.test(nom)) return { type: 'restaurant' };
  const texte = `${p.detail ?? ''} ${p.categorie ?? ''}`;
  const source = PAR_OVERTURE.find(([motif]) => motif.test(texte))?.[1];
  return parLeNom(nom) ?? (source ? classe(source) : null);
}

function classeOsm(b: BoutiqueOsm): Classe | null {
  const nom = normaliserIntention(b.nom);
  if (NOM_PAS_UN_COMMERCE.test(nom)) return null;
  const source = PAR_OSM[b.shop];
  if (source === null) return null;
  return parLeNom(nom) ?? (source ? classe(source) : null);
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
const boutiquesOsm = JSON.parse(readFileSync(process.argv[3] ?? 'osm-boutiques-niamey.json', 'utf8')) as BoutiqueOsm[];
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

type Fiche = {
  id: string; nom: string; nom_normalise: string; type: TypeCommerce; categorie?: string; adresse: string | null;
  quartier: string | null; telephone: string | null; telephone_appel: string | null; lat: number; lng: number;
  fiabilite: number; source: string;
};
const commerces: Fiche[] = [];
const bilan: Record<string, number> = {};
const compter = (cle: string) => { bilan[cle] = (bilan[cle] ?? 0) + 1; };
// Déjà là : le même nom à moins de 400 m. On garde le premier (Overture, qui
// a souvent un téléphone).
const dejaLa = (n: string, p: { lat: number; lng: number }) => commerces.some((c) => c.nom_normalise === n && metres(c, p) < 400);

for (const p of overture) {
  if (!p.nom) { compter('overture : sans nom'); continue; }
  if (p.confidence < FIABILITE_MIN) { compter('overture : fiabilité < 0,5'); continue; }
  const c = classeOverture(p);
  if (!c) { compter('overture : service, institution ou sans type utile'); continue; }
  const tel = telephone(p.phones?.[0]);
  commerces.push({
    id: `ovt:${p.id}`, nom: p.nom.replace(/\s+/g, ' ').trim(), nom_normalise: normaliserIntention(p.nom),
    type: c.type, ...(c.categorie ? { categorie: c.categorie } : {}), adresse: adresse(p.adresse, p.nom), quartier: quartierDe(p),
    telephone: tel?.affiche ?? null, telephone_appel: tel?.appel ?? null,
    lat: Number(p.lat), lng: Number(p.lng), fiabilite: Math.round(p.confidence * 100) / 100, source: 'overture',
  });
  compter('overture : gardés');
}

const GENRES_OSM: Record<string, Classe> = {
  'supermarché': { type: 'supermarche' }, 'marché': { type: 'marche' }, restaurant: { type: 'restaurant' },
  // Incluses le 01/10 à la demande de l'équipe (« c'est très important »).
  pharmacie: { type: 'pharmacie' },
};
for (const l of lieux) {
  const c = GENRES_OSM[l.genre];
  if (!c || !l.nom) continue;
  const n = normaliserIntention(l.nom);
  if (NOM_PAS_UN_COMMERCE.test(n)) { compter('osm lieux : nom de service'); continue; }
  if (dejaLa(n, l)) { compter('osm lieux : doublon'); continue; }
  const fine = l.genre === 'restaurant' ? null : parLeNom(n);
  commerces.push({
    id: `osm:${l.id}`, nom: l.nom, nom_normalise: n, type: fine?.type ?? c.type, ...(fine?.categorie ? { categorie: fine.categorie } : {}),
    adresse: null, quartier: l.quartier ?? quartierDe(l),
    telephone: null, telephone_appel: null, lat: l.lat, lng: l.lng, fiabilite: 0.8, source: 'osm',
  });
  compter('osm lieux : gardés');
}

for (const b of boutiquesOsm) {
  const id = `osm:${b.id}`;
  // Déjà repris comme lieu (supermarché, pharmacie…).
  if (commerces.some((c) => c.id === id)) { compter('osm boutiques : déjà repris comme lieu'); continue; }
  const c = classeOsm(b);
  if (!c) { compter(PAR_OSM[b.shop] === null ? 'osm boutiques : service' : 'osm boutiques : type inconnu, nom muet'); continue; }
  const n = normaliserIntention(b.nom);
  if (dejaLa(n, b)) { compter('osm boutiques : doublon'); continue; }
  commerces.push({
    id, nom: b.nom, nom_normalise: n, type: c.type, ...(c.categorie ? { categorie: c.categorie } : {}),
    adresse: null, quartier: quartierDe(b), telephone: null, telephone_appel: null,
    lat: b.lat, lng: b.lng, fiabilite: 0.8, source: 'osm',
  });
  compter('osm boutiques : gardées');
}

// Les ajouts à la main (data/commerces-ajouts.json) : ce que l'équipe connaît
// et que personne n'a publié (« le vendeur de merguez de la place Toumo »).
const ajouts = (JSON.parse(readFileSync('data/commerces-ajouts.json', 'utf8')) as {
  commerces: Array<{ nom: string } & Record<string, unknown>>;
}).commerces;
for (const a of ajouts) {
  const { note: _note, ...commerce } = a;
  commerces.push({ ...commerce, nom_normalise: normaliserIntention(a.nom) } as Fiche);
}

writeFileSync('data/commerces-niamey.json', JSON.stringify({
  source: 'Overture Maps Foundation (CDLA Permissive 2.0) ; © les contributeurs d’OpenStreetMap (ODbL) ; ajouts Tovo',
  construit_le: new Date().toISOString(),
  commerces,
}));
const parType: Record<string, number> = {};
const parCategorie: Record<string, number> = {};
for (const c of commerces) {
  parType[c.type] = (parType[c.type] ?? 0) + 1;
  if (c.categorie) parCategorie[c.categorie] = (parCategorie[c.categorie] ?? 0) + 1;
}
console.log(`${commerces.length} commerces → data/commerces-niamey.json`);
console.log('par type', parType);
console.log('par catégorie', parCategorie);
console.log('bilan', bilan);
console.log(`avec téléphone : ${commerces.filter((c) => c.telephone).length}`);
