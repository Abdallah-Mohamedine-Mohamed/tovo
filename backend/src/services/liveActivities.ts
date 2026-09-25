import { getMessaging } from 'firebase-admin/messaging';
import { serviceClient } from './supabase.js';
import { firebaseApp } from './notifications.js';
import { estimerArrivee } from './arrivee.js';

const terminal = new Set(['delivered', 'cancelled']);

/** Ce que l'étape dit au client, quand elle mérite d'être dite. */
export type AlerteEtape = { titre: string; corps: string };

/**
 * Met à jour la Live Activity du client (écran verrouillé, Dynamic Island).
 *
 * `content-state` doit correspondre à TovoOrderAttributes.ContentState côté
 * iOS : { status, driver, arrivee }. `driver` et `arrivee` (heure d'arrivée,
 * en secondes depuis 1970) sont facultatifs des deux côtés.
 *
 * AVEC UNE ALERTE, l'étape se voit : sur un iPhone à Dynamic Island, l'île
 * s'ouvre en grand avec la phrase de l'étape ; sur les autres, la Live
 * Activity s'affiche en bannière. C'est iOS qui choisit selon le téléphone.
 * Sans alerte, la mise à jour reste silencieuse.
 *
 * Renvoie les appareils (jetons FCM) qui ont reçu la mise à jour : ceux-là
 * n'ont pas besoin, en plus, d'une notification classique — les deux à la
 * fois se marchaient dessus sur l'île (retour du client, 25/09).
 */
export async function updateLiveActivities(
  orderId: string,
  status: string,
  driver: string | null = null,
  alerte: AlerteEtape | null = null,
): Promise<Set<string>> {
  const servis = new Set<string>();
  const db = serviceClient();
  const { data: activities, error } = await db
    .from('order_live_activities')
    .select('activity_token, fcm_token')
    .eq('order_id', orderId);
  if (error || !activities?.length) return servis;

  const app = firebaseApp();
  if (!app) return servis;

  const now = Math.floor(Date.now() / 1000);
  const ended = terminal.has(status);
  // Un livreur en route : l'heure d'arrivée, recalculée à chaque étape.
  // Une estimation impossible ne doit jamais empêcher la mise à jour.
  const arrivee = ended ? null : await estimerArrivee(db, orderId, status).catch(() => null);
  const responses = await getMessaging(app).sendEach(activities.map((activity) => ({
    token: activity.fcm_token as string,
    apns: {
      liveActivityToken: activity.activity_token as string,
      headers: { 'apns-priority': '10' },
      payload: {
        aps: {
          timestamp: now,
          event: ended ? 'end' : 'update',
          'content-state': { status, ...(driver ? { driver } : {}), ...(arrivee ? { arrivee } : {}) },
          ...(alerte ? { alert: { title: alerte.titre, body: alerte.corps }, sound: 'default' } : {}),
          ...(ended ? { 'dismissal-date': now + 60 } : {}),
        },
      },
    },
  })));

  activities.forEach((activity, index) => {
    if (responses.responses[index]?.success) servis.add(activity.fcm_token as string);
  });

  const expired = activities.filter((_, index) => {
    const response = responses.responses[index];
    return (ended && response?.success) ||
      response?.error?.code === 'messaging/registration-token-not-registered' ||
      response?.error?.code === 'messaging/invalid-registration-token';
  }).map((activity) => activity.activity_token as string);
  if (expired.length) {
    await db.from('order_live_activities').delete().in('activity_token', expired);
  }
  return servis;
}
