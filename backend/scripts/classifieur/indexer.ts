/**
 * Construit l'index du classifieur local : chaque phrase étiquetée du corpus,
 * transformée UNE FOIS en vecteur par le modèle e5-small.
 *
 *   npm run classifieur:indexer
 *
 * Écrit :
 *   data/classifieur/vecteurs.bin     Float32, N × dimension
 *   data/classifieur/etiquettes.json  modèle, préfixe, dimension, intentions
 *
 * Le serveur (src/ai/classifieur.ts) charge ces fichiers au démarrage et n'a
 * plus qu'à vectoriser LE message du client. À relancer quand le corpus
 * change (nouvelles phrases, étiquettes corrigées, distillation par Jev).
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pipeline } from '@huggingface/transformers';
import { MODELE_CLASSIFIEUR, PREFIXE_CLASSIFIEUR } from '../../src/ai/classifieur.js';
import type { Intention } from '../../src/ai/jev.js';

const corpus = JSON.parse(readFileSync('scripts/corpus/corpus.json', 'utf8')) as Array<{ texte: string; intention: Intention }>;
const extracteur = await pipeline('feature-extraction', MODELE_CLASSIFIEUR, { dtype: 'q8' });

const vecteurs: number[] = [];
let dimension = 0;
for (let i = 0; i < corpus.length; i += 32) {
  const lot = corpus.slice(i, i + 32).map((l) => PREFIXE_CLASSIFIEUR + l.texte);
  const t = await extracteur(lot, { pooling: 'mean', normalize: true });
  dimension = t.dims[1] as number;
  vecteurs.push(...(t.data as Float32Array));
  process.stdout.write(`\r${Math.min(i + 32, corpus.length)}/${corpus.length}`);
}
console.log('');

mkdirSync('data/classifieur', { recursive: true });
writeFileSync('data/classifieur/vecteurs.bin', Buffer.from(new Float32Array(vecteurs).buffer));
writeFileSync('data/classifieur/etiquettes.json', JSON.stringify({
  modele: MODELE_CLASSIFIEUR,
  prefixe: PREFIXE_CLASSIFIEUR,
  dimension,
  cree_le: new Date().toISOString(),
  intentions: corpus.map((l) => l.intention),
}));
console.log(`Index : ${corpus.length} phrases × ${dimension} → data/classifieur/ (${Math.round(vecteurs.length * 4 / 1024)} Ko)`);
