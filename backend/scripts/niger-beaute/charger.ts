/**
 * NIGER BEAUTÉ (17/10) — met la boutique et son catalogue dans Tovo, à partir
 * du dossier préparé sur le PC : inventaire, images validées par le client,
 * prix relevés pendant la visite.
 *
 *   npx tsx --env-file=.env scripts/niger-beaute/charger.ts                 à blanc : lit, vérifie, n'écrit rien
 *   npx tsx --env-file=.env scripts/niger-beaute/charger.ts --appliquer     écrit
 *   ... --boutique-seule   la fiche, la couverture et les horaires, sans les produits
 *   ... [dossier]   par défaut C:\Users\abdal\Documents\niger beaute catalogue
 *
 * Le dossier contient :
 *   inventaire.csv    les 1 013 articles (nom, marque, catégorie, description…)
 *   visite.json       ce que la visite a saisi : prix, « pas en boutique », corrections, ajouts
 *   images\NB-xxx.jpg l'image catalogue validée, fond blanc 1200 × 1200
 *   boutique.json     la fiche de la boutique (téléphone, position, horaires)
 *
 * Un article est CHARGÉ s'il a un prix ; ÉCARTÉ si la visite l'a marqué
 * « pas en boutique » ; EN ATTENTE sinon. On peut donc lancer le chargement
 * au milieu de la visite et le relancer à la fin : le script est reprenable
 * par construction (`legacy_id` « niger-beaute:NB-xxx »), il met à jour ce qui
 * existe et ne crée jamais de doublon.
 *
 * L'inventaire n'est jamais modifié. La recherche (embeddings) n'est pas faite
 * ici : l'indexeur du serveur s'en charge, ou scripts/etl/indexAll.ts pour
 * tout faire d'un coup.
 */
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';

const args = process.argv.slice(2);
const appliquer = args.includes('--appliquer');
const DOSSIER = args.find((a) => !a.startsWith('--')) ?? 'C:\\Users\\abdal\\Documents\\niger beaute catalogue';
const CLE_BOUTIQUE = 'niger-beaute';
const BUCKET = 'products';
// Même rendu que scripts/convertirLesImages.ts : WebP 1000 px, qualité 82.
const COTE_MAX = 1000;
const QUALITE = 82;

const url = process.env.SUPABASE_URL;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !service) throw new Error('SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY absent : lancez avec --env-file=.env');
const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

// --- Lecture du dossier --------------------------------------------------------

/** CSV point-virgule, champs entre guillemets (même lecteur que la visite). */
function lireCsv(texte: string): Record<string, string>[] {
  const lignes: string[][] = [];
  let ligne: string[] = [], champ = '', guillemets = false;
  texte = texte.replace(/^\uFEFF/, '');
  for (let i = 0; i < texte.length; i++) {
    const c = texte[i];
    if (guillemets) {
      if (c === '"') { if (texte[i + 1] === '"') { champ += '"'; i++; } else guillemets = false; } else champ += c;
    } else if (c === '"') guillemets = true;
    else if (c === ';') { ligne.push(champ); champ = ''; }
    else if (c === '\n') { ligne.push(champ.replace(/\r$/, '')); lignes.push(ligne); ligne = []; champ = ''; }
    else champ += c;
  }
  if (champ || ligne.length) { ligne.push(champ); lignes.push(ligne); }
  const [entete, ...reste] = lignes.filter((l) => l.length > 1);
  return reste.map((l) => Object.fromEntries(entete.map((k, i) => [k.trim(), (l[i] ?? '').trim()])));
}

type Article = Record<string, string> & { id: string };

const inventaire = lireCsv(readFileSync(join(DOSSIER, 'inventaire.csv'), 'utf8')) as Article[];
const visite = existsSync(join(DOSSIER, 'visite.json'))
  ? JSON.parse(readFileSync(join(DOSSIER, 'visite.json'), 'utf8')) as { articles: Record<string, Record<string, string>>; ajouts: Article[] }
  : { articles: {}, ajouts: [] };
const fiche = JSON.parse(readFileSync(join(DOSSIER, 'boutique.json'), 'utf8'));

// La visite l'emporte sur l'inventaire, champ par champ — comme son export.
const articles: Article[] = [
  ...inventaire.map((a) => ({ ...a, ...(visite.articles[a.id] ?? {}) }) as Article),
  ...visite.ajouts.map((a) => ({ ...a, ajout: 'oui' }) as Article),
];

/** « 2 500 », « 2500 F » → 2500 ; rien de lisible → null. */
function prixDe(a: Article): number | null {
  const n = Number(String(a.prix ?? '').replace(/[^\d]/g, ''));
  return Number.isInteger(n) && n > 0 ? n : null;
}

const aCharger = articles.filter((a) => a.statut !== 'absent' && prixDe(a) !== null);
const ecartes = articles.filter((a) => a.statut === 'absent');
const enAttente = articles.filter((a) => a.statut !== 'absent' && prixDe(a) === null);
const imageDe = (a: Article): string | null => {
  const f = join(DOSSIER, 'images', `${a.id}.jpg`);
  return existsSync(f) ? f : null;
};

// --- Catégories ------------------------------------------------------------------
// Les rayons « Beauté & soins » existants de Tovo (ceux de Vella Beauty). La
// sous-catégorie fine de l'inventaire part dans les étiquettes : elle aide la
// recherche sans multiplier les rayons à l'accueil.

const RAYONS: Array<[string, string[]]> = [
  ['parfum-c197', ['Eaux de parfum', 'Eaux de Cologne et de toilette', 'Parfums de poche', 'Coffrets parfum',
    "Brumes et parfums d'ambiance"]],
  ['soins-de-cheveux-c175', ['Shampooings', 'Après-shampooings', 'Pommades capillaires', 'Huiles et soins capillaires',
    'Défrisants et colorations']],
  ['soins-du-corps-c176', ['Laits et lotions corporels', 'Gels douche', 'Savons', 'Déodorants', 'Crèmes et baumes corporels',
    'Huiles corporelles', 'Gommages corporels', 'Protection solaire']],
];
const RAYON_PAR_DEFAUT = 'beaute-et-hygiene-c69';
const rayonDe = (a: Article): string => RAYONS.find(([, sous]) => sous.includes(a.sous_categorie))?.[0] ?? RAYON_PAR_DEFAUT;

function etiquettes(a: Article): string[] {
  const brutes = [a.sous_categorie, a.marque, a.gamme, ...(a.mots_cles ?? '').split(',')];
  return [...new Set(brutes.map((x) => (x ?? '').trim().toLowerCase()).filter((x) => x.length > 1))].slice(0, 12);
}

// --- Petits outils ------------------------------------------------------------------

function telephone(brut: string | undefined): string | null {
  const chiffres = String(brut ?? '').replace(/[^\d]/g, '');
  if (chiffres.length === 8) return `+227${chiffres}`;
  if (chiffres.startsWith('227') && chiffres.length === 11) return `+${chiffres}`;
  return null;
}

async function verifier<R extends { data: unknown; error: { message: string } | null }>(promesse: PromiseLike<R>, quoi: string): Promise<R['data']> {
  const { data, error } = await promesse;
  if (error) throw new Error(`${quoi} : ${error.message}`);
  return data;
}

async function enWebp(source: Buffer | string): Promise<Buffer> {
  return sharp(source)
    .resize({ width: COTE_MAX, height: COTE_MAX, fit: 'inside', withoutEnlargement: true })
    .webp({ quality: QUALITE })
    .toBuffer();
}

/** Trois essais espacés : une coupure réseau d'une seconde (vécue le 17/10 au 1er
 * chargement) ne doit pas arrêter un envoi de plusieurs centaines d'images. */
async function televerser(chemin: string, contenu: Buffer): Promise<string> {
  for (let essai = 1; ; essai++) {
    try {
      await verifier(db.storage.from(BUCKET).upload(chemin, contenu, { contentType: 'image/webp', upsert: true }), `image ${chemin}`);
      return db.storage.from(BUCKET).getPublicUrl(chemin).data.publicUrl;
    } catch (cause) {
      if (essai >= 3) throw cause;
      await new Promise((ok) => setTimeout(ok, 5000 * essai));
    }
  }
}

const JOURS: Record<string, number> = { dimanche: 0, lundi: 1, mardi: 2, mercredi: 3, jeudi: 4, vendredi: 5, samedi: 6 };
function horaires(): Array<{ day: number; opens_at: string; closes_at: string }> {
  const sortie = [];
  for (const [jour, valeur] of Object.entries(fiche.horaires ?? {})) {
    if (!(jour in JOURS) || typeof valeur !== 'string' || !valeur.trim()) continue;
    for (const plage of valeur.split(',')) {
      const m = plage.trim().match(/^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})$/);
      if (!m) throw new Error(`boutique.json : horaire illisible pour ${jour} (« ${plage} ») — attendu 09:00-21:00`);
      sortie.push({ day: JOURS[jour], opens_at: `${m[1].padStart(2, '0')}:${m[2]}`, closes_at: `${m[3].padStart(2, '0')}:${m[4]}` });
    }
  }
  return sortie;
}

// --- Bilan avant écriture -------------------------------------------------------------

const sansImage = aCharger.filter((a) => !imageDe(a));
const proprietaire = telephone(fiche.telephone_proprietaire);
const plages = horaires();

console.log(`Niger Beauté — ${articles.length} articles (${visite.ajouts.length} ajoutés pendant la visite)`);
console.log(`  à charger (prix connu)     ${aCharger.length}${sansImage.length ? `, dont ${sansImage.length} sans image` : ''}`);
console.log(`  pas en boutique (écartés)  ${ecartes.length}`);
console.log(`  en attente (sans prix)     ${enAttente.length}`);
const parRayon = new Map<string, number>();
for (const a of aCharger) parRayon.set(rayonDe(a), (parRayon.get(rayonDe(a)) ?? 0) + 1);
for (const [r, n] of parRayon) console.log(`    rayon ${r.padEnd(24)} ${n}`);
console.log(`  propriétaire               ${proprietaire ?? 'NON RENSEIGNÉ (boutique.json : telephone_proprietaire)'}`);
console.log(`  horaires                   ${plages.length ? `${plages.length} plages` : 'aucun (seul l\'interrupteur de l\'app comptera)'}`);
if (sansImage.length) console.log(`  sans image : ${sansImage.map((a) => a.id).join(' ')}`);

// Lecture de l'existant (sans écrire) : ce qui serait créé ou mis à jour.
const categories = (await verifier(db.from('categories').select('id, slug'), 'catégories')) ?? [];
const categorie = (slug: string): string => {
  const id = categories.find((c) => c.slug === slug)?.id;
  if (!id) throw new Error(`catégorie « ${slug} » absente de la base`);
  return id;
};
// Vérifié dès l'essai à blanc : un rayon renommé dans la base doit arrêter
// AVANT la première écriture, pas au 400e produit.
for (const slug of ['beaute-soins', RAYON_PAR_DEFAUT, ...RAYONS.map(([r]) => r)]) categorie(slug);
const boutiqueExistante = await verifier(
  db.from('merchants').select('id, owner_id, logo_url, cover_url').eq('legacy_id', CLE_BOUTIQUE).maybeSingle(), 'boutique');
const existants = new Map<string, { id: string; image_url: string | null; is_available: boolean }>();
if (boutiqueExistante) {
  for (let depuis = 0; ; depuis += 1000) {
    const lot = await verifier(db.from('products').select('id, legacy_id, image_url, is_available')
      .eq('merchant_id', boutiqueExistante.id).range(depuis, depuis + 999), 'produits existants') ?? [];
    for (const p of lot) existants.set(p.legacy_id as string, p as { id: string; image_url: string | null; is_available: boolean });
    if (lot.length < 1000) break;
  }
}
const nouveaux = aCharger.filter((a) => !existants.has(`${CLE_BOUTIQUE}:${a.id}`)).length;
console.log(`  base Tovo : boutique ${boutiqueExistante ? 'déjà créée' : 'à créer'} ; ${nouveaux} produits à créer, ${aCharger.length - nouveaux} à mettre à jour`);

if (!appliquer) {
  console.log('\nÀ blanc : rien écrit. Relancez avec --appliquer.');
  process.exit(0);
}
if (!proprietaire) throw new Error('boutique.json : telephone_proprietaire manquant ou illisible (8 chiffres).');

// --- 1. Le propriétaire --------------------------------------------------------------
// Son compte se connecte par téléphone, comme tous les boutiquiers. S'il en a
// déjà un (client Tovo par exemple), on le reprend et on le passe boutiquier.

async function compteProprietaire(): Promise<string> {
  const sansPlus = proprietaire!.slice(1);
  const profil = await verifier(db.from('profiles').select('id').eq('phone', sansPlus).maybeSingle(), 'profil');
  let id = profil?.id as string | undefined;
  if (!id) {
    const cree = await verifier(db.auth.admin.createUser({
      phone: proprietaire!, phone_confirm: true, user_metadata: { full_name: fiche.nom },
    }), 'création du compte propriétaire');
    id = cree.user!.id;
  }
  await verifier(db.from('profiles').update({ role: 'merchant' }).eq('id', id), 'rôle boutiquier');
  return id;
}

// --- 2. La boutique ----------------------------------------------------------------------

const zone = await verifier(db.rpc('zone_for_point', { p_lat: fiche.lat, p_lng: fiche.lng }), 'zone');
const zoneId = (Array.isArray(zone) ? zone[0]?.id : (zone as { id?: string } | null)?.id) ?? null;
if (!zoneId) console.log('⚠ position hors de toute zone de livraison : boutique créée sans zone');

const champsBoutique = {
  name: fiche.nom,
  description: fiche.description || null,
  phone: telephone(fiche.telephone_public),
  address_hint: fiche.repere ?? '',
  location: `SRID=4326;POINT(${fiche.lng} ${fiche.lat})`,
  zone_id: zoneId,
  category_id: categorie('beaute-soins'),
  prep_time_min: Number(fiche.delai_preparation_min) || 15,
};

let boutiqueId: string;
if (boutiqueExistante) {
  boutiqueId = boutiqueExistante.id;
  await verifier(db.from('merchants').update(champsBoutique).eq('id', boutiqueId), 'mise à jour boutique');
  console.log('✓ boutique mise à jour');
} else {
  boutiqueId = crypto.randomUUID();
  await verifier(db.from('merchants').insert({
    id: boutiqueId, legacy_id: CLE_BOUTIQUE, owner_id: await compteProprietaire(), ...champsBoutique,
    // Approuvée : le fondateur l'a choisie. Fermée : c'est le boutiquier qui
    // ouvre depuis son app, quand quelqu'un surveille les commandes.
    is_approved: true, is_open: false,
  }), 'création boutique');
  console.log('✓ boutique créée (fermée : le commerçant l\'ouvre depuis son app)');
}

// Logo et couverture : fichiers du dossier s'ils sont fournis (renvoyés à
// chaque passage, pour qu'un changement d'image soit pris), sinon la photo
// du relevé terrain, une seule fois.
if (fiche.logo && existsSync(join(DOSSIER, fiche.logo))) {
  const contenu = fiche.logo.toLowerCase().endsWith('.webp')
    ? readFileSync(join(DOSSIER, fiche.logo))
    : await enWebp(join(DOSSIER, fiche.logo));
  const logo = await televerser(`${boutiqueId}/logo.webp`, contenu);
  await verifier(db.from('merchants').update({ logo_url: `${logo}?v=${Date.now()}` }).eq('id', boutiqueId), 'logo');
  console.log('✓ logo envoyé');
}
if (fiche.couverture && existsSync(join(DOSSIER, fiche.couverture))) {
  // Un WebP déjà préparé part tel quel : le recompresser ne ferait que le
  // dégrader. Sinon, 1600 px (une couverture prend toute la largeur).
  const contenu = fiche.couverture.toLowerCase().endsWith('.webp')
    ? readFileSync(join(DOSSIER, fiche.couverture))
    : await sharp(join(DOSSIER, fiche.couverture))
      .resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true }).webp({ quality: QUALITE }).toBuffer();
  const cover = await televerser(`${boutiqueId}/cover.webp`, contenu);
  // Le fichier garde le même nom : la date dans l'URL force les téléphones à
  // recharger l'image au lieu de montrer l'ancienne gardée en cache.
  await verifier(db.from('merchants').update({ cover_url: `${cover}?v=${Date.now()}` }).eq('id', boutiqueId), 'couverture');
  console.log('✓ couverture envoyée');
} else if (fiche.couverture_terrain && !boutiqueExistante?.cover_url) {
  const { data } = await db.storage.from('terrain').download(fiche.couverture_terrain);
  if (data) {
    const cover = await televerser(`${boutiqueId}/cover.webp`, await enWebp(Buffer.from(await data.arrayBuffer())));
    await verifier(db.from('merchants').update({ cover_url: cover }).eq('id', boutiqueId), 'couverture');
  }
}

if (plages.length) {
  await verifier(db.from('merchant_hours').delete().eq('merchant_id', boutiqueId), 'anciens horaires');
  await verifier(db.from('merchant_hours').insert(plages.map((p) => ({ merchant_id: boutiqueId, ...p }))), 'horaires');
  console.log(`✓ ${plages.length} plages horaires`);
}

if (args.includes('--boutique-seule')) {
  console.log('Boutique seule : produits non touchés.');
  process.exit(0);
}

// --- 3. Les produits ----------------------------------------------------------------------
// Ordre : la ligne, PUIS l'image, PUIS l'URL. Une coupure entre deux laisse
// un produit sans photo, que la relance complète — jamais une URL vers un
// fichier absent.

let crees = 0, majs = 0, images = 0, retires = 0;
for (const [i, a] of aCharger.entries()) {
  const legacy = `${CLE_BOUTIQUE}:${a.id}`;
  const champs = {
    name: a.nom,
    description: a.description || null,
    price: prixDe(a)!,
    category_id: categorie(rayonDe(a)),
    tags: etiquettes(a),
    is_available: true,
  };
  let produit = existants.get(legacy);
  if (produit) {
    await verifier(db.from('products').update(champs).eq('id', produit.id), `produit ${a.id}`);
    majs++;
  } else {
    const id = crypto.randomUUID();
    await verifier(db.from('products').insert({ id, merchant_id: boutiqueId, legacy_id: legacy, ...champs }), `produit ${a.id}`);
    produit = { id, image_url: null, is_available: true };
    crees++;
  }
  const fichier = imageDe(a);
  if (fichier && (!produit.image_url || args.includes('--images'))) {
    const image = await televerser(`${boutiqueId}/${produit.id}/${a.id}.webp`, await enWebp(fichier));
    await verifier(db.from('products').update({ image_url: image }).eq('id', produit.id), `image ${a.id}`);
    images++;
  }
  process.stdout.write(`\r  produits ${i + 1}/${aCharger.length}`);
}
console.log();

// Un article chargé puis déclaré absent à la visite disparaît de la vitrine,
// sans effacer son historique de commandes.
for (const a of ecartes) {
  const p = existants.get(`${CLE_BOUTIQUE}:${a.id}`);
  if (p?.is_available) {
    await verifier(db.from('products').update({ is_available: false }).eq('id', p.id), `retrait ${a.id}`);
    retires++;
  }
}

console.log(`✓ ${crees} produits créés, ${majs} mis à jour, ${images} images envoyées, ${retires} retirés de la vente`);
console.log('Recherche : l\'indexeur du serveur les rend trouvables peu à peu ; pour tout faire d\'un coup :');
console.log('  npx tsx --env-file=.env scripts/etl/indexAll.ts');
