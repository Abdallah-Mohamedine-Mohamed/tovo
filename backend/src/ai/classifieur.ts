import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { env } from '../config/env.js';
import { INTENTIONS, type DecisionJev, type Intention } from './jev.js';

/**
 * Classifieur d'intentions LOCAL — la première marche de la cascade.
 *
 * Un petit modèle d'embeddings multilingue (e5-small, ~120 Mo) tourne dans le
 * processus du serveur : aucun appel réseau, ~20 ms par message. Le message
 * est comparé aux phrases étiquetées du corpus (index précalculé par
 * `npm run classifieur:indexer`), et les plus proches votent.
 *
 * Mesuré (scripts/classifieur/banc.ts, phrases jamais vues) : 82 % de
 * justesse ; au-dessus de 0,8 de confiance, il décide seul un message sur
 * deux avec 1 % d'erreur. En dessous, il passe la main — à Jev, aux tuiles
 * ou au modèle. Il ne décide jamais « au jugé ».
 *
 * Le modèle se charge EN ARRIÈRE-PLAN au démarrage. Tant qu'il n'est pas
 * prêt (premier démarrage : téléchargement), `classerLocalement` renvoie
 * `null` et la cascade continue sans lui. Rien n'attend jamais le chargement.
 */

export const MODELE_CLASSIFIEUR = 'Xenova/multilingual-e5-small';
// e5 a été entraîné avec ce préfixe : l'omettre dégrade les vecteurs.
export const PREFIXE_CLASSIFIEUR = 'query: ';
const VOISINS = 7;

export type Vectoriser = (texte: string) => Promise<Float32Array>;

/**
 * Seconde méthode, qui sert d'ARBITRE : une régression logistique entraînée
 * sur les mêmes vecteurs. Seule, elle est trop sûre d'elle (3 à 8 % d'erreurs
 * même à 0,99). Mais quand on exige qu'elle soit d'ACCORD avec le vote des
 * voisins, leurs erreurs se compensent : au seuil 0,7, le classifieur décide
 * seul 57 % des messages avec 1 % d'erreur, contre 45 % sans elle
 * (scripts/classifieur/banc.ts --logistique --accord).
 */
export interface Logistique {
  /** Amplification des vecteurs normés, sans laquelle le softmax n'ose pas trancher. */
  echelle: number;
  classes: Intention[];
  /** Une ligne par classe : `dimension` poids, puis le biais. */
  poids: number[][];
}

export function predireLogistique(l: Logistique, v: Float32Array): Intention {
  let meilleur = 0;
  let meilleurScore = -Infinity;
  l.poids.forEach((w, k) => {
    let s = w[w.length - 1]!;
    for (let d = 0; d < w.length - 1; d++) s += w[d]! * v[d]! * l.echelle;
    if (s > meilleurScore) { meilleurScore = s; meilleur = k; }
  });
  return l.classes[meilleur]!;
}

/** Entraînement (descente de gradient, softmax, régularisation L2). Hors ligne : indexer.ts. */
export function entrainerLogistique(
  vecteurs: Float32Array[],
  intentions: Intention[],
  options: { echelle?: number; l2?: number; pas?: number; tours?: number } = {},
): Logistique {
  const echelle = options.echelle ?? 20;
  const l2 = options.l2 ?? 3e-3;
  const pas = options.pas ?? 1;
  const tours = options.tours ?? 1500;
  const classes = [...new Set(intentions)];
  const dim = vecteurs[0]?.length ?? 0;
  const W = classes.map(() => new Float64Array(dim + 1));
  const y = intentions.map((i) => classes.indexOf(i));
  for (let t = 0; t < tours; t++) {
    const grad = classes.map(() => new Float64Array(dim + 1));
    vecteurs.forEach((x, i) => {
      const z = W.map((w) => { let s = w[dim]!; for (let d = 0; d < dim; d++) s += w[d]! * x[d]! * echelle; return s; });
      const m = Math.max(...z);
      const e = z.map((v) => Math.exp(v - m));
      const tot = e.reduce((a, b) => a + b, 0);
      e.forEach((ek, k) => {
        const g = ek / tot - (k === y[i] ? 1 : 0);
        for (let d = 0; d < dim; d++) grad[k]![d]! += g * x[d]! * echelle;
        grad[k]![dim]! += g;
      });
    });
    W.forEach((w, k) => { for (let d = 0; d <= dim; d++) w[d]! -= pas * (grad[k]![d]! / vecteurs.length + (d < dim ? l2 * w[d]! : 0)); });
  }
  return { echelle, classes, poids: W.map((w) => [...w]) };
}

export interface Classifieur {
  classer(message: string): Promise<DecisionJev>;
}

/**
 * Le vote, séparé du modèle : testable avec des vecteurs fabriqués.
 *
 * Chaque voisin vote pour son intention avec un poids s⁴ (s = similarité
 * cosinus) : les voisins nettement plus proches pèsent beaucoup plus que les
 * autres. La confiance est la part du vote gagnant.
 */
export function creerClassifieur(
  vectoriser: Vectoriser,
  vecteurs: Float32Array,
  intentions: Intention[],
  dimension: number,
  arbitre?: Logistique,
): Classifieur {
  return {
    async classer(message) {
      const debut = performance.now();
      const q = await vectoriser(message);
      const decision = voter(q);
      decision.ms = performance.now() - debut;
      // Désaccord de l'arbitre : confiance nulle. Le classifieur ne tranche
      // pas seul ; ses probabilités restent, pour proposer des tuiles.
      if (arbitre && decision.choix && predireLogistique(arbitre, q) !== decision.choix) {
        return { ...decision, confiance: 0 };
      }
      return decision;
    },
  };

  function voter(q: Float32Array): DecisionJev {
      const meilleurs: Array<{ i: number; s: number }> = [];
      for (let i = 0; i < intentions.length; i++) {
        let s = 0;
        const o = i * dimension;
        for (let d = 0; d < dimension; d++) s += q[d]! * vecteurs[o + d]!;
        if (meilleurs.length < VOISINS || s > meilleurs[meilleurs.length - 1]!.s) {
          meilleurs.push({ i, s });
          meilleurs.sort((a, b) => b.s - a.s);
          if (meilleurs.length > VOISINS) meilleurs.pop();
        }
      }
      const votes = new Map<Intention, number>();
      for (const { i, s } of meilleurs) {
        votes.set(intentions[i]!, (votes.get(intentions[i]!) ?? 0) + Math.max(s, 0) ** 4);
      }
      const total = [...votes.values()].reduce((a, b) => a + b, 0) || 1;
      const classes = [...votes.entries()].sort((a, b) => b[1] - a[1]);
      return {
        choix: classes[0]?.[0] ?? null,
        confiance: (classes[0]?.[1] ?? 0) / total,
        probabilites: Object.fromEntries(classes.map(([k, v]) => [k, v / total])) as Partial<Record<Intention, number>>,
        ms: 0,
        cout: 0,
      };
  }
}

// --- Chargement ------------------------------------------------------------

type Etat = { etat: 'eteint' } | { etat: 'chargement' } | { etat: 'pret'; classifieur: Classifieur } | { etat: 'echec'; raison: string };
let etat: Etat = { etat: 'eteint' };

export const classifieurActif = (): boolean => env.CLASSIFIEUR_LOCAL === '1';

/** Lance le chargement (une seule fois). Ne lève jamais ; `journal` reçoit l'issue. */
export function chargerClassifieur(journal?: (message: string, erreur?: unknown) => void): void {
  if (!classifieurActif() || etat.etat !== 'eteint') return;
  etat = { etat: 'chargement' };
  const debut = Date.now();
  void (async () => {
    try {
      const dossier = join(process.cwd(), 'data', 'classifieur');
      const meta = JSON.parse(readFileSync(join(dossier, 'etiquettes.json'), 'utf8')) as {
        modele: string; prefixe: string; dimension: number; intentions: Intention[];
      };
      if (meta.modele !== MODELE_CLASSIFIEUR || meta.prefixe !== PREFIXE_CLASSIFIEUR) {
        throw new Error(`index construit pour ${meta.modele}, relancer npm run classifieur:indexer`);
      }
      const intentions = meta.intentions.filter((i) => i in INTENTIONS);
      const octets = readFileSync(join(dossier, 'vecteurs.bin'));
      const vecteurs = new Float32Array(octets.buffer, octets.byteOffset, octets.byteLength / 4);
      if (vecteurs.length !== meta.intentions.length * meta.dimension) throw new Error('index incohérent');

      // Import tardif : ni les tests ni un serveur sans classifieur ne
      // chargent la bibliothèque (et ses 100 Mo de dépendances natives).
      const { pipeline } = await import('@huggingface/transformers');
      const extracteur = await pipeline('feature-extraction', MODELE_CLASSIFIEUR, { dtype: 'q8' });
      const vectoriser: Vectoriser = async (texte) => {
        const t = await extracteur(PREFIXE_CLASSIFIEUR + texte, { pooling: 'mean', normalize: true });
        return t.data as Float32Array;
      };
      await vectoriser('bonjour'); // échauffement : le premier passage est lent
      // L'arbitre est facultatif : un index construit avant lui fonctionne
      // encore, simplement sans le double accord.
      let arbitre: Logistique | undefined;
      try {
        arbitre = JSON.parse(readFileSync(join(dossier, 'logistique.json'), 'utf8')) as Logistique;
      } catch {
        arbitre = undefined;
      }
      etat = { etat: 'pret', classifieur: creerClassifieur(vectoriser, vecteurs, intentions, meta.dimension, arbitre) };
      journal?.(`classifieur local prêt en ${Math.round((Date.now() - debut) / 1000)} s (${intentions.length} phrases${arbitre ? ', double accord' : ''})`);
    } catch (cause) {
      etat = { etat: 'echec', raison: cause instanceof Error ? cause.message : String(cause) };
      journal?.('classifieur local indisponible — la cascade continue sans lui', cause);
    }
  })();
}

/**
 * La décision du classifieur, ou `null` s'il est éteint, pas encore prêt ou
 * en échec. N'attend jamais le chargement du modèle.
 */
export async function classerLocalement(message: string): Promise<DecisionJev | null> {
  // Le chargement part du démarrage du serveur (index.ts), jamais d'ici :
  // un message ne doit pas déclencher 120 Mo de téléchargement.
  if (!classifieurActif() || !message.trim() || etat.etat !== 'pret') return null;
  try {
    return await etat.classifieur.classer(message);
  } catch {
    return null;
  }
}

/** Réservé aux tests : installe un classifieur prêt. */
export function installerClassifieur(c: Classifieur | null): void {
  etat = c ? { etat: 'pret', classifieur: c } : { etat: 'eteint' };
}
