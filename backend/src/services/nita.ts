import { env } from '../config/env.js';

/**
 * Client de l'API de paiement Nita.
 *
 * Nita n'est pas un débit instantané. On crée un « achat en ligne », Nita
 * renvoie un code, et c'est le CLIENT qui va payer ce code au guichet Nita ou
 * depuis MYNITA. Rien n'est prélevé au moment de la commande : tant que le
 * paiement n'est pas constaté, la commande ne doit pas partir en cuisine.
 *
 * Deux écarts entre la documentation et l'API réelle, vérifiés contre le
 * service en ligne :
 *
 *  - la réponse de création ne contient pas `referenceAchat` comme l'annonce
 *    le texte, mais `codeAchat` ;
 *  - l'enveloppe `status` change de casse selon l'endpoint (« success » à
 *    l'authentification, « Success » ailleurs). On compare donc sans tenir
 *    compte de la casse : lire un paiement réussi comme un échec laisserait
 *    un client débité avec une commande annulée.
 */

const CHEMIN_AUTH = '/api/authenticate';
const CHEMIN_CREER = '/api/nitaServices/achatEnLigne/saveAchatEnLigne';
const CHEMIN_STATUT = '/api/nitaServices/achatEnLigne/checkAchatStatus';
const CHEMIN_ANNULER = '/api/nitaServices/achatEnLigne/annulerAchat';

/** Codes de statut d'un achat, tels que Nita les renvoie (en chaîne). */
export const STATUT_ACHAT = {
  nonPaye: '0',
  paye: '1',
  annule: '2',
  bloque: '3',
} as const;

export type StatutAchat = (typeof STATUT_ACHAT)[keyof typeof STATUT_ACHAT];

export class NitaError extends Error {
  constructor(
    message: string,
    readonly statut: number,
    readonly renvoyable: boolean,
  ) {
    super(message);
    this.name = 'NitaError';
  }
}

interface Enveloppe<T> {
  status?: string;
  code?: number;
  message?: string;
  data?: T;
}

function reussi(corps: Enveloppe<unknown>): boolean {
  return (corps.status ?? '').toLowerCase() === 'success';
}

// ---------------------------------------------------------------------
// Jeton
// ---------------------------------------------------------------------

let jetonCourant: string | null = null;

/**
 * Jusqu'à quand ne pas retenter de s'authentifier.
 *
 * Nita compte les échecs et suspend le compte au bout de quelques-uns. Sans
 * ce repos, un mot de passe erroné dans la configuration provoque une
 * tentative à CHAQUE commande payée en mobile : quelques clients suffisent
 * à faire suspendre le compte, et il faut alors appeler Nita pour le
 * rouvrir.
 *
 * Vu en production : un mot de passe collé avec ses apostrophes sur Railway,
 * et chaque commande relançait l'échec.
 */
let reposApresRefus = 0;
const REPOS_MS = 600_000;

/**
 * Le jeton est mis en cache et renouvelé à la première requête refusée.
 *
 * Nita ne documente pas sa durée de validité et le corps du jeton n'est pas
 * à interpréter : plutôt que de deviner une expiration, on réessaie une fois
 * quand le service répond 401 ou 403. Un compteur de tentatives protège le
 * compte côté Nita — s'authentifier en boucle finirait par le suspendre.
 */
async function authentifier(): Promise<string> {
  if (Date.now() < reposApresRefus) {
    throw new NitaError(
      'Identifiants Nita refusés récemment : nouvelle tentative suspendue pour ' +
        'protéger le compte. Vérifiez NITA_USERNAME et NITA_PASSWORD.',
      401,
      false,
    );
  }

  const r = await fetch(`${env.NITA_BASE_URL}${CHEMIN_AUTH}`, {
    method: 'POST',
    headers: {
      'X-NT-API-KEY': env.NITA_API_KEY!,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({
      username: env.NITA_USERNAME,
      password: env.NITA_PASSWORD,
    }),
    signal: AbortSignal.timeout(20_000),
  });

  const corps = (await r.json().catch(() => ({}))) as Enveloppe<{ token?: string }>;

  // Un mot de passe refusé n'est pas à réessayer : chaque échec consomme une
  // tentative, et le compte est suspendu au bout de quelques-unes.
  //
  // Nita répond HTTP 200 même pour un refus — le verdict est dans `status`,
  // pas dans le code HTTP. Un `statut: 200` accompagné d'un refus est donc
  // la signature d'identifiants erronés, et non d'une panne.
  if (!reussi(corps) || !corps.data?.token) {
    reposApresRefus = Date.now() + REPOS_MS;
    throw new NitaError(
      `Authentification Nita refusée : ${corps.message ?? r.status}`,
      r.status,
      false,
    );
  }

  reposApresRefus = 0;
  jetonCourant = corps.data.token;
  return jetonCourant;
}

// ---------------------------------------------------------------------
// Appels
// ---------------------------------------------------------------------

async function appeler<T>(
  methode: 'POST' | 'PUT',
  chemin: string,
  corpsRequete: Record<string, unknown>,
  deuxiemeEssai = false,
): Promise<T> {
  const jeton = jetonCourant ?? (await authentifier());

  const r = await fetch(`${env.NITA_BASE_URL}${chemin}`, {
    method: methode,
    headers: {
      'X-NT-API-KEY': env.NITA_API_KEY!,
      Authorization: `Bearer ${jeton}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify(corpsRequete),
    signal: AbortSignal.timeout(20_000),
  });

  // Jeton expiré : on en reprend un et on rejoue, une seule fois.
  if ((r.status === 401 || r.status === 403) && !deuxiemeEssai) {
    jetonCourant = null;
    await authentifier();
    return appeler<T>(methode, chemin, corpsRequete, true);
  }

  const corps = (await r.json().catch(() => ({}))) as Enveloppe<T>;

  if (!r.ok || !reussi(corps)) {
    throw new NitaError(
      corps.message ?? `Nita a répondu ${r.status}`,
      r.status,
      r.status >= 500,
    );
  }
  if (corps.data === undefined) {
    throw new NitaError('Réponse Nita sans données', r.status, false);
  }

  return corps.data;
}

// ---------------------------------------------------------------------
// Opérations
// ---------------------------------------------------------------------

export interface DemandeAchat {
  /** Notre identifiant, unique côté Nita : l'identifiant de la commande. */
  requestId: string;
  montant: number;
  description: string[];
  motif: string;
  /** Téléphone du client, au format Nita : 00 + indicatif + numéro. */
  phoneClient: string;
  adresseIp: string;
  urlCallback?: string;
  lat?: string | undefined;
  lng?: string | undefined;
}

export interface AchatCree {
  codeAchat: string;
  montant: number;
}

/**
 * Convertit un téléphone au format attendu par Nita.
 *
 * Nita veut `0022786967908` : deux zéros, puis l'indicatif, puis le numéro.
 * Supabase Auth, lui, enregistre `22786967908` sans le « + ». On repart donc
 * des chiffres seuls, d'où qu'ils viennent.
 */
export function versTelephoneNita(telephone: string): string {
  const chiffres = telephone.replace(/\D/g, '');
  if (chiffres.length < 8) {
    throw new NitaError(`Numéro inexploitable pour Nita : ${telephone}`, 400, false);
  }
  // Numéro nigérien saisi sans indicatif.
  const international = chiffres.length === 8 ? `227${chiffres}` : chiffres;
  return `00${international}`;
}

export async function creerAchat(demande: DemandeAchat): Promise<AchatCree> {
  const data = await appeler<Record<string, unknown>>('POST', CHEMIN_CREER, {
    descriptionAchat: demande.description,
    montantTransaction: demande.montant,
    motifTransaction: demande.motif,
    requestId: demande.requestId,
    phoneClient: demande.phoneClient,
    adresseIp: demande.adresseIp,
    ...(demande.urlCallback ? { urlCallback: demande.urlCallback } : {}),
    ...(demande.lng ? { longTransaction: demande.lng } : {}),
    ...(demande.lat ? { latTransaction: demande.lat } : {}),
  });

  const codeAchat = data['codeAchat'];
  if (typeof codeAchat !== 'string' || codeAchat.length === 0) {
    throw new NitaError('Nita n’a pas renvoyé de code d’achat', 502, false);
  }

  return { codeAchat, montant: Number(data['montant'] ?? demande.montant) };
}

export interface StatutRetour {
  code: StatutAchat;
  codeAchat: string | null;
  description: string;
}

/**
 * Interroge Nita sur l'état d'un achat.
 *
 * C'est la source de vérité du paiement. Le callback de Nita n'est signé par
 * rien : quiconque connaîtrait l'URL pourrait déclarer une commande payée.
 * On ne s'en sert donc que comme d'un signal pour venir vérifier ici.
 */
export async function statutAchat(
  requestId: string,
  contexte: { adresseIp: string; lat?: string | undefined; lng?: string | undefined },
): Promise<StatutRetour> {
  const data = await appeler<Record<string, unknown>>('POST', CHEMIN_STATUT, {
    requestId,
    adresseIp: contexte.adresseIp,
    longTransaction: contexte.lng ?? '',
    latTransaction: contexte.lat ?? '',
  });

  return {
    code: String(data['code'] ?? '') as StatutAchat,
    codeAchat: typeof data['codeAchat'] === 'string' ? data['codeAchat'] : null,
    description: String(data['description'] ?? ''),
  };
}

export async function annulerAchat(
  codeAchat: string,
  requestId: string,
  contexte: { adresseIp: string },
): Promise<void> {
  await appeler('PUT', CHEMIN_ANNULER, {
    codeAchat,
    requestId,
    adresseIp: contexte.adresseIp,
    longTransaction: '',
    latTransaction: '',
  });
}

/** Pour les tests : repartir sans jeton en cache. */
export function reinitialiserJeton(): void {
  jetonCourant = null;
}
