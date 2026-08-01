import { Queue, Worker, type JobsOptions, type Processor } from 'bullmq';
import IORedis from 'ioredis';
import { env } from '../config/env.js';

/**
 * File de traitement — avec dégradation assumée.
 *
 * En production, Railway fournit un Redis et les jobs passent par BullMQ :
 * réessais, temporisation, traçabilité. En développement, personne n'a
 * envie de faire tourner un Redis pour tester une commande — les jobs
 * s'exécutent alors immédiatement, en direct.
 *
 * Le mode dégradé n'est pas un mode de production : il perd les réessais et
 * bloque l'appelant. C'est acceptable pour développer, pas pour livrer, d'où
 * l'avertissement au démarrage.
 */

let connexion: IORedis | null = null;
let redisHorsService = false;

function redis(): IORedis | null {
  if (!env.REDIS_URL || redisHorsService) return null;
  if (connexion) return connexion;

  try {
    connexion = construireConnexion(env.REDIS_URL);
  } catch (cause) {
    // Une URL malformée ne doit PAS faire tomber le serveur. Le dispatch est
    // une commodité : sans lui l'API continue de servir, en mode direct.
    // L'inverse — une variable mal collée qui met l'API à terre en boucle —
    // est un défaut de robustesse, pas une protection.
    redisHorsService = true;
    // eslint-disable-next-line no-console
    console.error(
      '[queue] REDIS_URL inexploitable, dispatch en mode direct :',
      cause instanceof Error ? cause.message : cause,
    );
    return null;
  }

  return connexion;
}

function construireConnexion(url: string): IORedis {
  return new IORedis(url, {
    maxRetriesPerRequest: null,
    enableReadyCheck: false,
    // Sans ces deux réglages, un Redis injoignable fait attendre l'appelant
    // indéfiniment au lieu d'échouer vite. Un dispatch qui rate doit rater
    // franchement : la commande, elle, est déjà enregistrée.
    connectTimeout: 5000,
    enableOfflineQueue: false,
    // Le réseau privé de Railway (*.railway.internal) est en IPv6 seul.
    // Par défaut Node résout en IPv4 et la connexion échoue par
    // ENOTFOUND — symptôme classique et déroutant, puisque l'URL est
    // correcte. `family: 0` laisse Node choisir la famille disponible.
    family: 0,
  }).on('error', () => {
    // Les erreurs de connexion sont récurrentes par nature ; les laisser
    // remonter en `unhandled error` ferait tomber le process.
  });
}

export const queuesEnabled = Boolean(env.REDIS_URL);

const queues = new Map<string, Queue>();

export function getQueue(name: string): Queue | null {
  const connection = redis();
  if (!connection) return null;

  let queue = queues.get(name);
  if (!queue) {
    queue = new Queue(name, { connection });
    queues.set(name, queue);
  }
  return queue;
}

/**
 * Registre des exécuteurs, pour que le mode dégradé sache quoi appeler
 * quand il n'y a pas de file.
 */
const executeurs = new Map<string, Processor>();

/** Déclare l'exécuteur, sans ouvrir de connexion. */
export function registerProcessor(name: string, processor: Processor): void {
  executeurs.set(name, processor);
}

/** Démarre un worker BullMQ. Sans Redis, ne fait rien. */
export function startWorker(name: string, processor: Processor): Worker | null {
  registerProcessor(name, processor);

  const connection = redis();
  if (!connection) return null;

  const worker = new Worker(name, processor, { connection, concurrency: 4 });
  worker.on('failed', (job, cause) => {
    // eslint-disable-next-line no-console
    console.error(`[queue:${name}] job ${job?.id ?? '?'} échoué`, cause?.message);
  });
  return worker;
}

export async function enqueue(
  name: string,
  data: unknown,
  options?: JobsOptions,
): Promise<void> {
  const queue = getQueue(name);

  if (queue) {
    await queue.add(name, data, {
      attempts: 3,
      backoff: { type: 'exponential', delay: 2000 },
      removeOnComplete: 100,
      removeOnFail: 500,
      ...options,
    });
    return;
  }

  const executeur = executeurs.get(name);
  if (!executeur) return;

  // Mode dégradé : exécution immédiate. Une erreur ici ne doit pas faire
  // échouer la requête HTTP qui a déclenché le job — une commande créée
  // reste créée même si sa notification échoue.
  try {
    await executeur({ data } as never, '' as never);
  } catch {
    // Journalisé par l'exécuteur lui-même.
  }
}

export async function closeQueues(): Promise<void> {
  for (const queue of queues.values()) await queue.close();
  queues.clear();
  await connexion?.quit();
  connexion = null;
}
