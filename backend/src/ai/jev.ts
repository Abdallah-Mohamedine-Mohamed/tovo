import type { FastifyBaseLogger } from 'fastify';
import { env } from '../config/env.js';

/**
 * Jev (TypeSafe), un modèle qui ne rédige rien : il choisit une option parmi
 * une liste et dit à quel point il en est sûr.
 *
 * Candidat pour remplacer les détecteurs à mots (intents.ts), qui servent
 * une mauvaise réponse avec assurance dès qu'une phrase sort de leurs
 * listes. Banc d'essai : scripts/jev/banc.ts.
 *
 * Pour l'instant en MODE OMBRE seulement : consulté en arrière-plan, sa
 * décision est journalisée à côté de ce que Tovo a réellement fait, et
 * n'influence rien.
 */

export const INTENTIONS = {
  recherche: 'Cherche un produit ou un plat précis (riz, tacos, Coca, pizza, pain…)',
  envie: 'Exprime une envie ou un besoin général, sans produit précis (manger, faire les courses, une idée, un bon restaurant)',
  boutique: 'Veut voir une boutique ou un restaurant précis, nommé (sa carte, ses produits, s’il est ouvert)',
  livreur: 'Demande qu’un livreur ou un coursier vienne le voir, sans commande de boutique',
  colis: 'Veut envoyer ou faire livrer un colis, un paquet ou un document à quelqu’un',
  designe: 'Désigne un article qu’on vient de lui montrer (le deuxième, celui-là, ajoute-le, le moins cher)',
  habitude: 'Veut refaire une commande passée (comme d’habitude, la même chose que la dernière fois)',
  suivi: 'Demande où en est sa commande en cours ou son livreur actuel',
  annuler: 'Veut annuler sa commande',
  social: 'Salutation, remerciement, plainte ou bavardage, sans demande',
} as const;

export type Intention = keyof typeof INTENTIONS;

const CONSIGNE =
  'Message d’un client à Tovo, une application de livraison à Niamey (Niger) : ' +
  'repas, courses et colis. Que veut-il faire ?';

export interface DecisionJev {
  choix: Intention | null;
  confiance: number;
  /** Probabilité de CHAQUE intention : de quoi proposer les 2-3 plus plausibles. */
  probabilites: Partial<Record<Intention, number>>;
  ms: number;
  cout: number;
  erreur?: string;
}

export async function classerIntention(
  message: string,
  options: { cle: string; modele: string; url?: string; delaiMs?: number },
): Promise<DecisionJev> {
  const debut = performance.now();
  try {
    const res = await fetch(options.url ?? 'https://openrouter.ai/api/alpha/decisions', {
      method: 'POST',
      headers: { authorization: `Bearer ${options.cle}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        model: options.modele,
        state: { message },
        questions: { intention: { type: 'choice', instructions: CONSIGNE, criteria: INTENTIONS } },
      }),
      signal: AbortSignal.timeout(options.delaiMs ?? 10_000),
    });
    const ms = performance.now() - debut;
    const corps = (await res.json()) as {
      answers?: { intention?: { choice?: string; confidence?: number; probabilities?: Record<string, number> } };
      usage?: { cost?: number };
      error?: { message?: string };
    };
    if (!res.ok) {
      return { choix: null, confiance: 0, probabilites: {}, ms, cout: 0, erreur: `${res.status} ${corps.error?.message ?? ''}`.trim() };
    }
    const reponse = corps.answers?.intention;
    const choix = reponse?.choice && reponse.choice in INTENTIONS ? (reponse.choice as Intention) : null;
    return {
      choix,
      confiance: reponse?.confidence ?? 0,
      probabilites: Object.fromEntries(
        Object.entries(reponse?.probabilities ?? {}).filter(([k, v]) => k in INTENTIONS && typeof v === 'number'),
      ) as Partial<Record<Intention, number>>,
      ms,
      cout: corps.usage?.cost ?? 0,
    };
  } catch (cause) {
    return { choix: null, confiance: 0, probabilites: {}, ms: performance.now() - debut, cout: 0, erreur: String(cause) };
  }
}

/**
 * Consulte Jev en arrière-plan et journalise sa décision. Ne lève jamais,
 * ne retarde rien : la réponse au client part sans l'attendre.
 *
 * Journal « ombre jev » : message, choix, confiance, latence mesurée DEPUIS
 * le serveur (Railway), coût. `ref` relie la ligne aux autres journaux du
 * même message (« livreur commandé sans formulaire », etc.).
 */
export function ombreJev(message: string, log: FastifyBaseLogger, ref: string): void {
  // Aiguillage actif : Jev est déjà consulté pour de vrai, inutile de payer
  // un second appel pour l'observer.
  if (env.JEV_AIGUILLAGE === '1') return;
  if (env.JEV_OMBRE !== '1' || !env.OPENROUTER_API_KEY || !message.trim()) return;
  void classerIntention(message, { cle: env.OPENROUTER_API_KEY, modele: env.JEV_MODEL, delaiMs: 5_000 })
    .then((d) => log.info({
      ref,
      message,
      jev: { choix: d.choix, confiance: Number(d.confiance.toFixed(2)), ms: Math.round(d.ms), cout: d.cout },
      ...(d.erreur ? { erreur: d.erreur } : {}),
    }, 'ombre jev'))
    .catch(() => undefined);
}
