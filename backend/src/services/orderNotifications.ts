import { serviceClient } from './supabase.js';
import { sendPush, type PushMessage } from './notifications.js';

/**
 * Notifications liées au cycle d'une commande.
 *
 * Le principe qui décide de tout ici : **on ne notifie que ce sur quoi le
 * destinataire peut agir, ou ce qu'il attend vraiment.**
 *
 * Un client se moque que sa commande soit passée de « confirmée » à « en
 * préparation » — il vient de la passer, il sait qu'elle est en cours. Il
 * veut savoir quand un livreur part avec, et quand c'est arrivé. Notifier
 * chaque étape apprend à l'utilisateur à ignorer les notifications, et le
 * jour où l'une compte vraiment, il ne la lit plus.
 *
 * Ce module utilise `serviceClient()` : il n'y a pas d'utilisateur derrière
 * une notification, et il doit lire les jetons de quelqu'un d'autre.
 */

/** Étapes qui méritent d'interrompre le client. */
const MESSAGES_CLIENT: Record<string, { titre: string; corps: string }> = {
  confirmed: {
    titre: 'Commande acceptée',
    corps: 'La boutique prépare votre commande.',
  },
  assigned: {
    titre: 'Un livreur arrive',
    corps: 'Votre commande va être récupérée.',
  },
  delivering: {
    titre: 'En route vers vous',
    corps: 'Votre livreur est parti. Tenez le paiement prêt.',
  },
  delivered: {
    titre: 'Commande livrée',
    corps: 'Bon appétit ! Donnez-nous votre avis.',
  },
  cancelled: {
    titre: 'Commande annulée',
    corps: 'Votre commande a été annulée.',
  },
};

async function jetons(userId: string, app: 'client' | 'driver' | 'merchant') {
  const { data } = await serviceClient().rpc('tokens_for', {
    p_user_id: userId,
    p_app: app,
  });
  return ((data ?? []) as Array<{ token: string }>).map((t) => t.token);
}

/** Supprime les jetons que FCM vient de déclarer morts. */
async function purger(invalides: string[]): Promise<void> {
  if (invalides.length === 0) return;
  await serviceClient().from('push_tokens').delete().in('token', invalides);
}

/**
 * Prévient le client d'un changement d'état de sa commande.
 *
 * Silencieux si l'étape ne le concerne pas — voir la liste ci-dessus.
 */
export async function notifierClient(orderId: string, statut: string): Promise<void> {
  const modele = MESSAGES_CLIENT[statut];
  if (!modele) return;

  const db = serviceClient();
  const { data: commande } = await db
    .from('orders')
    .select('id, user_id, total, payment_method')
    .eq('id', orderId)
    .maybeSingle();

  if (!commande) return;

  const tokens = await jetons(commande.user_id as string, 'client');
  if (tokens.length === 0) return;

  // Le montant à préparer, au moment où il devient utile : quand le livreur
  // est en route et que le client paiera en espèces.
  const corps =
    statut === 'delivering' && commande.payment_method === 'cash'
      ? `Votre livreur arrive. Préparez ${commande.total} F en espèces.`
      : modele.corps;

  const messages: PushMessage[] = tokens.map((token) => ({
    token,
    title: modele.titre,
    body: corps,
    data: { order_id: orderId, kind: 'order_status', status: statut },
  }));

  const resultat = await sendPush(messages);
  await purger(resultat.invalidTokens);
}

/**
 * Prévient le boutiquier qu'une commande vient d'arriver.
 *
 * C'est la notification la plus critique du système : tant qu'il ne l'a pas
 * vue, rien n'avance et le client attend devant un écran qui dit « en
 * attente de confirmation ».
 */
export async function notifierBoutique(orderId: string): Promise<void> {
  const db = serviceClient();

  const { data: commande } = await db
    .from('orders')
    .select('id, total, merchant_id, merchants(owner_id, name)')
    .eq('id', orderId)
    .maybeSingle();

  const proprietaire = (commande?.merchants as { owner_id?: string } | null)?.owner_id;
  if (!proprietaire) return;

  const tokens = await jetons(proprietaire, 'merchant');
  if (tokens.length === 0) return;

  const resultat = await sendPush(
    tokens.map((token) => ({
      token,
      title: 'Nouvelle commande',
      body: `${commande!.total} F — à confirmer`,
      data: { order_id: orderId, kind: 'new_order' },
    })),
  );

  await purger(resultat.invalidTokens);
}

/**
 * Prévient le livreur qu'il vient de recevoir une course assignée à la main
 * par l'admin. Distinct du dispatch : ici la course lui est attribuée, il
 * n'a pas à courir pour l'obtenir.
 */
export async function notifierLivreurAssigne(
  orderId: string,
  driverId: string,
): Promise<void> {
  const db = serviceClient();
  const { data: commande } = await db
    .from('orders')
    .select('total, dropoff_hint')
    .eq('id', orderId)
    .maybeSingle();

  if (!commande) return;

  const tokens = await jetons(driverId, 'driver');
  if (tokens.length === 0) return;

  const resultat = await sendPush(
    tokens.map((token) => ({
      token,
      title: 'Course qui vous est attribuée',
      body: `${commande.dropoff_hint} · ${commande.total} F`,
      data: { order_id: orderId, kind: 'assigned' },
    })),
  );

  await purger(resultat.invalidTokens);
}
