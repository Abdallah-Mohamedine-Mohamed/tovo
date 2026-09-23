/**
 * Efface TOUT ce que les scénarios ont créé, et rien d'autre :
 *   - comptes `scenario-…@tovo.test` et `boutiques-scenario@tovo.test` ;
 *   - boutiques `legacy_id` « scenario-… » (produits et options en cascade) ;
 *   - commandes de ces comptes ou de ces boutiques.
 *
 *   npm run staging:nettoyer
 *
 * Ordre imposé par la base : une commande bloque la suppression de son
 * client et de sa boutique (on delete restrict). Refuse la production
 * (garde.ts).
 */
import { createClient } from '@supabase/supabase-js';
import { exigerStaging } from './garde.js';

const { url, service } = exigerStaging();
const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

const DE_TEST = /^(scenario-[0-9a-f-]+|boutiques-scenario)@tovo\.test$/;

const comptes: string[] = [];
for (let page = 1; ; page++) {
  const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
  if (error) throw error;
  comptes.push(...data.users.filter((u) => DE_TEST.test(u.email ?? '')).map((u) => u.id));
  if (data.users.length < 1000) break;
}

const { data: boutiques, error: eb } = await admin.from('merchants').select('id').like('legacy_id', 'scenario-%');
if (eb) throw eb;
const idsBoutiques = (boutiques ?? []).map((b) => b.id as string);

let commandes = 0;
for (const [colonne, ids] of [['user_id', comptes], ['merchant_id', idsBoutiques]] as const) {
  if (!ids.length) continue;
  const { data, error } = await admin.from('orders').delete().in(colonne, ids).select('id');
  if (error) throw new Error(`commandes (${colonne}) : ${error.message}`);
  commandes += data?.length ?? 0;
}

if (idsBoutiques.length) {
  const { error } = await admin.from('merchants').delete().in('id', idsBoutiques);
  if (error) throw new Error(`boutiques : ${error.message}`);
}

let supprimes = 0;
for (const id of comptes) {
  const { error } = await admin.auth.admin.deleteUser(id);
  if (error) console.log(`   compte non supprimé : ${error.message}`);
  else supprimes++;
}

console.log(`Nettoyé : ${commandes} commandes, ${idsBoutiques.length} boutiques (et leurs produits), ${supprimes}/${comptes.length} comptes de test.`);
