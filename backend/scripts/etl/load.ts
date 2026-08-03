import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { parseDump, type Row } from './dumpParser.js';
import {
  delaiPreparation,
  nomComplet,
  normaliserTelephone,
  polygoneEstPlausible,
  polygoneVersWkt,
  slug,
  stockUtile,
  transformerOptions,
  transformerVariantes,
  versXof,
  type OptionTransformee,
} from './transform.js';

/**
 * Chargement des données 6ammart dans Tovo.
 *
 * Deux principes gouvernent ce fichier.
 *
 * REPRENABLE. Sur 2 300 comptes et 2 000 produits, une coupure réseau est
 * certaine. Chaque objet porte son identifiant d'origine (`legacy_id`) ;
 * relancer le script saute ce qui est déjà là au lieu de créer des doublons.
 *
 * À BLANC PAR DÉFAUT. Sans `--apply`, rien n'est écrit : le script affiche ce
 * qu'il ferait et signale ce qu'il refuserait de faire. On lit ce rapport
 * avant d'écrire quoi que ce soit dans une base.
 *
 *   npx tsx scripts/etl/load.ts <dump.sql> --images <dossier>
 *   npx tsx scripts/etl/load.ts <dump.sql> --images <dossier> --apply
 *   npx tsx scripts/etl/load.ts <dump.sql> --images <dossier> --apply --only produits
 */

// ---------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------

const argv = process.argv.slice(2);
const option = (nom: string): string | null => {
  const i = argv.indexOf(nom);
  return i >= 0 ? (argv[i + 1] ?? null) : null;
};

const chemin = argv[0];
const dossierImages = option('--images');
const appliquer = argv.includes('--apply');
const seulement = option('--only')?.split(',').map((s) => s.trim());

if (!chemin || chemin.startsWith('--')) {
  console.error(
    'Usage : tsx scripts/etl/load.ts <dump.sql> --images <dossier> [--apply] [--only etape1,etape2]',
  );
  process.exit(1);
}

const ETAPES = ['zones', 'categories', 'comptes', 'boutiques', 'produits', 'livreurs', 'clients'] as const;
type Etape = (typeof ETAPES)[number];

const active = (e: Etape): boolean => !seulement || seulement.includes(e);

// ---------------------------------------------------------------------
// Connexion
// ---------------------------------------------------------------------

const URL_SUPABASE = process.env['SUPABASE_URL'];
const CLE_SERVICE = process.env['SUPABASE_SERVICE_ROLE_KEY'];

if (appliquer && (!URL_SUPABASE || !CLE_SERVICE)) {
  console.error('SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont requis avec --apply.');
  process.exit(1);
}

// La clé de service ignore la RLS : c'est voulu ici, et seulement ici.
const db: SupabaseClient | null =
  URL_SUPABASE && CLE_SERVICE
    ? createClient(URL_SUPABASE, CLE_SERVICE, {
        auth: { persistSession: false, autoRefreshToken: false },
      })
    : null;

// ---------------------------------------------------------------------
// Journal
// ---------------------------------------------------------------------

const bilans = new Map<string, { cree: number; existant: number; ignore: number }>();
const alertes: { type: string; detail: string }[] = [];

function noter(etape: string, quoi: 'cree' | 'existant' | 'ignore'): void {
  const b = bilans.get(etape) ?? { cree: 0, existant: 0, ignore: 0 };
  b[quoi]++;
  bilans.set(etape, b);
}

const images = { trouvees: 0, manquantes: 0 };

/** Le type regroupe : sans lui, 27 collisions de numéros font 27 rubriques. */
function alerter(type: string, detail: string): void {
  alertes.push({ type, detail });
}

/** Interrompt : continuer sur une base à moitié chargée ferait pire. */
function fatal(message: string, erreur: unknown): never {
  console.error(`\n✗ ${message}`);
  console.error(erreur instanceof Error ? erreur.message : String(erreur));
  process.exit(1);
}

// ---------------------------------------------------------------------
// Lecture du dump
// ---------------------------------------------------------------------

const { tables } = await parseDump(
  chemin,
  new Set([
    'zones', 'modules', 'categories', 'vendors', 'stores',
    'items', 'users', 'delivery_men', 'storages',
  ]),
);

const t = (nom: string): Row[] => tables.get(nom) ?? [];

console.log(`\nMode : ${appliquer ? 'ÉCRITURE RÉELLE' : 'à blanc (aucune écriture)'}`);
if (seulement) console.log(`Étapes : ${seulement.join(', ')}`);
console.log('');

// ---------------------------------------------------------------------
// Correspondances entre identifiants d'origine et identifiants Tovo
// ---------------------------------------------------------------------

/** legacy_id 6ammart → uuid Tovo, rechargé au démarrage pour la reprise. */
const zonesTovo = new Map<string, string>();
const categoriesTovo = new Map<string, string>(); // clé : « module:3 » ou « cat:57 »
const profilsTovo = new Map<string, string>(); // clé : « vendor:12 », « user:8 », « dm:3 »
const boutiquesTovo = new Map<string, string>();
const produitsTovo = new Map<string, string>();
/** Téléphone déjà pris, avec le rôle qui l'a pris — voir les collisions. */
const telephonesPris = new Map<string, string>();

/** Relit une table entière malgré la limite de 1 000 lignes de PostgREST. */
async function relire(
  table: string,
  colonnes: string,
  dans: Map<string, string>,
  cle: (r: Record<string, string>) => string | null,
): Promise<void> {
  if (!db) return;
  const PAGE = 1000;
  for (let debut = 0; ; debut += PAGE) {
    const { data, error } = await db
      .from(table)
      .select(colonnes)
      .not('legacy_id', 'is', null)
      .range(debut, debut + PAGE - 1);
    if (error) fatal(`relecture de ${table}`, error);

    const lignes = (data ?? []) as unknown as Record<string, string>[];
    for (const r of lignes) {
      const k = cle(r);
      if (k && r['id']) dans.set(k, r['id']);
    }
    if (lignes.length < PAGE) break;
  }
}

if (db) {
  await relire('delivery_zones', 'id, legacy_id', zonesTovo, (r) => r['legacy_id'] ?? null);
  await relire('categories', 'id, legacy_id', categoriesTovo, (r) => r['legacy_id'] ?? null);
  await relire('merchants', 'id, legacy_id', boutiquesTovo, (r) => r['legacy_id'] ?? null);
  await relire('products', 'id, legacy_id', produitsTovo, (r) => r['legacy_id'] ?? null);
  await relire('profiles', 'id, legacy_id, phone', profilsTovo, (r) => r['legacy_id'] ?? null);

  // Les téléphones déjà attribués, pour détecter les collisions avant de
  // demander à l'auth de créer un compte qui échouerait.
  for (let debut = 0; ; debut += 1000) {
    const { data, error } = await db
      .from('profiles')
      .select('phone, role')
      .not('phone', 'is', null)
      .range(debut, debut + 999);
    if (error) fatal('relecture des téléphones', error);
    // Supabase Auth enregistre le numéro sans « + » : la base contient
    // « 22790626927 » là où le dump donne « +22790626927 ». Comparer les deux
    // formes ne correspond jamais, et les collisions passent le contrôle pour
    // n'être refusées qu'au moment de la création — le compte n'est pas créé
    // en double, mais le rapport annonce une panne d'authentification là où
    // il devrait annoncer un doublon attendu.
    const lignes = (data ?? []) as unknown as { phone: string; role: string }[];
    for (const r of lignes) telephonesPris.set(`+${r.phone.replace(/^\+/, '')}`, r.role);
    if (lignes.length < 1000) break;
  }

  const deja =
    zonesTovo.size + categoriesTovo.size + boutiquesTovo.size + produitsTovo.size + profilsTovo.size;
  if (deja > 0) console.log(`Reprise : ${deja} objets déjà migrés seront sautés.\n`);
}

// ---------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------

/**
 * Téléverse une image téléchargée de l'ancienne app.
 *
 * `fetchImages.ts` a réparti les fichiers entre `s3/` et `serveur/` selon
 * leur emplacement d'origine ; on essaie les deux plutôt que de refaire ce
 * calcul. Une image manquante n'est pas bloquante : 91 fichiers étaient déjà
 * absents chez 6ammart, la boutique fonctionne sans sa photo.
 */
async function televerser(
  bucket: string,
  prefixe: string,
  sousDossier: string,
  fichier: string | null,
): Promise<string | null> {
  if (!fichier || fichier === 'NULL' || !dossierImages) return null;

  const chemin = `${prefixe}/${fichier}`;

  let contenu: Buffer | null = null;
  for (const racine of ['s3', 'serveur']) {
    try {
      contenu = await readFile(join(dossierImages, racine, sousDossier, fichier));
      break;
    } catch {
      /* essayer l'autre emplacement */
    }
  }

  // Compté même à blanc : c'est la seule façon de savoir avant d'écrire
  // combien de produits arriveront sans photo. 6ammart en référence
  // plusieurs dizaines dont le fichier a été supprimé sans nettoyer la base.
  images[contenu ? 'trouvees' : 'manquantes']++;
  if (!contenu) {
    if (images.manquantes <= 200) alerter('image absente du disque', `${sousDossier}/${fichier}`);
    return null;
  }

  if (!appliquer || !db) return `(${bucket}/${chemin})`;

  const type = fichier.toLowerCase().endsWith('.png')
    ? 'image/png'
    : fichier.toLowerCase().endsWith('.webp')
      ? 'image/webp'
      : 'image/jpeg';

  const { error } = await db.storage
    .from(bucket)
    .upload(chemin, contenu, { contentType: type, upsert: true });
  if (error) {
    alerter('image non téléversée', `${chemin} — ${error.message}`);
    return null;
  }

  return db.storage.from(bucket).getPublicUrl(chemin).data.publicUrl;
}

// ---------------------------------------------------------------------
// 1. Zones
// ---------------------------------------------------------------------

if (active('zones')) {
  console.log('── Zones ──');

  for (const z of t('zones')) {
    if (!z.id) continue;
    if (zonesTovo.has(z.id)) {
      noter('zones', 'existant');
      continue;
    }

    const wkt = polygoneVersWkt(z.coordinates ?? '');

    // Les zones de démonstration livrées avec 6ammart sont en Inde. Les
    // reprendre créerait des zones de livraison où Tovo n'opère pas, et le
    // calcul de frais y affecterait de vraies commandes.
    if (!wkt || !polygoneEstPlausible(wkt)) {
      alerter('zone hors Niger ou illisible', String(z.name));
      noter('zones', 'ignore');
      continue;
    }
    if (z.status !== '1') {
      alerter('zone désactivée chez 6ammart', String(z.name));
      noter('zones', 'ignore');
      continue;
    }

    console.log(`  + ${z.name}`);
    if (appliquer && db) {
      const { data, error } = await db
        .from('delivery_zones')
        .insert({ name: z.name, area: wkt, legacy_id: z.id, is_active: true })
        .select('id')
        .single();
      if (error) fatal(`zone ${z.name}`, error);
      zonesTovo.set(z.id, (data as { id: string }).id);
    } else {
      zonesTovo.set(z.id, `(zone:${z.id})`);
    }
    noter('zones', 'cree');
  }
}

// ---------------------------------------------------------------------
// 2. Catégories
// ---------------------------------------------------------------------

/**
 * 6ammart sépare « modules » (Restaurants, Boutiques, Grocery…) et
 * « categories » (Pizzas, Boissons…), sans lien de parenté explicite entre
 * les deux — la catégorie porte seulement le numéro de son module. Tovo n'a
 * qu'un arbre : les modules deviennent les catégories racines, les catégories
 * 6ammart leurs enfants. La navigation de l'app y gagne un niveau cohérent.
 */
if (active('categories')) {
  console.log('\n── Catégories ──');

  const DEMO = /^demo\b/i;

  for (const m of t('modules')) {
    if (!m.id || DEMO.test(m.module_name ?? '')) continue;
    const cle = `module:${m.id}`;
    if (categoriesTovo.has(cle)) {
      noter('categories', 'existant');
      continue;
    }

    console.log(`  + [racine] ${m.module_name}`);
    if (appliquer && db) {
      const { data, error } = await db
        .from('categories')
        .insert({
          name: m.module_name,
          slug: slug(m.module_name ?? '', `m${m.id}`),
          sort_order: Number(m.id),
          legacy_id: cle,
        })
        .select('id')
        .single();
      if (error) fatal(`module ${m.module_name}`, error);
      categoriesTovo.set(cle, (data as { id: string }).id);
    } else {
      categoriesTovo.set(cle, `(cat:${cle})`);
    }
    noter('categories', 'cree');
  }

  for (const c of t('categories')) {
    if (!c.id || DEMO.test(c.name ?? '')) continue;
    const cle = `cat:${c.id}`;
    if (categoriesTovo.has(cle)) {
      noter('categories', 'existant');
      continue;
    }

    const parent = categoriesTovo.get(`module:${c.module_id}`) ?? null;
    const image = await televerser('catalog', `categories/${c.id}`, 'category', c.image);

    if (appliquer && db) {
      const { data, error } = await db
        .from('categories')
        .insert({
          parent_id: parent && !parent.startsWith('(') ? parent : null,
          name: c.name,
          slug: slug(c.name ?? '', `c${c.id}`),
          image_url: image,
          sort_order: Number(c.position ?? 0),
          is_active: c.status === '1',
          legacy_id: cle,
        })
        .select('id')
        .single();
      if (error) fatal(`catégorie ${c.name}`, error);
      categoriesTovo.set(cle, (data as { id: string }).id);
    } else {
      categoriesTovo.set(cle, `(cat:${cle})`);
    }
    noter('categories', 'cree');
  }
}

// ---------------------------------------------------------------------
// Comptes
// ---------------------------------------------------------------------

/**
 * Crée un compte authentifiable et son profil.
 *
 * Tovo authentifie par téléphone : c'est le numéro, pas le mot de passe, qui
 * fait le compte. Les empreintes bcrypt de 6ammart ne sont donc pas reprises
 * — il n'y a rien à reprendre, l'utilisateur recevra un code par WhatsApp.
 *
 * `phone_confirm` est posé à vrai : ces numéros ont déjà servi en production,
 * exiger une nouvelle validation avant le premier code n'apporterait rien.
 */
async function creerCompte(
  etape: string,
  cleLegacy: string,
  telephone: string,
  nom: string,
  role: 'client' | 'merchant' | 'driver',
): Promise<string | null> {
  if (profilsTovo.has(cleLegacy)) {
    noter(etape, 'existant');
    return profilsTovo.get(cleLegacy) ?? null;
  }

  // Un numéro ne peut désigner qu'une personne. Quand le boutiquier a aussi
  // commandé comme client, son compte professionnel l'emporte : sans lui il
  // ne peut plus tenir sa boutique, alors qu'il peut recommander depuis le
  // même numéro. Le rattachement se fait plus loin, sur l'id d'origine.
  const dejaPris = telephonesPris.get(telephone);
  if (dejaPris) {
    alerter(`numéro déjà pris par un compte ${dejaPris}`, `${telephone} — ${nom} (${cleLegacy})`);
    noter(etape, 'ignore');
    return null;
  }

  if (!appliquer || !db) {
    telephonesPris.set(telephone, role);
    profilsTovo.set(cleLegacy, `(profil:${cleLegacy})`);
    noter(etape, 'cree');
    return null;
  }

  const { data, error } = await db.auth.admin.createUser({
    phone: telephone,
    phone_confirm: true,
    user_metadata: { full_name: nom },
  });
  if (error || !data.user) {
    alerter('compte refusé par l’auth', `${telephone} (${cleLegacy}) — ${error?.message ?? 'inconnu'}`);
    noter(etape, 'ignore');
    return null;
  }

  // Le trigger handle_new_user a créé le profil avec le rôle « client » : il
  // ne lit jamais les métadonnées, sans quoi n'importe qui se déclarerait
  // admin à l'inscription. On corrige ici, avec la clé de service.
  const { error: erreurProfil } = await db
    .from('profiles')
    .update({ role, full_name: nom, legacy_id: cleLegacy })
    .eq('id', data.user.id);
  if (erreurProfil) fatal(`profil de ${telephone}`, erreurProfil);

  telephonesPris.set(telephone, role);
  profilsTovo.set(cleLegacy, data.user.id);
  noter(etape, 'cree');
  return data.user.id;
}

// ---------------------------------------------------------------------
// 3. Vendeurs
// ---------------------------------------------------------------------

if (active('comptes')) {
  console.log('\n── Comptes boutiquiers ──');

  for (const v of t('vendors')) {
    if (!v.id) continue;
    const tel = normaliserTelephone(v.phone);
    if (!tel) {
      alerter('vendeur sans numéro exploitable', `${nomComplet(v.f_name, v.l_name)} (${v.id})`);
      noter('comptes', 'ignore');
      continue;
    }
    const nom = nomComplet(v.f_name, v.l_name) || `Boutique ${v.id}`;
    await creerCompte('comptes', `vendor:${v.id}`, tel, nom, 'merchant');
  }
}

// ---------------------------------------------------------------------
// 4. Boutiques
// ---------------------------------------------------------------------

/** Propriétaire d'une boutique, en retombant sur le vendeur qui partage son numéro. */
function proprietaire(v: Row | undefined): string | null {
  if (!v?.id) return null;
  const direct = profilsTovo.get(`vendor:${v.id}`);
  if (direct) return direct;

  // Trois vendeurs 6ammart partagent un numéro avec un autre : c'est le même
  // propriétaire avec deux boutiques, cas que le schéma prévoit.
  const tel = normaliserTelephone(v.phone);
  if (!tel) return null;
  for (const autre of t('vendors')) {
    if (autre.id !== v.id && normaliserTelephone(autre.phone) === tel) {
      const id = profilsTovo.get(`vendor:${autre.id}`);
      if (id) return id;
    }
  }
  return null;
}

/**
 * Complète les images d'une boutique déjà migrée.
 *
 * Sert quand une image n'était pas encore téléchargée au moment du premier
 * chargement — c'est arrivé pour les 80 photos de couverture, cherchées dans
 * `store/` au lieu de `store/cover/`. Ne touche à rien si la boutique est
 * complète : on ne réécrit pas une URL déjà bonne.
 */
async function completerImagesBoutique(id: string, s: Row): Promise<void> {
  if (!appliquer || !db) return;

  const { data, error } = await db
    .from('merchants')
    .select('logo_url, cover_url')
    .eq('id', id)
    .single();
  if (error) fatal(`relecture de la boutique ${s.name}`, error);

  const actuel = data as { logo_url: string | null; cover_url: string | null };
  const correctif: Record<string, string> = {};

  if (!actuel.logo_url) {
    const url = await televerser('products', `${id}/logo`, 'store', s.logo);
    if (url) correctif['logo_url'] = url;
  }
  if (!actuel.cover_url) {
    const url = await televerser('products', `${id}/cover`, 'store/cover', s.cover_photo);
    if (url) correctif['cover_url'] = url;
  }
  if (Object.keys(correctif).length === 0) return;

  const { error: erreurMaj } = await db.from('merchants').update(correctif).eq('id', id);
  if (erreurMaj) fatal(`complément d'images pour ${s.name}`, erreurMaj);
  noter('images boutiques rattrapées', 'cree');
}

if (active('boutiques')) {
  console.log('\n── Boutiques ──');

  const vendeurs = new Map(t('vendors').map((v) => [v.id ?? '', v]));

  for (const s of t('stores')) {
    if (!s.id) continue;
    const dejaMigree = boutiquesTovo.get(s.id);
    if (dejaMigree) {
      // Déjà là, mais peut-être incomplète : une image absente lors d'un
      // passage précédent doit pouvoir être rattrapée sans tout recharger.
      await completerImagesBoutique(dejaMigree, s);
      noter('boutiques', 'existant');
      continue;
    }

    const zone = zonesTovo.get(s.zone_id ?? '');
    if (!zone) {
      alerter('boutique en zone non migrée', String(s.name));
      noter('boutiques', 'ignore');
      continue;
    }

    const owner = proprietaire(vendeurs.get(s.vendor_id ?? ''));
    if (!owner && appliquer) {
      alerter('boutique sans propriétaire', String(s.name));
      noter('boutiques', 'ignore');
      continue;
    }

    const lng = Number(s.longitude);
    const lat = Number(s.latitude);
    if (!Number.isFinite(lng) || !Number.isFinite(lat)) {
      alerter('boutique sans coordonnées', String(s.name));
      noter('boutiques', 'ignore');
      continue;
    }

    const identifiant = appliquer && db ? crypto.randomUUID() : `(boutique:${s.id})`;
    const logo = await televerser('products', `${identifiant}/logo`, 'store', s.logo);
    const cover = await televerser('products', `${identifiant}/cover`, 'store/cover', s.cover_photo);

    if (appliquer && db) {
      const { error } = await db.from('merchants').insert({
        id: identifiant,
        owner_id: owner,
        category_id: categoriesTovo.get(`module:${s.module_id}`) ?? null,
        name: s.name,
        logo_url: logo,
        cover_url: cover,
        phone: normaliserTelephone(s.phone),
        address_hint: s.address ?? '',
        location: `SRID=4326;POINT(${lng} ${lat})`,
        zone_id: zone,
        // Approuvée d'office : ces boutiques vendaient déjà. Leur demander de
        // repasser une validation les couperait de leurs clients le jour de
        // la bascule.
        is_approved: true,
        // Fermée, en revanche : c'est au boutiquier d'ouvrir depuis son app,
        // sinon on afficherait comme ouvertes des boutiques que personne ne
        // surveille encore.
        is_open: false,
        prep_time_min: delaiPreparation(s.delivery_time),
        legacy_id: s.id,
      });
      if (error) fatal(`boutique ${s.name}`, error);
    }

    boutiquesTovo.set(s.id, identifiant);
    noter('boutiques', 'cree');
  }
}

// ---------------------------------------------------------------------
// 5. Produits et options
// ---------------------------------------------------------------------

/** Écrit les options d'un produit, avec leurs valeurs. */
async function ecrireOptions(produit: string, options: OptionTransformee[]): Promise<void> {
  if (!appliquer || !db || options.length === 0) return;

  for (const [i, o] of options.entries()) {
    const { data, error } = await db
      .from('product_options')
      .insert({
        product_id: produit,
        name: o.nom,
        is_required: o.obligatoire,
        min_select: o.minSelect,
        max_select: Math.min(o.maxSelect, o.valeurs.length),
        sort_order: i,
      })
      .select('id')
      .single();
    if (error) fatal(`option ${o.nom}`, error);

    const { error: erreurValeurs } = await db.from('product_option_values').insert(
      o.valeurs.map((v, j) => ({
        option_id: (data as { id: string }).id,
        name: v.nom,
        price_delta: v.supplement,
        sort_order: j,
      })),
    );
    if (erreurValeurs) fatal(`valeurs de ${o.nom}`, erreurValeurs);
  }
}

if (active('produits')) {
  console.log('\n── Produits ──');

  let avecOptions = 0;
  let traites = 0;
  const items = t('items');

  for (const i of items) {
    if (!i.id) continue;
    if (produitsTovo.has(i.id)) {
      noter('produits', 'existant');
      continue;
    }

    const boutique = boutiquesTovo.get(i.store_id ?? '');
    if (!boutique) {
      alerter('produit sans boutique migrée', String(i.name));
      noter('produits', 'ignore');
      continue;
    }

    let prix = versXof(i.price);
    let options = transformerOptions(i.food_variations);

    // Les 42 produits e-commerce à variantes portent des prix absolus qu'il
    // faut convertir en base + suppléments ; en cas de structure inattendue
    // on garde le produit sans options plutôt que d'inventer un prix.
    if (options.length === 0 && i.choice_options && i.choice_options !== '[]') {
      const variantes = transformerVariantes(i.choice_options, i.variations, prix);
      if (variantes) {
        prix = variantes.prix;
        options = variantes.options;
      } else {
        alerter('variantes non converties (produit gardé sans options)', `${i.name} (${i.id})`);
      }
    }
    if (options.length > 0) avecOptions++;

    const identifiant = appliquer && db ? crypto.randomUUID() : `(produit:${i.id})`;
    const image = await televerser('products', `${boutique}/${identifiant}`, 'product', i.image);

    if (appliquer && db) {
      const { error } = await db.from('products').insert({
        id: identifiant,
        merchant_id: boutique,
        category_id: categoriesTovo.get(`cat:${i.category_id}`) ?? null,
        name: i.name,
        description: i.description,
        image_url: image,
        price: prix,
        is_available: i.status === '1',
        stock_qty: stockUtile(i.stock),
        legacy_id: i.id,
      });
      if (error) fatal(`produit ${i.name}`, error);
      await ecrireOptions(identifiant, options);
    }

    produitsTovo.set(i.id, identifiant);
    noter('produits', 'cree');

    if (++traites % 200 === 0) process.stdout.write(`\r  ${traites}/${items.length}`);
  }
  console.log(`\r  ${traites}/${items.length} traités, ${avecOptions} avec options`);
}

// ---------------------------------------------------------------------
// 6. Livreurs
// ---------------------------------------------------------------------

if (active('livreurs')) {
  console.log('\n── Livreurs ──');

  for (const d of t('delivery_men')) {
    if (!d.id) continue;
    const tel = normaliserTelephone(d.phone);
    if (!tel) {
      alerter('livreur sans numéro exploitable', `${nomComplet(d.f_name, d.l_name)} (${d.id})`);
      noter('livreurs', 'ignore');
      continue;
    }

    const nom = nomComplet(d.f_name, d.l_name) || `Livreur ${d.id}`;
    const profil = await creerCompte('livreurs', `dm:${d.id}`, tel, nom, 'driver');
    if (!profil || !appliquer || !db) continue;

    // Hors ligne et disponible : personne ne roule au moment de la bascule.
    // Les marquer en ligne les ferait recevoir des courses sans app ouverte,
    // et la commande resterait en attente jusqu'à expiration.
    const { error } = await db.from('driver_profiles').upsert({
      id: profil,
      zone_id: zonesTovo.get(d.zone_id ?? '') ?? null,
      is_online: false,
      is_available: true,
    });
    if (error) fatal(`profil livreur ${nom}`, error);
  }
}

// ---------------------------------------------------------------------
// 7. Clients
// ---------------------------------------------------------------------

if (active('clients')) {
  console.log('\n── Clients ──');

  const utilisateurs = t('users');
  let traites = 0;

  for (const u of utilisateurs) {
    if (!u.id) continue;
    const tel = normaliserTelephone(u.phone);
    if (!tel) {
      alerter('client sans numéro exploitable', `${nomComplet(u.f_name, u.l_name)} (${u.id})`);
      noter('clients', 'ignore');
      continue;
    }

    const nom = nomComplet(u.f_name, u.l_name) || 'Client Tovo';
    await creerCompte('clients', `user:${u.id}`, tel, nom, 'client');

    if (++traites % 200 === 0) process.stdout.write(`\r  ${traites}/${utilisateurs.length}`);
  }
  console.log(`\r  ${traites}/${utilisateurs.length} traités`);
}

// ---------------------------------------------------------------------
// Rapport
// ---------------------------------------------------------------------

console.log('\n════ BILAN ════');
for (const [etape, b] of bilans) {
  console.log(
    `${etape.padEnd(12)} ${String(b.cree).padStart(5)} à créer   ` +
      `${String(b.existant).padStart(5)} déjà là   ${String(b.ignore).padStart(5)} écartés`,
  );
}

console.log(
  `\nimages       ${String(images.trouvees).padStart(5)} sur le disque   ` +
    `${String(images.manquantes).padStart(5)} introuvables`,
);

if (alertes.length > 0) {
  console.log(`\n════ ${alertes.length} POINTS À REGARDER ════`);
  // Les collisions de numéros se comptent par dizaines et disent toutes la
  // même chose ; on montre de quoi juger sans noyer le reste.
  const parType = new Map<string, string[]>();
  for (const a of alertes) {
    parType.set(a.type, [...(parType.get(a.type) ?? []), a.detail]);
  }
  for (const [type, liste] of parType) {
    console.log(`\n${liste.length} × ${type}`);
    for (const a of liste.slice(0, 5)) console.log(`  · ${a}`);
    if (liste.length > 5) console.log(`  … et ${liste.length - 5} autres`);
  }
}

if (!appliquer) {
  console.log('\nRien n’a été écrit. Relancez avec --apply pour charger.');
}
