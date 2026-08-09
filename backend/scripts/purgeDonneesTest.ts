import { createClient } from '@supabase/supabase-js';

/**
 * Efface ce que la suite de tests laisse derrière elle.
 *
 * Le nettoyage des tests supprime les comptes créés ; la cascade devrait
 * emporter leurs boutiques. Elle échoue : `orders.merchant_id` est en
 * `on delete restrict`, et une boutique qui porte une commande ne peut pas
 * disparaître. Le `catch` du harnais avale l'erreur, et chaque exécution
 * laisse un peu plus de résidus.
 *
 * Ces résidus ne sont pas inertes. Ils gonflent les compteurs de l'admin,
 * et surtout la suite crée de nouveaux comptes à chaque passage jusqu'à ce
 * que Supabase limite le débit — d'où les échecs qui changent de fichier à
 * chaque exécution.
 *
 * L'ORDRE COMPTE : commandes, puis produits, puis boutiques, puis comptes.
 * Chaque étape lève le verrou de la suivante.
 *
 *   npx tsx --env-file=.env scripts/purgeDonneesTest.ts [--apply]
 */

const appliquer = process.argv.includes('--apply');

const db = createClient(process.env['SUPABASE_URL']!, process.env['SUPABASE_SERVICE_ROLE_KEY']!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

/**
 * Ce qui est de test, et rien d'autre.
 *
 * `legacy_id is null` ne suffirait pas : une vraie boutique créée depuis
 * l'admin n'en aurait pas non plus, et on l'effacerait avec le reste. Le nom
 * est le seul repère sûr — le harnais les appelle toutes « Boutique test ».
 */
const { data: boutiques, error } = await db
  .from('merchants')
  .select('id, name')
  .is('legacy_id', null)
  .like('name', 'Boutique test%');

if (error) throw error;

const ids = (boutiques ?? []).map((m) => m.id as string);
console.log(`${ids.length} boutiques de test repérées`);

if (ids.length === 0) {
  console.log('Rien à faire.');
  process.exit(0);
}

const compter = async (table: string, colonne: string): Promise<number> => {
  const { count } = await db
    .from(table)
    .select('*', { count: 'exact', head: true })
    .in(colonne, ids);
  return count ?? 0;
};

console.log(`  ${await compter('orders', 'merchant_id')} commandes`);
console.log(`  ${await compter('products', 'merchant_id')} produits`);

if (!appliquer) {
  console.log('\nMode à blanc : rien supprimé. Relancez avec --apply.');
  process.exit(0);
}

/**
 * Supprime par lots de boutiques.
 *
 * Une seule requête sur 168 boutiques et leurs 758 commandes dépasse le
 * délai de PostgREST : la connexion tombe, et on ne sait pas ce qui a été
 * effacé. Par tranches, chaque lot est court et le script reprend là où il
 * s'est arrêté si on le relance.
 */
async function supprimerParLots(
  table: string,
  colonne: string,
  libelle: string,
): Promise<void> {
  let total = 0;
  for (let i = 0; i < ids.length; i += 10) {
    const lot = ids.slice(i, i + 10);
    const { error, count } = await db
      .from(table)
      .delete({ count: 'exact' })
      .in(colonne, lot);
    if (error) {
      console.error(`\n${libelle} : échec au lot ${i / 10 + 1} — ${error.message}`);
      process.exit(1);
    }
    total += count ?? 0;
    process.stdout.write(`\r${libelle} : ${total}`);
  }
  console.log('');
}

// L'ordre compte : c'est le `restrict` des commandes qui bloque tout le
// reste. Leurs lignes, historiques et avis partent en cascade.
await supprimerParLots('orders', 'merchant_id', 'commandes supprimées');
await supprimerParLots('products', 'merchant_id', 'produits supprimés');
await supprimerParLots('merchants', 'id', 'boutiques supprimées');

// Les comptes de test restés orphelins. On ne touche à AUCUN compte migré :
// eux portent un `legacy_id`.
const { data: orphelins } = await db
  .from('profiles')
  .select('id, full_name')
  .is('legacy_id', null)
  .like('full_name', 'Test %');

let comptes = 0;
for (const p of orphelins ?? []) {
  const { error } = await db.auth.admin.deleteUser(p.id as string);
  if (!error) comptes++;
}
console.log(`${comptes} comptes de test supprimés`);

const { count: restantes } = await db
  .from('merchants')
  .select('*', { count: 'exact', head: true });
console.log(`\n${restantes} boutiques en base.`);
