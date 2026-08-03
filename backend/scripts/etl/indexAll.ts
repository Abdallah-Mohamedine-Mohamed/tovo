import { indexProducts } from '../../src/services/indexer.js';
import { serviceClient } from '../../src/services/supabase.js';

/**
 * Indexation de rattrapage après la migration.
 *
 * L'indexeur du serveur traite 50 produits toutes les 5 minutes : c'est le
 * bon rythme pour une fiche corrigée par un boutiquier, mais il faudrait
 * près de quatre heures pour les 2 000 produits arrivés d'un coup — pendant
 * lesquelles la recherche ne les trouverait pas.
 *
 * Ce script fait le même travail sans attendre. Il est reprenable par
 * construction : `products_to_embed()` ne remonte que ce qui n'a pas encore
 * d'embedding, donc relancer après une coupure continue là où on en était.
 *
 *   npx tsx --env-file=.env scripts/etl/indexAll.ts
 */

const LOT = 50;
const db = serviceClient();

let examines = 0;
let indexes = 0;
let echecs = 0;
const debut = Date.now();

/**
 * Nombre de produits restant à indexer, mesuré indépendamment de l'indexeur.
 *
 * Sans ce contrôle, une régression comme celle du trigger `updated_at` passe
 * inaperçue : l'indexeur annonce des milliers de succès en réindexant sans
 * fin le même lot, pendant que le reste du catalogue reste introuvable. Le
 * compteur qui compte vraiment est celui des produits jamais indexés.
 */
async function restants(): Promise<number> {
  const { count, error } = await db
    .from('products')
    .select('*', { count: 'exact', head: true })
    .is('embedded_at', null);
  if (error) throw error;
  return count ?? 0;
}

let precedent = await restants();
console.log(`${precedent} produits à indexer.`);

for (;;) {
  const bilan = await indexProducts(LOT);
  examines += bilan.examined;
  indexes += bilan.indexed;
  echecs += bilan.failed;

  const minutes = ((Date.now() - debut) / 60000).toFixed(1);
  process.stdout.write(`\r${indexes} indexés, ${echecs} en échec — ${minutes} min`);

  // Plus rien à indexer : la file est vide, on a fini.
  if (bilan.examined === 0) break;

  // Un lot entier traité sans succès ni échec fait reculer le reste de zéro :
  // l'indexeur tourne alors sur des produits déjà faits.
  const reste = await restants();
  if (bilan.indexed > 0 && reste >= precedent) {
    console.error(
      `\n✗ ${bilan.indexed} produits annoncés indexés, mais il en reste toujours ${reste}.` +
        `\n  L'indexeur reprend les mêmes : arrêt avant d'épuiser le quota pour rien.`,
    );
    process.exit(1);
  }
  precedent = reste;

  // Un lot entièrement en échec signifie une panne côté API, pas des
  // produits fautifs. Continuer ne ferait qu'épuiser le quota en boucle.
  if (bilan.failed === bilan.examined && bilan.examined > 0) {
    console.error(`\n✗ Lot entièrement en échec — arrêt. ${indexes} produits indexés avant l'arrêt.`);
    process.exit(1);
  }
}

console.log(`\n${examines} examinés, ${indexes} indexés, ${echecs} en échec.`);
