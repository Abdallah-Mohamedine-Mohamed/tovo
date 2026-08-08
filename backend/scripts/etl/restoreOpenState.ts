import { createClient } from '@supabase/supabase-js';
import { parseDump } from './dumpParser.js';

/**
 * Rétablit l'état ouvert/fermé réel des boutiques migrées.
 *
 * Le chargement les avait TOUTES marquées fermées, en partant du principe
 * que chaque boutiquier ouvrirait depuis son app. Le raisonnement se tenait
 * pour un lancement progressif ; il ne tient pas aujourd'hui, puisque aucun
 * boutiquier n'a encore l'application. Résultat : un client parcourt un
 * catalogue de 2 000 produits dont pas un seul n'est commandable.
 *
 * On repart donc de la vérité de 6ammart : `active = 1` et `status = 1`,
 * soit les boutiques qui servaient réellement des clients avant la bascule.
 * Les autres restent fermées — elles l'étaient déjà.
 *
 *   npx tsx --env-file=.env scripts/etl/restoreOpenState.ts <dump.sql> [--apply]
 */

const chemin = process.argv[2];
const appliquer = process.argv.includes('--apply');

if (!chemin) {
  console.error('Usage : tsx scripts/etl/restoreOpenState.ts <dump.sql> [--apply]');
  process.exit(1);
}

const db = createClient(process.env['SUPABASE_URL']!, process.env['SUPABASE_SERVICE_ROLE_KEY']!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const { tables } = await parseDump(chemin, new Set(['stores']));
const ouvertes = (tables.get('stores') ?? [])
  .filter((s) => s.active === '1' && s.status === '1' && s.id)
  .map((s) => s.id as string);

console.log(`${ouvertes.length} boutiques étaient ouvertes chez 6ammart.`);

if (!appliquer) {
  console.log('Mode à blanc : rien écrit. Relancez avec --apply.');
  process.exit(0);
}

// Par lots : `in` sur 55 identifiants passe, mais la limite d'URL de
// PostgREST se rappelle vite au bon souvenir quand la liste grandit.
let modifiees = 0;
for (let i = 0; i < ouvertes.length; i += 25) {
  const lot = ouvertes.slice(i, i + 25);
  const { data, error } = await db
    .from('merchants')
    .update({ is_open: true })
    .in('legacy_id', lot)
    .select('id');
  if (error) {
    console.error('échec du lot :', error.message);
    process.exit(1);
  }
  modifiees += (data ?? []).length;
}

const { count } = await db
  .from('merchants')
  .select('*', { count: 'exact', head: true })
  .not('legacy_id', 'is', null)
  .eq('is_open', true);

console.log(`${modifiees} boutiques passées ouvertes. Total ouvert : ${count}.`);
