import { env } from '../config/env.js';

/**
 * Livraison de l'OTP par WhatsApp Cloud API (Meta).
 *
 * Supabase Auth génère le code, gère l'expiration, le rate-limit et la session.
 * Ce module ne fait que le transport — c'est toute la raison d'utiliser le Send
 * SMS Hook plutôt qu'un flux OTP maison : on ne réimplémente pas de la
 * sécurité d'authentification.
 *
 * Le modèle Meta et sa forme d'envoi doivent s'accorder exactement, et c'est
 * la source d'échec la plus fréquente ici :
 *
 *   catégorie AUTHENTICATION → bouton « copier le code » obligatoire, et le
 *   code passe DEUX fois, dans le corps et dans le paramètre du bouton ;
 *
 *   catégorie UTILITY → le plus souvent aucun bouton, et joindre un
 *   composant bouton fait rejeter l'envoi.
 *
 * `WHATSAPP_TEMPLATE_BUTTON` accorde les deux. Se tromper ne casse rien au
 * démarrage : le code n'arrive simplement jamais, et l'utilisateur reste
 * bloqué sur l'écran de connexion sans savoir pourquoi.
 */

export class OtpDeliveryError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'OtpDeliveryError';
  }
}

/**
 * Normalise un numéro au format attendu par Meta : chiffres uniquement,
 * indicatif pays compris, sans « + » ni séparateurs.
 * Supabase fournit déjà le numéro en E.164.
 */
export function toWhatsAppNumber(phone: string): string {
  const digits = phone.replace(/\D/g, '');
  if (digits.length < 8) {
    throw new OtpDeliveryError(`Numéro invalide : ${phone}`, 400);
  }
  return digits;
}

export interface OtpMessage {
  phone: string;
  code: string;
}

/** Composant bouton correspondant au modèle configuré, ou aucun. */
function boutonDuModele(code: string): Record<string, unknown>[] {
  switch (env.WHATSAPP_TEMPLATE_BUTTON) {
    case 'copy_code':
      return [
        {
          type: 'button',
          sub_type: 'copy_code',
          index: '0',
          parameters: [{ type: 'coupon_code', coupon_code: code }],
        },
      ];
    case 'url':
      return [
        { type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: code }] },
      ];
    default:
      return [];
  }
}

async function sendViaWhatsApp({ phone, code }: OtpMessage): Promise<void> {
  const url = `https://graph.facebook.com/${env.WHATSAPP_GRAPH_VERSION}/${env.WHATSAPP_PHONE_NUMBER_ID}/messages`;

  const body = {
    messaging_product: 'whatsapp',
    recipient_type: 'individual',
    to: toWhatsAppNumber(phone),
    type: 'template',
    template: {
      name: env.WHATSAPP_TEMPLATE_NAME,
      language: { code: env.WHATSAPP_TEMPLATE_LOCALE },
      components: [
        {
          type: 'body',
          parameters: [{ type: 'text', text: code }],
        },
        // Le bouton s'accorde au modèle approuvé chez Meta, et à rien
        // d'autre. Un modèle utilitaire n'en a le plus souvent aucun :
        // joindre un composant bouton ferait refuser l'envoi, et le code ne
        // partirait jamais. Un modèle d'authentification, lui, exige
        // `copy_code` avec un paramètre `coupon_code` — pas un texte.
        ...boutonDuModele(code),
      ],
    },
  };

  // Budget total, tous essais compris.
  //
  // Le hook Supabase attend une réponse rapide : dépasser son délai le ferait
  // rejouer l'appel de son côté, et le client recevrait deux codes — dont un
  // seul valable. On préfère abandonner franchement dans les temps.
  const echeance = Date.now() + 4500;
  let derniere: OtpDeliveryError | null = null;

  for (let essai = 1; essai <= 2; essai++) {
    const restant = echeance - Date.now();
    // Moins d'une seconde : un essai de plus n'aboutirait pas, il ne ferait
    // que retarder le message d'erreur.
    if (restant < 1000) break;

    try {
      await tenterEnvoi(url, body, Math.min(restant, 3000));
      return;
    } catch (cause) {
      derniere = cause as OtpDeliveryError;
      if (!vautLaPeineDeReessayer(derniere)) throw derniere;
      await new Promise((r) => setTimeout(r, 200));
    }
  }

  throw derniere ?? new OtpDeliveryError("Échec de l'envoi WhatsApp", 502);
}

/**
 * Faut-il retenter après cet échec ?
 *
 * Le critère n'est pas « est-ce transitoire » mais « le message a-t-il pu
 * partir malgré l'erreur ». Un code envoyé deux fois est déroutant : le
 * premier reçu n'est plus valable, et le client saisit celui qu'il a lu en
 * premier.
 *
 *  502 — la connexion n'a pas abouti, rien n'est parti. On retente.
 *  5xx — Meta a répondu en erreur, le message n'a pas été accepté. On retente.
 *  504 — NOTRE délai a expiré. La requête peut très bien être arrivée chez
 *        Meta : retenter risquerait un doublon. On abandonne.
 *  4xx — modèle inconnu, numéro invalide, jeton expiré. Retenter donnerait
 *        exactement la même réponse, une seconde plus tard.
 */
export function vautLaPeineDeReessayer(erreur: OtpDeliveryError): boolean {
  if (erreur.status === 504) return false;
  return erreur.status === 502 || erreur.status >= 500;
}

/** Un envoi, avec son propre délai. */
async function tenterEnvoi(
  url: string,
  body: unknown,
  delaiMs: number,
): Promise<void> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), delaiMs);

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.WHATSAPP_ACCESS_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    if (!response.ok) {
      const details: unknown = await response.json().catch(() => null);
      throw new OtpDeliveryError(
        `WhatsApp Cloud API a refusé l'envoi (HTTP ${response.status})`,
        response.status,
        details,
      );
    }
  } catch (error) {
    if (error instanceof OtpDeliveryError) throw error;
    if (error instanceof Error && error.name === 'AbortError') {
      throw new OtpDeliveryError("Délai dépassé à l'envoi WhatsApp", 504);
    }
    throw new OtpDeliveryError(
      error instanceof Error ? error.message : "Échec de l'envoi WhatsApp",
      502,
    );
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Canal de développement. Interdit en production par config/env.ts : un code
 * de connexion dans les logs est lisible par quiconque a accès à Railway.
 */
function sendViaLog({ phone, code }: OtpMessage): void {
  // eslint-disable-next-line no-console
  console.info(`[otp] ${phone} → ${code}`);
}

/**
 * Point d'entrée unique. Ajouter un canal de secours (SMS pour les numéros
 * sans WhatsApp) ne touche que ce fichier et la variable OTP_CHANNEL.
 */
export async function deliverOtp(message: OtpMessage): Promise<void> {
  switch (env.OTP_CHANNEL) {
    case 'whatsapp':
      await sendViaWhatsApp(message);
      return;
    case 'log':
      sendViaLog(message);
      return;
  }
}
