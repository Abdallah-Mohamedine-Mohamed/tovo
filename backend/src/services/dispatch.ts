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
    .select('id, status, driver_id, type, total, dropoff_hint')
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
  if (candidats.length === 0) {
    return { orderId: job.orderId, candidates: 0, notified: 0, reason: 'no_candidates' };
  }

  const messages: PushMessage[] = candidats
    .filter((c) => c.fcm_token)
    .map((c) => ({
      token: c.fcm_token!,
      title: order.type === 'courier' ? 'Nouvelle course' : 'Nouvelle livraison',
      body: `${order.dropoff_hint} · ${order.total} F`,
      data: { order_id: order.id as string, kind: 'dispatch' },
    }));

  const resultat = await sendPush(messages);

  // Un jeton mort fait échouer tous les envois suivants : on l'efface dès
  // que FCM nous signale qu'il ne vaut plus rien.
  if (resultat.invalidTokens.length > 0) {
    await db
      .from('driver_profiles')
      .update({ fcm_token: null })
      .in('fcm_token', resultat.invalidTokens);
  }

  return {
    orderId: job.orderId,
    candidates: candidats.length,
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
