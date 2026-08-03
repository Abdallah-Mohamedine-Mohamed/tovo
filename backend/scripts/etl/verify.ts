import { createClient } from '@supabase/supabase-js';

/**
 * Contrôle d'après-migration.
 *
 * Le chargeur dit ce qu'il a écrit ; ce script dit ce qui est réellement en
 * base et utilisable. La différence compte : une image téléversée mais
 * inaccessible, un produit sans embedding ou une boutique hors zone ne
 * lèvent aucune erreur — ils rendent seulement l'app inutilisable par
 * endroits.
 *
 *   npx tsx --env-file=.env scripts/etl/verify.ts
 */

const db = createClient(process.env['SUPABASE_URL']!, process.env['SUPABASE_SERVICE_ROLE_KEY']!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type Filtre = (q: any) => any;

async function compter(table: string, filtre?: Filtre): Promise<number> {
  let q = db.from(table).select('*', { count: 'exact', head: true });
  if (filtre) q = filtre(q);
  const { count, error } = await q;
  if (error) throw new Error(`${table} : ${error.message}`);
  return count ?? 0;
}

const migre: Filtre = (q) => q.not('legacy_id', 'is', null);
const ligne = (libelle: string, valeur: string | number, note = '') =>
  console.log(`  ${libelle.padEnd(34)} ${String(valeur).padStart(6)}  ${note}`);

console.log('\n════ CE QUI EST EN BASE ════');
ligne('zones', await compter('delivery_zones', migre));
ligne('catégories', await compter('categories', migre));
ligne('  avec image', await compter('categories', (q) => migre(q).not('image_url', 'is', null)));
ligne('boutiques', await compter('merchants', migre));
ligne('  avec logo', await compter('merchants', (q) => migre(q).not('logo_url', 'is', null)));
ligne('  avec couverture', await compter('merchants', (q) => migre(q).not('cover_url', 'is', null)));
ligne('  approuvées', await compter('merchants', (q) => migre(q).eq('is_approved', true)));
ligne('produits', await compter('products', migre));
ligne('  avec image', await compter('products', (q) => migre(q).not('image_url', 'is', null)));
ligne('  disponibles', await compter('products', (q) => migre(q).eq('is_available', true)));
// Sur `embedded_at` et non sur `embedding` : PostgREST ne sait pas filtrer
// une colonne vector, et `not.is.null` y renvoie un compte fantaisiste —
// on croirait l'indexation bloquée alors qu'elle avance.
ligne('  indexés (recherche)', await compter('products', (q) => migre(q).not('embedded_at', 'is', null)));
ligne('options', await compter('product_options'));
ligne('valeurs d’options', await compter('product_option_values'));
ligne('comptes boutiquiers', await compter('profiles', (q) => migre(q).eq('role', 'merchant')));
ligne('comptes livreurs', await compter('profiles', (q) => migre(q).eq('role', 'driver')));
ligne('  avec fiche livreur', await compter('driver_profiles'));
ligne('comptes clients', await compter('profiles', (q) => migre(q).eq('role', 'client')));

// ---------------------------------------------------------------------
// Contrôles qui ne se voient pas dans les compteurs
// ---------------------------------------------------------------------

console.log('\n════ CONTRÔLES ════');
const soucis: string[] = [];

// Une image téléversée peut rester inaccessible si le bucket n'est pas
// public : le compteur serait bon et l'app n'afficherait rien.
for (const [quoi, table, colonne] of [
  ['produit', 'products', 'image_url'],
  ['boutique (logo)', 'merchants', 'logo_url'],
  ['boutique (couverture)', 'merchants', 'cover_url'],
  ['catégorie', 'categories', 'image_url'],
] as const) {
  const { data } = await db.from(table).select(colonne).not(colonne, 'is', null).limit(1);
  const url = (data?.[0] as Record<string, string> | undefined)?.[colonne];
  if (!url) {
    soucis.push(`aucune image ${quoi} à vérifier`);
    continue;
  }
  const r = await fetch(url, { method: 'HEAD' });
  console.log(`  image ${quoi.padEnd(24)} HTTP ${r.status}`);
  if (!r.ok) soucis.push(`image ${quoi} inaccessible (HTTP ${r.status})`);
}

// Prix à zéro : la conversion des variantes e-commerce reconstruit le prix
// de base ; un zéro signifierait un produit offert.
const gratuits = await compter('products', (q) => migre(q).eq('price', 0));
console.log(`  produits à prix nul${' '.repeat(15)}${String(gratuits).padStart(6)}`);
if (gratuits > 0) soucis.push(`${gratuits} produits à prix nul`);

// Un profil sans téléphone ne peut pas se connecter du tout.
const sansTel = await compter('profiles', (q) => migre(q).is('phone', null));
console.log(`  profils sans téléphone${' '.repeat(12)}${String(sansTel).padStart(6)}`);
if (sansTel > 0) soucis.push(`${sansTel} profils sans téléphone`);

// Une option obligatoire sans valeur bloque l'ajout au panier.
const { data: options } = await db
  .from('product_options')
  .select('id, name, is_required, product_option_values(id)')
  .eq('is_required', true);
const bloquantes = (options ?? []).filter(
  (o) => ((o as { product_option_values: unknown[] }).product_option_values ?? []).length === 0,
);
console.log(`  options obligatoires sans valeur${' '.repeat(2)}${String(bloquantes.length).padStart(6)}`);
if (bloquantes.length > 0) soucis.push(`${bloquantes.length} options obligatoires sans valeur`);

console.log('');
if (soucis.length === 0) {
  console.log('Aucun problème détecté.');
} else {
  console.log('À REGARDER :');
  for (const s of soucis) console.log(`  · ${s}`);
}
