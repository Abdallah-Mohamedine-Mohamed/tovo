import { env } from '../config/env.js';
import { quickReplies, type Component } from '../components/builders.js';
import { classerIntention, type DecisionJev, type Intention, INTENTIONS } from './jev.js';

/**
 * Aiguillage par Jev : quelle route pour ce message ?
 *
 * Remplace les détecteurs à mots, qui servaient une mauvaise réponse avec
 * assurance à un message sur quatre (banc : scripts/jev, corpus de 1 700
 * phrases). Trois issues :
 *
 *   - Jev est sûr (≥ JEV_SEUIL) → il décide la route.
 *   - Jev hésite, et l'une des pistes est une ACTION (livreur, colis,
 *     suivi, annulation, habitude) → on ne devine pas : des tuiles proposent
 *     ce qu'on a compris, le client touche. Se tromper d'action coûte cher
 *     (un livreur qui se déplace, une commande annulée).
 *   - Jev hésite entre des pistes de catalogue, ou ne répond pas à temps
 *     → chemin habituel. Des tuiles sur « attiéké » seraient une friction
 *     inutile : la recherche montre déjà des produits.
 *
 * Interrupteur : JEV_AIGUILLAGE=0 rend la main aux détecteurs à mots.
 */

export const aiguillageActif = (): boolean =>
  env.JEV_AIGUILLAGE === '1' && Boolean(env.OPENROUTER_API_KEY);

/**
 * Consulte Jev ; `null` seulement s'il est éteint. Une panne ou une lenteur
 * revient avec `choix: null` et `erreur` : `decider` prend alors le chemin
 * habituel, et le journal garde la trace (combien d'abandons, et pourquoi).
 * Ne lève jamais.
 */
export async function consulterJev(message: string): Promise<DecisionJev | null> {
  if (!aiguillageActif() || !message.trim()) return null;
  return classerIntention(message, {
    cle: env.OPENROUTER_API_KEY!,
    modele: env.JEV_MODEL,
    delaiMs: env.JEV_DELAI_MS,
  });
}

const ACTIONS = new Set<Intention>(['livreur', 'colis', 'suivi', 'annuler', 'habitude']);

/** Ce que le client lit sur la tuile : SA phrase, pas notre catégorie. */
export const LIBELLES: Record<Intention, string> = {
  recherche: 'Trouver un produit',
  envie: 'Des idées de quoi commander',
  boutique: 'Voir une boutique',
  livreur: 'Commander un livreur',
  colis: 'Envoyer un colis',
  designe: 'Choisir parmi ce que je vois',
  habitude: 'Recommander comme d’habitude',
  suivi: 'Suivre ma commande',
  annuler: 'Annuler ma commande',
  social: 'Rien de précis',
};

const PREFIXE = 'intention:';
const SEPARATEUR = '::';

export type Route =
  | { type: 'intention'; intention: Intention; decision: DecisionJev }
  | { type: 'clarifier'; contenu: string; components: Component[]; decision: DecisionJev }
  | { type: 'habituel'; decision: DecisionJev | null };

export function decider(decision: DecisionJev | null, message: string): Route {
  if (!decision?.choix) return { type: 'habituel', decision };
  if (decision.confiance >= env.JEV_SEUIL) return { type: 'intention', intention: decision.choix, decision };

  // Les pistes plausibles, de la plus probable à la moins probable.
  const pistes = (Object.entries(decision.probabilites) as Array<[Intention, number]>)
    .filter(([, p]) => p >= 0.15)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([i]) => i);
  if (!pistes.includes(decision.choix)) pistes.unshift(decision.choix);

  if (pistes.length < 2 || !pistes.some((i) => ACTIONS.has(i))) return { type: 'habituel', decision };

  const texte = message.trim().slice(0, 300);
  return {
    type: 'clarifier',
    decision,
    contenu: 'Je veux être sûr de bien vous comprendre. Vous voulez :',
    components: [quickReplies([
      ...pistes.slice(0, 3).map((i) => ({ label: LIBELLES[i], value: `${PREFIXE}${i}${SEPARATEUR}${texte}` })),
      // Aucune piste ne convient : le modèle reprend la phrase telle quelle.
      { label: 'Autre chose', value: `${PREFIXE}modele${SEPARATEUR}${texte}` },
    ])],
  };
}

/**
 * La tuile touchée : l'intention CHOISIE par le client et sa phrase d'origine.
 * `modele` : « Autre chose », le modèle traite la phrase sans aiguillage.
 */
export function intentionChoisie(
  interaction: { action: string; payload: Record<string, unknown> } | undefined,
): { intention: Intention | 'modele'; message: string } | null {
  if (interaction?.action !== 'quick_reply') return null;
  const valeur = String(interaction.payload.value ?? '');
  if (!valeur.startsWith(PREFIXE)) return null;
  const [cle, ...reste] = valeur.slice(PREFIXE.length).split(SEPARATEUR);
  const message = reste.join(SEPARATEUR).trim();
  if (!message) return null;
  if (cle === 'modele') return { intention: 'modele', message };
  return cle && cle in INTENTIONS ? { intention: cle as Intention, message } : null;
}

/**
 * Indication donnée au modèle quand la route est connue, ou `null`.
 *
 * Jamais pour la recherche ni la boutique : la recherche catalogue lit le
 * MÊME message, et cherchait « riz aiguillage client plat précis… ».
 */
export function indication(intention: Intention): string | null {
  if (intention === 'recherche' || intention === 'boutique') return null;
  return `[Aiguillage : le client ${INTENTIONS[intention].charAt(0).toLowerCase()}${INTENTIONS[intention].slice(1)}.]`;
}
