import { env } from '../config/env.js';

/**
 * Livraison de l'OTP par WhatsApp Cloud API (Meta).
 *
 * Supabase Auth génère le code, gère l'expiration, le rate-limit et la session.
 * Ce module ne fait que le transport — c'est toute la raison d'utiliser le Send
 * SMS Hook plutôt qu'un flux OTP maison : on ne réimplémente pas de la
 * sécurité d'authentification.
 *
 * Le template Meta doit être de catégorie AUTHENTICATION, avec un bouton
 * « copier le code ». Meta exige alors que le code soit passé DEUX fois : une
 * fois dans le corps, une fois dans le paramètre du bouton. Un seul des deux
 * et l'envoi est rejeté.
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
        {
          type: 'button',
          sub_type: 'url',
          index: '0',
          parameters: [{ type: 'text', text: code }],
        },
      ],
    },
  };

  // Le hook Supabase attend une réponse rapide : au-delà, l'utilisateur voit
  // une erreur de connexion. On coupe court plutôt que de le laisser attendre.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);

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
