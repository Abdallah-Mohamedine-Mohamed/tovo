import { env } from '../config/env.js';
import { aiguillageActif, consulterJev, decider, type Route } from './aiguillage.js';
import { classerLocalement, classifieurActif } from './classifieur.js';
import type { DecisionJev } from './jev.js';
import { indiceDeCourse } from './intents.js';

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
  return garderLesCourses(message, await aiguillerSansGarde(message));
}

/**
 * Une course (livreur, colis) n'est décidée d'office que si la phrase en
 * porte un indice : « Je cherche un livre » ressemblait assez à « un
 * livreur » pour que le classifieur tranche seul, et commande un livreur
 * (26/09). Sans indice, la phrase repart sur le chemin habituel.
 */
function garderLesCourses(message: string, a: Aiguillage): Aiguillage {
  const r = a.route;
  if (r.type === 'intention' && (r.intention === 'livreur' || r.intention === 'colis') && !indiceDeCourse(message)) {
    return { ...a, route: { type: 'habituel', decision: r.decision } };
  }
  return a;
}

async function aiguillerSansGarde(message: string): Promise<Aiguillage> {
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
