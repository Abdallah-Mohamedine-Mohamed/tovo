import { cert, getApps, initializeApp, type App } from 'firebase-admin/app';
import { getMessaging } from 'firebase-admin/messaging';
import { env } from '../config/env.js';

/**
 * Notifications push (Firebase FCM).
 *
 * Le compte de service est fourni par la variable FCM_SERVICE_ACCOUNT_JSON,
 * acceptée sous deux formes : le JSON brut, ou le même JSON encodé en
 * base64. Le base64 évite les mésaventures de sauts de ligne et de
 * guillemets dans les interfaces de variables d'environnement — c'est la
 * forme recommandée.
 *
 * Sans identifiants, le module journalise au lieu d'envoyer et le dit
 * clairement. Un envoi silencieusement inopérant serait pire que rien : on
 * croirait le dispatch fonctionnel alors qu'aucun livreur ne reçoit son
 * signal.
 */

export interface PushMessage {
  token: string;
  title: string;
  body: string;
  data?: Record<string, string>;
}

export interface PushResult {
  sent: number;
  failed: number;
  /** Jetons rejetés par FCM : à effacer de la base, ils ne servent plus. */
  invalidTokens: string[];
  simulated: boolean;
}

function chargerCompteDeService(): Record<string, unknown> | null {
  const brut = env.FCM_SERVICE_ACCOUNT_JSON;
  if (!brut) return null;

  const texte = brut.trim().startsWith('{')
    ? brut
    : Buffer.from(brut, 'base64').toString('utf8');

  try {
    return JSON.parse(texte) as Record<string, unknown>;
  } catch {
    throw new Error(
      'FCM_SERVICE_ACCOUNT_JSON illisible : attendu le JSON du compte de service, ou ce JSON encodé en base64.',
    );
  }
}

let application: App | null = null;

export function firebaseApp(): App | null {
  if (application) return application;

  const compte = chargerCompteDeService();
  if (!compte) return null;

  application =
    getApps()[0] ??
    initializeApp({
      credential: cert({
        projectId: compte.project_id as string,
        clientEmail: compte.client_email as string,
        // Les sauts de ligne de la clé privée sont souvent échappés par les
        // interfaces de variables d'environnement. Sans cette réparation,
        // l'authentification échoue avec un message peu parlant.
        privateKey: (compte.private_key as string).replace(/\\n/g, '\n'),
      }),
    });

  return application;
}

export const pushEnabled = Boolean(env.FCM_SERVICE_ACCOUNT_JSON);

/**
 * État de la configuration FCM, pour l'annoncer au démarrage. Sans ce
 * retour, impossible de savoir si la variable d'environnement a été prise
 * en compte autrement qu'en provoquant un envoi réel.
 */
export function pushStatus(): { enabled: boolean; projectId?: string; error?: string } {
  if (!pushEnabled) return { enabled: false };
  try {
    const compte = chargerCompteDeService();
    const projectId = compte?.project_id as string | undefined;
    return projectId ? { enabled: true, projectId } : { enabled: false, error: 'project_id absent' };
  } catch (cause) {
    return { enabled: false, error: cause instanceof Error ? cause.message : 'illisible' };
  }
}

export async function sendPush(messages: PushMessage[]): Promise<PushResult> {
  const valides = messages.filter((m) => m.token.length > 0);

  const app = firebaseApp();
  if (!app || valides.length === 0) {
    for (const message of valides) {
      // eslint-disable-next-line no-console
      console.info(`[push simulé] ${message.title} — ${message.body}`);
    }
    return {
      sent: 0,
      failed: 0,
      invalidTokens: [],
      simulated: !app,
    };
  }

  const reponse = await getMessaging(app).sendEach(
    valides.map((message) => ({
      token: message.token,
      notification: { title: message.title, body: message.body },
      data: message.data ?? {},
      android: {
        priority: 'high' as const,
        // Une course expire vite : inutile de livrer une notification
        // vieille de dix minutes à un livreur qui rallume son téléphone.
        ttl: 5 * 60 * 1000,
      },
      apns: {
        headers: { 'apns-priority': '10' },
        payload: { aps: { sound: 'default' } },
      },
    })),
  );

  const invalides: string[] = [];
  reponse.responses.forEach((resultat, index) => {
    if (resultat.success) return;
    const code = (resultat.error as { code?: string } | undefined)?.code ?? '';
    // Ces deux codes signifient que le jeton est mort : l'app a été
    // désinstallée ou réinstallée. Le garder ferait échouer tous les envois
    // suivants.
    if (
      code === 'messaging/registration-token-not-registered' ||
      code === 'messaging/invalid-registration-token'
    ) {
      invalides.push(valides[index]!.token);
    }
  });

  return {
    sent: reponse.successCount,
    failed: reponse.failureCount,
    invalidTokens: invalides,
    simulated: false,
  };
}

/**
 * Messages SANS notification (données seules), pour Android : c'est l'app
 * qui affiche — et met à jour sur place — sa notification de suivi. Une
 * notification classique, elle, s'empilerait à chaque étape.
 *
 * Priorité haute : Android réveille l'app même en veille pour la mettre à
 * jour. Une heure de validité : au-delà, l'étape est dépassée.
 */
export async function sendData(messages: Array<{ token: string; data: Record<string, string> }>): Promise<PushResult> {
  const valides = messages.filter((m) => m.token.length > 0);
  const app = firebaseApp();
  if (!app || valides.length === 0) {
    return { sent: 0, failed: 0, invalidTokens: [], simulated: !app };
  }
  const reponse = await getMessaging(app).sendEach(
    valides.map((message) => ({
      token: message.token,
      data: message.data,
      android: { priority: 'high' as const, ttl: 60 * 60 * 1000 },
    })),
  );
  const invalides: string[] = [];
  reponse.responses.forEach((resultat, index) => {
    const code = (resultat.error as { code?: string } | undefined)?.code ?? '';
    if (
      code === 'messaging/registration-token-not-registered' ||
      code === 'messaging/invalid-registration-token'
    ) {
      invalides.push(valides[index]!.token);
    }
  });
  return { sent: reponse.successCount, failed: reponse.failureCount, invalidTokens: invalides, simulated: false };
}
