/**
 * Classifieur d'intentions LOCAL : un petit modèle d'embeddings multilingue
 * qui tourne dans le processus Node, sans appel réseau, plus un vote des plus
 * proches voisins parmi les phrases étiquetées du corpus.
 *
 *   npm run classifieur:banc                       → modèle par défaut
 *   npm run classifieur:banc -- Xenova/paraphrase-multilingual-MiniLM-L12-v2
 *
 * Mesure honnête : apprentissage sur 80 % du corpus, test sur les 20 % jamais
 * vus (répartition fixe par intention). Rapporte la précision, ce qui serait
 * servi faux au-dessus d'un seuil de confiance, la vitesse d'un message et la
 * mémoire consommée. Ne touche ni à la base ni à l'application.
 */
import { readFileSync } from 'node:fs';
import { pipeline } from '@huggingface/transformers';
import type { Intention } from '../../src/ai/jev.js';

// `--distille` : apprendre sur scripts/corpus/distille.json (corpus relu par
// Jev + phrases qu'il a étiquetées) au lieu des 80 % du corpus. Le TEST reste
// le même : les 20 % du corpus, absents de distille.json par construction.
const avecDistille = process.argv.includes('--distille');
const MODELE = process.argv.slice(2).find((a) => !a.startsWith('--')) ?? 'Xenova/multilingual-e5-small';
// Chaque famille a été entraînée avec sa propre forme d'entrée : e5 attend
// « query: », Qwen3 une consigne suivie de « Query: » et la sortie du DERNIER
// jeton (pas la moyenne).
const QWEN = /qwen3/i.test(MODELE);
const PREFIXE = QWEN
  ? 'Instruct: Identifier ce que veut faire le client d’une application de livraison\nQuery: '
  : /e5/i.test(MODELE) ? 'query: ' : '';
const REGROUPEMENT = QWEN ? 'last_token' : 'mean';
const K = 7;

interface Ligne { texte: string; intention: Intention; registre: string }
const corpus = JSON.parse(readFileSync('scripts/corpus/corpus.json', 'utf8')) as Ligne[];

// Répartition fixe et stratifiée : 1 phrase sur 5 de chaque intention en test.
const vus = new Map<string, number>();
const entrainement: Ligne[] = [];
const test: Ligne[] = [];
for (const l of corpus) {
  const n = (vus.get(l.intention) ?? 0) + 1;
  vus.set(l.intention, n);
  (n % 5 === 0 ? test : entrainement).push(l);
}
if (avecDistille) {
  entrainement.length = 0;
  const distille = JSON.parse(readFileSync('scripts/corpus/distille.json', 'utf8')) as Array<{ texte: string; intention: Intention }>;
  entrainement.push(...distille.map((d) => ({ texte: d.texte, intention: d.intention, registre: 'distille' })));
}

const memoireAvant = process.memoryUsage().rss;
let debut = performance.now();
const extracteur = await pipeline('feature-extraction', MODELE, { dtype: 'q8' });
const chargement = performance.now() - debut;

async function vecteurs(textes: string[]): Promise<Float32Array[]> {
  const sortie: Float32Array[] = [];
  for (let i = 0; i < textes.length; i += 32) {
    const lot = textes.slice(i, i + 32).map((t) => PREFIXE + t);
    const t = await extracteur(lot, { pooling: REGROUPEMENT as 'mean', normalize: true });
    const [n, d] = t.dims as [number, number];
    for (let j = 0; j < n; j++) sortie.push((t.data as Float32Array).slice(j * d, (j + 1) * d));
  }
  return sortie;
}

debut = performance.now();
const base = await vecteurs(entrainement.map((l) => l.texte));
const indexation = performance.now() - debut;

const produit = (a: Float32Array, b: Float32Array) => { let s = 0; for (let i = 0; i < a.length; i++) s += a[i]! * b[i]!; return s; };

// `--logistique` : au lieu du vote des voisins, une régression logistique
// (softmax) entraînée sur les vecteurs d'apprentissage. Même coût à l'usage :
// un produit matrice-vecteur.
const avecLogistique = process.argv.includes('--logistique');
const CLASSES = [...new Set(entrainement.map((l) => l.intention))];
const DIM = base[0]?.length ?? 0;
// Amplification : des vecteurs normés donnent des scores trop plats pour
// que le softmax ose trancher.
const ECHELLE = 20;
const W = CLASSES.map(() => new Float32Array(DIM + 1));
if (avecLogistique) {
  const y = entrainement.map((l) => CLASSES.indexOf(l.intention));
  const pas = 1, l2 = Number(process.env.L2 ?? 1e-4), tours = 1500;
  for (let t = 0; t < tours; t++) {
    const grad = CLASSES.map(() => new Float64Array(DIM + 1));
    base.forEach((x, i) => {
      const z = W.map((w) => { let s = w[DIM]!; for (let d = 0; d < DIM; d++) s += w[d]! * x[d]! * ECHELLE; return s; });
      const m = Math.max(...z); const e = z.map((v) => Math.exp(v - m)); const tot = e.reduce((a, b) => a + b, 0);
      e.forEach((ek, k) => { const g = ek / tot - (k === y[i] ? 1 : 0); for (let d = 0; d < DIM; d++) grad[k]![d]! += g * x[d]! * ECHELLE; grad[k]![DIM]! += g; });
    });
    W.forEach((w, k) => { for (let d = 0; d <= DIM; d++) w[d]! -= pas * (grad[k]![d]! / base.length + (d < DIM ? l2 * w[d]! : 0)); });
  }
}

function classerLogistique(v: Float32Array): { choix: Intention; confiance: number } {
  const z = W.map((w) => { let s = w[DIM]!; for (let d = 0; d < DIM; d++) s += w[d]! * v[d]! * ECHELLE; return s; });
  const m = Math.max(...z); const e = z.map((x) => Math.exp(x - m)); const tot = e.reduce((a, b) => a + b, 0);
  const k = e.indexOf(Math.max(...e));
  return { choix: CLASSES[k]!, confiance: e[k]! / tot };
}

// `--accord` (avec --logistique) : la confiance des voisins, mais mise à zéro
// quand la régression logistique n'est pas d'accord sur l'intention.
const avecAccord = process.argv.includes('--accord');

function classer(v: Float32Array): { choix: Intention; confiance: number } {
  if (avecAccord) {
    const voisins = classerVoisins(v);
    return classerLogistique(v).choix === voisins.choix ? voisins : { ...voisins, confiance: 0 };
  }
  if (avecLogistique) return classerLogistique(v);
  return classerVoisins(v);
}

function classerVoisins(v: Float32Array): { choix: Intention; confiance: number } {
  const voisins = base.map((b, i) => ({ i, s: produit(v, b) })).sort((a, b) => b.s - a.s).slice(0, K);
  const votes = new Map<Intention, number>();
  for (const { i, s } of voisins) votes.set(entrainement[i]!.intention, (votes.get(entrainement[i]!.intention) ?? 0) + Math.max(s, 0) ** 4);
  const total = [...votes.values()].reduce((a, b) => a + b, 0) || 1;
  const [choix, poids] = [...votes.entries()].sort((a, b) => b[1] - a[1])[0]!;
  return { choix, confiance: poids / total };
}

const vt = await vecteurs(test.map((l) => l.texte));
const resultats = test.map((l, i) => ({ ...l, ...classer(vt[i]!) }));

// Vitesse d'UN message, comme en production (après échauffement).
const durees: number[] = [];
for (const l of test.slice(0, 60)) {
  const t = performance.now();
  const [v] = await vecteurs([l.texte]);
  classer(v!);
  durees.push(performance.now() - t);
}
durees.sort((a, b) => a - b);

const pct = (a: number, b: number) => (b ? `${Math.round((100 * a) / b)} %` : '—');
const justes = resultats.filter((r) => r.choix === r.intention).length;
console.log(`\n=== ${MODELE} — ${entrainement.length} phrases apprises, ${test.length} testées (jamais vues) ===`);
console.log(`Précision brute : ${pct(justes, test.length)}`);
for (const seuil of [0.6, 0.7, 0.8, 0.9, 0.95, 0.98, 0.99]) {
  const surs = resultats.filter((r) => r.confiance >= seuil);
  const faux = surs.filter((r) => r.choix !== r.intention).length;
  console.log(`Confiance ≥ ${seuil} : décide seul ${pct(surs.length, test.length).padStart(5)} · justes ${pct(surs.length - faux, test.length).padStart(5)} · MAUVAISES servies ${pct(faux, test.length).padStart(5)}`);
}
const registres = [...new Set(test.map((l) => l.registre))];
console.log('Par registre (précision brute) :');
for (const r of registres) {
  const du = resultats.filter((x) => x.registre === r);
  console.log(`   ${r.padEnd(9)} ${pct(du.filter((x) => x.choix === x.intention).length, du.length).padStart(5)}  (${du.length})`);
}
const erreurs = resultats.filter((r) => r.choix !== r.intention).sort((a, b) => b.confiance - a.confiance).slice(0, 10);
console.log('Erreurs les plus sûres :');
for (const e of erreurs) console.log(`   ✗ « ${e.texte} » → ${e.choix} (${e.confiance.toFixed(2)}), attendu : ${e.intention}`);
console.log(`\nUn message : médiane ${durees[30]!.toFixed(0)} ms, p95 ${durees[56]!.toFixed(0)} ms (processeur de ce poste, aucun réseau)`);
console.log(`Chargement du modèle : ${(chargement / 1000).toFixed(1)} s · indexation du corpus : ${(indexation / 1000).toFixed(1)} s`);
console.log(`Mémoire ajoutée : ${Math.round((process.memoryUsage().rss - memoireAvant) / 1024 / 1024)} Mo`);
