import { env } from '../config/env.js';
import { aiguillageActif, consulterJev, decider, type Route } from './aiguillage.js';
import { classerLocalement, classifieurActif } from './classifieur.js';
import type { DecisionJev } from './jev.js';

/**
 * La cascade : du plus rapide au plus lent, on s'arrête dès qu'on est sûr.
 *
 *   1. (en amont, dans la route) recherche exacte au catalogue — « du riz »
 *   2. classifieur LOCAL, ~20 ms, sans réseau — sûr : il décide
 *   3. Jev, SEULEMENT si le local hésite, avec un budget court
 *      (JEV_DELAI_MS) — lent ce jour-là : on ne l'attend pas davantage
 *   4. doute sur une action : tuiles ; sinon le chemin habituel (Gemini)
 *
 * Jev n'est donc plus jamais sur le chemin d'un message évident, et n'est
 * payé que pour les messages où il apporte quelque chose.
 */

export interface Aiguillage {
  route: Route;
  /** Qui a tranché : utile dans les journaux pour régler les seuils. */
  source: 'local' | 'jev' | 'aucune';
  local: DecisionJev | null;
  jev: DecisionJev | null;
}

export const cascadeActive = (): boolean => classifieurActif() || aiguillageActif();

export async function aiguiller(message: string): Promise<Aiguillage> {
  const local = await classerLocalement(message);
  if (local?.choix && local.confiance >= env.CLASSIFIEUR_SEUIL) {
    return { route: { type: 'intention', intention: local.choix, decision: local }, source: 'local', local, jev: null };
  }

  const jev = await consulterJev(message);
  if (jev?.choix) return { route: decider(jev, message), source: 'jev', local, jev };

  // Ni sûr ni second avis : l'avis du local, jugé à SON seuil, peut encore
  // proposer des tuiles s'il hésite sur une action.
  return { route: decider(local, message, env.CLASSIFIEUR_SEUIL), source: local ? 'local' : 'aucune', local, jev };
}
