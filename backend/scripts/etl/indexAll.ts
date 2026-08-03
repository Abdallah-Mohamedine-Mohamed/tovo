import { indexProducts } from '../../src/services/indexer.js';

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

let examines = 0;
let indexes = 0;
let echecs = 0;
const debut = Date.now();

for (;;) {
  const bilan = await indexProducts(LOT);
  examines += bilan.examined;
  indexes += bilan.indexed;
  echecs += bilan.failed;

  const minutes = ((Date.now() - debut) / 60000).toFixed(1);
  process.stdout.write(`\r${indexes} indexés, ${echecs} en échec — ${minutes} min`);

  // Plus rien à indexer : la file est vide, on a fini.
  if (bilan.examined === 0) break;

  // Un lot entièrement en échec signifie une panne côté API, pas des
  // produits fautifs. Continuer ne ferait qu'épuiser le quota en boucle.
  if (bilan.failed === bilan.examined && bilan.examined > 0) {
    console.error(`\n✗ Lot entièrement en échec — arrêt. ${indexes} produits indexés avant l'arrêt.`);
    process.exit(1);
  }
}

console.log(`\n${examines} examinés, ${indexes} indexés, ${echecs} en échec.`);
