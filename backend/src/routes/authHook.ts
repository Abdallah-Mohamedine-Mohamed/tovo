import type { FastifyInstance } from 'fastify';
import { Webhook } from 'standardwebhooks';
import { z } from 'zod';
import { env } from '../config/env.js';
import { deliverOtp, OtpDeliveryError } from '../services/whatsapp.js';

/**
 * Send SMS Hook de Supabase Auth.
 *
 * Supabase appelle cette route quand un utilisateur demande un code de
 * connexion. Le corps contient le code déjà généré ; notre seul travail est de
 * le livrer. Aucune génération, aucun stockage, aucune vérification côté Tovo :
 * GoTrue reste seul maître de l'expiration, du rate-limit et de la session.
 *
 * Le secret est au format « v1,whsec_… » dans le dashboard ; la librairie
 * standardwebhooks attend la partie base64 seule.
 */

const payloadSchema = z.object({
  user: z.object({
    id: z.string().uuid(),
    phone: z.string().min(6),
  }),
  sms: z.object({
    otp: z.string().min(4),
  }),
});

const webhook = env.AUTH_HOOK_SECRET
  ? new Webhook(env.AUTH_HOOK_SECRET.replace(/^v1,whsec_/, ''))
  : null;

export async function authHookRoutes(app: FastifyInstance): Promise<void> {
  if (!webhook) {
    app.log.warn('AUTH_HOOK_SECRET absent : /hooks/auth/send-sms répondra 503.');
  }

  app.post('/hooks/auth/send-sms', async (request, reply) => {
    // Mieux vaut refuser franchement que d'accepter un appel non vérifié :
    // sans secret, n'importe qui déclencherait des envois à nos frais.
    if (!webhook) {
      return reply.code(503).send({ error: 'hook auth non configuré' });
    }

    if (!request.rawBody) {
      return reply.code(400).send({ error: 'corps de requête illisible' });
    }

    // Sans cette vérification, n'importe qui pourrait déclencher des envois
    // WhatsApp à nos frais, et se faire livrer un OTP arbitraire.
    try {
      webhook.verify(request.rawBody, {
        'webhook-id': String(request.headers['webhook-id'] ?? ''),
        'webhook-timestamp': String(request.headers['webhook-timestamp'] ?? ''),
        'webhook-signature': String(request.headers['webhook-signature'] ?? ''),
      });
    } catch {
      request.log.warn({ ip: request.ip }, 'signature de hook auth invalide');
      return reply.code(401).send({ error: 'signature invalide' });
    }

    const parsed = payloadSchema.safeParse(request.body);
    if (!parsed.success) {
      request.log.error({ issues: parsed.error.issues }, 'payload de hook auth inattendu');
      return reply.code(400).send({ error: 'payload invalide' });
    }

    const { user, sms } = parsed.data;

    try {
      await deliverOtp({ phone: user.phone, code: sms.otp });
    } catch (error) {
      // Ne jamais journaliser sms.otp : ce serait remettre dans les logs ce
      // qu'on cherche justement à ne pas y mettre.
      const status = error instanceof OtpDeliveryError ? error.status : 502;
      const details = error instanceof OtpDeliveryError ? error.details : undefined;
      request.log.error({ userId: user.id, status, details }, "échec de livraison de l'OTP");

      // Le format d'erreur attendu par GoTrue : il le remonte tel quel au
      // client, qui peut proposer un autre canal.
      return reply.code(500).send({
        error: {
          http_code: status,
          message: "Impossible d'envoyer le code de vérification pour le moment.",
        },
      });
    }

    request.log.info({ userId: user.id, channel: env.OTP_CHANNEL }, 'OTP livré');
    return reply.code(200).send({});
  });
}
