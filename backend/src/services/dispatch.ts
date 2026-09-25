import { serviceClient } from './supabase.js';
import { sendPush, type PushMessage } from './notifications.js';
import { enqueue, registerProcessor, startWorker } from './queue.js';

/**
 * Attribution des courses.
 *
 * Le principe est le « premier arrivé, premier servi » : on notifie les N
 * livreurs les plus proches en même temps, et le premier qui accepte gagne.
 * L'atomicité est garantie par `accept_order()` en base — deux acceptations
 * simultanées ne peuvent pas produire deux gagnants, c'est vérifié par les
 * tests RLS.
 *
 * On ne réserve pas la course à un seul livreur : sur un réseau où l'app
 * peut être en veille ou hors couverture, attendre la réponse d'un livreur
 * unique ferait attendre le client pour rien.
 *
 * Ce module utilise `serviceClient()` — et c'est l'un des rares endroits où
 * c'est légitime : il n'y a pas d'utilisateur derrière un job de dispatch.
 */

export const DISPATCH_QUEUE = 'dispatch';

export interface DispatchJob {
  orderId: string;
  /** Nombre de tentatives déjà effectuées, pour la relance. */
  round?: number;
}

interface Candidat {
  driver_id: string;
  full_name: string | null;
  fcm_token: string | null;
  distance_m: number | null;
}

export interface DispatchOutcome {
  orderId: string;
  candidates: number;
  notified: number;
  reason?: 'already_assigned' | 'no_candidates' | 'not_ready';
}

export async function dispatchOrder(job: DispatchJob): Promise<DispatchOutcome> {
  const db = serviceClient();

  const { data: order } = await db
    .from('orders')
    .select('id, status, driver_id, type, total, dropoff_hint, zone_id')
    .eq('id', job.orderId)
    .maybeSingle();

  if (!order) return { orderId: job.orderId, candidates: 0, notified: 0, reason: 'not_ready' };

  // Un livreur a pu accepter entre la mise en file et l'exécution.
  if (order.driver_id) {
    return { orderId: job.orderId, candidates: 0, notified: 0, reason: 'already_assigned' };
  }
  if (order.status !== 'ready') {
    return { orderId: job.orderId, candidates: 0, notified: 0, reason: 'not_ready' };
  }

  const { data, error } = await db.rpc('dispatch_candidates', { p_order_id: job.orderId });
  if (error) throw error;

  const candidats = (data ?? []) as Candidat[];

  // PERSONNE À PROXIMITÉ CONNUE : on prévient quand même les livreurs en
  // ligne de la zone. `dispatch_candidates` exige une position fraîche de
  // moins de deux minutes ; un livreur à l'écran d'accueil, app en veille,
  // n'en envoie plus — et les colis ne prévenaient alors PERSONNE, alors que
  // les commandes de boutique (autre chemin) arrivaient bien.
  let ids = candidats.map((c) => c.driver_id);
  if (ids.length === 0) {
    const { data: profils } = await db
      .from('driver_profiles')
      .select('id, zone_id')
      .eq('is_online', true)
      .eq('is_available', true);
    ids = (profils ?? [])
      .filter((p) => p.zone_id == null || order.zone_id == null || p.zone_id === order.zone_id)
      .map((p) => p.id as string);
  }
  if (ids.length === 0) {
    return { orderId: job.orderId, candidates: 0, notified: 0, reason: 'no_candidates' };
  }

  // LES JETONS VIVENT DANS push_tokens. L'ancienne colonne
  // driver_profiles.fcm_token n'est plus remplie : s'y fier seule faisait
  // partir zéro notification. On garde les deux, sans doublon.
  const { data: lignes } = await db
    .from('push_tokens')
    .select('token')
    .eq('app', 'driver')
    .in('user_id', ids)
    .gt('last_seen_at', new Date(Date.now() - 60 * 24 * 60 * 60_000).toISOString());
  const jetons = [...new Set([
    ...candidats.map((c) => c.fcm_token).filter((t): t is string => Boolean(t)),
    ...(lignes ?? []).map((l) => l.token as string),
  ])];

  const colis = order.type === 'courier';
  const messages: PushMessage[] = jetons.map((token) => ({
    token,
    title: colis ? 'Nouvelle course de colis' : 'Nouvelle livraison',
    body: colis ? `Un client demande un livreur · ${order.total} F` : `${order.dropoff_hint} · ${order.total} F`,
    data: { order_id: order.id as string, kind: 'dispatch' },
  }));

  const resultat = await sendPush(messages);

  // Un jeton mort fait échouer tous les envois suivants : on l'efface dès
  // que FCM nous signale qu'il ne vaut plus rien, aux deux endroits.
  if (resultat.invalidTokens.length > 0) {
    await db
      .from('driver_profiles')
      .update({ fcm_token: null })
      .in('fcm_token', resultat.invalidTokens);
    await db.from('push_tokens').delete().in('token', resultat.invalidTokens);
  }

  return {
    orderId: job.orderId,
    candidates: ids.length,
    notified: resultat.sent,
  };
}

const processor = async (job: { data: unknown }): Promise<DispatchOutcome> =>
  dispatchOrder(job.data as DispatchJob);

/**
 * Déclare l'exécuteur sans ouvrir de connexion Redis.
 *
 * Appelé par `buildApp()`, y compris dans les tests : une instance de test ne
 * doit jamais tenter de joindre un Redis, sinon la suite pend sur des
 * reconnexions à un service absent.
 */
export function registerDispatchProcessor(): void {
  registerProcessor(DISPATCH_QUEUE, processor);
}

/**
 * Démarre le worker BullMQ. Réservé au vrai serveur (`index.ts`).
 * Sans Redis, ne fait rien : le mode dégradé passe par l'exécuteur
 * ci-dessus.
 */
export function startDispatchWorker(): void {
  startWorker(DISPATCH_QUEUE, processor);
}

/** Met une commande en file d'attribution. */
export function queueDispatch(orderId: string): Promise<void> {
  return enqueue(DISPATCH_QUEUE, { orderId, round: 0 } satisfies DispatchJob);
}
