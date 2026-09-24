import { serviceClient } from './supabase.js';
import { sendPush, type PushMessage } from './notifications.js';
import { updateLiveActivities } from './liveActivities.js';

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

export interface ContexteCommande {
  statut: string;
  /** 'delivery' (un repas, des courses) ou 'courier' (un colis). */
  type: string;
  /** Colis : 'deposer' (on vient chez le client) ou 'recuperer'. */
  mode?: string | null;
  /** Prénom du livreur, s'il y en a un. */
  livreur?: string | null;
  boutique?: string | null;
  total?: number | null;
  especes?: boolean;
}

/**
 * Le message d'une étape, ou null si elle ne mérite pas d'interrompre.
 *
 * Un repas et un colis ne se racontent pas pareil. Avant, un client qui
 * envoyait un colis lisait « Votre commande va être récupérée », puis
 * « Bon appétit ! » à la livraison — et rien quand son colis était pris.
 */
export function messageClient(c: ContexteCommande): { titre: string; corps: string } | null {
  const qui = c.livreur?.trim() || 'Votre livreur';
  const paiement = c.especes && c.total ? ` Préparez ${c.total} F en espèces.` : '';

  if (c.type === 'courier') {
    const recuperer = c.mode === 'recuperer';
    switch (c.statut) {
      case 'assigned':
        return {
          titre: 'Livreur trouvé',
          corps: recuperer ? `${qui} part chercher votre colis.` : `${qui} arrive chez vous pour prendre le colis.`,
        };
      case 'picked_up':
        return {
          titre: 'Colis récupéré',
          corps: recuperer ? `${qui} a votre colis et vous l’apporte.${paiement}` : `${qui} a votre colis et part le livrer.`,
        };
      case 'delivered':
        return recuperer
          ? { titre: 'Colis reçu', corps: 'Votre colis vous a été remis. Merci d’avoir choisi Tovo.' }
          : { titre: 'Colis livré', corps: 'Votre colis est bien arrivé à destination.' };
      case 'cancelled':
        return { titre: 'Course annulée', corps: 'Votre demande de livreur a été annulée.' };
      // « En route » suit « récupéré » de quelques secondes : un seul message.
      default:
        return null;
    }
  }

  const chez = c.boutique?.trim();
  switch (c.statut) {
    case 'confirmed':
      return { titre: 'Commande acceptée', corps: chez ? `${chez} prépare votre commande.` : 'La boutique prépare votre commande.' };
    case 'assigned':
      return { titre: 'Un livreur est en route', corps: `${qui} va récupérer votre commande${chez ? ` chez ${chez}` : ''}.` };
    case 'delivering':
      return { titre: 'Votre commande arrive', corps: `${qui} est en route vers vous.${paiement}` };
    case 'delivered':
      return { titre: 'Bon appétit !', corps: 'Votre commande est arrivée. Dites-nous comment c’était.' };
    case 'cancelled':
      return { titre: 'Commande annulée', corps: 'Votre commande a été annulée.' };
    default:
      return null;
  }
}

/** Le prénom seul : « Moussa » plutôt que « Moussa Issoufou Mahamadou ». */
function prenom(nom: string | null | undefined): string | null {
  const t = (nom ?? '').trim();
  return t ? t.split(/\s+/)[0]! : null;
}

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
  const db = serviceClient();
  const { data: commande } = await db
    .from('orders')
    .select('id, user_id, total, payment_method, type, driver_id, merchants(name), courier_details(mode)')
    .eq('id', orderId)
    .maybeSingle();

  // Le livreur par son prénom : dans la Live Activity comme dans le message.
  let livreur: string | null = null;
  if (commande?.driver_id) {
    const { data: profil } = await db.from('profiles').select('full_name').eq('id', commande.driver_id).maybeSingle();
    livreur = prenom(profil?.full_name as string | null);
  }

  // La Live Activity d'abord : elle bouge même quand l'étape ne mérite pas
  // de notification (« en cuisine », « prête »).
  await updateLiveActivities(orderId, statut, livreur).catch(() => undefined);
  if (!commande) return;

  const une = <T,>(v: T | T[] | null | undefined): T | null => (Array.isArray(v) ? v[0] ?? null : v ?? null);
  const modele = messageClient({
    statut,
    type: commande.type as string,
    mode: une(commande.courier_details as { mode: string } | { mode: string }[] | null)?.mode ?? null,
    livreur,
    boutique: une(commande.merchants as { name: string } | { name: string }[] | null)?.name ?? null,
    total: commande.total as number,
    especes: commande.payment_method === 'cash',
  });
  if (!modele) return;

  const tokens = await jetons(commande.user_id as string, 'client');
  if (tokens.length === 0) return;

  const messages: PushMessage[] = tokens.map((token) => ({
    token,
    title: modele.titre,
    body: modele.corps,
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
 * Prévient les livreurs qu'une commande vient d'entrer en préparation.
 *
 * Ce n'est pas encore un dispatch : aucun livreur ne peut l'accepter avant
 * le statut `ready`. L'objectif est de rendre la demande visible tout de
 * suite, y compris lorsque l'app livreur dort en arrière-plan.
 */
export async function notifierLivreursCommandeRecue(orderId: string): Promise<void> {
  const db = serviceClient();
  const { data: commande } = await db
    .from('orders')
    .select('id, zone_id, total, merchant_id, merchants(name)')
    .eq('id', orderId)
    .maybeSingle();

  if (!commande) return;

  const { data: profils } = await db
    .from('driver_profiles')
    .select('id, zone_id')
    .eq('is_online', true)
    .eq('is_available', true);

  const ids = (profils ?? [])
    .filter((profil) =>
      profil.zone_id == null || commande.zone_id == null || profil.zone_id === commande.zone_id)
    .map((profil) => profil.id as string);

  if (ids.length === 0) return;

  const { data: lignes } = await db
    .from('push_tokens')
    .select('token')
    .eq('app', 'driver')
    .in('user_id', ids)
    .gt('last_seen_at', new Date(Date.now() - 60 * 24 * 60 * 60_000).toISOString());

  const tokens = [...new Set((lignes ?? []).map((ligne) => ligne.token as string))];
  if (tokens.length === 0) return;

  const marchand = (commande.merchants as { name?: string } | null)?.name ?? 'une boutique';
  const resultat = await sendPush(tokens.map((token) => ({
    token,
    title: 'Commande à venir',
    body: `${marchand} · ${commande.total} F · en attente de confirmation`,
    data: { order_id: orderId, kind: 'incoming_order', status: 'pending' },
  })));

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
