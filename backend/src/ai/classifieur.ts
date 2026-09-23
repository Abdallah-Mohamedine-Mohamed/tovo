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
): Classifieur {
  return {
    async classer(message) {
      const debut = performance.now();
      const q = await vectoriser(message);
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
        ms: performance.now() - debut,
        cout: 0,
      };
    },
  };
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
      etat = { etat: 'pret', classifieur: creerClassifieur(vectoriser, vecteurs, intentions, meta.dimension) };
      journal?.(`classifieur local prêt en ${Math.round((Date.now() - debut) / 1000)} s (${intentions.length} phrases)`);
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
