import { serviceClient } from './supabase.js';
import { dispatchOrder } from './dispatch.js';
import { getQueue, registerProcessor, startWorker } from './queue.js';

/**
 * Filet de sécurité du dispatch.
 *
 * Le dispatch est déclenché par la route qui passe une commande à `ready`.
 * Ça couvre le cas normal, mais pas les autres :
 *
 *   - une écriture directe via PostgREST, que la RLS autorise au boutiquier
 *     et qui ne passe donc pas par notre route ;
 *   - un redémarrage du serveur entre la mise en file et l'exécution ;
 *   - un échec de notification alors qu'aucun livreur n'était en ligne, et
 *     qu'un livreur se connecte deux minutes plus tard.
 *
 * Dans les trois cas, une commande prête reste sans livreur et personne ne
 * s'en aperçoit — sauf le client qui attend. Ce balayage périodique rattrape
 * ces commandes orphelines.
 *
 * Il est idempotent : `dispatchOrder` vérifie que la commande est toujours
 * `ready` et sans livreur avant de notifier quoi que ce soit.
 */

export const SWEEP_QUEUE = 'dispatch-sweep';

/** Délai avant de considérer qu'une commande prête a été oubliée. */
const SEUIL_SECONDES = 90;

export interface SweepOutcome {
  examined: number;
  dispatched: number;
}

export async function sweepReadyOrders(): Promise<SweepOutcome> {
  const db = serviceClient();
  const seuil = new Date(Date.now() - SEUIL_SECONDES * 1000).toISOString();

  const { data, error } = await db
    .from('orders')
    .select('id, updated_at')
    .eq('status', 'ready')
    .is('driver_id', null)
    .lt('updated_at', seuil)
    .limit(20);

  if (error) throw error;

  const orphelines = data ?? [];
  let dispatched = 0;

  for (const commande of orphelines) {
    const resultat = await dispatchOrder({ orderId: commande.id as string });
    if (resultat.candidates > 0) dispatched++;
  }

  return { examined: orphelines.length, dispatched };
}

const processor = async (): Promise<SweepOutcome> => sweepReadyOrders();

export function registerSweepProcessor(): void {
  registerProcessor(SWEEP_QUEUE, processor);
}

/**
 * Démarre le balayage périodique. Sans Redis, il n'y a pas de job répétable
 * — le mode dégradé du développement s'en passe, et c'est acceptable : le
 * cas qu'on rattrape ici est un incident de production.
 */
export async function startSweep(): Promise<void> {
  startWorker(SWEEP_QUEUE, processor);

  const queue = getQueue(SWEEP_QUEUE);
  if (!queue) return;

  // `upsertJobScheduler` et non `add({ repeat })` : depuis BullMQ 5, les
  // jobs répétables passent par un planificateur nommé. L'identifiant fixe
  // garantit que redémarrer le serveur remplace le planificateur au lieu
  // d'en empiler un second — sinon chaque déploiement doublerait la
  // fréquence du balayage.
  await queue.upsertJobScheduler(
    'sweep-recurrent',
    { every: 60_000 },
    {
      name: SWEEP_QUEUE,
      data: {},
      opts: { removeOnComplete: 20, removeOnFail: 50 },
    },
  );
}
