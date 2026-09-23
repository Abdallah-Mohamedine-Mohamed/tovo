import { redisConnexion } from './queue.js';

/**
 * Limite de débit par utilisateur.
 *
 * Chaque message envoyé à `/chat` peut coûter un appel au modèle, chaque
 * enregistrement vocal une transcription. Sans plafond, un seul compte — ou
 * un jeton volé rejoué en boucle — pouvait vider le budget Gemini en une nuit,
 * et personne ne l'aurait vu avant la facture.
 *
 * Deux fenêtres par action :
 *   - à la minute, contre la rafale (script, bouton coincé) ;
 *   - à la journée, contre l'abus lent qui reste sous la première.
 * Les plafonds sont larges pour un humain : une commande complète, c'est une
 * vingtaine de messages, et taper vite les catégories ne doit jamais bloquer.
 *
 * Compteurs à fenêtre fixe dans Redis, partagés entre instances. Sans Redis
 * (développement, ou Redis en panne), repli sur une mémoire locale : la
 * protection devient par instance, mais elle ne disparaît pas.
 */

export interface Fenetre {
  /** Durée de la fenêtre, en secondes. */
  secondes: number;
  /** Nombre d'appels autorisés dans la fenêtre. */
  max: number;
}

export const LIMITES = {
  chat: [
    { secondes: 60, max: 30 },
    { secondes: 86_400, max: 400 },
  ],
  transcription: [
    { secondes: 60, max: 12 },
    { secondes: 86_400, max: 150 },
  ],
} satisfies Record<string, Fenetre[]>;

export type Verdict = { ok: true } | { ok: false; reessayerDans: number };

// ---------------------------------------------------------------------------
// Repli mémoire
// ---------------------------------------------------------------------------

const memoire = new Map<string, { compte: number; expire: number }>();

function incrementerEnMemoire(cle: string, secondes: number, maintenant: number): number {
  // Ménage paresseux : sans lui, un serveur qui tourne des semaines garderait
  // une entrée par utilisateur et par fenêtre écoulée.
  if (memoire.size > 10_000) {
    for (const [k, v] of memoire) if (v.expire <= maintenant) memoire.delete(k);
  }
  const entree = memoire.get(cle);
  if (!entree || entree.expire <= maintenant) {
    memoire.set(cle, { compte: 1, expire: maintenant + secondes * 1000 });
    return 1;
  }
  entree.compte += 1;
  return entree.compte;
}

/** Réservé aux tests : repart d'une mémoire vide. */
export function viderMemoireLimites(): void {
  memoire.clear();
}

// ---------------------------------------------------------------------------
// Décompte
// ---------------------------------------------------------------------------

/**
 * Attente maximale d'une réponse de Redis.
 *
 * La limite est sur le chemin de CHAQUE message et de chaque vocal. Une
 * connexion morte en silence (Railway coupe les sockets inactives) garde les
 * commandes en suspens jusqu'à la reconnexion : en production, des vocaux ont
 * attendu une minute pour une transcription d'une seconde, et l'app affichait
 * « Connexion perdue ». Mieux vaut compter en mémoire un instant que bloquer.
 */
const DELAI_REDIS_MS = 250;

function avecDelai<T>(promesse: Promise<T>, ms: number): Promise<T> {
  let minuterie: NodeJS.Timeout | undefined;
  const delai = new Promise<never>((_, rejeter) => {
    minuterie = setTimeout(() => rejeter(new Error('redis trop lent')), ms);
  });
  return Promise.race([promesse, delai]).finally(() => clearTimeout(minuterie));
}

async function incrementer(cles: string[], fenetres: Fenetre[], maintenant: number): Promise<number[]> {
  const redis = redisConnexion();
  // Hors « ready » (connexion en cours, reconnexion), inutile d'essayer.
  if (redis && redis.status === 'ready') {
    try {
      const transaction = redis.multi();
      cles.forEach((cle, i) => {
        transaction.incr(cle);
        // Marge de quelques secondes : la clé porte déjà le numéro de fenêtre,
        // l'expiration ne sert qu'à faire le ménage.
        transaction.expire(cle, fenetres[i]!.secondes + 5);
      });
      const exec = transaction.exec();
      // Si le délai l'emporte, la réponse tardive ne doit pas devenir une
      // erreur non gérée qui ferait tomber le processus.
      exec.catch(() => undefined);
      const resultats = await avecDelai(exec, DELAI_REDIS_MS);
      if (resultats) {
        const comptes = cles.map((_, i) => {
          const [erreur, valeur] = resultats[i * 2] ?? [];
          return erreur ? Number.NaN : Number(valeur);
        });
        if (comptes.every(Number.isFinite)) return comptes;
      }
    } catch {
      // Redis injoignable : on bascule sur la mémoire plutôt que de laisser
      // passer sans limite ou de refuser tout le monde.
    }
  }
  return cles.map((cle, i) => incrementerEnMemoire(cle, fenetres[i]!.secondes, maintenant));
}

/**
 * Compte un appel de `utilisateur` pour `action` et dit s'il passe.
 *
 * Un appel refusé est compté aussi : marteler le bouton ne raccourcit pas
 * l'attente, sinon l'attente ne servirait à rien.
 */
export async function consommer(
  action: keyof typeof LIMITES,
  utilisateur: string,
  maintenant: number = Date.now(),
): Promise<Verdict> {
  const fenetres = LIMITES[action];
  const cles = fenetres.map((f) => {
    const numero = Math.floor(maintenant / (f.secondes * 1000));
    return `limite:${action}:${f.secondes}:${utilisateur}:${numero}`;
  });

  const comptes = await incrementer(cles, fenetres, maintenant);

  let reessayerDans = 0;
  fenetres.forEach((f, i) => {
    if (comptes[i]! > f.max) {
      const fin = (Math.floor(maintenant / (f.secondes * 1000)) + 1) * f.secondes * 1000;
      reessayerDans = Math.max(reessayerDans, Math.ceil((fin - maintenant) / 1000));
    }
  });

  return reessayerDans > 0 ? { ok: false, reessayerDans } : { ok: true };
}

/** Message pour le client, selon l'attente restante. */
export function messageLimite(reessayerDans: number): string {
  if (reessayerDans <= 90) {
    return 'Vous envoyez beaucoup de messages d’un coup. Patientez une minute, puis reprenez.';
  }
  return 'Vous avez atteint la limite de messages pour aujourd’hui. Vous pourrez reprendre demain ; vos commandes en cours restent suivies normalement.';
}
