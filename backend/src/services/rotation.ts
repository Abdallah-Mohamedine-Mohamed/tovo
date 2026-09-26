import type { FastifyRequest } from 'fastify';

/**
 * L'ordre des enseignes : une ROTATION PONDÉRÉE, ni figée ni au hasard.
 *
 * Toujours les mêmes boutiques en tête lassent, et les petites ne sont jamais
 * vues ; le pur hasard, lui, mettrait une boutique fermée ou lointaine en
 * premier et empêcherait le client de retrouver la sienne (décidé avec le
 * client, 26/09). Donc :
 *
 *   1. les boutiques OUVERTES d'abord, toujours ;
 *   2. parmi elles, un tirage pondéré : plus une boutique est commandée
 *      (30 derniers jours), plus elle a de chances d'être haut — sans y être
 *      abonnée ; une boutique nouvelle (moins de 21 jours) reçoit un coup de
 *      pouce ; une boutique proche (quand la position est connue) aussi ;
 *   3. le MÊME ordre toute la journée pour un même client (graine = jour +
 *      client) : il retrouve ses repères, et l'ordre change le lendemain.
 *
 * Tirage pondéré d'Efraimidis–Spirakis : clé = u^(1/poids), triée décroissante.
 */

export interface EnseigneAClasser {
  id: string;
  is_open: boolean;
  distance_m?: number | null;
  created_at?: string | null;
}

export interface OptionsRotation {
  /** Commandes récentes par boutique (services/popularite.ts). */
  commandes: Map<string, number>;
  /** Graine du jour : même ordre toute la journée pour ce client. */
  graine: string;
  maintenant?: Date;
}

const NOUVELLE_JOURS = 21;

/** Hachage FNV-1a 32 bits, puis un nombre dans ]0, 1[. */
function aleaStable(texte: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < texte.length; i++) {
    h ^= texte.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  // Un peu de brassage en plus : deux graines voisines ne donnent pas deux
  // valeurs voisines.
  h ^= h >>> 16;
  h = Math.imul(h, 0x45d9f3b) >>> 0;
  h ^= h >>> 16;
  return (h + 1) / 4_294_967_297;
}

export function poidsEnseigne(e: EnseigneAClasser, commandes: Map<string, number>, maintenant: Date): number {
  let poids = 1 + Math.log1p(commandes.get(e.id) ?? 0);
  const creee = e.created_at ? Date.parse(e.created_at) : NaN;
  if (!Number.isNaN(creee) && maintenant.getTime() - creee < NOUVELLE_JOURS * 86_400_000) poids *= 1.6;
  if (typeof e.distance_m === 'number') poids /= 1 + e.distance_m / 2_000;
  return poids;
}

export function rotationPonderee<T extends EnseigneAClasser>(enseignes: T[], options: OptionsRotation): T[] {
  const maintenant = options.maintenant ?? new Date();
  const cle = (e: T) => Math.pow(aleaStable(`${options.graine}:${e.id}`), 1 / poidsEnseigne(e, options.commandes, maintenant));
  const cles = new Map(enseignes.map((e) => [e.id, cle(e)]));
  return [...enseignes].sort((a, b) =>
    Number(b.is_open) - Number(a.is_open) || cles.get(b.id)! - cles.get(a.id)!);
}

/**
 * La graine du jour pour cette requête : la date (heure de Niamey, UTC+1) et
 * le client s'il est connecté. Le jeton n'est lu que pour son identifiant, à
 * seule fin de varier l'ordre d'un client à l'autre — il n'autorise rien ici.
 */
export function graineDuJour(request: FastifyRequest, maintenant = new Date()): string {
  const jour = new Date(maintenant.getTime() + 3_600_000).toISOString().slice(0, 10);
  let client = '';
  const entete = request.headers.authorization;
  if (entete?.startsWith('Bearer ')) {
    try {
      const charge = entete.slice(7).split('.')[1] ?? '';
      client = String((JSON.parse(Buffer.from(charge, 'base64url').toString('utf8')) as { sub?: string }).sub ?? '');
    } catch {
      client = '';
    }
  }
  return `${jour}:${client}`;
}
