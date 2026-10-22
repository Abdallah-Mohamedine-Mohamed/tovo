/**
 * NIGER BEAUTÉ (22/10) — ses 12 catégories et leurs pastilles (migration 0087).
 *
 *   npx tsx --env-file=.env scripts/niger-beaute/rayons.ts               à blanc : classe, affiche le bilan, n'écrit rien
 *   npx tsx --env-file=.env scripts/niger-beaute/rayons.ts --appliquer   écrit (icônes, catégories, produits, affichage)
 *   ... [dossier]   par défaut C:\Users\abdal\Documents\niger beaute catalogue
 *
 * La page de la boutique ne montre plus que ces catégories (une icône, un
 * nom) ; une catégorie ouvre ses articles, que des pastilles filtrent sur
 * place. Les autres boutiques ne sont pas touchées.
 *
 * Chaque produit est rangé d'après la sous-catégorie de l'inventaire (celle
 * que la visite a pu corriger), jamais par l'IA. Les parfums sont répartis
 * par genre (genres-parfums.json : IA, revue, puis « mixte » pour les
 * indécidables, décision du fondateur du 22/10). Aucun produit n'est laissé
 * de côté : un produit qu'aucune règle ne range ARRÊTE le script.
 *
 * Le dossier contient en plus du chargement :
 *   icones-rayons\<clé>.png   l'icône de chaque catégorie, fond transparent
 *   genres-parfums.json        { genres: { <nom en base>: homme | femme | mixte } }
 */
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';
import { toutLire } from '../../src/ai/banc/lire.js';

const args = process.argv.slice(2);
const appliquer = args.includes('--appliquer');
const DOSSIER = args.find((a) => !a.startsWith('--')) ?? 'C:\\Users\\abdal\\Documents\\niger beaute catalogue';
const CLE_BOUTIQUE = 'niger-beaute';
const BUCKET = 'products';

const url = process.env.SUPABASE_URL;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !service) throw new Error('SUPABASE_URL ou SUPABASE_SERVICE_ROLE_KEY absent : lancez avec --env-file=.env');
const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

// --- Les 12 catégories, dans l'ordre de la page ------------------------------------
// Les pastilles dans l'ordre voulu ; une pastille sans produit disparaît.

const CATEGORIES: Array<{ cle: string; nom: string; pastilles: string[] }> = [
  { cle: 'parfums', nom: 'Parfums', pastilles: ['Pour homme', 'Pour femme', 'Mixtes', 'Eaux de Cologne', 'Parfums de poche', 'Coffrets', 'Brumes et diffuseurs'] },
  { cle: 'deodorants', nom: 'Déodorants', pastilles: ['Sprays', 'Roll-on'] },
  { cle: 'laits-et-cremes', nom: 'Laits et crèmes', pastilles: ['Laits et lotions', 'Crèmes et baumes', 'Gommages', 'Coffrets'] },
  { cle: 'huiles', nom: 'Huiles', pastilles: [] },
  { cle: 'gels-douche', nom: 'Gels douche', pastilles: ['Gels douche', 'Désinfectants'] },
  { cle: 'savons', nom: 'Savons', pastilles: [] },
  { cle: 'visage', nom: 'Sérums et crèmes visage', pastilles: ['Crèmes', 'Sérums', 'Nettoyants', 'Masques', 'Coffrets', 'Protection solaire'] },
  { cle: 'cheveux', nom: 'Cheveux', pastilles: ['Shampooings', 'Après-shampooings', 'Pommades', 'Huiles et soins', 'Défrisants et colorations'] },
  { cle: 'maquillage', nom: 'Maquillage', pastilles: ['Lèvres', 'Teint', 'Yeux', 'Coffrets'] },
  { cle: 'hygiene-intime', nom: 'Hygiène intime', pastilles: ['Toilette intime', 'Serviettes hygiéniques', 'Protections adulte'] },
  { cle: 'dents-et-haleine', nom: 'Dents et haleine', pastilles: ['Brosses et dentifrices', 'Chewing-gums'] },
  { cle: 'bebe', nom: 'Bébé', pastilles: ['Soins', 'Biberons et accessoires', 'Linge'] },
];

type Place = [cle: string, pastille: string | null];

/** La sous-catégorie de l'inventaire → catégorie et pastille. Les cas à trancher sur le nom sont plus bas. */
const PAR_SOUS_CATEGORIE: Record<string, Place> = {
  'Eaux de Cologne et de toilette': ['parfums', 'Eaux de Cologne'],
  'Parfums de poche': ['parfums', 'Parfums de poche'],
  'Coffrets parfum': ['parfums', 'Coffrets'],
  "Brumes et parfums d'ambiance": ['parfums', 'Brumes et diffuseurs'],
  'Laits et lotions corporels': ['laits-et-cremes', 'Laits et lotions'],
  'Crèmes et baumes corporels': ['laits-et-cremes', 'Crèmes et baumes'],
  'Gommages corporels': ['laits-et-cremes', 'Gommages'],
  'Coffrets soin': ['laits-et-cremes', 'Coffrets'],
  'Huiles corporelles': ['huiles', null],
  'Gels douche': ['gels-douche', 'Gels douche'],
  'Désinfectants': ['gels-douche', 'Désinfectants'],
  'Savons': ['savons', null],
  'Crèmes et soins visage': ['visage', 'Crèmes'],
  'Sérums visage': ['visage', 'Sérums'],
  'Nettoyants visage': ['visage', 'Nettoyants'],
  'Masques visage': ['visage', 'Masques'],
  'Protection solaire': ['visage', 'Protection solaire'],
  'Shampooings': ['cheveux', 'Shampooings'],
  'Après-shampooings': ['cheveux', 'Après-shampooings'],
  'Pommades capillaires': ['cheveux', 'Pommades'],
  'Huiles et soins capillaires': ['cheveux', 'Huiles et soins'],
  'Défrisants et colorations': ['cheveux', 'Défrisants et colorations'],
  'Lèvres': ['maquillage', 'Lèvres'],
  'Teint': ['maquillage', 'Teint'],
  'Yeux': ['maquillage', 'Yeux'],
  'Coffrets maquillage': ['maquillage', 'Coffrets'],
  'Protections adulte': ['hygiene-intime', 'Protections adulte'],
  'Hygiène bucco-dentaire': ['dents-et-haleine', 'Brosses et dentifrices'],
  'Chewing-gums': ['dents-et-haleine', 'Chewing-gums'],
  'Soins bébé': ['bebe', 'Soins'],
  'Biberons et accessoires': ['bebe', 'Biberons et accessoires'],
  'Linge de bébé': ['bebe', 'Linge'],
  // Un accessoire va avec la gourde. Le seul de l'inventaire, « GRAFFITI CUP »,
  // était un 202 Men mal nommé : retiré de la vente le 23/10.
  'Accessoires': ['bebe', 'Biberons et accessoires'],
};

/**
 * Rangés « parfum » par l'inventaire alors que ce n'en sont pas (revue des
 * photos du 22/10) : on suit le TYPE du produit en base (0086).
 */
const PAR_TYPE: Array<[RegExp, Place]> = [
  [/pain de toilette|savon/, ['savons', null]],
  [/coffret (de )?(cosm|soin)/, ['visage', 'Coffrets']],
];

const GENRES: Record<string, string> = existsSync(join(DOSSIER, 'genres-parfums.json'))
  ? JSON.parse(readFileSync(join(DOSSIER, 'genres-parfums.json'), 'utf8')).genres
  : {};
const PASTILLE_DU_GENRE: Record<string, string> = { homme: 'Pour homme', femme: 'Pour femme', mixte: 'Mixtes' };

function placeDe(sousCategorie: string, nom: string, types: string[]): Place | null {
  const type = types.join(' ').toLowerCase();
  if (['Eaux de parfum', 'Eaux de Cologne et de toilette', 'Coffrets parfum', 'Parfums de poche'].includes(sousCategorie)) {
    for (const [motif, place] of PAR_TYPE) if (motif.test(type)) return place;
  }
  if (sousCategorie === 'Eaux de parfum') return ['parfums', PASTILLE_DU_GENRE[GENRES[nom] ?? 'mixte'] ?? 'Mixtes'];
  if (sousCategorie === 'Déodorants') return ['deodorants', /roll-?on/i.test(nom) ? 'Roll-on' : 'Sprays'];
  if (sousCategorie === 'Hygiène intime et féminine') {
    return ['hygiene-intime', /serviette|pads?\b/i.test(nom) ? 'Serviettes hygiéniques' : 'Toilette intime'];
  }
  return PAR_SOUS_CATEGORIE[sousCategorie] ?? null;
}

// --- Lecture de l'inventaire (la visite l'emporte, comme dans charger.ts) ----------

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

const inventaire = lireCsv(readFileSync(join(DOSSIER, 'inventaire.csv'), 'utf8'));
const visite = existsSync(join(DOSSIER, 'visite.json'))
  ? JSON.parse(readFileSync(join(DOSSIER, 'visite.json'), 'utf8')) as { articles: Record<string, Record<string, string>>; ajouts: Array<Record<string, string>> }
  : { articles: {}, ajouts: [] };
const sousCategorieDe = new Map<string, string>([
  ...inventaire.map((a) => [a.id, { ...a, ...(visite.articles[a.id] ?? {}) }.sous_categorie ?? ''] as [string, string]),
  ...visite.ajouts.map((a) => [a.id, a.sous_categorie ?? ''] as [string, string]),
]);

// --- Classement -----------------------------------------------------------------

// À blanc, le bilan se lit même avant la migration 0087 (colonnes absentes).
const boutique = await db.from('merchants').select('id').eq('legacy_id', CLE_BOUTIQUE).maybeSingle();
if (boutique.error) throw new Error(`boutique : ${boutique.error.message}`);
if (!boutique.data) throw new Error('boutique Niger Beauté introuvable');
const boutiqueId = boutique.data.id as string;
const affichage = await db.from('merchants').select('affichage').eq('id', boutiqueId).maybeSingle();
const migrationFaite = !affichage.error;
if (!migrationFaite && appliquer) throw new Error('la migration 0087 n’est pas appliquée : rien n’a été écrit');

type Produit = { id: string; legacy_id: string | null; name: string; is_available: boolean; type_produit: string[] | null; rayon_boutique?: string | null; sous_rayon?: string | null };
const produits = await toutLire<Produit>(
  (de, a) => db.from('products')
    .select(`id, legacy_id, name, is_available, type_produit${migrationFaite ? ', rayon_boutique, sous_rayon' : ''}`)
    .eq('merchant_id', boutiqueId).order('id').range(de, a),
);
if (produits.error) throw new Error(`produits : ${produits.error.message}`);

const places = new Map<string, Place>();
const orphelins: string[] = [];
for (const p of produits.data) {
  const id = (p.legacy_id ?? '').replace(`${CLE_BOUTIQUE}:`, '');
  const place = placeDe(sousCategorieDe.get(id) ?? '', p.name, p.type_produit ?? []);
  if (place) places.set(p.id, place);
  else orphelins.push(`${id || '(sans legacy_id)'} « ${p.name} » sous-catégorie « ${sousCategorieDe.get(id) ?? '?'} »`);
}

console.log(`\nNiger Beauté : ${produits.data.length} produits (${produits.data.filter((p) => p.is_available).length} en vente)\n`);
for (const c of CATEGORIES) {
  const ici = produits.data.filter((p) => places.get(p.id)?.[0] === c.cle);
  const enVente = ici.filter((p) => p.is_available);
  console.log(`  ${c.nom.padEnd(26)} ${String(enVente.length).padStart(4)} en vente   (${ici.length} en tout)`);
  const parPastille = new Map<string, number>();
  for (const p of enVente) {
    const s = places.get(p.id)![1] ?? '—';
    parPastille.set(s, (parPastille.get(s) ?? 0) + 1);
  }
  for (const [s, n] of parPastille) console.log(`      ${s.padEnd(28)} ${n}`);
}
if (orphelins.length) {
  console.log(`\n${orphelins.length} produit(s) qu'aucune règle ne range :`);
  for (const o of orphelins) console.log(`  ${o}`);
  throw new Error('classement incomplet : ajoutez une règle, rien n’a été écrit');
}

const icones = CATEGORIES.map((c) => join(DOSSIER, 'icones-rayons', `${c.cle}.png`));
const manquantes = icones.filter((f) => !existsSync(f));
if (manquantes.length) throw new Error(`icônes manquantes : ${manquantes.join(', ')}`);

// Les « parfums » mal rangés par l'inventaire (revue du 22/10) : leur place doit se voir.
for (const n of ['Dove Pink', 'Dove FIFA', 'Dove Refreshing', 'Dove Beauty Cream', 'Jhalak', 'Fair & White Mix', 'FaceFresh']) {
  for (const p of produits.data.filter((x) => x.name.includes(n))) {
    console.log(`  contrôle : ${p.name} → ${places.get(p.id)?.join(' / ')}${p.is_available ? '' : ' (pas en vente)'}`);
  }
}

const aChanger = produits.data.filter((p) => {
  const [cle, pastille] = places.get(p.id)!;
  return (p.rayon_boutique ?? null) !== cle || (p.sous_rayon ?? null) !== pastille;
});
console.log(`\n${aChanger.length} produit(s) à ranger ou à déplacer ; affichage actuel : ${migrationFaite ? (affichage.data as { affichage: string }).affichage : "migration 0087 pas encore appliquée"}`);

if (!appliquer) {
  console.log('\nÀ blanc : rien n’a été écrit. Relancez avec --appliquer.');
  process.exit(0);
}

// --- Écriture ---------------------------------------------------------------------

async function verifier<T>(promesse: PromiseLike<{ data: T; error: { message: string } | null }>, quoi: string): Promise<T> {
  const { data, error } = await promesse;
  if (error) throw new Error(`${quoi} : ${error.message}`);
  return data;
}

// Les icônes : WebP 256 px, transparence gardée (l'icône repose sur un galet gris).
for (const [i, c] of CATEGORIES.entries()) {
  const contenu = await sharp(icones[i]).trim({ threshold: 1 })
    .resize(256, 256, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .webp({ quality: 88, alphaQuality: 100 }).toBuffer();
  const chemin = `${CLE_BOUTIQUE}/rayons/${c.cle}.webp`;
  await verifier(db.storage.from(BUCKET).upload(chemin, contenu, { contentType: 'image/webp', upsert: true }), `icône ${c.cle}`);
  // ?v= : une icône remplacée n'est pas resservie par les caches.
  const icone = `${db.storage.from(BUCKET).getPublicUrl(chemin).data.publicUrl}?v=${Date.now()}`;
  await verifier(db.from('rayons_boutique').upsert({
    merchant_id: boutiqueId, cle: c.cle, nom: c.nom, icone_url: icone, ordre: i + 1, sous_rayons: c.pastilles,
  }), `catégorie ${c.cle}`);
}
console.log('12 catégories et leurs icônes écrites');

// Les produits, regroupés par place : un appel par (catégorie, pastille).
const parPlace = new Map<string, string[]>();
for (const p of aChanger) {
  const k = JSON.stringify(places.get(p.id));
  parPlace.set(k, [...(parPlace.get(k) ?? []), p.id]);
}
for (const [k, ids] of parPlace) {
  const [cle, pastille] = JSON.parse(k) as Place;
  for (let i = 0; i < ids.length; i += 200) {
    await verifier(db.from('products').update({ rayon_boutique: cle, sous_rayon: pastille }).in('id', ids.slice(i, i + 200)), `produits ${cle}`);
  }
}
console.log(`${aChanger.length} produit(s) rangé(s)`);

await verifier(db.from('merchants').update({ affichage: 'categories' }).eq('id', boutiqueId), 'affichage');
console.log('Niger Beauté s’affiche désormais par catégories.');
